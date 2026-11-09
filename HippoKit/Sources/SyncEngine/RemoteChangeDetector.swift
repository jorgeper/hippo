import Foundation
import os
import CaptureCore
import LocalRepository

public struct RemoteChangeReport: Sendable, Equatable {
    /// Captures removed from this phone because they were deleted in the destination.
    public var removed: Int
    /// Captures newly marked "changed in the destination".
    public var changed: Int
    /// Deletion candidates kept because their upload isn't verified.
    public var protected: Int
    /// Review items queued instead of applying deletes.
    public var reviewQueued: Int
    /// True when the change cursor had to be reset and the destination was listed in full.
    public var cursorReset: Bool
    /// The error that ended the run, nil when it finished.
    public var code: String?

    public init(removed: Int = 0, changed: Int = 0, protected: Int = 0, reviewQueued: Int = 0,
                cursorReset: Bool = false, code: String? = nil) {
        self.removed = removed; self.changed = changed; self.protected = protected
        self.reviewQueued = reviewQueued; self.cursorReset = cursorReset; self.code = code
    }
}

/// Applies deletes made in the active destination's `captures/` tree to this phone, and marks captures whose
/// files were removed or changed there (design §4.3). A capture is deleted remotely when its package folder
/// or its `complete.json` is gone; any other missing or different manifest file only marks it "changed".
/// Nothing is removed for a capture whose upload isn't verified, and nothing at all when one pass would
/// remove more than `maxAutoRemovals` captures or more than `maxAutoRemovalFraction` of the synced ones, when
/// the `captures/` root is gone, or after a cursor reset: those queue review items instead. Runs after
/// uploads in a sync pass. Logs carry capture IDs, fixed codes and the provider kind only.
public final class RemoteChangeDetector: Sendable {
    public static let prefix = "captures/"
    public static let maxAutoRemovals = 20
    public static let maxAutoRemovalFraction = 0.10
    /// Changes processed per pass before the detector stops listing new pages (the page in hand is finished).
    public static let softChangeLimit = 2000

    private static let markerName = "complete.json"
    private static let osLog = Logger(subsystem: "com.jorgeper.hippo", category: "remote-changes")

    private let layout: StoreLayout
    private let index: CaptureIndex
    private let jobs: JobStore
    private let remoteState: RemoteStateStore
    private let trims: TrimStore
    private let destinations: DestinationStore
    private let adapterFor: @Sendable (Destination) throws -> any StorageAdapter
    private let removeLocally: @Sendable (String) async throws -> Void
    private let now: @Sendable () -> Date
    private let log: ActivityLog?

    /// `removeLocally` removes one capture from this phone after its remote deletion (the store's
    /// `removeAfterRemoteDelete`).
    public init(layout: StoreLayout, index: CaptureIndex, jobs: JobStore, remoteState: RemoteStateStore,
                trims: TrimStore, destinations: DestinationStore,
                adapterFor: @escaping @Sendable (Destination) throws -> any StorageAdapter,
                removeLocally: @escaping @Sendable (String) async throws -> Void,
                now: @escaping @Sendable () -> Date = Date.init, log: ActivityLog? = nil) {
        self.layout = layout
        self.index = index
        self.jobs = jobs
        self.remoteState = remoteState
        self.trims = trims
        self.destinations = destinations
        self.adapterFor = adapterFor
        self.removeLocally = removeLocally
        self.now = now
        self.log = log
    }

