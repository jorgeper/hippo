import Foundation
import os
import CaptureCore
import LocalRepository

public struct RemoteDeleteResult: Sendable, Equatable {
    public var deleted: Int
    public var failed: Int
    /// True when no tombstone was due.
    public var idle: Bool

    public init(deleted: Int, failed: Int, idle: Bool) {
        self.deleted = deleted
        self.failed = failed
        self.idle = idle
    }
}

/// Applies "Delete everywhere" tombstones in the active destination (design §4.2). Only a tombstone ever
/// deletes anything remotely, and only for the destination and account it was written for. Each
/// capture's package folder and its device and server enrichment folders are removed; a folder that is
/// already gone counts as removed. This never re-adds a tombstone (that would reset its attempts): it
/// removes it on success and marks it failed otherwise. Runs before uploads in a sync pass.
public final class RemoteDeleter: Sendable {
    private static let osLog = Logger(subsystem: "com.jorgeper.hippo", category: "remote-delete")

    private let destinations: DestinationStore
    private let remoteState: RemoteStateStore
    private let adapterFor: @Sendable (Destination) throws -> any StorageAdapter
    private let policy: RetryPolicy
    private let now: @Sendable () -> Date
    private let random: @Sendable () -> Double
    private let log: ActivityLog?

    public init(destinations: DestinationStore, remoteState: RemoteStateStore,
                adapterFor: @escaping @Sendable (Destination) throws -> any StorageAdapter,
                policy: RetryPolicy = .init(), now: @escaping @Sendable () -> Date = Date.init,
                random: @escaping @Sendable () -> Double = { .random(in: 0...1) }, log: ActivityLog? = nil) {
        self.destinations = destinations
        self.remoteState = remoteState
        self.adapterFor = adapterFor
        self.policy = policy
        self.now = now
        self.random = random
        self.log = log
    }

    /// Processes up to `maxItems` due tombstones for the active destination. Cancellation returns at once;
    /// `needsAuthentication` ends the pass and records nothing.
    public func runOnce(maxItems: Int = 20) async -> RemoteDeleteResult {
        var result = RemoteDeleteResult(deleted: 0, failed: 0, idle: true)
        guard !Task.isCancelled, let active = try? destinations.active() else { return result }
        let due: [RemoteTombstone]
        do {
            due = try remoteState.dueTombstones(destinationID: active.id, accountIdentifier: active.accountIdentifier,
                                                now: now(), limit: maxItems)
        } catch {
            Self.osLog.error("\("tombstones_failed", privacy: .public)")
            return result
        }
        for tombstone in due {
            if Task.isCancelled { return result }
            result.idle = false
            do {
                let adapter = try adapterFor(active)
                for path in try Self.folders(for: tombstone) {
                    try Task.checkCancellation()
                    try await adapter.deleteFolder(relativePath: path)
                }
                try remoteState.removeTombstone(captureID: tombstone.captureID)
                log?.append(LogEvent(event: .remoteDelete, captureID: tombstone.captureID, outcome: .ok,
                                     dest: active.providerKind))
                result.deleted += 1
            } catch is CancellationError {
                return result
            } catch StorageError.needsAuthentication {
                return result
            } catch {
                // A cancelled call may surface as any error; it is not a failure of the tombstone.
                if Task.isCancelled { return result }
                result.failed += 1
                record(error, tombstone, active)
            }
        }
        return result
    }

    private static func folders(for t: RemoteTombstone) throws -> [String] {
        do {
            return [t.relativeDirectory,
                    try EnrichmentPaths.remoteDirectory(.device, packageDirectory: t.relativeDirectory),
                    try EnrichmentPaths.remoteDirectory(.server, packageDirectory: t.relativeDirectory)]
        } catch {
            throw StorageError.permanent(code: "local_package_invalid")
        }
    }

    private func record(_ error: Error, _ t: RemoteTombstone, _ destination: Destination) {
        var retryAfter: TimeInterval?
        let code: String
        switch error as? StorageError {
        case .offline?: code = "offline"
        case .transient(let c)?: code = "transient:\(c)"
        case .rateLimited(let after)?: code = "rate_limited"; retryAfter = after
        case .permanent(let c)?: code = "permanent:\(c)"
        case .quotaExceeded?: code = "quota_exceeded"
        case .conflict?: code = "remote_conflict"
        case .checkpointExpired?: code = "checkpoint_expired"
        case .cursorReset?: code = "cursor_reset"
        case .needsAuthentication?: code = "needs_authentication"
        case nil: code = "transient:internal"
        }
        let next = now().addingTimeInterval(policy.delay(attempt: t.attemptCount + 1, retryAfter: retryAfter,
                                                         random: random))
        do {
            try remoteState.markTombstoneFailed(captureID: t.captureID, code: code, nextAttemptAt: next, now: now())
            log?.append(LogEvent(event: .remoteDelete, captureID: t.captureID, outcome: .failed, code: code,
                                 dest: destination.providerKind))
        } catch {
            Self.osLog.error("\("tombstone_record_failed", privacy: .public)")
        }
    }
}
