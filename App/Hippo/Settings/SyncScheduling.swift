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

    /// The `onExpire` for any background-assertion block that syncs.
    static func stopper(_ coordinator: SyncCoordinator) -> @Sendable () -> Void {
        { Task { await coordinator.stop() } }
    }

    @discardableResult
    static func runPass(_ coordinator: SyncCoordinator, name: String) async -> SyncPassResult {
        await BackgroundActivity.run(name: name, onExpire: stopper(coordinator)) { await coordinator.syncNow() }
    }

    /// Call from `App.init`, before launch finishes.
    static func registerBackgroundTask(_ environment: AppEnvironment) {
        guard let coordinator = environment.coordinator else { return }
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            handle(task, coordinator: coordinator)
        }
        if !registered { log.error("\("bg_register_failed", privacy: .public)") }
    }

    private static func handle(_ task: BGProcessingTask, coordinator: SyncCoordinator) {
        let completion = CompleteOnce(task)
        let finish: @Sendable (Bool) -> Void = { completion.finish(success: $0) }
        task.expirationHandler = {
            Task {
                await coordinator.stop()
                finish(false)
            }
        }
        Task {
            await runPass(coordinator, name: "background-sync")
            finish(true)
        }
    }

    /// Calls `setTaskCompleted` exactly once, whether the pass ends or the task expires first.
    /// `BGTask.setTaskCompleted` may be called from any thread.
    private final class CompleteOnce: @unchecked Sendable {
        private let task: BGProcessingTask
        private let completed = OSAllocatedUnfairLock(initialState: false)
        init(_ task: BGProcessingTask) { self.task = task }
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
    /// The launch itself goes inactive to active; only a return from the background syncs here, because
    /// launch recovery triggers its own pass.
    @State private var wasBackgrounded = false

    func body(content: Content) -> some View {
        content.onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                wasBackgrounded = true
                enteredBackground()
            case .active where wasBackgrounded:
                wasBackgrounded = false
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
                try? environment.store.writeDiagnostics(appVersion: environment.producer.appVersion)
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
