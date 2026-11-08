import Foundation

/// User preferences stored in `UserDefaults`.
public struct AppSettings: @unchecked Sendable {
    private static let locationKey = "location_enabled"
    // UserDefaults is thread-safe.
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    /// Whether captures save the location at the moment of saving. Off unless the user turns it on.
    public var locationEnabled: Bool {
        get { defaults.bool(forKey: Self.locationKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.locationKey) }
    }
}