    /// One pass over the changes since the saved cursor. The first run for a destination only saves a cursor.
    /// Pages are classified, then their cursor is saved; what the saved pages found is applied once listing
    /// stops, even when a later page fails. Cancellation returns what was done so far.
    public func run() async -> RemoteChangeReport {
        var report = RemoteChangeReport()
        guard !Task.isCancelled, let destination = try? destinations.active() else { return report }
        var stop: Error?
        do {
            let adapter = try adapterFor(destination)
            guard var cursor = try remoteState.changeCursor(destinationID: destination.id) else {
                // The first connect of this account never enumerates history.
                let latest = try await adapter.latestCursor(under: Self.prefix)
                try remoteState.saveChangeCursor(destinationID: destination.id, cursor: latest, now: now())
                return report
            }
            var pass = Pass()
            var processed = 0
            while true {
                do {
                    try Task.checkCancellation()
                    let page = try await adapter.listChanges(under: Self.prefix, cursor: cursor)
                    var next = pass
                    for change in page.changes {
                        try Task.checkCancellation()
                        processed += 1
                        try await classify(change, destination: destination, adapter: adapter, pass: &next)
                    }
                    try remoteState.saveChangeCursor(destinationID: destination.id, cursor: page.cursor, now: now())
                    pass = next
                    cursor = page.cursor
                    if !page.hasMore || processed >= Self.softChangeLimit { break }
                } catch StorageError.cursorReset {
                    try await rebaseline(destination, adapter: adapter, report: &report)
                    return report
                } catch {
                    stop = error
                    break
                }
            }
            if Task.isCancelled { return report }
            try await apply(pass, destination: destination, report: &report)
        } catch {
            stop = error
        }
        if let stop, !(stop is CancellationError), !Task.isCancelled {
            if let error = stop as? StorageError {
                report.code = GoldPuller.code(for: error)
            } else {
                Self.osLog.error("\("remote_changes_failed", privacy: .public)")
                report.code = "transient:internal"
            }
        }
        return report
    }

    // MARK: - Classification

    /// What one pass found, by capture ID.
    private struct Pass {
        var rootGone = false
        var candidates: Set<String> = []
        /// Manifest paths found missing or different.
        var changed: [String: Set<String>] = [:]
        /// Manifest paths found matching again, to clear from an existing changed record.
        var matched: [String: Set<String>] = [:]
        /// Loaded manifests (nil when the local package doesn't load), and receipts by path, per capture.
        var manifests: [String: Manifest?] = [:]
        var receipts: [String: [String: StoredReceipt]] = [:]

        mutating func markChanged(_ id: String, _ paths: some Sequence<String>) {
            for path in paths {
                changed[id, default: []].insert(path)
                matched[id]?.remove(path)
            }
        }

        mutating func markMatched(_ id: String, _ path: String) {
            changed[id]?.remove(path)
            matched[id, default: []].insert(path)
        }
    }

    private struct Manifest {
        var directoryURL: URL
        /// Every manifest file except `complete.json`, by package-relative path.
        var files: [String: FileIntegrity]
        var trimmed: Set<String>
    }

    private enum Target: Equatable {
        /// `captures` itself.
        case root
        /// `captures/YYYY`, `captures/YYYY/MM` or `captures/YYYY/MM/DD`.
        case partition(String)
        /// A capture directory `captures/YYYY/MM/DD/<uuid>`, or a path inside it (`rest`, package-relative).
        case capture(id: String, directory: String, rest: String)
    }

    private static func parse(_ path: String) -> Target? {
        var trimmed = Substring(path)
        while trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.first == "captures", !parts.contains("") else { return nil }
        for (i, width) in [4, 2, 2].enumerated() where parts.count > i + 1 {
            guard isDigits(parts[i + 1], width) else { return nil }
        }
        switch parts.count {
        case 1: return .root
        case 2...4: return .partition(String(trimmed))
        default:
            guard isLowercaseUUID(parts[4]) else { return nil }
            return .capture(id: parts[4], directory: parts[0...4].joined(separator: "/"),
                            rest: parts[5...].joined(separator: "/"))
        }
    }

    private static func isDigits(_ s: String, _ width: Int) -> Bool {
        s.utf8.count == width && s.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }

    private static func isLowercaseUUID(_ s: String) -> Bool {
        UUID(uuidString: s) != nil && s == s.lowercased()
    }

    /// The capture's ID and package-relative path when `path` is inside an indexed capture's own directory.
    private func indexedTarget(_ path: String) throws -> (id: String, rest: String)? {
        guard case .capture(let id, let directory, let rest)? = Self.parse(path),
              try index.relativeDirectory(captureID: id) == directory else { return nil }
        return (id, rest)
    }

