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
    private static let nothingDone = SyncPassResult(synced: 0, failed: 0, idle: true)

    private static let log = Logger(subsystem: "com.jorgeper.hippo", category: "sync")

    private let store: HippoStore
    private let worker: SyncWorker
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

    public init(store: HippoStore, registry: ProviderRegistry, ownerPrefix: String, appVersion: String) {
        self.store = store
        self.appVersion = appVersion
        worker = store.makeWorker(adapterFor: { try registry.adapter(for: $0) }, owner: ownerPrefix)
    }

    /// Runs a pass, or joins the follow-up pass when one is already running, and returns that pass's
    /// result. A pass cancelled by `stop()` returns what it had done so far.
    public func syncNow() async -> SyncPassResult {
        callsReceived += 1
        if let pending { return await pending.value }
        let generation = generation
        if let running {
            let followUp = Task {
                _ = await running.value
                return await self.promotePending(generation)
            }
            pending = followUp
            return await followUp.value
        }
        let previous = stopped
        let pass = Task {
            _ = await previous?.value
            return await self.run(generation)
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

    private func promotePending(_ generation: Int) async -> SyncPassResult {
        guard generation == self.generation else { return Self.nothingDone }
        running = pending
        pending = nil
        return await run(generation)
    }

    /// Runs a pass, then follow-up passes while the previous one ended with work left. The chain ends
    /// on `stop()`, after `maxFollowUps` follow-ups, or when a pass uploaded nothing (every round
    /// failed), so a persistent failure cannot hot-loop.
    private func run(_ generation: Int) async -> SyncPassResult {
        guard generation == self.generation else { return Self.nothingDone }
        isRunning = true
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
        if generation == self.generation { running = nil }
        return total
    }

    /// `moreWork` is true when the pass used all its rounds without reaching an idle one.
    private func runPass() async -> (result: SyncPassResult, moreWork: Bool) {
        var total = Self.nothingDone
        var moreWork = true
        for _ in 0..<Self.maxRounds {
            if Task.isCancelled { moreWork = false; break }
            let round = await worker.runOnce()
            total.synced += round.synced
            total.failed += round.failed
            if round.idle { moreWork = false; break }
            total.idle = false
        }
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
