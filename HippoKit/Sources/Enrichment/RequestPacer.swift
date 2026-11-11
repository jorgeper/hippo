import Foundation

/// Spaces requests at least `minimumInterval` apart (Open-Meteo's free tier: at most one request per second).
/// Waiters are served in arrival order; each reserves its slot before it sleeps, so concurrent callers never bunch up.
public actor RequestPacer {
    private let minimumInterval: Duration
    private let sleep: @Sendable (Duration) async -> Void
    private let now: @Sendable () -> ContinuousClock.Instant
    private var lastSlot: ContinuousClock.Instant?

    public init(minimumInterval: Duration = .seconds(1),
                sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
                now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.minimumInterval = minimumInterval; self.sleep = sleep; self.now = now
    }

    /// Returns when at least `minimumInterval` has passed since the previous call returned.
    public func wait() async {
        let current = now()
        var slot = current
        if let lastSlot, lastSlot + minimumInterval > current { slot = lastSlot + minimumInterval }
        lastSlot = slot
        if slot > current { await sleep(slot - current) }
    }
}