    private func classify(_ change: RemoteChange, destination: Destination, adapter: any StorageAdapter,
                          pass: inout Pass) async throws {
        switch change {
        case .deleted(let path):
            switch Self.parse(path) {
            case .root?:
                pass.rootGone = true
            case .partition(let partition)?:
                // The partition is gone, and so is every capture under it.
                for (id, directory) in try index.indexedDirectories() where directory.hasPrefix(partition + "/") {
                    pass.candidates.insert(id)
                }
            case .capture?:
                guard let (id, rest) = try indexedTarget(path) else { return }
                if rest.isEmpty || rest == Self.markerName {
                    pass.candidates.insert(id)
                    return
                }
                // A folder inside the package (a provider may report just the folder) stands for the manifest
                // files under it.
                let files = manifest(id, pass: &pass)?.files.keys.filter { $0 == rest || $0.hasPrefix(rest + "/") }
                pass.markChanged(id, files ?? [rest])
            case nil:
                return
            }
        case .upserted(let info):
            guard let (id, rest) = try indexedTarget(info.relativePath), !rest.isEmpty else { return }
            if rest == Self.markerName {
                // The marker is back (or was never really gone): the capture isn't deleted.
                pass.candidates.remove(id)
                return
            }
            if try matchesReceipt(info, id: id, path: rest, destination: destination, pass: &pass) {
                pass.markMatched(id, rest)
                return
            }
            guard let manifest = manifest(id, pass: &pass), let expected = manifest.files[rest],
                  !manifest.trimmed.contains(rest) else { return }
            let local = manifest.directoryURL.appendingPathComponent(rest)
            if try await adapter.verify(remote: info, localURL: local, expected: expected) != nil {
                pass.markMatched(id, rest)
            } else {
                pass.markChanged(id, [rest])
            }
        }
    }

    /// The local package's manifest, loaded once per pass. Nil when the package doesn't validate locally,
    /// so nothing is compared against it.
    private func manifest(_ id: String, pass: inout Pass) -> Manifest? {
        if let cached = pass.manifests[id] { return cached }
        var loaded: Manifest?
        if let directory = try? index.relativeDirectory(captureID: id), let trimmed = try? trims.trimmedPaths(captureID: id),
           let package = CommittedPackage.load(directory: layout.packageURL(relativeDirectory: directory),
                                               layout: layout, trimmed: trimmed) {
            var files: [String: FileIntegrity] = [:]
            for entry in package.marker.files where entry.relativePath != Self.markerName {
                files[entry.relativePath] = FileIntegrity(byteCount: entry.byteCount, sha256: entry.sha256)
            }
            loaded = Manifest(directoryURL: package.directoryURL, files: files, trimmed: trimmed)
        }
        pass.manifests[id] = .some(loaded)
        return loaded
    }

    /// True when the remote file is exactly the one this phone verified when uploading it: the same provider
    /// hash as the stored receipt's evidence. Saves hashing the local file again for the phone's own uploads.
    private func matchesReceipt(_ info: RemoteFileInfo, id: String, path: String, destination: Destination,
                                pass: inout Pass) throws -> Bool {
        guard let hash = info.providerHash else { return false }
        if pass.receipts[id] == nil {
            var byPath: [String: StoredReceipt] = [:]
            for job in try jobs.jobs(captureID: id) where job.destinationID == destination.id {
                for receipt in try jobs.receipts(jobID: job.jobID) { byPath[receipt.relativePath] = receipt }
            }
            pass.receipts[id] = byPath
        }
        guard let receipt = pass.receipts[id]?[path] else { return false }
        return receipt.evidenceKind == hash.algorithm && receipt.evidenceValue == hash.value
            && receipt.byteCount == info.byteCount
    }

    // MARK: - Applying

