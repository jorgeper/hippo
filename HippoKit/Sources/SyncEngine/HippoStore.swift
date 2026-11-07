import Foundation
import CaptureCore
import LocalRepository

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

    /// How long deletion waits for a worker to let go of an active upload before proceeding anyway.
    static let leaseWaitLimit: Duration = .seconds(10)
    static let leasePollInterval: Duration = .milliseconds(100)

    public let layout: StoreLayout
    public let index: CaptureIndex
    public let jobs: JobStore
    public let destinations: DestinationStore
    private let db: Database
    private let writer: PackageWriter

    private init(layout: StoreLayout, db: Database, producer: Producer) {
        self.layout = layout
        self.db = db
        index = CaptureIndex(db: db)
        jobs = JobStore(db: db)
        destinations = DestinationStore(db: db)
        writer = PackageWriter(layout: layout, producer: producer)
    }

    /// Opens (creating if needed) the store at `root`. Does not run recovery: call `recover()` at launch.
    public static func open(root: URL, producer: Producer) throws -> HippoStore {
        let layout = StoreLayout(root: root)
        for dir in [root, layout.stagingDir, layout.capturesDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return HippoStore(layout: layout, db: try Database(url: layout.databaseURL), producer: producer)
    }

    /// Startup recovery (spec §4).
    public func recover() throws -> RecoveryReport {
        try Reconciler(layout: layout, index: index, jobs: jobs, destinations: destinations).run()
    }

    /// Commits the draft, then indexes it and enqueues it for the active destination. Once the commit
    /// succeeds the capture is saved: the package is the truth, so an indexing or enqueueing failure is
    /// not reported, and the next `recover()` registers and binds the package.
    public func capture(_ d: CaptureDraft, partialPolicy: PartialPolicy = .rejectPartial) async throws -> CommittedPackage {
        let package = try await writer.commit(d, partialPolicy: partialPolicy)
        do {
            _ = try index.register(package, noteBody: package.noteBody())
            try jobs.enqueueIfActive(captureID: package.metadata.captureID)
        } catch {
            // Repaired by the reconciler at next launch.
        }
        return package
    }

    /// A sync worker over this store's database and files, with the default retry policy and clock.
    public func makeWorker(adapterFor: @escaping @Sendable (Destination) throws -> any StorageAdapter,
                           owner: String) -> SyncWorker {
        SyncWorker(layout: layout, jobs: jobs, destinations: destinations, index: index, adapterFor: adapterFor,
                   owner: owner)
    }

    /// Deletes the capture from this phone (spec §11): cancels its uploads, waits up to 10 s for a
    /// worker holding an active upload lease to let go, then removes the index row (its jobs, receipts
    /// and checkpoints cascade) and the package directory. Remote copies, complete or partial, are never
    /// touched. A worker still mid-file after the wait loses its lease with the job row and stops.
    /// Deleting an unknown capture does nothing.
    public func delete(captureID: String) async throws -> DeletionResult {
        guard let directory = try index.relativeDirectory(captureID: captureID) else {
            return DeletionResult(wasSynced: false, hadActiveUpload: false)
        }
        let existing = try jobs.jobs(captureID: captureID)
        let wasSynced = !existing.isEmpty && existing.allSatisfy { $0.state == .synced }

        // After this no worker can claim the capture's jobs, so only a lease already held can be active.
        try jobs.requestCancel(captureID: captureID)
        let hadActiveUpload = try jobs.activeLeaseExists(captureID: captureID, now: Date())
        if hadActiveUpload {
            let deadline = ContinuousClock.now + Self.leaseWaitLimit
            while ContinuousClock.now < deadline, try jobs.activeLeaseExists(captureID: captureID, now: Date()) {
                // Deletion was confirmed by the user: if this task is cancelled, stop waiting and finish it.
                do { try await Task.sleep(for: Self.leasePollInterval) } catch { break }
            }
        }

        try index.remove(captureID: captureID)
        do {
            try FileManager.default.removeItem(at: layout.packageURL(relativeDirectory: directory))
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Already gone.
        }
        return DeletionResult(wasSynced: wasSynced, hadActiveUpload: hadActiveUpload)
    }

    /// Writes the redacted `diagnostics.json` at `layout.diagnosticsURL`.
    public func writeDiagnostics(appVersion: String) throws {
        try Diagnostics.write(db: db, appVersion: appVersion, now: Date(), to: layout.diagnosticsURL)
    }
}
