import Foundation
import os
import CaptureCore
import LocalRepository

public struct DownloadResult: Sendable, Equatable {
    public var downloaded: Int
    public var skipped: Int
    public var failed: Int
    /// The last failure or stop reason, if any.
    public var code: String?

    public init(downloaded: Int, skipped: Int, failed: Int, code: String?) {
        self.downloaded = downloaded
        self.skipped = skipped
        self.failed = failed
        self.code = code
    }
}

/// "Download from <destination>" (design §4.5): brings complete remote captures from a recent window onto
/// this phone in light form. Each capture's `metadata.json`, `complete.json` and attachments at or under
/// the light limit are downloaded into staging and validated by the reader algorithm before the package
/// moves into `captures/`; larger attachments stay in the destination only, recorded as trimmed with the
/// size and hash from the metadata. A downloaded capture is indexed with a `synced` job, so it is never
/// uploaded again, and its device and server enrichment documents are imported. A capture that fails
/// validation is skipped and counted, never half-indexed. Codes are fixed strings; nothing here logs
/// content, paths or account details.
public final class RemoteDownloader: Sendable {
    public static let defaultLightAttachmentLimit: Int64 = 10 * 1024 * 1024
    /// `metadata.json` and `complete.json` are small; a larger one is not a package Hippo wrote.
    public let maxPackageDocumentBytes: Int64 = 1_048_576
    /// Enrichment caps, the same as a gold pull's (`GoldPuller`).
    public let maxDocumentBytes: Int64 = 1_048_576
    public let maxAssetBytes: Int64 = 5_242_880
    public let maxAssetsPerDocument = 32
    public let maxDocumentAssetBytes: Int64 = 52_428_800
    public let lightAttachmentLimit: Int64
    static let thumbnailPixelSize = 640

    private static let osLog = Logger(subsystem: "com.jorgeper.hippo", category: "download")

    private let layout: StoreLayout
    private let index: CaptureIndex
    private let jobs: JobStore
    private let destinations: DestinationStore
    private let remoteState: RemoteStateStore
    private let trims: TrimStore
    private let enrichments: EnrichmentStore
    private let enrichmentTasks: EnrichmentTaskStore
    private let adapterFor: @Sendable (Destination) throws -> any StorageAdapter
    private let listing: RemoteListing
    private let now: @Sendable () -> Date
    private let log: ActivityLog?

    public init(layout: StoreLayout, index: CaptureIndex, jobs: JobStore, destinations: DestinationStore,
                remoteState: RemoteStateStore, trims: TrimStore, enrichments: EnrichmentStore,
                enrichmentTasks: EnrichmentTaskStore,
                adapterFor: @escaping @Sendable (Destination) throws -> any StorageAdapter,
                lightAttachmentLimit: Int64 = defaultLightAttachmentLimit, calendar: Calendar = .current,
                now: @escaping @Sendable () -> Date = Date.init, log: ActivityLog? = nil) {
        self.layout = layout
        self.index = index
        self.jobs = jobs
        self.destinations = destinations
        self.remoteState = remoteState
        self.trims = trims
        self.enrichments = enrichments
        self.enrichmentTasks = enrichmentTasks
        self.adapterFor = adapterFor
        self.lightAttachmentLimit = lightAttachmentLimit
        listing = RemoteListing(calendar: calendar, lightAttachmentLimit: lightAttachmentLimit)
        self.now = now
        self.log = log
    }

    // MARK: Estimate

    /// Lists the window's `captures/YYYY/MM` folders in the active destination (all of `captures/` for
    /// everything) and returns the complete captures that aren't indexed here and have no pending remote
    /// delete. Captures removed with "Delete from iPhone" are counted, and listed only when included.
    /// Newest folder first. The window is checked against `captured_at` only when downloading; here a
    /// folder dated up to a day before it still counts.
    public func estimate(window: DownloadWindow, includeLocallyDeleted: Bool) async throws -> DownloadEstimate {
        guard let active = try destinations.active() else {
            return DownloadEstimate(candidates: [], skippedLocallyDeleted: 0, bytes: 0, count: 0)
        }
        let listed = try await listing.completeCaptures(window: window, now: now(), adapter: try adapterFor(active))
        let locallyDeleted = try remoteState.localDeletedCaptureIDs()
        var candidates: [DownloadCandidate] = []
        var skippedLocallyDeleted = 0
        for var candidate in listed {
            guard try index.relativeDirectory(captureID: candidate.captureID) == nil,
                  try !remoteState.hasTombstone(captureID: candidate.captureID) else { continue }
            if locallyDeleted.contains(candidate.captureID) {
                skippedLocallyDeleted += 1
                if !includeLocallyDeleted { continue }
                candidate.locallyDeleted = true
            }
            candidates.append(candidate)
        }
        return DownloadEstimate(candidates: candidates, skippedLocallyDeleted: skippedLocallyDeleted,
                                bytes: candidates.reduce(0) { $0 + $1.lightBytes }, count: candidates.count)
    }