    private func apply(_ pass: Pass, destination: Destination, report: inout RemoteChangeReport) async throws {
        // A capture whose upload isn't verified is never removed: the next upload recreates the remote copy.
        var eligible: [String] = []
        for id in pass.candidates.sorted() {
            let mine = try jobs.jobs(captureID: id).filter { $0.destinationID == destination.id }
            if !mine.isEmpty, mine.allSatisfy({ $0.state == .synced }) {
                eligible.append(id)
            } else {
                report.protected += 1
                log?.append(LogEvent(event: .remoteChanged, captureID: id, code: "unverified",
                                     dest: destination.providerKind))
            }
        }

        let synced = try jobs.capturesFullySynced(destinationID: destination.id)
        if pass.rootGone {
            try queueReview(synced.sorted(), reason: "root_missing", destination: destination, report: &report)
        } else if eligible.count > Self.maxAutoRemovals
                    || Double(eligible.count) > Self.maxAutoRemovalFraction * Double(synced.count) {
            try queueReview(eligible, reason: "threshold", destination: destination, report: &report)
        } else {
            for id in eligible {
                if Task.isCancelled { return }
                do {
                    try await removeLocally(id)
                    report.removed += 1
                } catch {
                    Self.osLog.error("\("remote_remove_failed", privacy: .public)")
                    report.code = "remove_failed"
                }
            }
        }

        // Deletion candidates are removed or waiting for review, so they are never also marked changed.
        for id in Set(pass.changed.keys).union(pass.matched.keys).sorted() where !pass.candidates.contains(id) {
            if Task.isCancelled { return }
            let cleared = pass.matched[id] ?? []
            if !cleared.isEmpty, let existing = try remoteState.changed(captureID: id),
               !Set(existing.paths).isDisjoint(with: cleared) {
                let kept = Set(existing.paths).subtracting(cleared)
                try remoteState.clearChanged(captureID: id)
                if !kept.isEmpty {
                    try remoteState.markChanged(captureID: id, destinationID: existing.destinationID,
                                                paths: kept.sorted(), now: existing.detectedAt)
                }
            }
            guard let paths = pass.changed[id], !paths.isEmpty else { continue }
            try remoteState.markChanged(captureID: id, destinationID: destination.id, paths: paths.sorted(), now: now())
            report.changed += 1
            log?.append(LogEvent(event: .remoteChanged, captureID: id, dest: destination.providerKind))
        }
    }

    private func queueReview(_ ids: [String], reason: String, destination: Destination,
                             report: inout RemoteChangeReport) throws {
        guard !ids.isEmpty else { return }
        let at = now()
        try remoteState.addReviewItems(ids.map {
            ReviewItem(captureID: $0, destinationID: destination.id, reason: reason, createdAt: at)
        })
        report.reviewQueued += ids.count
        log?.append(LogEvent(event: .remoteReview, code: reason, count: ids.count, dest: destination.providerKind))
    }

    /// After a cursor reset: a new cursor is saved first, then `captures/` is listed in full and every synced
    /// capture without a remote `complete.json` goes to review. A reset can't tell "deleted" from "not listed",
    /// so nothing is applied. If the listing fails the new cursor stays and no review is queued this time.
    private func rebaseline(_ destination: Destination, adapter: any StorageAdapter,
                            report: inout RemoteChangeReport) async throws {
        report.cursorReset = true
        let latest = try await adapter.latestCursor(under: Self.prefix)
        try remoteState.saveChangeCursor(destinationID: destination.id, cursor: latest, now: now())

        var present: Set<String> = []
        var cursor: String?
        repeat {
            try Task.checkCancellation()
            let page = try await adapter.listFolder(relativePath: "captures", recursive: true, cursor: cursor)
            for entry in page.entries where !entry.isFolder {
                if case .capture(_, let directory, Self.markerName)? = Self.parse(entry.relativePath) {
                    present.insert(directory)
                }
            }
            cursor = page.hasMore ? page.cursor : nil
        } while cursor != nil

        var missing: [String] = []
        for id in try jobs.capturesFullySynced(destinationID: destination.id).sorted() {
            guard let directory = try index.relativeDirectory(captureID: id), !present.contains(directory) else { continue }
            missing.append(id)
        }
        try queueReview(missing, reason: "cursor_reset", destination: destination, report: &report)
    }
}
