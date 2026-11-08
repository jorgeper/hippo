import Foundation
import os
import CaptureCore
import LocalRepository

public struct GoldPullResult: Sendable, Equatable {
    public var applied: Int
    public var removed: Int
    public var ignored: Int
    public var skipped: Int
    /// An adapter error that ended the pull, else the last per-document skip or mismatch code, else nil.
    public var code: String?

    public init(applied: Int = 0, removed: Int = 0, ignored: Int = 0, skipped: Int = 0, code: String? = nil) {
        self.applied = applied; self.removed = removed; self.ignored = ignored; self.skipped = skipped
        self.code = code
    }
}

/// Pulls server-produced (gold) enrichment from the active destination's `enrichments/server/` tree into
/// the local server layer (design §6.5). Documents are size-capped, decoded and checked against the path
/// they came from, and every referenced asset is verified by SHA-256 before anything is written, so the
/// local layer only ever holds complete, checked documents. A document that fails a check is skipped and
/// not retried: the cursor moves past it. Bronze and the device layer are never touched. Codes are fixed
/// strings; nothing here logs or records content, paths, URLs or IDs.
public final class GoldPuller: Sendable {
    public static let prefix = "enrichments/server/"
    public let maxDocumentBytes: Int64 = 1_048_576
    public let maxAssetBytes: Int64 = 5_242_880
    /// Changes processed per pass before the puller stops listing new pages (soft: the page in hand is
    /// finished). Each asset downloaded counts as one change.
    public let softChangeLimit: Int
    /// Per document, at most this many referenced assets and this many declared asset bytes in total;
    /// a document over either is skipped (`gold_too_large`) before any asset is downloaded.
    public let maxAssetsPerDocument = 32
    public let maxDocumentAssetBytes: Int64 = 52_428_800

    private static let log = Logger(subsystem: "com.jorgeper.hippo", category: "enrichment")

    private let layout: StoreLayout
    private let index: CaptureIndex
    private let destinations: DestinationStore
    private let enrichments: EnrichmentStore
    private let adapterFor: @Sendable (Destination) throws -> any StorageAdapter
    private let now: @Sendable () -> Date
    private let log: ActivityLog?

    public init(layout: StoreLayout, index: CaptureIndex, destinations: DestinationStore, enrichments: EnrichmentStore,
                adapterFor: @escaping @Sendable (Destination) throws -> any StorageAdapter,
                softChangeLimit: Int = 200, now: @escaping @Sendable () -> Date = Date.init,
                log: ActivityLog? = nil) {
        self.log = log
        self.softChangeLimit = softChangeLimit
        self.layout = layout
        self.index = index
        self.destinations = destinations
        self.enrichments = enrichments
        self.adapterFor = adapterFor
        self.now = now
    }

    /// One pass over the changes since the saved cursor. Cancellation ends it at once and records nothing.
    public func pull() async -> GoldPullResult {
        var result = GoldPullResult()
        guard !Task.isCancelled, let destination = try? destinations.active() else { return result }

        let name = "gold-\(UUID().uuidString)"
        let staging = layout.stagingDir.appendingPathComponent(name, isDirectory: true)
        // Held from before the directory exists until after it is removed, as a package writer holds its
        // own: launch recovery deletes only staging whose lock it can take, so it leaves a live pull alone
        // and still sweeps one a crash left behind.
        var lock: StagingLock?
        defer {
            try? FileManager.default.removeItem(at: staging)
            lock?.release()
        }

        var itemCode: String?
        var endCode: String?
        var resetUsed = false
        do {
            let adapter = try adapterFor(destination)
            try FileManager.default.createDirectory(at: layout.stagingDir, withIntermediateDirectories: true)
            lock = try StagingLock.acquire(at: layout.stagingDir.appendingPathComponent("\(name).lock"))
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            var cursor = try enrichments.goldCursor(destinationID: destination.id)
            var processed = 0
            var seen = Seen()
            while true {
                try Task.checkCancellation()
                let page: ChangePage
                do {
                    page = try await adapter.listChanges(under: Self.prefix, cursor: cursor)
                } catch StorageError.cursorReset {
                    if resetUsed { endCode = "cursor_reset"; break }
                    resetUsed = true
                    cursor = nil
                    continue
                }
                seen = Seen()
                for change in page.changes {
                    try Task.checkCancellation()
                    processed += 1
                    if let code = try await handle(change, adapter: adapter, staging: staging, result: &result, seen: &seen,
                                                   downloads: &processed) {
                        itemCode = code
                    }
                }
                try enrichments.saveGoldCursor(destinationID: destination.id, cursor: page.cursor, now: now())
                cursor = page.cursor
                if !page.hasMore || processed >= softChangeLimit { break }
            }
        } catch is CancellationError {
            return result
        } catch let error as StorageError {
            if Task.isCancelled { return result }
            endCode = Self.code(for: error)
        } catch {
            if Task.isCancelled { return result }
            Self.log.error("\("gold_pull_failed", privacy: .public)")
            endCode = "transient:internal"
        }

        result.code = endCode ?? itemCode
        do {
            try enrichments.recordGoldResult(destinationID: destination.id, code: result.code ?? "ok", now: now())
        } catch {
            Self.log.error("\("gold_record_failed", privacy: .public)")
        }
        log?.append(LogEvent(event: .goldPull, code: result.code ?? "ok", count: result.applied, on: resetUsed))
        return result
    }

