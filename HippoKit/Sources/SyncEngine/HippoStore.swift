import Foundation
import CaptureCore
import LocalRepository
import os

/// What "Upload again from iPhone" did.
public struct UploadAgainResult: Sendable, Equatable {
    /// False when the capture has no upload job.
    public var requeued: Bool
    /// Paths that couldn't be requeued because their local originals were trimmed.
    public var unrestorablePaths: [String]
    public init(requeued: Bool, unrestorablePaths: [String]) {
        self.requeued = requeued; self.unrestorablePaths = unrestorablePaths
    }
}

/// The one entry point the app and the Share Extension use: commit, index and enqueue captures,
/// recover at launch, delete locally, and write diagnostics. Both processes may open the same root.
public final class HippoStore: Sendable {
    public struct DeletionResult: Sendable, Equatable {
        /// The capture had at least one upload job and every one of them was synced.
        public var wasSynced: Bool
        /// When deletion started, a worker held an unexpired lease on one of its uploads.
        public var hadActiveUpload: Bool

        public init(wasSynced: Bool, hadActiveUpload: Bool) {
            self.wasSynced = wasSynced
            self.hadActiveUpload = hadActiveUpload
        }
    }

    /// How long deletion waits, by default, for a worker to let go of an active upload before
    /// proceeding anyway.
    static let defaultLeaseWaitLimit: Duration = .seconds(10)
    static let leasePollInterval: Duration = .milliseconds(100)

    /// Messages are fixed category strings only: never IDs, paths or error descriptions.
    private static let osLog = Logger(subsystem: "com.jorgeper.hippo", category: "store")

    public let layout: StoreLayout
    public let index: CaptureIndex
    public let jobs: JobStore
    public let destinations: DestinationStore
    /// Local silver and gold documents, their search text, silver upload rows and gold cursors.
    public let enrichments: EnrichmentStore
    /// Silver enrichment work per (capture, kind).
    public let enrichmentTasks: EnrichmentTaskStore
    /// Remote-delete tombstones, local-delete records, change cursors, review items and changed records.
    public let remoteState: RemoteStateStore
    /// Attachments whose local originals were trimmed after verification in the destination.
    public let trims: TrimStore
    /// The content-free event log, in `logs/` beside the store. Shared by the app and the extension.
    public let log: ActivityLog
    private let db: Database
    private let writer: PackageWriter
    private let leaseWaitLimit: Duration
    /// The clock `delete` checks upload leases against. Replaced only by tests.
    private let now: @Sendable () -> Date

    private init(layout: StoreLayout, db: Database, producer: Producer, process: LogProcess,
                 leaseWaitLimit: Duration, now: @escaping @Sendable () -> Date) {
        self.layout = layout
        self.db = db
        self.leaseWaitLimit = leaseWaitLimit
        self.now = now
        index = CaptureIndex(db: db)
        jobs = JobStore(db: db)
        destinations = DestinationStore(db: db)
        enrichments = EnrichmentStore(db: db, layout: layout)
        enrichmentTasks = EnrichmentTaskStore(db: db)
        remoteState = RemoteStateStore(db: db)
        trims = TrimStore(db: db)
        writer = PackageWriter(layout: layout, producer: producer)
        log = ActivityLog(layout: layout, process: process)
    }

    /// Opens (creating if needed) the store at `root`. Does not run recovery: call `recover()` at launch.
    /// `process` says who writes this store's log lines: the app or the share extension.
    public static func open(root: URL, producer: Producer, process: LogProcess = .app) throws -> HippoStore {
        try open(root: root, producer: producer, process: process, leaseWaitLimit: defaultLeaseWaitLimit)
    }