    // MARK: Run

    /// Downloads each candidate in turn, reporting `progress` after each. Cancellation stops before the
    /// next capture (one in flight is dropped unless it already reached `captures/`); what was downloaded
    /// stays, so running again picks up the rest. Offline or a lost sign-in ends the run.
    public func run(_ candidates: [DownloadCandidate], window: DownloadWindow,
                    progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void) async -> DownloadResult {
        var result = DownloadResult(downloaded: 0, skipped: 0, failed: 0, code: nil)
        var dest: String?
        defer { log?.append(LogEvent(event: .downloadRun, code: result.code, count: result.downloaded, dest: dest)) }
        let destination: Destination
        let adapter: any StorageAdapter
        do {
            guard let active = try destinations.active() else { result.code = "no_destination"; return result }
            destination = active
            dest = active.providerKind
            adapter = try adapterFor(active)
        } catch {
            result.code = "unavailable"
            return result
        }
        let cutoff = window.seconds.map { now().addingTimeInterval(-$0) }
        progress(0, candidates.count)
        for (offset, candidate) in candidates.enumerated() {
            if Task.isCancelled { result.code = "cancelled"; return result }
            let outcome = await download(candidate, cutoff: cutoff, destination: destination, adapter: adapter)
            // A malformed candidate's ID is not a capture ID and is never logged.
            let captureID = Self.isValid(candidate) ? candidate.captureID : nil
            switch outcome {
            case .downloaded:
                result.downloaded += 1
                log?.append(LogEvent(event: .downloadCapture, captureID: captureID, outcome: .ok, dest: dest))
            case .skipped(let code):
                result.skipped += 1
                log?.append(LogEvent(event: .downloadCapture, captureID: captureID, outcome: .skipped, code: code,
                                     dest: dest))
            case .failed(let code), .stop(let code):
                result.failed += 1
                result.code = code
                log?.append(LogEvent(event: .downloadCapture, captureID: captureID, outcome: .failed, code: code,
                                     dest: dest))
                if case .stop = outcome { return result }
            case .cancelled:
                result.code = "cancelled"
                return result
            }
            progress(offset + 1, candidates.count)
        }
        return result
    }

    private enum Outcome { case downloaded, skipped(String), failed(String), stop(String), cancelled }

    /// A capture that can't be downloaded; the run goes on.
    private struct Rejected: Error { var code: String }

    private static func isValid(_ c: DownloadCandidate) -> Bool {
        RemoteListing.isCaptureDirectory(c.relativeDirectory)
            && c.relativeDirectory.split(separator: "/").last.map(String.init) == c.captureID
    }

