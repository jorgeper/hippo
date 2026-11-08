import Foundation

/// Holds the first caller of `arrive()` until `release()`; later callers pass straight through.
/// Lets a test finish a newer load while an older one is parked between its read and its apply.
actor FirstCallGate {
    private var calls = 0
    private var held: CheckedContinuation<Void, Never>?
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func arrive() async {
        calls += 1
        guard calls == 1, !released else { return }
        await withCheckedContinuation { c in
            held = c
            for w in arrivalWaiters { w.resume() }
            arrivalWaiters = []
        }
    }

    /// Returns once the first caller is parked in `arrive()`.
    func firstArrived() async {
        if held != nil || released { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func release() {
        released = true
        held?.resume()
        held = nil
    }
}
