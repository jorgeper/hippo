import Foundation
import CaptureCore
import LocalRepository

/// How old and how large an attachment must be before "Save space" removes it from this phone.
public struct SpaceSaveOptions: Sendable, Equatable {
    public var olderThan: TimeInterval
    public var largerThan: Int64

    public init(olderThan: TimeInterval, largerThan: Int64) {
        self.olderThan = olderThan
        self.largerThan = largerThan
    }

    /// 1 week, 1 month, 3 months, 1 year.
    public static let ageSteps: [TimeInterval] = [7, 30, 90, 365].map { $0 * 86_400 }
    /// 1, 10, 50 and 100 MB (decimal).
    public static let sizeSteps: [Int64] = [1, 10, 50, 100].map { $0 * 1_000_000 }
    public static let `default` = SpaceSaveOptions(olderThan: 30 * 86_400, largerThan: 10 * 1_000_000)
}

public struct TrimCandidate: Sendable, Equatable {
    public var captureID: String
    public var attachment: Attachment
    public var relativeDirectory: String
    public var destinationID: String

    public init(captureID: String, attachment: Attachment, relativeDirectory: String, destinationID: String) {
        self.captureID = captureID
        self.attachment = attachment
        self.relativeDirectory = relativeDirectory
        self.destinationID = destinationID
    }
}

public struct SpaceSaveEstimate: Sendable, Equatable {
    public var captures: Int
    public var files: Int
    public var bytes: Int64

    public init(captures: Int, files: Int, bytes: Int64) {
        self.captures = captures
        self.files = files
        self.bytes = bytes
    }
}

public struct SpaceSaveResult: Sendable, Equatable {
    public var trimmed: Int
    public var bytes: Int64
    public var skipped: Int
    /// The last skip or stop reason, if any.
    public var code: String?

    public init(trimmed: Int, bytes: Int64, skipped: Int, code: String?) {
        self.trimmed = trimmed
        self.bytes = bytes
        self.skipped = skipped
        self.code = code
    }
}

/// "Save space" (design §4.4): removes large, old attachments of captures whose upload is verified in the
/// active destination, keeping a thumbnail and the trimmed state in the store. The phone never trims a file
/// without a fresh check that the destination holds the same bytes.
public final class SpaceSaver: Sendable {
    private let layout: StoreLayout
    private let index: CaptureIndex
    private let jobs: JobStore
    private let destinations: DestinationStore
    private let trims: TrimStore
    private let adapterFor: @Sendable (Destination) throws -> any StorageAdapter
    private let now: @Sendable () -> Date
    private let log: ActivityLog?

    public init(layout: StoreLayout, index: CaptureIndex, jobs: JobStore, destinations: DestinationStore,
                trims: TrimStore, adapterFor: @escaping @Sendable (Destination) throws -> any StorageAdapter,
                now: @escaping @Sendable () -> Date = Date.init, log: ActivityLog? = nil) {
        self.layout = layout
        self.index = index
        self.jobs = jobs
        self.destinations = destinations
        self.trims = trims
        self.adapterFor = adapterFor
        self.now = now
        self.log = log
    }

    /// Attachments eligible now: of captures fully synced to the active destination and older than the
    /// cutoff, larger than `largerThan`, not trimmed yet and still on this phone. Oldest capture first,
    /// attachments in manifest order.
    public func candidates(_ o: SpaceSaveOptions) throws -> [TrimCandidate] {
        guard let active = try destinations.active() else { return [] }
        let cutoff = now().addingTimeInterval(-o.olderThan)
        var result: [TrimCandidate] = []
        for capture in try index.capturesSyncedBefore(destinationID: active.id, cutoff: cutoff) {
            guard let metadata = try? index.metadata(captureID: capture.captureID, layout: layout) else { continue }
            let trimmed = try trims.trimmedPaths(captureID: capture.captureID)
            let package = layout.packageURL(relativeDirectory: capture.relativeDirectory)
            for a in metadata.attachments where a.byteCount > o.largerThan && !trimmed.contains(a.relativePath)
                && FileManager.default.fileExists(atPath: package.appendingPathComponent(a.relativePath).path) {
                result.append(TrimCandidate(captureID: capture.captureID, attachment: a,
                                            relativeDirectory: capture.relativeDirectory, destinationID: active.id))
            }
        }
        return result
    }

