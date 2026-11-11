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

    /// Whether captures record the audio route, battery, network and time since the last capture. On unless turned off.
    public var deviceContextEnabled: Bool {
        get { defaults.object(forKey: "device_context_enabled") == nil ? true : defaults.bool(forKey: "device_context_enabled") }
        nonmutating set { defaults.set(newValue, forKey: "device_context_enabled") }
    }

    /// The capture saved most recently on this phone. Nil when unset or undecodable.
    public var lastSaved: LastSaved? {
        get {
            guard let data = defaults.data(forKey: "last_saved_capture") else { return nil }
            return try? JSONDecoder().decode(LastSaved.self, from: data)
        }
        nonmutating set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: "last_saved_capture")
            } else {
                defaults.removeObject(forKey: "last_saved_capture")
            }
        }
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

    /// Whether pictures and videos taken in Hippo are also saved to Photos. Off unless the user turns it on.
    public var cameraSavesToPhotos: Bool {
        get { defaults.bool(forKey: "camera_saves_to_photos") }
        nonmutating set { defaults.set(newValue, forKey: "camera_saves_to_photos") }
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

    /// Kinds that stay off until the user switches them on (they ask for a permission or send data off the phone).
    public static let enrichmentKindsOffByDefault: Set<FacetKind> = [.motionActivity, .weather]

    /// Whether enrichment of `kind` runs. An unset key is on, except for `enrichmentKindsOffByDefault`.
    public func isEnrichmentEnabled(_ kind: FacetKind) -> Bool {
        let key = "enrichment.\(kind.rawValue)"
        return defaults.object(forKey: key) == nil ? !Self.enrichmentKindsOffByDefault.contains(kind) : defaults.bool(forKey: key)
    }

    public func setEnrichmentEnabled(_ kind: FacetKind, _ on: Bool) {
        defaults.set(on, forKey: "enrichment.\(kind.rawValue)")
    }
}