    private func download(_ c: DownloadCandidate, cutoff: Date?, destination: Destination,
                          adapter: any StorageAdapter) async -> Outcome {
        guard Self.isValid(c) else { return .failed("invalid_package") }
        do {
            if try index.relativeDirectory(captureID: c.captureID) != nil { return .skipped("already_present") }
        } catch {
            return .failed("index_failed")
        }

        let fm = FileManager.default
        let name = "download-\(UUID().uuidString)"
        let staging = layout.stagingDir.appendingPathComponent(name, isDirectory: true)
        // Held from before the directory exists until after it is removed, as a gold pull holds its own:
        // launch recovery deletes only staging whose lock it can take.
        var lock: StagingLock?
        defer {
            try? fm.removeItem(at: staging)
            lock?.release()
        }
        let work = staging.appendingPathComponent(c.captureID, isDirectory: true)
        let target = layout.packageURL(relativeDirectory: c.relativeDirectory)
        let remote = c.relativeDirectory + "/"
        let package: CommittedPackage
        let large: [Attachment]
        do {
            try fm.createDirectory(at: layout.stagingDir, withIntermediateDirectories: true)
            lock = try StagingLock.acquire(at: layout.stagingDir.appendingPathComponent("\(name).lock"))
            try fm.createDirectory(at: work, withIntermediateDirectories: true)

            // The metadata first: the window applies to `captured_at`, not to the folder's date.
            let metadataURL = work.appendingPathComponent("metadata.json")
            try await fetch(remote + "metadata.json", to: metadataURL, maxBytes: maxPackageDocumentBytes, adapter)
            guard let metadata = try? HippoJSON.decodeMetadata(Data(contentsOf: metadataURL)) else {
                throw Rejected(code: "invalid_package")
            }
            if let cutoff, metadata.capturedAt < cutoff { return .skipped("outside_window") }

            let markerURL = work.appendingPathComponent("complete.json")
            try await fetch(remote + "complete.json", to: markerURL, maxBytes: maxPackageDocumentBytes, adapter)
            large = metadata.attachments.filter { $0.byteCount > lightAttachmentLimit }
            let largePaths = Set(large.map(\.relativePath))
            // An undecodable marker downloads nothing more; the validator rejects it below.
            let marker = try? HippoJSON.decodeMarker(Data(contentsOf: markerURL))
            for entry in marker?.files ?? [] where entry.relativePath != "metadata.json"
                && !largePaths.contains(entry.relativePath) {
                // Checked before anything is written: a remote manifest must not place files outside `work`.
                guard (try? PackagePath.validateRelative(entry.relativePath)) != nil else {
                    throw Rejected(code: "invalid_package")
                }
                let local = work.appendingPathComponent(entry.relativePath)
                try fm.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await fetch(remote + entry.relativePath, to: local, maxBytes: max(entry.byteCount, 0), adapter)
            }

            switch PackageValidator.validate(directory: work, trimmed: largePaths) {
            case .complete(let validated, _):
                guard Self.expectedDirectory(validated) == c.relativeDirectory else {
                    throw Rejected(code: "invalid_package")
                }
            case .incomplete: throw Rejected(code: "incomplete_package")
            case .corrupt, .unsupportedSchema: throw Rejected(code: "invalid_package")
            }

            if fm.fileExists(atPath: target.path) { return .skipped("already_present") }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: work, to: target)
            // From here the capture is on this phone: cancellation no longer drops it.
            guard let loaded = CommittedPackage.load(directory: target, layout: layout, trimmed: largePaths) else {
                try? fm.moveItem(at: target, to: work)
                throw Rejected(code: "invalid_package")
            }
            do {
                _ = try index.register(loaded, noteBody: loaded.noteBody())
            } catch {
                try? fm.moveItem(at: target, to: work)
                throw Rejected(code: "index_failed")
            }
            package = loaded
        } catch let rejected as Rejected {
            return .failed(rejected.code)
        } catch {
            if Task.isCancelled || error is CancellationError { return .cancelled }
            switch error as? StorageError {
            case .offline?: return .stop("offline")
            case .needsAuthentication?: return .stop("needs_authentication")
            case let e?: return .failed(GoldPuller.code(for: e))
            case nil: return .failed("download_failed")
            }
        }