    public func estimate(_ o: SpaceSaveOptions) throws -> SpaceSaveEstimate {
        let all = try candidates(o)
        return SpaceSaveEstimate(captures: Set(all.map(\.captureID)).count, files: all.count,
                                 bytes: all.reduce(0) { $0 + $1.attachment.byteCount })
    }

    public func run(_ o: SpaceSaveOptions,
                    progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void) async -> SpaceSaveResult {
        var result = SpaceSaveResult(trimmed: 0, bytes: 0, skipped: 0, code: nil)
        var dest: String?
        defer {
            log?.append(LogEvent(event: .trimRun, code: result.code, count: result.trimmed, dest: dest,
                                 bytes: result.bytes))
        }
        let all: [TrimCandidate]
        let adapter: any StorageAdapter
        do {
            guard let active = try destinations.active() else { result.code = "no_destination"; return result }
            dest = active.providerKind
            all = try candidates(o)
            adapter = try adapterFor(active)
        } catch {
            result.code = "unavailable"
            return result
        }
        progress(0, all.count)
        for (offset, c) in all.enumerated() {
            if Task.isCancelled { result.code = "cancelled"; return result }
            switch await trim(c, adapter: adapter) {
            case .trimmed:
                result.trimmed += 1
                result.bytes += c.attachment.byteCount
            case .skipped(let code):
                result.skipped += 1
                result.code = code
            case .stop(let code):
                result.code = code
                return result
            }
            progress(offset + 1, all.count)
        }
        return result
    }

    private enum Outcome { case trimmed, skipped(String), stop(String) }

    private func localURL(_ c: TrimCandidate) -> URL {
        layout.packageURL(relativeDirectory: c.relativeDirectory).appendingPathComponent(c.attachment.relativePath)
    }

    /// The capture is still indexed and its file is still here.
    private func isPresent(_ c: TrimCandidate) -> Bool {
        ((try? index.relativeDirectory(captureID: c.captureID)) ?? nil) != nil
            && FileManager.default.fileExists(atPath: localURL(c).path)
    }

    private func trim(_ c: TrimCandidate, adapter: any StorageAdapter) async -> Outcome {
        let a = c.attachment
        guard isPresent(c) else { return .skipped("capture_gone") }
        do {
            guard let remote = try await adapter.inspectFile(relativePath: c.relativeDirectory + "/" + a.relativePath)
            else { return .skipped("remote_missing") }
            guard remote.byteCount == a.byteCount else { return .skipped("remote_mismatch") }
            guard isPresent(c) else { return .skipped("capture_gone") }
            guard try await adapter.verify(remote: remote, localURL: localURL(c),
                                           expected: FileIntegrity(byteCount: a.byteCount, sha256: a.sha256)) != nil
            else { return .skipped("remote_mismatch") }
            // The capture may have been deleted while the remote copy was checked.
            guard isPresent(c) else { return .skipped("capture_gone") }

            // The thumbnailer returns nil for anything but images and videos.
            if let jpeg = await LocalThumbnailer.jpeg(for: localURL(c), uti: a.uti, maxPixelSize: 640) {
                try? FileManager.default.createDirectory(at: layout.thumbnailsDir, withIntermediateDirectories: true)
                try? jpeg.write(to: layout.thumbnailURL(attachmentID: a.attachmentID), options: .atomic)
            }
            try trims.record(TrimmedAttachment(captureID: c.captureID, attachmentID: a.attachmentID,
                                               relativePath: a.relativePath, byteCount: a.byteCount, sha256: a.sha256,
                                               destinationID: c.destinationID, state: .trimmed, trimmedAt: now()))
            do {
                try FileManager.default.removeItem(at: localURL(c))
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // Already gone: the record stands.
            } catch {
                // Still here: it was not trimmed.
                try? trims.remove(captureID: c.captureID, attachmentID: a.attachmentID)
                return .skipped("remove_failed")
            }
            return .trimmed
        } catch StorageError.needsAuthentication {
            return .stop("needs_authentication")
        } catch StorageError.offline {
            return .stop("offline")
        } catch {
            if Task.isCancelled || error is CancellationError { return .stop("cancelled") }
            if !isPresent(c) { return .skipped("capture_gone") }
            if let e = error as? StorageError { return .skipped(GoldPuller.code(for: e)) }
            return .skipped("trim_failed")
        }
    }
}
