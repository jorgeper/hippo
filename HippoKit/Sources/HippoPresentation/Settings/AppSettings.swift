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

    /// A lowercase UUID created on first read; names this install's folder under `logs/` on the destination.
    public var installID: String {
        if let existing = defaults.string(forKey: "install_id"), !existing.isEmpty { return existing }
        let fresh = UUID().uuidString.lowercased()
        defaults.set(fresh, forKey: "install_id")
        return fresh
    }

    /// Whether the Developer section is shown. Off by default.
    public var developerMode: Bool {
        get { defaults.bool(forKey: "developer_mode") }
        nonmutating set { defaults.set(newValue, forKey: "developer_mode") }
    }

    /// Whether timeline and detail rows show the layer stripes. On unless the user turned it off.
    public var showsLayerStripes: Bool {
        get { defaults.object(forKey: "layer_stripes") == nil ? true : defaults.bool(forKey: "layer_stripes") }
        nonmutating set { defaults.set(newValue, forKey: "layer_stripes") }
    }

    /// When the last sync chain ended un-cancelled, and whether anything in it failed.
    public var lastSync: (at: Date, failed: Bool)? {
        guard let at = defaults.object(forKey: "last_sync_at") as? Date else { return nil }
        return (at, defaults.bool(forKey: "last_sync_failed"))
    }

    public func recordSync(at: Date, failed: Bool) {
        defaults.set(at, forKey: "last_sync_at")
        defaults.set(failed, forKey: "last_sync_failed")
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