    /// `leaseWaitLimit` is shortened, and `now` (the clock `delete` checks leases against) replaced, only by tests.
    static func open(root: URL, producer: Producer, process: LogProcess = .app,
                     leaseWaitLimit: Duration, now: @escaping @Sendable () -> Date = Date.init) throws -> HippoStore {
        let layout = StoreLayout(root: root)
        for dir in [root, layout.stagingDir, layout.capturesDir, layout.thumbnailsDir, layout.transfersDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return HippoStore(layout: layout, db: try Database(url: layout.databaseURL), producer: producer,
                          process: process, leaseWaitLimit: leaseWaitLimit, now: now)
    }

    /// Startup recovery (spec §4), then the enrichment steps (design §6.2, §9): enrichment staging
    /// leftovers are removed, and so are enrichment directories with no indexed capture, unless some item
    /// of the package recovery failed (that capture's package may still exist). Then the index's search
    /// text and `device_revision` are re-synced with the enrichment files. Enrichment failures are only logged.
    public func recover() throws -> RecoveryReport {
        let report = try Reconciler(
            layout: layout, index: index, jobs: jobs, destinations: destinations,
            trimmedPaths: { [trims] in try trims.trimmedPaths(captureID: $0) }).run()
        do { _ = try enrichments.sweep(removingOrphans: report.failed == 0) } catch {
            Self.osLog.error("\("recover_enrichment_sweep_failed", privacy: .public)")
        }
        do { _ = try enrichments.reconcileIndex() } catch {
            Self.osLog.error("\("recover_enrichment_reindex_failed", privacy: .public)")
        }
        return report
    }

    /// Commits the draft, then indexes it and enqueues it for the active destination. Once the commit
    /// succeeds the capture is saved: the package is the truth, so an indexing or enqueueing failure is
    /// not reported (only logged, as a fixed category), and the next `recover()` registers and binds
    /// the package.
    public func capture(_ d: CaptureDraft, partialPolicy: PartialPolicy = .rejectPartial) async throws -> CommittedPackage {
        let package: CommittedPackage
        do {
            package = try await writer.commit(d, partialPolicy: partialPolicy)
        } catch {
            log.append(LogEvent(event: .captureSaveFailed, code: Self.saveFailureCode(error)))
            throw error
        }
        log.append(LogEvent(event: .captureSaved, captureID: package.metadata.captureID,
                            trigger: package.metadata.captureMethod.rawValue))
        do {
            _ = try index.register(package, noteBody: package.noteBody())
        } catch {
            Self.osLog.error("\("register_failed", privacy: .public)")
            return package
        }
        do {
            try jobs.enqueueIfActive(captureID: package.metadata.captureID)
        } catch {
            Self.osLog.error("\("enqueue_failed", privacy: .public)")
        }
        return package
    }

    /// A fixed name for the error's case, never its payload (paths, file names, byte counts).
    private static func saveFailureCode(_ error: Error) -> String {
        switch error as? CaptureError {
        case .insufficientSpace: "insufficient_space"
        case .attachmentsFailed: "attachments_failed"
        case .emptyCapture: "empty_capture"
        case .io: "io"
        case nil: "unknown"
        }
    }

    /// A sync worker over this store's database and files, with the default retry policy and clock.
    /// `owner` is a prefix (e.g. "app"); the worker's `leaseOwner` makes it unique per worker.
    public func makeWorker(adapterFor: @escaping @Sendable (Destination) throws -> any StorageAdapter,
                           owner: String) -> SyncWorker {
        SyncWorker(layout: layout, jobs: jobs, destinations: destinations, index: index, trims: trims,
                   remoteState: remoteState, adapterFor: adapterFor,
                   owner: owner, log: log)
    }

    /// Uploads silver enrichment to the active destination after packages have synced, with the default
    /// retry policy and clock.
    public func makeEnrichmentUploader(adapterFor: @escaping @Sendable (Destination) throws -> any StorageAdapter)
        -> EnrichmentUploader {
        EnrichmentUploader(layout: layout, destinations: destinations, enrichments: enrichments,
                           adapterFor: adapterFor, log: log)
    }

    /// Uploads the event log's segment files to `logs/<installID>/` on the active destination.
    public func makeLogUploader(installID: String,
                                adapterFor: @escaping @Sendable (Destination) throws -> any StorageAdapter,
                                isConstrained: @escaping @Sendable () -> Bool = { false })
        -> LogUploader {
        LogUploader(layout: layout, log: log, destinations: destinations, installID: installID, adapterFor: adapterFor,
                    isConstrained: isConstrained)
    }

    /// Pulls gold enrichment from the active destination's `enrichments/server/` tree, with the default clock.
    public func makeGoldPuller(adapterFor: @escaping @Sendable (Destination) throws -> any StorageAdapter)
        -> GoldPuller {
        GoldPuller(layout: layout, index: index, destinations: destinations, enrichments: enrichments,
                   adapterFor: adapterFor, log: log)
    }

    /// Pushes queued remote deletes (tombstones) to the active destination. Runs before uploads.
    public func makeRemoteDeleter(adapterFor: @escaping @Sendable (Destination) throws -> any StorageAdapter)
        -> RemoteDeleter {
        RemoteDeleter(destinations: destinations, remoteState: remoteState, adapterFor: adapterFor, log: log)
    }

    /// Applies deletes and marks changes made in the active destination's `captures/` tree, with the default
    /// clock. Runs after uploads. Removals use `removeAfterRemoteDelete`.
    public func makeChangeDetector(adapterFor: @escaping @Sendable (Destination) throws -> any StorageAdapter)
        -> RemoteChangeDetector {
        RemoteChangeDetector(layout: layout, index: index, jobs: jobs, remoteState: remoteState, trims: trims,
                             destinations: destinations, adapterFor: adapterFor,
                             removeLocally: { [self] in try await removeAfterRemoteDelete(captureID: $0) }, log: log)
    }

    /// "Save space": trims large, old attachments that are verified in the active destination.
    public func makeSpaceSaver(adapterFor: @escaping @Sendable (Destination) throws -> any StorageAdapter) -> SpaceSaver {
        SpaceSaver(layout: layout, index: index, jobs: jobs, destinations: destinations, trims: trims,
                   adapterFor: adapterFor, log: log)
    }

    /// Downloads a trimmed attachment back into its package.
    public func makeRestorer(adapterFor: @escaping @Sendable (Destination) throws -> any StorageAdapter)
        -> AttachmentRestorer {
        AttachmentRestorer(layout: layout, index: index, trims: trims, destinations: destinations,
                           adapterFor: adapterFor, log: log)
    }

    /// Deletes the capture from this phone (spec §11): cancels its uploads, waits up to 10 s for a
    /// worker holding an active upload lease to let go, then removes the package and the index row
    /// (its jobs, receipts and checkpoints cascade), then its local silver and gold (their rows cascade
    /// too). Remote copies, complete or partial, are never touched. A worker still mid-file after the
    /// wait loses its lease with the job row and stops.
    /// Deleting an unknown capture does nothing.
    ///
    /// Crash-safe (ruling R31): the package is first renamed out of `captures/` to
    /// `staging/<id>.deleted`, so it can never be re-registered. An interruption leaves at worst an
    /// orphan index row and a staged directory, and `recover()` removes both.
    public func delete(captureID: String) async throws -> DeletionResult {
        try await remove(captureID: captureID, mode: .iPhoneOnly)
    }

    /// "Delete everywhere": the same local removal as `delete`, plus a durable tombstone that the next sync
    /// pass applies in the destination (`RemoteDeleter`). The tombstone is written, bound to the capture's
    /// destination and that destination's account, just before the index row goes. A capture with no job
    /// has nothing remote to delete and behaves exactly like `delete`.
    public func deleteEverywhere(captureID: String) async throws -> DeletionResult {
        try await remove(captureID: captureID, mode: .everywhere)
    }

    /// Removes the capture locally after its remote copy was deleted elsewhere: `delete` without the
    /// local-delete record. The `capture.deleted` event carries `trigger: "remote"`.
    public func removeAfterRemoteDelete(captureID: String) async throws {
        _ = try await remove(captureID: captureID, mode: .remote)
    }

    private enum RemovalMode { case iPhoneOnly, everywhere, remote }

    private func remove(captureID: String, mode: RemovalMode) async throws -> DeletionResult {
        guard let directory = try index.relativeDirectory(captureID: captureID) else {
            return DeletionResult(wasSynced: false, hadActiveUpload: false)
        }
        let existing = try jobs.jobs(captureID: captureID)
        let wasSynced = !existing.isEmpty && existing.allSatisfy { $0.state == .synced }
        let bound = try existing.map(\.destinationID).min().flatMap { try destinations.destination(id: $0) }
        let thumbnailIDs = (try? trims.trimmed(captureID: captureID).map(\.attachmentID)) ?? []

        // After this no worker can claim the capture's jobs, so only a lease already held can be active.
        try jobs.requestCancel(captureID: captureID)
        var removed = false
        // If deletion fails before the row is gone, the capture stays and its uploads must resume.
        defer { if !removed { try? jobs.clearCancel(captureID: captureID) } }
        let hadActiveUpload = try jobs.activeLeaseExists(captureID: captureID, now: now())
        if hadActiveUpload {
            let deadline = ContinuousClock.now + leaseWaitLimit
            while ContinuousClock.now < deadline, try jobs.activeLeaseExists(captureID: captureID, now: now()) {
                // Deletion was confirmed by the user: if this task is cancelled, stop waiting and finish it.
                do { try await Task.sleep(for: Self.leasePollInterval) } catch { break }
            }
        }

        // The record goes in before the package moves, so a crash after the rename can't lose it.
        var tombstoned = false, recordedLocalDelete = false
        switch mode {
        case .everywhere where bound != nil:
            let destination = bound!
            try remoteState.addTombstone(captureID: captureID, relativeDirectory: directory,
                                         destinationID: destination.id,
                                         accountIdentifier: destination.accountIdentifier, now: now())
            tombstoned = true
        case .iPhoneOnly, .everywhere:
            try remoteState.recordLocalDelete(captureID: captureID, relativeDirectory: directory,
                                              accountIdentifier: bound?.accountIdentifier, now: now())
            recordedLocalDelete = true
        case .remote: break
        }
        let fm = FileManager.default
        let staged = layout.stagingDir.appendingPathComponent("\(captureID).deleted", isDirectory: true)
        do {
            try fm.createDirectory(at: layout.stagingDir, withIntermediateDirectories: true)
            // Left by an earlier attempt that crashed after its rename.
            try Self.removeIfPresent(staged)
            do {
                try fm.moveItem(at: layout.packageURL(relativeDirectory: directory), to: staged)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // Already moved or gone.
            }
            try index.remove(captureID: captureID)
        } catch {
            // The capture stays, so nothing may claim it was deleted. If this rollback also fails, a stale
            // tombstone could outlive the capture: the next delete of it rewrites the row, and none runs otherwise.
            if tombstoned { try? remoteState.removeTombstone(captureID: captureID) }
            if recordedLocalDelete { try? remoteState.removeLocalDelete(captureID: captureID) }
            throw error
        }
        removed = true
        log.append(LogEvent(event: .captureDeleted, captureID: captureID, trigger: mode == .remote ? "remote" : nil))
        if tombstoned, let bound {
            log.append(LogEvent(event: .remoteDelete, captureID: captureID, dest: bound.providerKind))
        }
        for id in thumbnailIDs { try? Self.removeIfPresent(layout.thumbnailURL(attachmentID: id)) }
        // Without the index row these are orphans, and the next recover() sweeps whatever is left.
        do { try enrichments.removeAll(captureID: captureID) } catch {
            Self.osLog.error("\("delete_enrichment_cleanup_failed", privacy: .public)")
        }
        // The capture is already deleted from the user's point of view. Another process's recover()
        // may be sweeping the directory at the same time, and the next recover() finishes it anyway.
        do { try Self.removeIfPresent(staged) } catch { Self.osLog.error("\("delete_cleanup_failed", privacy: .public)") }
        return DeletionResult(wasSynced: wasSynced, hadActiveUpload: hadActiveUpload)
    }

    private static func removeIfPresent(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Nothing to remove.
        }
    }