        await settle(package, large: large, destination: destination, adapter: adapter, staging: staging)
        return .downloaded
    }

    /// Downloads one package file. A missing or oversized file means the package is incomplete.
    private func fetch(_ path: String, to url: URL, maxBytes: Int64, _ adapter: any StorageAdapter) async throws {
        try Task.checkCancellation()
        do {
            _ = try await adapter.downloadFile(relativePath: path, to: url, maxBytes: maxBytes)
        } catch StorageError.permanent {
            throw Rejected(code: "incomplete_package")
        }
    }

    /// `captures/YYYY/MM/DD/<id>` from the metadata's recorded local date, never from time-zone math.
    private static func expectedDirectory(_ m: CaptureMetadata) -> String? {
        let parts = m.localDatetime.prefix(10).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let mo = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        return PackagePath.captureDirectory(captureID: m.captureID,
                                            localDate: DateComponents(year: y, month: mo, day: d))
    }

    /// The bookkeeping of a capture that is now indexed: synced job, trimmed records and thumbnails, the
    /// local-delete record, then enrichment. A failure here is logged and leaves the capture downloaded.
    private func settle(_ p: CommittedPackage, large: [Attachment], destination: Destination,
                        adapter: any StorageAdapter, staging: URL) async {
        let captureID = p.metadata.captureID
        do { try jobs.insertSynced(captureID: captureID, destinationID: destination.id) } catch {
            Self.osLog.error("\("download_job_failed", privacy: .public)")
        }
        for a in large {
            do {
                try trims.record(TrimmedAttachment(captureID: captureID, attachmentID: a.attachmentID,
                                                   relativePath: a.relativePath, byteCount: a.byteCount,
                                                   sha256: a.sha256, destinationID: destination.id, state: .trimmed,
                                                   trimmedAt: now()))
            } catch {
                Self.osLog.error("\("download_trim_record_failed", privacy: .public)")
            }
            // The ID names a local file, so it must be a plain UUID.
            guard adapter.capabilities.supportsThumbnails, UUID(uuidString: a.attachmentID) != nil,
                  let jpeg = try? await adapter.thumbnail(relativePath: p.relativeDirectory + "/" + a.relativePath,
                                                          maxPixelSize: Self.thumbnailPixelSize) else { continue }
            try? FileManager.default.createDirectory(at: layout.thumbnailsDir, withIntermediateDirectories: true)
            try? jpeg.write(to: layout.thumbnailURL(attachmentID: a.attachmentID), options: .atomic)
        }
        do { try remoteState.removeLocalDelete(captureID: captureID) } catch {
            Self.osLog.error("\("download_local_delete_failed", privacy: .public)")
        }
        for layer in [EnrichmentLayer.device, .server] {
            do {
                try await importEnrichment(layer, package: p, destination: destination, adapter: adapter,
                                           staging: staging)
            } catch {
                Self.osLog.error("\("download_enrichment_failed", privacy: .public)")
            }
        }
    }

    // MARK: Enrichment

    private struct EnrichmentRejected: Error {}

    /// Imports the layer's remote document, if there is one, after the same checks a gold pull makes: size
    /// caps, decoding, the capture and layer it claims, and every asset's SHA-256. An imported device
    /// document counts as uploaded to the destination, and its facets become this phone's enrichment
    /// tasks at their versions and statuses, so the runner only queues kinds that are missing or outdated.
    private func importEnrichment(_ layer: EnrichmentLayer, package p: CommittedPackage, destination: Destination,
                                  adapter: any StorageAdapter, staging: URL) async throws {
        let captureID = p.metadata.captureID
        let remoteDirectory = try EnrichmentPaths.remoteDirectory(layer, packageDirectory: p.relativeDirectory)
        let documentPath = remoteDirectory + "/" + EnrichmentPaths.documentName
        guard let info = try await adapter.inspectFile(relativePath: documentPath) else { return }
        guard info.byteCount <= maxDocumentBytes else { throw EnrichmentRejected() }

        let fm = FileManager.default
        let work = staging.appendingPathComponent("enrich-\(layer.rawValue)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let documentURL = work.appendingPathComponent(EnrichmentPaths.documentName)
        _ = try await adapter.downloadFile(relativePath: documentPath, to: documentURL, maxBytes: maxDocumentBytes)
        let document = try EnrichmentJSON.decode(Data(contentsOf: documentURL))
        guard document.captureID == captureID, document.layer == layer else { throw EnrichmentRejected() }

        let assets = document.referencedAssets()
        guard assets.count <= maxAssetsPerDocument,
              assets.reduce(Int64(0), { $0 + max($1.byteCount, 0) }) <= maxDocumentAssetBytes
        else { throw EnrichmentRejected() }
        var newAssets: [String: URL] = [:]
        for asset in assets {
            guard EnrichmentPaths.isValidAssetPath(asset.relativePath), asset.byteCount >= 0,
                  asset.byteCount <= maxAssetBytes else { throw EnrichmentRejected() }
            let local = work.appendingPathComponent(asset.relativePath)
            try fm.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try await adapter.downloadFile(relativePath: remoteDirectory + "/" + asset.relativePath, to: local,
                                               maxBytes: maxAssetBytes)
            guard let digest = try? StreamingHasher.digest(of: local), digest.sha256 == asset.sha256,
                  digest.byteCount == asset.byteCount else { throw EnrichmentRejected() }
            newAssets[asset.relativePath] = local
        }
        try enrichments.write(document, newAssets: newAssets)

        guard layer == .device else { return }
        let written = layout.enrichmentDirectory(.device, captureID: captureID)
            .appendingPathComponent(EnrichmentPaths.documentName)
        try enrichments.markUploaded(captureID: captureID, destinationID: destination.id,
                                     revision: try StreamingHasher.digest(of: written).sha256, now: now())
        for (key, facet) in document.facets {
            try enrichmentTasks.set(captureID: captureID, kind: FacetKind(rawValue: key), version: facet.version,
                                    status: facet.status.rawValue, now: now())
        }
    }
}
