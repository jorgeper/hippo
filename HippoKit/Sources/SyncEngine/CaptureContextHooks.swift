import Foundation
import CaptureCore

/// What the store needs from the app to write capture context: which groups are on, the capture saved
/// last, and a place to record the one just saved. Synchronous and non-throwing: a save never waits on them.
public struct CaptureContextHooks: Sendable {
    public var enabledGroups: @Sendable () -> (deviceContext: Bool, location: Bool)
    public var lastSaved: @Sendable () -> LastSaved?
    public var recordSaved: @Sendable (LastSaved) -> Void

    public init(enabledGroups: @escaping @Sendable () -> (deviceContext: Bool, location: Bool),
                lastSaved: @escaping @Sendable () -> LastSaved?,
                recordSaved: @escaping @Sendable (LastSaved) -> Void) {
        self.enabledGroups = enabledGroups; self.lastSaved = lastSaved; self.recordSaved = recordSaved
    }
}
