import Foundation
import CaptureCore
import LocalRepository

public struct SyncPassResult: Sendable, Equatable {
    public var synced: Int
    public var failed: Int
    /// True when the pass claimed no job.
    public var idle: Bool

    public init(synced: Int, failed: Int, idle: Bool) {
        self.synced = synced
        self.failed = failed
        self.idle = idle
    }
}

/// Uploads claimed jobs with the marker-last protocol (spec §9, §10). Every manifest file is uploaded
/// or found, then inspected and verified remotely, before `complete.json`; a job is marked synced only
/// once the marker itself is verified. Error codes recorded on jobs never carry content, file names,
/// URLs or account identifiers.
public final class SyncWorker: Sendable {
    public static let lease: TimeInterval = 120
    private static let markerName = "complete.json"

    private let layout: StoreLayout
    private let jobs: JobStore
    private let destinations: DestinationStore
    private let index: CaptureIndex
    private let adapterFor: @Sendable (Destination) throws -> any StorageAdapter
    /// The lease owner for every job this worker claims: the `owner` prefix plus a per-instance UUID,
    /// so two workers with the same prefix (e.g. two app passes) never share a lease.
    public let leaseOwner: String
    private let policy: RetryPolicy
    private let now: @Sendable () -> Date
    private let random: @Sendable () -> Double

    public init(layout: StoreLayout, jobs: JobStore, destinations: DestinationStore, index: CaptureIndex,
                adapterFor: @escaping @Sendable (Destination) throws -> any StorageAdapter, owner: String,
                policy: RetryPolicy = .init(), now: @escaping @Sendable () -> Date = Date.init,
                random: @escaping @Sendable () -> Double = { .random(in: 0...1) }) {
        self.layout = layout
        self.jobs = jobs
        self.destinations = destinations
        self.index = index
        self.adapterFor = adapterFor
        self.leaseOwner = "\(owner)#\(UUID().uuidString.lowercased())"
        self.policy = policy
        self.now = now
        self.random = random
    }

    /// Claims and processes jobs one at a time until none is eligible or `maxJobs` were claimed. A
    /// claim that throws ends the pass and counts as one failure.
    /// Task cancellation ends the pass without recording anything for the current job: its lease
    /// expires and it is reclaimed later.
    public func runOnce(maxJobs: Int = 20) async -> SyncPassResult {
        var result = SyncPassResult(synced: 0, failed: 0, idle: true)
        var claimed = 0
        while claimed < maxJobs, !Task.isCancelled {
            let next: UploadJob?
            do {
                next = try jobs.claimNext(owner: leaseOwner, now: now(), lease: Self.lease, reclaimDelay: { [policy, random] in
                    policy.delay(attempt: $0, retryAfter: nil, random: random)
                })
            } catch {
                // A claim that fails is not "nothing to do".
                result.idle = false
                result.failed += 1
                break
            }
            guard let job = next else { break }
            claimed += 1
            result.idle = false
            switch await process(job) {
            case .synced: result.synced += 1
            case .failed: result.failed += 1
            case .abandoned: break
            case .stopped: return result
            }
        }
        return result
    }

    // MARK: - One job

    private enum Outcome { case synced, failed, abandoned, stopped }

    /// The failure state and safe error code to record for a job.
    private struct Failure: Error {
        var state: JobState
        var code: String
        var retryAfter: TimeInterval? = nil
    }

    private func process(_ job: UploadJob) async -> Outcome {
        do {
            try await upload(job)
            try jobs.markSynced(jobID: job.jobID, owner: leaseOwner)
            return .synced
        } catch is CancellationError {
            return .stopped
        } catch JobError.leaseLost, JobError.notFound {
            return .abandoned
        } catch let failure as Failure {
            return record(failure, for: job)
        } catch let error as StorageError {
            return record(Self.failure(for: error), for: job)
        } catch {
            return record(Failure(state: .retryableFailure, code: "transient:internal"), for: job)
        }
    }

    private func upload(_ job: UploadJob) async throws {
        guard let destination = try destinations.active(), destination.id == job.destinationID else {
            throw Failure(state: .paused, code: "destination_inactive")
        }
        // Any package that fails to load is surfaced as blocked (visible "Needs attention");
        // the user's Retry (JobStore.retryNow) re-queues it once the cause is gone.
        guard let directory = try index.relativeDirectory(captureID: job.captureID),
              let package = CommittedPackage.load(directory: layout.packageURL(relativeDirectory: directory),
                                                  layout: layout) else {
            throw Failure(state: .blocked, code: "local_package_invalid")
        }
        let adapter = try adapterFor(destination)
        let files = package.marker.files.filter { $0.relativePath != Self.markerName }

        try await adapter.ensureContainer(relativePath: directory)
        // Mirror the local layout: a package without attachments has no content/ folder.
        if files.contains(where: { $0.relativePath.hasPrefix("content/") }) {
            try await adapter.ensureContainer(relativePath: directory + "/content")
        }

        let receipted = Set(try jobs.receipts(jobID: job.jobID).map(\.relativePath))
        for entry in files where !receipted.contains(entry.relativePath) {
            try await syncFile(entry.relativePath, local: package.directoryURL.appendingPathComponent(entry.relativePath),
                               expected: FileIntegrity(byteCount: entry.byteCount, sha256: entry.sha256),
                               directory: directory, job: job, adapter: adapter)
        }

        // The marker goes last, and only once every file it lists has a stored receipt.
        let stored = Set(try jobs.receipts(jobID: job.jobID).map(\.relativePath))
        guard files.allSatisfy({ stored.contains($0.relativePath) }) else {
            throw Failure(state: .retryableFailure, code: "verify_failed")
        }
        guard !stored.contains(Self.markerName) else { return }
        let markerURL = package.directoryURL.appendingPathComponent(Self.markerName)
        let digest = try StreamingHasher.digest(of: markerURL)
        try await syncFile(Self.markerName, local: markerURL,
                           expected: FileIntegrity(byteCount: digest.byteCount, sha256: digest.sha256),
                           directory: directory, job: job, adapter: adapter)
    }

