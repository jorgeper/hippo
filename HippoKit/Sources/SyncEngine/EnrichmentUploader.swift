import Foundation
import os
import CaptureCore
import LocalRepository

/// Uploads each capture's on-device (silver) enrichment to the active destination once the capture's
/// package has synced (design §6.3). Assets go first, `enrichment.json` last, so a reader never sees a
/// document whose assets are missing. Silver is replaceable: the document is written with `replaceFile`
/// and recorded as uploaded only after remote verification. Work is tracked per (capture, destination)
/// in `enrichment_uploads`; there are no leases, because only the app process runs this and each pass is
/// serialized by its caller. Error codes never carry content, file names, URLs or account identifiers.
public final class EnrichmentUploader: Sendable {
    private static let log = Logger(subsystem: "com.jorgeper.hippo", category: "enrichment")

    private let layout: StoreLayout
    private let destinations: DestinationStore
    private let enrichments: EnrichmentStore
    private let adapterFor: @Sendable (Destination) throws -> any StorageAdapter
    private let policy: RetryPolicy
    private let now: @Sendable () -> Date
    private let random: @Sendable () -> Double
    private let log: ActivityLog?

    public init(layout: StoreLayout, destinations: DestinationStore, enrichments: EnrichmentStore,
                adapterFor: @escaping @Sendable (Destination) throws -> any StorageAdapter,
                policy: RetryPolicy = .init(), now: @escaping @Sendable () -> Date = Date.init,
                random: @escaping @Sendable () -> Double = { .random(in: 0...1) }, log: ActivityLog? = nil) {
        self.log = log
        self.layout = layout
        self.destinations = destinations
        self.enrichments = enrichments
        self.adapterFor = adapterFor
        self.policy = policy
        self.now = now
        self.random = random
    }

    /// Processes up to `maxCaptures` candidates for the active destination, one at a time. Cancellation
    /// ends the pass at once and records nothing for the capture in flight; `needsAuthentication` ends
    /// it without counting a failure.
    public func runOnce(maxCaptures: Int = 20) async -> SyncPassResult {
        var result = SyncPassResult(synced: 0, failed: 0, idle: true)
        guard !Task.isCancelled, let destination = try? destinations.active() else { return result }
        let candidates: [(captureID: String, relativeDirectory: String, revision: String)]
        do {
            candidates = try enrichments.uploadCandidates(destinationID: destination.id, now: now(), limit: maxCaptures)
        } catch {
            Self.log.error("\("enrichment_upload_candidates_failed", privacy: .public)")
            result.idle = false
            result.failed += 1
            return result
        }
        for candidate in candidates {
            if Task.isCancelled { return result }
            result.idle = false
            switch await process(candidate, destination: destination) {
            case .uploaded: result.synced += 1
            case .failed: result.failed += 1
            case .skipped: break
            case .stopped: return result
            }
        }
        return result
    }

    private enum Outcome { case uploaded, failed, skipped, stopped }

    private struct Failure: Error {
        var blocked: Bool
        var code: String
        var retryAfter: TimeInterval? = nil
    }

    /// The local document changed since the capture was selected; the next pass handles it.
    private struct Superseded: Error {}

    private func process(_ c: (captureID: String, relativeDirectory: String, revision: String),
                         destination: Destination) async -> Outcome {
        do {
            try await upload(c, destination: destination)
            try enrichments.markUploaded(captureID: c.captureID, destinationID: destination.id,
                                         revision: c.revision, now: now())
            log?.append(LogEvent(event: .silverUploaded, captureID: c.captureID, dest: destination.providerKind))
            return .uploaded
        } catch is CancellationError {
            return .stopped
        } catch is Superseded {
            return .skipped
        } catch let failure as Failure {
            return record(failure, c, destination)
        } catch let error as StorageError {
            if case .needsAuthentication = error { return .stopped }
            return record(Self.failure(for: error), c, destination)
        } catch {
            return record(Failure(blocked: false, code: "transient:internal"), c, destination)
        }
    }

