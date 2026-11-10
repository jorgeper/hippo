import Foundation
import SyncEngine
import HippoPresentation

extension TaskBox {
    /// Runs `work` as a task inside `BackgroundActivity.run(name:)`. On expiry the task is cancelled and sync
    /// stopped; `finished` runs when the work ends. The task is stored before any expiry can fire.
    @MainActor
    static func runInBackground(name: String, coordinator: SyncCoordinator?, finished: @escaping @MainActor () -> Void,
                                work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let box = TaskBox()
        let task = Task { @MainActor in
            await BackgroundActivity.run(name: name, onExpire: {
                box.task?.cancel()
                coordinator.map(SyncScheduling.stopper)?()
            }) { await work() }
            finished()
        }
        box.task = task
        return task
    }
}
