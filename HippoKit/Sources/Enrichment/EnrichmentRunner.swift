import Foundation
import CaptureCore
import LocalRepository
import os

public struct EnrichmentPassResult: Sendable, Equatable {
    /// Tasks whose enricher was run this pass, whatever the outcome (including deferrals and failures).
    public var ran: Int
    /// Of those, the attempts that failed (transient or permanent errors, or a result that couldn't be saved).
    public var failed: Int
    /// True when the pass claimed no task.
    public var idle: Bool

    public init(ran: Int, failed: Int, idle: Bool) {
        self.ran = ran
        self.failed = failed
        self.idle = idle
    }
}

/// Runs silver enrichment (design §10): decides which (capture, kind) work exists, runs it one task at a
/// time and records each outcome in the capture's device document and its task row. Only the app runs
/// it; passes are serialized. Network kinds wait while offline without spending attempts; transient
/// failures back off up to `maxAttempts`; a facet that gets new data reruns the enrichers that read it.
public actor EnrichmentRunner {
    public static let maxAttempts = 5
    /// Posted on the main actor after each `runPending`.
    public static let passFinished = Notification.Name("HippoEnrichmentPassFinished")

    /// Fixed category strings only: never IDs, paths, URLs or content.
    private static let log = Logger(subsystem: "com.jorgeper.hippo", category: "enrichment")

    private let layout: StoreLayout
    private let index: CaptureIndex
    private let tasks: EnrichmentTaskStore
    private let store: EnrichmentStore
    private let enrichers: [any Enricher]
    private let byKind: [FacetKind: any Enricher]
    private let producer: EnrichmentProducer
    private let isEnabled: @Sendable (FacetKind) -> Bool
    private let isOnline: @Sendable () -> Bool
    private let policy: RetryPolicy
    private let now: @Sendable () -> Date
    private let random: @Sendable () -> Double

    private var passRunning = false
    private var waitingPasses: [CheckedContinuation<Void, Never>] = []

    public init(layout: StoreLayout, index: CaptureIndex, tasks: EnrichmentTaskStore, store: EnrichmentStore,
                enrichers: [any Enricher], producer: EnrichmentProducer,
                isEnabled: @escaping @Sendable (FacetKind) -> Bool, isOnline: @escaping @Sendable () -> Bool,
                policy: RetryPolicy = .init(), now: @escaping @Sendable () -> Date = Date.init,
                random: @escaping @Sendable () -> Double = { .random(in: 0...1) }) {
        self.layout = layout
        self.index = index
        self.tasks = tasks
        self.store = store
        // One enricher per kind: the first one listed wins.
        var byKind: [FacetKind: any Enricher] = [:]
        var unique: [any Enricher] = []
        for e in enrichers where byKind[e.kind] == nil {
            byKind[e.kind] = e
            unique.append(e)
        }
        self.enrichers = unique
        self.byKind = byKind
        self.producer = producer
        self.isEnabled = isEnabled
        self.isOnline = isOnline
        self.policy = policy
        self.now = now
        self.random = random
    }

    // MARK: Scheduling

    /// For each enabled enricher, gives every capture with no row for its kind, or a row at another
    /// version, a row at the enricher's version: `pending` if the enricher applies, else
    /// `not_applicable`. At most `limitPerKind` captures per kind, newest first. Returns how many rows
    /// became `pending`.
    @discardableResult
    public func schedule(limitPerKind: Int = 500) throws -> Int {
        var pending = 0
        for e in enrichers where isEnabled(e.kind) {
            for id in try tasks.capturesNeeding(kind: e.kind, version: e.version, limit: limitPerKind) {
                if try scheduleOne(captureID: id, e) { pending += 1 }
            }
        }
        return pending
    }

    /// Sets the capture's row for `e` at `e.version`. True if it became `pending`. A capture whose
    /// metadata can't be read gets `failed` (retried only after a version bump).
    private func scheduleOne(captureID id: String, _ e: any Enricher) throws -> Bool {
        let t = now()
        let metadata: CaptureMetadata
        do {
            guard let m = try index.metadata(captureID: id, layout: layout) else { return false }  // deleted
            metadata = m
        } catch let error as DatabaseError {
            throw error
        } catch {
            Self.log.error("\("enrichment_metadata_unreadable", privacy: .public)")
            try tasks.set(captureID: id, kind: e.kind, version: e.version, status: "failed", now: t)
            try tasks.recordAttempt(captureID: id, kind: e.kind, status: "failed", errorCode: "metadata_unreadable",
                                    nextAttemptAt: nil, incrementAttempts: true, now: t)
            return false
        }
        let applies = e.applies(to: metadata)
        try tasks.set(captureID: id, kind: e.kind, version: e.version, status: applies ? "pending" : "not_applicable",
                      now: t)
        return applies
    }

    /// True if a pass would claim a task now, or a capture still needs scheduling for an enabled kind.
    public func hasWork() throws -> Bool {
        if try tasks.hasDueWork(kinds: claimableKinds(), now: now()) { return true }
        for e in enrichers where isEnabled(e.kind) {
            if try !tasks.capturesNeeding(kind: e.kind, version: e.version, limit: 1).isEmpty { return true }
        }
        return false
    }

    /// Enabled kinds, minus network kinds while offline.
    private func claimableKinds() -> Set<FacetKind> {
        let online = isOnline()
        return Set(enrichers.filter { isEnabled($0.kind) && (online || !$0.usesNetwork) }.map(\.kind))
    }

    // MARK: Running

    private enum Outcome {
        case ran(failed: Bool)
        /// Claimed but not run (rescheduled at a new version, or the capture is gone).
        case skipped
        case cancelled
    }

    /// Runs up to `maxTasks` due tasks, one at a time, newest capture first. Stops early when nothing is
    /// due or the calling task is cancelled; a cancelled task's row is left untouched. Passes never
    /// overlap: a call made during a pass waits for it to finish.
    public func runPending(maxTasks: Int = 50) async -> EnrichmentPassResult {
        await beginPass()
        var result = EnrichmentPassResult(ran: 0, failed: 0, idle: true)
        var claimed = 0
        passLoop: while claimed < maxTasks, !Task.isCancelled {
            let next: EnrichmentTask?
            do {
                next = try tasks.claimNext(kinds: claimableKinds(), now: now())
            } catch {
                Self.log.error("\("enrichment_claim_failed", privacy: .public)")
                break
            }
            guard let task = next, let enricher = byKind[task.kind] else { break }
            claimed += 1
            result.idle = false
            switch await process(task, enricher) {
            case .ran(let failed):
                result.ran += 1
                if failed { result.failed += 1 }
            case .skipped:
                break
            case .cancelled:
                break passLoop
            }
        }
        endPass()
        await MainActor.run { NotificationCenter.default.post(name: Self.passFinished, object: nil) }
        return result
    }

    private func beginPass() async {
        while passRunning {
            await withCheckedContinuation { waitingPasses.append($0) }
        }
        passRunning = true
    }

    private func endPass() {
        passRunning = false
        if !waitingPasses.isEmpty { waitingPasses.removeFirst().resume() }
    }

    private func process(_ task: EnrichmentTask, _ e: any Enricher) async -> Outcome {
        let id = task.captureID
        // A row left at another version (the app updated without scheduling): reschedule, don't run stale.
        if task.version != e.version {
            do { _ = try scheduleOne(captureID: id, e) } catch {
                Self.log.error("\("enrichment_schedule_failed", privacy: .public)")
            }
            return .skipped
        }

        let metadata: CaptureMetadata
        let packageURL: URL
        do {
            guard let m = try index.metadata(captureID: id, layout: layout),
                  let dir = try index.relativeDirectory(captureID: id) else { return .skipped }  // deleted
            metadata = m
            packageURL = layout.packageURL(relativeDirectory: dir)
        } catch {
            Self.log.error("\("enrichment_metadata_unreadable", privacy: .public)")
            record(task, status: "failed", code: "metadata_unreadable", nextAttemptAt: nil, countsAttempt: true)
            return .ran(failed: true)
        }
        // Validating a package hashes every file, so only typed notes (small) are loaded for their body.
        let noteBody = metadata.captureMethod == .typedNote
            ? CommittedPackage.load(directory: packageURL, layout: layout)?.noteBody() : nil
        var current: EnrichmentDocument?
        var currentUnreadable = false
        do { current = try store.document(.device, captureID: id) } catch {
            // Rebuilt from scratch below; the other kinds rerun to refill it.
            Self.log.error("\("enrichment_document_unreadable", privacy: .public)")
            currentUnreadable = true
        }

        let input = EnricherInput(captureID: id, metadata: metadata, packageURL: packageURL, noteBody: noteBody,
                                  current: current)
        let output: EnricherOutput
        do {
            output = try await e.run(input)
        } catch {
            if error is CancellationError || Task.isCancelled { return .cancelled }
            return handle(error, task, e, current: current)
        }
        defer { removeTemporaryFiles(output.newAssets) }
        if Task.isCancelled { return .cancelled }

        let t = now()
        let facet = Facet(version: e.version, status: output.status, generatedAt: t, provenance: output.provenance,
                          data: output.data)
        switch save(facet, kind: e.kind, captureID: id, current: current, newAssets: output.newAssets) {
        case .saved:
            record(task, status: output.status.rawValue, code: nil, nextAttemptAt: nil, countsAttempt: true)
            if currentUnreadable {
                for other in enrichers where other.kind != e.kind { resetToPending(id, other.kind) }
            }
            return .ran(failed: false)
        case .gone:
            return .ran(failed: false)
        case .failed:
            return retryOrFail(task, e, code: "write_failed", current: current)
        }
    }

    /// Records a failed attempt per its kind of error. Errors that aren't `EnrichmentError` are transient.
    private func handle(_ error: Error, _ task: EnrichmentTask, _ e: any Enricher,
                        current: EnrichmentDocument?) -> Outcome {
        switch error as? EnrichmentError {
        case .deferred(let code, let retryAfter):
            record(task, status: "pending", code: code, nextAttemptAt: now().addingTimeInterval(max(retryAfter, 0)),
                   countsAttempt: false)
            return .ran(failed: false)
        case .permanent(let code):
            return fail(task, e, code: code, current: current)
        case .transient(let code):
            return retryOrFail(task, e, code: code, current: current)
        case nil:
            Self.log.error("\("enrichment_unexpected_error", privacy: .public)")
            return retryOrFail(task, e, code: "unexpected", current: current)
        }
    }

    private func retryOrFail(_ task: EnrichmentTask, _ e: any Enricher, code: String,
                             current: EnrichmentDocument?) -> Outcome {
        let attempt = task.attemptCount + 1
        guard attempt < Self.maxAttempts else { return fail(task, e, code: code, current: current) }
        let delay = policy.delay(attempt: attempt, retryAfter: nil, random: random)
        record(task, status: "pending", code: code, nextAttemptAt: now().addingTimeInterval(delay), countsAttempt: true)
        return .ran(failed: true)
    }

    /// Writes a `failed` facet (no data; provenance is the error code) and records `failed`.
    private func fail(_ task: EnrichmentTask, _ e: any Enricher, code: String,
                      current: EnrichmentDocument?) -> Outcome {
        let facet = Facet(version: e.version, status: .failed, generatedAt: now(), provenance: code, data: nil)
        _ = save(facet, kind: e.kind, captureID: task.captureID, current: current, newAssets: [:])
        record(task, status: "failed", code: code, nextAttemptAt: nil, countsAttempt: true)
        return .ran(failed: true)
    }

    // MARK: Saving

    private enum SaveResult { case saved, gone, failed }

    /// Merges `facet` into the capture's device document (or a new one) and writes it. When the facet's
    /// data changed, the enrichers that read this kind are made pending again.
    private func save(_ facet: Facet, kind: FacetKind, captureID id: String, current: EnrichmentDocument?,
                      newAssets: [String: URL]) -> SaveResult {
        do {
            var doc: EnrichmentDocument
            if let current {
                doc = current
            } else {
                guard let digest = try index.packageDigest(captureID: id) else { return .gone }
                doc = EnrichmentDocument(schemaVersion: 1, captureID: id, layer: .device, packageDigest: digest,
                                         producer: producer, generatedAt: facet.generatedAt, facets: [:])
            }
            let previous = doc[kind]?.data
            doc.facets[kind.rawValue] = facet
            doc.producer = producer
            doc.generatedAt = facet.generatedAt
            try store.write(doc, newAssets: newAssets)
            if previous != facet.data {
                for dependent in enrichers where dependent.kind != kind && dependent.inputs.contains(kind) {
                    resetToPending(id, dependent.kind)
                }
            }
            return .saved
        } catch EnrichmentStoreError.notIndexed {
            return .gone  // The capture was deleted while its enricher ran: drop the result.
        } catch {
            Self.log.error("\("enrichment_write_failed", privacy: .public)")
            return .failed
        }
    }

    private func record(_ task: EnrichmentTask, status: String, code: String?, nextAttemptAt: Date?,
                        countsAttempt: Bool) {
        do {
            try tasks.recordAttempt(captureID: task.captureID, kind: task.kind, status: status, errorCode: code,
                                    nextAttemptAt: nextAttemptAt, incrementAttempts: countsAttempt, now: now())
        } catch {
            Self.log.error("\("enrichment_record_failed", privacy: .public)")
        }
    }

    private func resetToPending(_ captureID: String, _ kind: FacetKind) {
        do { try tasks.resetToPending(captureID: captureID, kind: kind, now: now()) } catch {
            Self.log.error("\("enrichment_reset_failed", privacy: .public)")
        }
    }

    /// Deletes an enricher's temp files: the whole `tmp-<uuid>` directory directly under enrichment
    /// staging, or just the file. Never touches anything outside enrichment staging.
    private func removeTemporaryFiles(_ assets: [String: URL]) {
        let staging = layout.enrichmentStagingDir.standardizedFileURL.path
        for url in assets.values {
            let file = url.standardizedFileURL
            guard file.path.hasPrefix(staging + "/") else { continue }
            let parent = file.deletingLastPathComponent()
            let isTempDir = parent.lastPathComponent.hasPrefix("tmp-")
                && parent.deletingLastPathComponent().path == staging
            do { try FileManager.default.removeItem(at: isTempDir ? parent : file) } catch let error as CocoaError
                where error.code == .fileNoSuchFile {
                // Already gone (another asset shared its directory).
            } catch {
                Self.log.error("\("enrichment_temp_cleanup_failed", privacy: .public)")
            }
        }
    }
}
