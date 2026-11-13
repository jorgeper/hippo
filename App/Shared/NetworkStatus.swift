import Foundation
import CaptureCore
import Network
import os

/// Whether the device has a usable network path, from one process-wide `NWPathMonitor`. Optimistic
/// until the first update: a fetch made offline defers itself without spending an attempt.
/// `onChange` fires when the online state flips, not on every path update.
/// `@unchecked`: the monitor is touched only in `init`; the status is behind locks.
final class NetworkStatus: @unchecked Sendable {
    static let shared = NetworkStatus()

    private let monitor = NWPathMonitor()
    private let online = OSAllocatedUnfairLock(initialState: true)

    private let expensive = OSAllocatedUnfairLock(initialState: false)
    private let latest = OSAllocatedUnfairLock<ContextSnapshot.Network?>(initialState: nil)
    private let handler = OSAllocatedUnfairLock<(@Sendable (Bool) -> Void)?>(initialState: nil)

    private init() {
        monitor.pathUpdateHandler = { [online, expensive, latest, handler] path in
            let nowOnline = path.status == .satisfied
            expensive.withLock { $0 = path.isExpensive || path.isConstrained }
            let interface = path.status != .satisfied ? "none"
                : path.usesInterfaceType(.wifi) ? "wifi"
                : path.usesInterfaceType(.cellular) ? "cellular"
                : path.usesInterfaceType(.wiredEthernet) ? "wired" : "other"
            latest.withLock {
                $0 = ContextSnapshot.Network(interface: interface, expensive: path.isExpensive,
                                             constrained: path.isConstrained)
            }
            let flipped = online.withLock { value in defer { value = nowOnline }; return value != nowOnline }
            if flipped { handler.withLock { $0 }?(nowOnline) }
        }
        monitor.start(queue: DispatchQueue(label: "com.jorgeper.hippo.network-status", qos: .utility))
    }

    var isOnline: Bool { online.withLock { $0 } }
    /// Cellular, a personal hotspot, or Low Data Mode.
    var isExpensive: Bool { expensive.withLock { $0 } }
    /// The last delivered path; nil until the first one arrives.
    var current: ContextSnapshot.Network? { latest.withLock { $0 } }
    /// Called, off the main thread, with the new state whenever `isOnline` flips. Set once at launch.
    var onChange: (@Sendable (Bool) -> Void)? {
        get { handler.withLock { $0 } }
        set { handler.withLock { $0 = newValue } }
    }
}
