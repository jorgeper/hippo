import Foundation
import Testing
import LocalRepository

@Suite struct RetryPolicyTests {
    @Test func retryDelayBoundsAndRetryAfter() {
        let p = RetryPolicy()
        #expect(p.delay(attempt: 1, retryAfter: nil, random: { 1 }) == 30)
        #expect(p.delay(attempt: 20, retryAfter: nil, random: { 1 }) == 21_600)
        #expect(p.delay(attempt: 900, retryAfter: nil, random: { 1 }) == 21_600)
        #expect(p.delay(attempt: 1, retryAfter: 900, random: { 0 }) == 900)
    }

    @Test func fullJitterScalesTheExponentialCeiling() {
        let p = RetryPolicy()
        #expect(p.delay(attempt: 3, retryAfter: nil, random: { 0.5 }) == 60)
        #expect(p.delay(attempt: 3, retryAfter: nil, random: { 0 }) == 0)
        // Retry-After is a floor, never lowered by jitter.
        #expect(p.delay(attempt: 3, retryAfter: 10, random: { 1 }) == 120)
        #expect(p.delay(attempt: 3, retryAfter: 500, random: { 1 }) == 500)
    }
}
