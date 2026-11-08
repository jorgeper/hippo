import Foundation
import CaptureCore

/// How a place is written in rows. Missing parts are omitted.
public enum PlaceText {
    /// The first two non-nil of sub-locality, locality, region, country, e.g. "Capitol Hill, Seattle".
    public static func area(_ p: PlaceItem) -> String? {
        let parts = [p.subLocality, p.locality, p.region, p.country].compactMap { $0 }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.prefix(2).joined(separator: ", ")
    }

    public static func nearby(_ p: PlaceItem) -> String? {
        guard let name = p.nearby?.name, !name.isEmpty else { return nil }
        return "near \(name)"
    }

    public static func line(_ p: PlaceItem) -> String? {
        let parts = [area(p), nearby(p)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
