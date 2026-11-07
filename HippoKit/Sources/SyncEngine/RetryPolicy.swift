import Foundation

/// Bounded exponential backoff with full jitter, never shorter than a server's Retry-After.
public struct RetryPolicy: Sendable {
    public var base: TimeInterval = 30
    public var cap: TimeInterval = 21_600

    public init(base: TimeInterval = 30, cap: TimeInterval = 21_600) {
        self.base = base
        self.cap = cap
    }

    /// `random() * min(cap, base * 2^(attempt-1))`, then at least `retryAfter`. `attempt` starts at 1.
    public func delay(attempt: Int, retryAfter: TimeInterval?, random: () -> Double) -> TimeInterval {
        let ceiling = min(cap, base * pow(2, Double(max(attempt, 1) - 1)))
        return max(random() * ceiling, retryAfter ?? 0)
    }
}
