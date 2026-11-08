import SwiftUI
import BackgroundTasks
import os
import HippoPresentation
import SyncEngine

/// When uploads run. Launch recovery, in-app captures, Retry and pull-to-refresh each call `runPass`
/// themselves; this file owns the rest: coming to the foreground, going to the background, and the
/// `BGProcessingTask`. Every pass runs inside `BackgroundActivity` and stops the coordinator if
/// background time runs out, so no SQLite lock is held when the process is suspended.
enum SyncScheduling {
    static let taskIdentifier = "com.jorgeper.hippo.sync"
    /// How long after entering the background iOS is asked to wait before running the task.
    static let earliestBeginDelay: TimeInterval = 15 * 60

    private static let log = Logger(subsystem: "com.jorgeper.hippo", category: "scheduling")

    static func logDiagnosticsFailure() { log.error("\("diagnostics_failed", privacy: .public)") }

    /// The `onExpire` for any background-assertion block that syncs.
    static func stopper(_ coordinator: SyncCoordinator) -> @Sendable () -> Void {
        { coordinator.requestStop() }
    }

    @discardableResult
    static func runPass(_ coordinator: SyncCoordinator, name: String) async -> SyncPassResult {
        await BackgroundActivity.run(name: name, onExpire: stopper(coordinator)) { await coordinator.syncNow() }
    }

    /// Call from `App.init`, before launch finishes. The handler is registered even when the store
    /// failed to open (`environment` is nil); a task that arrives then completes as unsuccessful.
    static func registerBackgroundTask(_ environment: AppEnvironment?) {
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            guard let environment, let coordinator = environment.coordinator else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(task, environment: environment, coordinator: coordinator)
        }
        if !registered { log.error("\("bg_register_failed", privacy: .public)") }
    }

    private static func handle(_ task: BGProcessingTask, environment: AppEnvironment, coordinator: SyncCoordinator) {
        let completion = CompleteOnce(task)
        let finish: @Sendable (Bool) -> Void = { completion.finish(success: $0) }
        // On expiry, stop at once and report incomplete when the pass has returned or after the grace.
        task.expirationHandler = {
            completion.markExpired()
            coordinator.requestStop()
            Task {
                try? await Task.sleep(for: BackgroundActivity.expiryGrace)
                finish(false)
            }
        }
        Task {
            await runPass(coordinator, name: "background-sync")
            // After expiry the task may already be completed and the assertion ended; the next
            // background entry resubmits, so skip the unprotected SQLite read here.
            if !completion.expired { await scheduleBackgroundTask(environment) }
            finish(!completion.expired)
        }
    }

    /// Calls `setTaskCompleted` exactly once, whether the pass ends or the task expires first.
    /// `BGTask.setTaskCompleted` may be called from any thread.
    private final class CompleteOnce: @unchecked Sendable {
        private let task: BGProcessingTask
        private let completed = OSAllocatedUnfairLock(initialState: false)
        private let expiredFlag = OSAllocatedUnfairLock(initialState: false)
        init(_ task: BGProcessingTask) { self.task = task }
        var expired: Bool { expiredFlag.withLock { $0 } }
        func markExpired() { expiredFlag.withLock { $0 = true } }
        func finish(success: Bool) {
            let first = completed.withLock { done in defer { done = true }; return !done }
            if first { task.setTaskCompleted(success: success) }
        }
    }

    /// Asks iOS to run a sync later, if anything is waiting to upload to a connected destination.
    static func scheduleBackgroundTask(_ environment: AppEnvironment) async {
        let store = environment.store
        let hasWork = await Task.detached { () -> Bool in
            guard (try? store.destinations.active()) != nil else { return false }
            return ((try? store.index.counts()) ?? [:])[.notSynced, default: 0] > 0
        }.value
        guard hasWork else { return }
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Date(timeIntervalSinceNow: earliestBeginDelay)
        do {
            try await BGTaskScheduler.shared.submitTaskRequest(request)
        } catch {
            log.error("\("bg_submit_failed", privacy: .public)")
        }
    }

    /// Syncs once launch recovery has registered the packages on disk.
    static func syncAfterLaunchRecovery(_ environment: AppEnvironment) async {
        guard let coordinator = environment.coordinator else { return }
        await runPass(coordinator, name: "launch-sync")
    }
}

private struct SyncSchedulingModifier: ViewModifier {
    let environment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                enteredBackground()
            case .active:
                // Every activation syncs; the coordinator coalesces overlapping calls.
                if let coordinator = environment.coordinator {
                    Task { await SyncScheduling.runPass(coordinator, name: "foreground-sync") }
                }
            default:
                break
            }
        }
    }

    private func enteredBackground() {
        let environment = environment
        Task {
            await BackgroundActivity.run(name: "enter-background") {
                do {
                    try environment.store.writeDiagnostics(appVersion: environment.producer.appVersion)
                } catch {
                    SyncScheduling.logDiagnosticsFailure()
                }
                await SyncScheduling.scheduleBackgroundTask(environment)
            }
        }
    }
}

extension View {
    func syncScheduling(_ environment: AppEnvironment) -> some View {
        modifier(SyncSchedulingModifier(environment: environment))
    }
}
