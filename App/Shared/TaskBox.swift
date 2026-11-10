import Foundation

/// Lets a `BackgroundActivity` expiry handler reach the task that is running inside it.
final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Task<Void, Never>?
    var task: Task<Void, Never>? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
