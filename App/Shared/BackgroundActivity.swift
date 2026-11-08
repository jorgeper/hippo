import Foundation
import os
#if !HIPPO_SHARE_EXTENSION
import UIKit
#endif

/// Keeps the process running while `work` touches SQLite or syncs, so iOS doesn't suspend it holding a
/// lock in the shared container (`0xdead10cc`). The app uses a UIKit background task; the Share
/// Extension, where `UIApplication.shared` is unavailable, uses `ProcessInfo.performExpiringActivity`.
enum BackgroundActivity {
    /// How long stopped work gets to unwind after background time expires.
    static let expiryGrace: Duration = .seconds(2)

    /// `name` is a fixed string; it shows up in system logs. `onExpire` runs when the app's background time
    /// runs out; sync passes use it to start stopping, and the assertion then ends when the work returns or
    /// after `expiryGrace`. The extension ignores it, because
    /// it never syncs.
    static func run<T: Sendable, E: Error>(name: String, onExpire: (@Sendable () -> Void)? = nil,
                                           _ work: @escaping @Sendable () async throws(E) -> T) async throws(E) -> T {
        let result: Result<T, E> = await withAssertion(name: name, onExpire: onExpire) {
            do throws(E) { return .success(try await work()) } catch { return .failure(error) }
        }
        return try result.get()
    }

    #if HIPPO_SHARE_EXTENSION
    private static func withAssertion<R: Sendable>(name: String, onExpire: (@Sendable () -> Void)?,
                                                   _ work: @escaping @Sendable () async -> R) async -> R {
        await withCheckedContinuation { continuation in
            let started = OSAllocatedUnfairLock(initialState: false)
            // The block runs on a background queue and the assertion lasts until it returns. It is called
            // again with `expired == true` when time runs out, or only that way if no time was granted, in
            // which case the work still runs, unprotected.
            ProcessInfo.processInfo.performExpiringActivity(withReason: name) { expired in
                let isFirstCall = started.withLock { wasStarted in
                    defer { wasStarted = true }
                    return !wasStarted
                }
                guard isFirstCall else { return }
                let done = DispatchSemaphore(value: 0)
                Task {
                    continuation.resume(returning: await work())
                    done.signal()
                }
                if !expired { done.wait() }
            }
        }
    }
    #else
    private static func withAssertion<R: Sendable>(name: String, onExpire: (@Sendable () -> Void)?,
                                                   _ work: @escaping @Sendable () async -> R) async -> R {
        let token = await MainActor.run { BackgroundTaskToken(name: name, onExpire: onExpire) }
        let result = await work()
        await MainActor.run { token.end() }
        return result
    }
    #endif
}

#if !HIPPO_SHARE_EXTENSION
/// One UIKit background task, ended exactly once: when the work finishes or when time runs out.
@MainActor
private final class BackgroundTaskToken {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String, onExpire: (@Sendable () -> Void)?) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated {
                guard let onExpire else { self?.end(); return }
                // Start winding the work down, then keep the assertion until `work()` returns (which ends
                // it) or a short cap passes, so the stopped work can release its SQLite locks first.
                onExpire()
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: BackgroundActivity.expiryGrace)
                    self?.end()
                }
            }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
#endif