    /// "Upload again from iPhone" (design §4.3): clears the receipts of the files the destination lost or
    /// changed (every manifest file when no change is recorded) and of `complete.json`, and requeues the
    /// capture's upload to the active destination (every upload when none is active). The worker then re-adds
    /// missing files and never overwrites: a file that exists with other content stays a conflict. Trimmed
    /// files have no local original; they keep their receipts, stay in the changed record and are returned.
    /// Once something is requeued, the requeued paths leave the changed record.
    public func uploadAgain(captureID: String) throws -> UploadAgainResult {
        try uploadAgain(captureID: captureID, allPaths: false)
    }

    private func uploadAgain(captureID: String, allPaths: Bool) throws -> UploadAgainResult {
        let record = allPaths ? nil : try remoteState.changed(captureID: captureID)
        let paths: [String]
        if let record {
            paths = record.paths
        } else {
            guard let directory = try index.relativeDirectory(captureID: captureID) else {
                return UploadAgainResult(requeued: false, unrestorablePaths: [])
            }
            let marker = try HippoJSON.decodeMarker(Data(contentsOf: layout.packageURL(relativeDirectory: directory)
                .appendingPathComponent("complete.json")))
            paths = marker.files.map(\.relativePath)
        }
        let trimmed = try trims.trimmedPaths(captureID: captureID)
        let unrestorable = paths.filter { trimmed.contains($0) }.sorted()
        let cleared = Array(Set(paths.filter { !trimmed.contains($0) } + ["complete.json"])).sorted()

        let all = try jobs.jobs(captureID: captureID)
        let active = try destinations.active()
        let targets = active.map { a in all.filter { $0.destinationID == a.id } } ?? all
        for job in targets {
            try jobs.clearReceipts(jobID: job.jobID, paths: cleared)
            try jobs.requeue(jobID: job.jobID)
        }
        if !targets.isEmpty { try remoteState.removeChangedPaths(captureID: captureID, paths: cleared) }
        return UploadAgainResult(requeued: !targets.isEmpty, unrestorablePaths: unrestorable)
    }