    /// Gets one package file to the destination and stores a receipt from remote verification.
    /// `path` is relative to the package directory and keys the receipt and checkpoint.
    private func syncFile(_ path: String, local: URL, expected: FileIntegrity, directory: String,
                          job: UploadJob, adapter: any StorageAdapter) async throws {
        try Task.checkCancellation()
        guard let current = try jobs.job(jobID: job.jobID) else { throw JobError.notFound }
        if current.cancelRequested { throw Failure(state: .paused, code: "cancelled") }
        guard try jobs.renewLease(jobID: job.jobID, owner: leaseOwner, now: now(), lease: Self.lease) else {
            throw JobError.leaseLost
        }

        let remotePath = directory + "/" + path
        // Inspect first: a previous request may have succeeded without us hearing back.
        if let existing = try await adapter.inspectFile(relativePath: remotePath) {
            guard let evidence = try await adapter.verify(remote: existing, localURL: local, expected: expected) else {
                throw Failure(state: .blocked, code: "remote_conflict")
            }
            try saveReceipt(path, remote: existing, evidence: evidence, job: job)
            return
        }

        let (jobs, jobID, owner, now) = (self.jobs, job.jobID, leaseOwner, self.now)
        var checkpoint = try jobs.checkpoint(jobID: jobID, relativePath: path).map(UploadCheckpoint.init(opaque:))
        var restarted = false
        while true {
            do {
                _ = try await adapter.uploadFile(localURL: local, relativePath: remotePath, expected: expected,
                                                 checkpoint: checkpoint, saveCheckpoint: { cp in
                    // Keep ownership through long uploads, and never write a checkpoint for a job
                    // another worker now owns. Adapters rethrow these errors unchanged.
                    guard try jobs.renewLease(jobID: jobID, owner: owner, now: now(), lease: Self.lease) else {
                        throw JobError.leaseLost
                    }
                    guard let current = try jobs.job(jobID: jobID) else { throw JobError.notFound }
                    if current.cancelRequested { throw Failure(state: .paused, code: "cancelled") }
                    try jobs.saveCheckpoint(jobID: jobID, relativePath: path, data: cp.opaque)
                })
                break
            } catch StorageError.checkpointExpired {
                try jobs.clearCheckpoint(jobID: jobID, relativePath: path)
                if restarted { throw StorageError.checkpointExpired }
                restarted = true
                checkpoint = nil
            }
        }

        // Never trust the upload response alone: the file must be visible and provably match.
        guard let uploaded = try await adapter.inspectFile(relativePath: remotePath),
              let evidence = try await adapter.verify(remote: uploaded, localURL: local, expected: expected) else {
            throw Failure(state: .retryableFailure, code: "verify_failed")
        }
        try saveReceipt(path, remote: uploaded, evidence: evidence, job: job)
    }

    private func saveReceipt(_ path: String, remote: RemoteFileInfo, evidence: VerificationEvidence,
                             job: UploadJob) throws {
        try jobs.saveReceipt(jobID: job.jobID, StoredReceipt(relativePath: path, byteCount: remote.byteCount,
                                                             evidenceKind: evidence.kind, evidenceValue: evidence.value))
        try jobs.clearCheckpoint(jobID: job.jobID, relativePath: path)
    }

    // MARK: - Recording failures

    /// Records the failure and releases the lease. If that fails (lease lost, job gone, database
    /// unavailable) nothing is recorded and the job is reclaimed once its lease expires.
    private func record(_ failure: Failure, for job: UploadJob) -> Outcome {
        let next: Date? = failure.state == .retryableFailure
            ? now().addingTimeInterval(policy.delay(attempt: job.attemptCount + 1, retryAfter: failure.retryAfter,
                                                    random: random))
            : nil
        do {
            try jobs.markFailed(jobID: job.jobID, owner: leaseOwner, state: failure.state, errorCode: failure.code,
                                nextAttemptAt: next)
            return .failed
        } catch {
            return .abandoned
        }
    }

    private static func failure(for error: StorageError) -> Failure {
        switch error {
        case .offline: Failure(state: .retryableFailure, code: "offline")
        case .transient(let code): Failure(state: .retryableFailure, code: "transient:\(code)")
        case .rateLimited(let retryAfter): Failure(state: .retryableFailure, code: "rate_limited", retryAfter: retryAfter)
        case .checkpointExpired: Failure(state: .retryableFailure, code: "checkpoint_expired")
        case .cursorReset: Failure(state: .retryableFailure, code: "cursor_reset")
        case .needsAuthentication: Failure(state: .needsAuthentication, code: "needs_authentication")
        case .quotaExceeded: Failure(state: .blocked, code: "quota_exceeded")
        case .conflict: Failure(state: .blocked, code: "remote_conflict")
        case .permanent(let code): Failure(state: .blocked, code: "permanent:\(code)")
        }
    }
}