    /// A per-document failure: the document is skipped and the pull goes on.
    private struct Skip: Error { var code: String }
    /// A local write failed: the pull ends with the cursor at the last saved page, so the document is retried.
    private struct WriteFailed: Error {}

    /// Directories whose document was already tried on the current page, so each is processed at most once.
    private struct Seen { var attempted: Set<String> = [] }

    /// The change's path if it is a server-layer file of an indexed capture, in the capture's own date
    /// partition; anything else is not ours to apply.
    private func target(_ path: String) throws -> RemoteEnrichmentPath? {
        guard let parsed = EnrichmentPaths.parseRemote(path), parsed.layer == .server,
              let packageDirectory = try index.relativeDirectory(captureID: parsed.captureID),
              (try? EnrichmentPaths.remoteDirectory(.server, packageDirectory: packageDirectory)) == parsed.directory
        else { return nil }
        return parsed
    }

    /// Applies one change. Returns a code when the change was skipped or applied with a mismatch.
    /// Each asset downloaded adds one to `downloads` (the pass's processed count).
    private func handle(_ change: RemoteChange, adapter: any StorageAdapter, staging: URL,
                        result: inout GoldPullResult, seen: inout Seen, downloads: inout Int) async throws -> String? {
        switch change {
        case .deleted(let path):
            guard let parsed = try target(path), parsed.file == .document else {
                result.ignored += 1
                return nil
            }
            let dir = layout.enrichmentDirectory(.server, captureID: parsed.captureID)
            let existed = FileManager.default.fileExists(atPath: dir.path)
            try enrichments.removeLayer(.server, captureID: parsed.captureID)
            if existed {
                result.removed += 1
                log?.append(LogEvent(event: .goldRemoved, captureID: parsed.captureID))
            } else { result.ignored += 1 }
            seen.attempted.remove(parsed.directory)
            return nil
        case .upserted(let info):
            guard let parsed = try target(info.relativePath) else {
                result.ignored += 1
                return nil
            }
            var documentInfo = info
            switch parsed.file {
            case .document:
                if !seen.attempted.insert(parsed.directory).inserted { result.ignored += 1; return nil }
            case .asset(let name):
                // Files can arrive in any order: an asset we don't have yet may complete a document that was
                // skipped earlier (or not listed yet). Fetch that document once.
                let local = layout.enrichmentDirectory(.server, captureID: parsed.captureID)
                    .appendingPathComponent("assets/" + name)
                guard !seen.attempted.contains(parsed.directory),
                      !FileManager.default.fileExists(atPath: local.path) else {
                    result.ignored += 1
                    return nil
                }
                seen.attempted.insert(parsed.directory)
                guard let document = try await adapter.inspectFile(
                    relativePath: parsed.directory + "/" + EnrichmentPaths.documentName) else {
                    result.ignored += 1
                    return nil
                }
                documentInfo = document
            }
            let work = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: work) }
            do {
                let code = try await apply(documentInfo, parsed: parsed, adapter: adapter, work: work,
                                           downloads: &downloads)
                result.applied += 1
                log?.append(LogEvent(event: .goldApplied, captureID: parsed.captureID))
                return code
            } catch let skip as Skip {
                result.skipped += 1
                log?.append(LogEvent(event: .goldSkipped, captureID: parsed.captureID, code: skip.code))
                return skip.code
            } catch EnrichmentStoreError.notIndexed {
                result.ignored += 1
                return nil
            } catch is WriteFailed {
                throw StorageError.transient(code: "gold_write_failed")
            }
        }
    }

    private func apply(_ info: RemoteFileInfo, parsed: RemoteEnrichmentPath, adapter: any StorageAdapter,
                       work: URL, downloads: inout Int) async throws -> String? {
        guard info.byteCount <= maxDocumentBytes else { throw Skip(code: "gold_too_large") }
        let fm = FileManager.default
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let documentURL = work.appendingPathComponent(EnrichmentPaths.documentName)
        do {
            let got = try await adapter.downloadFile(relativePath: info.relativePath, to: documentURL,
                                                     maxBytes: maxDocumentBytes)
            let size = (try? fm.attributesOfItem(atPath: documentURL.path)[.size] as? Int64) ?? got.byteCount
            guard got.byteCount <= maxDocumentBytes, size <= maxDocumentBytes else { throw Skip(code: "gold_too_large") }
        } catch StorageError.permanent(let code) {
            throw Skip(code: code == "too_large" ? "gold_too_large" : "gold_missing")
        }
        let document: EnrichmentDocument
        do {
            document = try EnrichmentJSON.decode(try Data(contentsOf: documentURL))
        } catch FormatError.unsupportedSchemaVersion {
            throw Skip(code: "gold_unsupported_version")
        } catch {
            throw Skip(code: "gold_invalid")
        }
        guard document.captureID == parsed.captureID, document.layer == .server else { throw Skip(code: "gold_mismatch") }

        // Bounded before anything is fetched: one document can't make the phone download without limit.
        let assets = document.referencedAssets()
        guard assets.count <= maxAssetsPerDocument,
              assets.reduce(Int64(0), { $0 + max($1.byteCount, 0) }) <= maxDocumentAssetBytes
        else { throw Skip(code: "gold_too_large") }

        var newAssets: [String: URL] = [:]
        for asset in assets {
            try Task.checkCancellation()
            guard EnrichmentPaths.isValidAssetPath(asset.relativePath), asset.byteCount >= 0,
                  asset.byteCount <= maxAssetBytes else { throw Skip(code: "gold_asset_invalid") }
            if localAssetMatches(asset, captureID: document.captureID) { continue }
            let local = work.appendingPathComponent(asset.relativePath)
            try fm.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            downloads += 1
            do {
                _ = try await adapter.downloadFile(relativePath: parsed.directory + "/" + asset.relativePath, to: local,
                                                   maxBytes: maxAssetBytes)
            } catch StorageError.permanent {
                throw Skip(code: "gold_asset_invalid")
            }
            guard let digest = try? StreamingHasher.digest(of: local), digest.sha256 == asset.sha256,
                  digest.byteCount == asset.byteCount else { throw Skip(code: "gold_asset_invalid") }
            newAssets[asset.relativePath] = local
        }

        try Task.checkCancellation()
        do {
            try enrichments.write(document, newAssets: newAssets)
        } catch EnrichmentStoreError.notIndexed {
            throw EnrichmentStoreError.notIndexed
        } catch {
            Self.log.error("\("gold_write_failed", privacy: .public)")
            throw WriteFailed()
        }
        // The document was made for another version of the package; it is applied all the same.
        return document.packageDigest == (try? index.packageDigest(captureID: document.captureID)) ? nil
            : "gold_digest_mismatch"
    }

    private func localAssetMatches(_ asset: AssetRef, captureID: String) -> Bool {
        let url = enrichments.assetURL(.server, captureID: captureID, asset: asset)
        guard let digest = try? StreamingHasher.digest(of: url) else { return false }
        return digest.sha256 == asset.sha256 && digest.byteCount == asset.byteCount
    }

    private func isIndexed(_ captureID: String) throws -> Bool {
        try index.packageDigest(captureID: captureID) != nil
    }

    private static func code(for error: StorageError) -> String {
        switch error {
        case .offline: "offline"
        case .transient(let code): "transient:\(code)"
        case .rateLimited: "rate_limited"
        case .checkpointExpired: "checkpoint_expired"
        case .cursorReset: "cursor_reset"
        case .needsAuthentication: "needs_authentication"
        case .quotaExceeded: "quota_exceeded"
        case .conflict: "remote_conflict"
        case .permanent(let code): "permanent:\(code)"
        }
    }
}