    /// Settles the destination's pending "looks different" review. `keep == false` removes each item's capture
    /// from this phone (as a remote delete); `keep == true` uploads again every file of each capture without
    /// trimmed files and leaves the others as they are. Captures that no longer exist are skipped. Returns
    /// how many items were settled.
    public func resolveReview(destinationID: String, keep: Bool) async throws -> Int {
        var settled = 0
        for item in try remoteState.reviewItems(destinationID: destinationID) {
            guard try index.relativeDirectory(captureID: item.captureID) != nil else { continue }
            if !keep {
                try await removeAfterRemoteDelete(captureID: item.captureID)
            } else if try trims.trimmedPaths(captureID: item.captureID).isEmpty {
                _ = try uploadAgain(captureID: item.captureID, allPaths: true)
            }
            settled += 1
        }
        try remoteState.clearReview(destinationID: destinationID)
        return settled
    }

    /// Manual retry (spec §10): makes this capture's blocked and retry-waiting uploads claimable now.
    @discardableResult
    public func retry(captureID: String) throws -> Int { try jobs.retryNow(captureID: captureID) }

    /// Manual retry for every capture bound to the active destination. Zero if there is none.
    @discardableResult
    public func retryAll() throws -> Int {
        guard let active = try destinations.active() else { return 0 }
        return try jobs.retryAll(destinationID: active.id)
    }

    /// Writes the redacted `diagnostics.json` at `layout.diagnosticsURL`.
    public func writeDiagnostics(appVersion: String) throws {
        try Diagnostics.write(db: db, appVersion: appVersion, now: Date(), to: layout.diagnosticsURL)
    }
}
