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
    private static let nothingDone = SyncPassResult(synced: 0, failed: 0, idle: true)

    private static let log = Logger(subsystem: "com.jorgeper.hippo", category: "sync")

    private let store: HippoStore
    private let worker: SyncWorker
    private let appVersion: String

    /// The current pass: running, or about to run once the pass it follows has finished.
    private var running: Task<SyncPassResult, Never>?
    /// The follow-up pass, waiting for `running`.
    private var pending: Task<SyncPassResult, Never>?
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

    private func promotePending(_ generation: Int) async -> SyncPassResult {
        guard generation == self.generation else { return Self.nothingDone }
        running = pending
        pending = nil
        return await run(generation)
    }

    private func run(_ generation: Int) async -> SyncPassResult {
        guard generation == self.generation else { return Self.nothingDone }
        isRunning = true
        var total = Self.nothingDone
        for _ in 0..<Self.maxRounds {
            if Task.isCancelled { break }
            let round = await worker.runOnce()
            total.synced += round.synced
            total.failed += round.failed
            if round.idle { break }
            total.idle = false
        }
        do {
            try store.writeDiagnostics(appVersion: appVersion)
        } catch {
            Self.log.error("\("diagnostics_failed", privacy: .public)")
        }
        isRunning = false
        if generation == self.generation { running = nil }
        NotificationCenter.default.post(name: Self.passFinished, object: self)
        return total
    }
}
