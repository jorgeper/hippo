import Foundation
import os
import LocalRepository
import SyncEngine

/// Runs upload passes for one process, one pass at a time. A call made while a pass runs waits for a
/// single follow-up pass, shared by every call made during that pass, so work captured mid-pass is
/// picked up without passes piling up. Only `stop()` cancels passes; cancelling a caller does not.
public actor SyncCoordinator {
    /// Posted, with the coordinator as the object, after every pass.
    public static let passFinished = Notification.Name("HippoSyncPassFinished")
    /// A pass stops after this many `runOnce()` rounds even if work remains.
    static let maxRounds = 10
    /// Consecutive follow-up passes after the first when work remains (25 x 200 jobs).
    static let maxFollowUps = 25
    /// A pass makes at most this many silver upload rounds (`EnrichmentUploader.runOnce`, 20 captures each).
    static let maxUploadRounds = 10
    private static let nothingDone = SyncPassResult(synced: 0, failed: 0, idle: true)

    private static let log = Logger(subsystem: "com.jorgeper.hippo", category: "sync")

    private let store: HippoStore
    private let worker: SyncWorker
    private let deleter: RemoteDeleter
    private let uploader: EnrichmentUploader
    private let puller: GoldPuller
    private let detector: RemoteChangeDetector
    private let logUploader: LogUploader
    private let formatUploader: FormatUploader?
    private let settings: AppSettings
    private let appVersion: String

    /// The current pass: running, or about to run once the pass it follows has finished.
    private var running: Task<SyncPassResult, Never>? { didSet { mirrorHandles() } }
    /// The follow-up pass, waiting for `running`.
    private var pending: Task<SyncPassResult, Never>? { didSet { mirrorHandles() } }
    /// Copies of `running` and `pending` that `requestStop()` can cancel without an actor hop.
    private let handles = OSAllocatedUnfairLock(initialState: [Task<SyncPassResult, Never>]())
    /// The last pass `stop()` cancelled. A new pass waits for it to wind down, so passes never overlap.
    private var stopped: Task<SyncPassResult, Never>?
    /// Bumped by `stop()`; a pass scheduled before then never starts.
    private var generation = 0
    /// Counts `syncNow()` calls; tests use it to know a call has been scheduled or joined.
    private(set) var callsReceived = 0

    /// True while a pass is executing; false between a pass and its follow-up.
    public private(set) var isRunning = false
    /// True while a pass is running or a follow-up is waiting.
    public var isBusy: Bool { running != nil || pending != nil }

    /// `random` draws the upload retry jitter (0...1); tests pass a constant.
    public init(store: HippoStore, registry: ProviderRegistry, ownerPrefix: String, appVersion: String,
                settings: AppSettings, formatUploader: FormatUploader? = nil,
                isConstrained: @escaping @Sendable () -> Bool = { false },
                random: @escaping @Sendable () -> Double = { .random(in: 0...1) }) {
        self.store = store
        self.settings = settings
        self.formatUploader = formatUploader
        self.appVersion = appVersion
        worker = store.makeWorker(adapterFor: { try registry.adapter(for: $0) }, owner: ownerPrefix, random: random)
        deleter = store.makeRemoteDeleter(adapterFor: { try registry.adapter(for: $0) })
        uploader = store.makeEnrichmentUploader(adapterFor: { try registry.adapter(for: $0) })
        puller = store.makeGoldPuller(adapterFor: { try registry.adapter(for: $0) })
        detector = store.makeChangeDetector(adapterFor: { try registry.adapter(for: $0) })
        logUploader = store.makeLogUploader(installID: settings.installID, adapterFor: { try registry.adapter(for: $0) },
                                          isConstrained: isConstrained)
    }

    /// Makes the next pass write the format files to `destinationID` again, even if they were uploaded before.
    public func forgetFormatUpload(destinationID: String) {
        formatUploader?.forgetUpload(destinationID: destinationID)
    }

    /// When the earliest waiting retry of the connected destination is due, or nil when nothing waits
    /// or nothing is connected.
    public func nextRetryAt() -> Date? {
        guard let active = try? store.destinations.active() else { return nil }
        return try? store.jobs.nextAttemptAt(destinationID: active.id)
    }

    /// Runs a pass, or joins the follow-up pass when one is already running, and returns that pass's
    /// result. A pass cancelled by `stop()` returns what it had done so far.
    /// `trigger` says why (a fixed string, e.g. `manual`); it lands on the pass's `sync.pass` events. A call
    /// that joins a pass already waiting shares that pass's trigger.
    public func syncNow(trigger: String = "manual") async -> SyncPassResult {
        callsReceived += 1
        if let pending { return await pending.value }
        let generation = generation
        if let running {
            let followUp = Task {
                _ = await running.value
                return await self.promotePending(generation, trigger: trigger)
            }
            pending = followUp
            return await followUp.value
        }
        let previous = stopped
        let pass = Task {
            _ = await previous?.value
            return await self.run(generation, trigger: trigger)
        }
        running = pass
        return await pass.value
    }

    /// Cancels the running pass and any follow-up (e.g. when background time expires). The job being
    /// uploaded keeps its lease and is reclaimed once it expires. The next `syncNow()` starts a fresh
    /// pass after the cancelled one has wound down.
    public func stop() {
        generation += 1
        running?.cancel()
        pending?.cancel()
        stopped = running ?? stopped
        running = nil
        pending = nil
    }

    /// Starts cancelling the current and waiting passes immediately, from any thread, without waiting
    /// for the actor (for expiry handlers that must not hop). Also performs `stop()`'s bookkeeping.
    public nonisolated func requestStop() {
        handles.withLock { $0 }.forEach { $0.cancel() }
        Task { await stop() }
    }

    private func mirrorHandles() {
        let current = [running, pending].compactMap { $0 }
        handles.withLock { $0 = current }
    }

    private func promotePending(_ generation: Int, trigger: String) async -> SyncPassResult {
        guard generation == self.generation else { return Self.nothingDone }
        running = pending
        pending = nil
        return await run(generation, trigger: trigger)
    }

    /// Runs a pass, then follow-up passes while the previous one ended with work left. The chain ends
    /// on `stop()`, after `maxFollowUps` follow-ups, or when a pass uploaded nothing (every round
    /// failed), so a persistent failure cannot hot-loop.
    private func run(_ generation: Int, trigger: String) async -> SyncPassResult {
        guard generation == self.generation else { return Self.nothingDone }
        isRunning = true
        // With nowhere to upload, the pass syncs nothing, so it isn't recorded as a sync.
        let hadDestination = (try? store.destinations.active()) != nil
        store.log.append(LogEvent(event: .syncPass, trigger: trigger, phase: "start"))
        var total = Self.nothingDone
        var followUps = 0
        while true {
            let pass = await runPass()
            total.synced += pass.result.synced
            total.failed += pass.result.failed
            total.idle = total.idle && pass.result.idle
            let carryOn = pass.moreWork && pass.result.synced > 0 && followUps < Self.maxFollowUps
                && !Task.isCancelled && generation == self.generation
            if !carryOn { break }
            followUps += 1
        }
        isRunning = false
        let cancelled = Task.isCancelled || generation != self.generation
        if !cancelled, hadDestination { settings.recordSync(at: Date(), failed: total.failed > 0) }
        let endCode = Task.isCancelled || generation != self.generation ? "cancelled" : total.failed > 0 ? "failed" : "ok"
        store.log.append(LogEvent(event: .syncPass, code: endCode, count: total.synced, trigger: trigger, phase: "end"))
        if generation == self.generation { running = nil }
        return total
    }

    /// `moreWork` is true when the pass used all its rounds without reaching an idle one.
    private func runPass() async -> (result: SyncPassResult, moreWork: Bool) {
        var total = Self.nothingDone
        var moreWork = true
        // Delete-everywhere tombstones go first, so a deleted capture is never uploaded again. They never
        // change the pass result or the follow-up decision.
        if !Task.isCancelled { _ = await deleter.runOnce() }
        // The folder describes itself before anything else lands in it. A failure is logged by the uploader,
        // retried on a later pass, and never stops this one.
        if !Task.isCancelled { _ = await formatUploader?.upload() }
        for _ in 0..<Self.maxRounds {
            if Task.isCancelled { moreWork = false; break }
            let round = await worker.runOnce()
            total.synced += round.synced
            total.failed += round.failed
            if round.idle { moreWork = false; break }
            total.idle = false
        }
        // Silver uploads never change the pass result or the follow-up decision. A backlog (the first
        // launch backfills the whole library) drains in batches while each one uploads something,
        // bounded by `maxUploadRounds`.
        for _ in 0..<Self.maxUploadRounds {
            if Task.isCancelled { break }
            let round = await uploader.runOnce()
            if round.idle || round.synced == 0 { break }
        }
        // Gold pulls never change the pass result or the follow-up decision either.
        if !Task.isCancelled { _ = await puller.pull() }
        // Deletes and changes made in the destination, after this pass's uploads; never change the result.
        if !Task.isCancelled { _ = await detector.run() }
        // Log uploads are not events and never change the pass result.
        if !Task.isCancelled { _ = await logUploader.upload() }
        store.log.prune()
        do {
            try store.writeDiagnostics(appVersion: appVersion)
        } catch {
            Self.log.error("\("diagnostics_failed", privacy: .public)")
        }
        // Posted on the main actor so SwiftUI `onReceive` handlers never run off-main.
        await MainActor.run { NotificationCenter.default.post(name: Self.passFinished, object: self) }
        return (total, moreWork)
    }
}
