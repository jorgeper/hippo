import Foundation
import os
import LocalRepository
import SyncEngine

/// Runs upload passes for one process, one pass at a time. A call made while a pass runs waits for a
/// single follow-up pass, shared by every call made during that pass, so work captured mid-pass is
/// picked up without passes piling up.
public actor SyncCoordinator {
    /// Posted, with the coordinator as the object, after every pass.
    public static let passFinished = Notification.Name("HippoSyncPassFinished")
    /// A pass stops after this many `runOnce()` rounds even if work remains.
    static let maxRounds = 10

    private static let log = Logger(subsystem: "com.jorgeper.hippo", category: "sync")

    private let store: HippoStore
    private let worker: SyncWorker
    private let appVersion: String

    /// The most recently scheduled pass; it waits for the one before it.
    private var latest: Task<SyncPassResult, Never>?
    private var scheduled = 0
    private var started = 0

    public private(set) var isRunning = false

    public init(store: HippoStore, registry: ProviderRegistry, ownerPrefix: String, appVersion: String) {
        self.store = store
        self.appVersion = appVersion
        worker = store.makeWorker(adapterFor: { try registry.adapter(for: $0) }, owner: ownerPrefix)
    }

    /// Runs a pass, or joins the follow-up pass when one is already running, and returns that pass's
    /// result. Cancelling the caller cancels the pass it waits on; the job being uploaded is then
    /// reclaimed once its lease expires.
    public func syncNow() async -> SyncPassResult {
        let pass: Task<SyncPassResult, Never>
        if let latest, started < scheduled {
            // A pass is scheduled but not started yet: it will see everything this call would.
            pass = latest
        } else {
            scheduled += 1
            let number = scheduled, previous = latest
            pass = Task {
                _ = await previous?.value
                return await self.run(number)
            }
            latest = pass
        }
        return await withTaskCancellationHandler {
            await pass.value
        } onCancel: {
            pass.cancel()
        }
    }

    private func run(_ number: Int) async -> SyncPassResult {
        started = number
        isRunning = true
        var total = SyncPassResult(synced: 0, failed: 0, idle: true)
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
        if number == scheduled { latest = nil }
        NotificationCenter.default.post(name: Self.passFinished, object: self)
        return total
    }
}