    private func upload(_ c: (captureID: String, relativeDirectory: String, revision: String),
                        destination: Destination) async throws {
        let remoteDirectory: String
        do {
            remoteDirectory = try EnrichmentPaths.remoteDirectory(.device, packageDirectory: c.relativeDirectory)
        } catch {
            throw Failure(blocked: true, code: "local_package_invalid")
        }
        let localDirectory = layout.enrichmentDirectory(.device, captureID: c.captureID)
        let documentURL = localDirectory.appendingPathComponent(EnrichmentPaths.documentName)
        // An unreadable or missing document is left to index reconciliation; nothing to upload.
        guard let document = try? enrichments.document(.device, captureID: c.captureID) else { throw Superseded() }
        let assets = document.referencedAssets()
        let adapter = try adapterFor(destination)

        try Task.checkCancellation()
        try await adapter.ensureContainer(relativePath: remoteDirectory)
        if !assets.isEmpty { try await adapter.ensureContainer(relativePath: remoteDirectory + "/assets") }

        for asset in assets {
            try Task.checkCancellation()
            guard EnrichmentPaths.isValidAssetPath(asset.relativePath) else {
                throw Failure(blocked: true, code: "local_package_invalid")
            }
            let local = enrichments.assetURL(.device, captureID: c.captureID, asset: asset)
            guard FileManager.default.fileExists(atPath: local.path) else {
                throw Failure(blocked: true, code: "local_asset_missing")
            }
            try await syncAsset(local: local, remotePath: remoteDirectory + "/" + asset.relativePath,
                                expected: FileIntegrity(byteCount: asset.byteCount, sha256: asset.sha256),
                                adapter: adapter)
        }

        // Only the revision selected is uploaded: if the document moved on, the next pass takes it.
        try Task.checkCancellation()
        guard let digest = try? StreamingHasher.digest(of: documentURL), digest.sha256 == c.revision else {
            throw Superseded()
        }
        let expected = FileIntegrity(byteCount: digest.byteCount, sha256: digest.sha256)
        let remotePath = remoteDirectory + "/" + EnrichmentPaths.documentName
        _ = try await adapter.replaceFile(localURL: documentURL, relativePath: remotePath, expected: expected)
        guard let uploaded = try await adapter.inspectFile(relativePath: remotePath),
              try await adapter.verify(remote: uploaded, localURL: documentURL, expected: expected) != nil else {
            throw Failure(blocked: false, code: "verify_failed")
        }
    }

    private func syncAsset(local: URL, remotePath: String, expected: FileIntegrity,
                           adapter: any StorageAdapter) async throws {
        if let existing = try await adapter.inspectFile(relativePath: remotePath) {
            guard try await adapter.verify(remote: existing, localURL: local, expected: expected) != nil else {
                throw Failure(blocked: true, code: "remote_conflict")
            }
            return
        }
        _ = try await adapter.uploadFile(localURL: local, relativePath: remotePath, expected: expected,
                                         checkpoint: nil, saveCheckpoint: { _ in try Task.checkCancellation() })
        guard let uploaded = try await adapter.inspectFile(relativePath: remotePath),
              try await adapter.verify(remote: uploaded, localURL: local, expected: expected) != nil else {
            throw Failure(blocked: false, code: "verify_failed")
        }
    }

    /// Records the failure. If that fails the capture simply stays a candidate.
    private func record(_ failure: Failure, _ c: (captureID: String, relativeDirectory: String, revision: String),
                        _ destination: Destination) -> Outcome {
        do {
            var next: Date?
            if !failure.blocked {
                let attempts = try enrichments.uploadAttemptCount(captureID: c.captureID, destinationID: destination.id,
                                                                  revision: c.revision)
                next = now().addingTimeInterval(policy.delay(attempt: attempts + 1, retryAfter: failure.retryAfter,
                                                             random: random))
            }
            try enrichments.markUploadFailed(captureID: c.captureID, destinationID: destination.id,
                                             revision: c.revision, code: failure.code, blocked: failure.blocked,
                                             nextAttemptAt: next, now: now())
            log?.append(LogEvent(event: .silverUploadFailed, captureID: c.captureID, code: failure.code,
                                 dest: destination.providerKind))
            return .failed
        } catch {
            Self.log.error("\("enrichment_upload_record_failed", privacy: .public)")
            return .skipped
        }
    }

    private static func failure(for error: StorageError) -> Failure {
        switch error {
        case .offline: Failure(blocked: false, code: "offline")
        case .transient(let code): Failure(blocked: false, code: "transient:\(code)")
        case .rateLimited(let retryAfter): Failure(blocked: false, code: "rate_limited", retryAfter: retryAfter)
        case .checkpointExpired: Failure(blocked: false, code: "checkpoint_expired")
        case .cursorReset: Failure(blocked: false, code: "cursor_reset")
        case .needsAuthentication: Failure(blocked: false, code: "needs_authentication")
        case .quotaExceeded: Failure(blocked: true, code: "quota_exceeded")
        case .conflict: Failure(blocked: true, code: "remote_conflict")
        case .permanent(let code): Failure(blocked: true, code: "permanent:\(code)")
        }
    }
}
