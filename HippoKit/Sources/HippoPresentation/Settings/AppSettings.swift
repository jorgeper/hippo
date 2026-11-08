import Foundation
import CaptureCore

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

    /// Whether enrichment of `kind` runs. On unless the user turned it off.
    public func isEnrichmentEnabled(_ kind: FacetKind) -> Bool {
        let key = "enrichment.\(kind.rawValue)"
        return defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }

    public func setEnrichmentEnabled(_ kind: FacetKind, _ on: Bool) {
        defaults.set(on, forKey: "enrichment.\(kind.rawValue)")
    }
}
