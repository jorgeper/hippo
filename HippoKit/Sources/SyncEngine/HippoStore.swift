import Foundation
import CaptureCore
import LocalRepository
import os

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
    private static let log = Logger(subsystem: "com.jorgeper.hippo", category: "store")

    public let layout: StoreLayout
    public let index: CaptureIndex
    public let jobs: JobStore
    public let destinations: DestinationStore
    /// Local silver and gold documents, their search text, silver upload rows and gold cursors.
    public let enrichments: EnrichmentStore
    /// Silver enrichment work per (capture, kind).
    public let enrichmentTasks: EnrichmentTaskStore
    private let db: Database
    private let writer: PackageWriter
    private let leaseWaitLimit: Duration

    private init(layout: StoreLayout, db: Database, producer: Producer, leaseWaitLimit: Duration) {
        self.layout = layout
        self.db = db
        self.leaseWaitLimit = leaseWaitLimit
        index = CaptureIndex(db: db)
        jobs = JobStore(db: db)
        destinations = DestinationStore(db: db)
        enrichments = EnrichmentStore(db: db, layout: layout)
        enrichmentTasks = EnrichmentTaskStore(db: db)
        writer = PackageWriter(layout: layout, producer: producer)
    }

    /// Opens (creating if needed) the store at `root`. Does not run recovery: call `recover()` at launch.
    public static func open(root: URL, producer: Producer) throws -> HippoStore {
        try open(root: root, producer: producer, leaseWaitLimit: defaultLeaseWaitLimit)
    }

    /// `leaseWaitLimit` is shortened only by tests.
    static func open(root: URL, producer: Producer, leaseWaitLimit: Duration) throws -> HippoStore {
        let layout = StoreLayout(root: root)
        for dir in [root, layout.stagingDir, layout.capturesDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return HippoStore(layout: layout, db: try Database(url: layout.databaseURL), producer: producer,
                          leaseWaitLimit: leaseWaitLimit)
    }

    /// Startup recovery (spec §4), then the enrichment sweep (design §6.2): enrichment staging leftovers
    /// and enrichment directories with no indexed capture are removed. A sweep failure is only logged.
    public func recover() throws -> RecoveryReport {
        let report = try Reconciler(layout: layout, index: index, jobs: jobs, destinations: destinations).run()
        do { _ = try enrichments.sweep() } catch { Self.log.error("\("recover_enrichment_sweep_failed", privacy: .public)") }
        return report
    }

    /// Commits the draft, then indexes it and enqueues it for the active destination. Once the commit
    /// succeeds the capture is saved: the package is the truth, so an indexing or enqueueing failure is
    /// not reported (only logged, as a fixed category), and the next `recover()` registers and binds
    /// the package.
    public func capture(_ d: CaptureDraft, partialPolicy: PartialPolicy = .rejectPartial) async throws -> CommittedPackage {
        let package = try await writer.commit(d, partialPolicy: partialPolicy)
        do {
            _ = try index.register(package, noteBody: package.noteBody())
        } catch {
            Self.log.error("\("register_failed", privacy: .public)")
            return package
        }
        do {
            try jobs.enqueueIfActive(captureID: package.metadata.captureID)
        } catch {
            Self.log.error("\("enqueue_failed", privacy: .public)")
        }
        return package
    }

    /// A sync worker over this store's database and files, with the default retry policy and clock.
    /// `owner` is a prefix (e.g. "app"); the worker's `leaseOwner` makes it unique per worker.
    public func makeWorker(adapterFor: @escaping @Sendable (Destination) throws -> any StorageAdapter,
                           owner: String) -> SyncWorker {
        SyncWorker(layout: layout, jobs: jobs, destinations: destinations, index: index, adapterFor: adapterFor,
                   owner: owner)
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
        guard let directory = try index.relativeDirectory(captureID: captureID) else {
            return DeletionResult(wasSynced: false, hadActiveUpload: false)
        }
        let existing = try jobs.jobs(captureID: captureID)
        let wasSynced = !existing.isEmpty && existing.allSatisfy { $0.state == .synced }

        // After this no worker can claim the capture's jobs, so only a lease already held can be active.
        try jobs.requestCancel(captureID: captureID)
        var removed = false
        // If deletion fails before the row is gone, the capture stays and its uploads must resume.
        defer { if !removed { try? jobs.clearCancel(captureID: captureID) } }
        let hadActiveUpload = try jobs.activeLeaseExists(captureID: captureID, now: Date())
        if hadActiveUpload {
            let deadline = ContinuousClock.now + leaseWaitLimit
            while ContinuousClock.now < deadline, try jobs.activeLeaseExists(captureID: captureID, now: Date()) {
                // Deletion was confirmed by the user: if this task is cancelled, stop waiting and finish it.
                do { try await Task.sleep(for: Self.leasePollInterval) } catch { break }
            }
        }

        let fm = FileManager.default
        let staged = layout.stagingDir.appendingPathComponent("\(captureID).deleted", isDirectory: true)
        try fm.createDirectory(at: layout.stagingDir, withIntermediateDirectories: true)
        // Left by an earlier attempt that crashed after its rename.
        try Self.removeIfPresent(staged)
        do {
            try fm.moveItem(at: layout.packageURL(relativeDirectory: directory), to: staged)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Already moved or gone.
        }
        try index.remove(captureID: captureID)
        removed = true
        // Without the index row these are orphans, and the next recover() sweeps whatever is left.
        do { try enrichments.removeAll(captureID: captureID) } catch {
            Self.log.error("\("delete_enrichment_cleanup_failed", privacy: .public)")
        }
        // The capture is already deleted from the user's point of view. Another process's recover()
        // may be sweeping the directory at the same time, and the next recover() finishes it anyway.
        do { try Self.removeIfPresent(staged) } catch { Self.log.error("\("delete_cleanup_failed", privacy: .public)") }
        return DeletionResult(wasSynced: wasSynced, hadActiveUpload: hadActiveUpload)
    }

    private static func removeIfPresent(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Nothing to remove.
        }
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
