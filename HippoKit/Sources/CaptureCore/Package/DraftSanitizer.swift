import Foundation

/// Optional metadata must never fail an otherwise valid capture: invalid location values and
/// observations carrying non-finite numbers are dropped before anything is written.
enum DraftSanitizer {
    static func sanitize(_ d: CaptureDraft) -> CaptureDraft {
        var out = d
        if let loc = d.location, !isValid(loc) {
            out.location = nil
            out.observations.append(MetadataObservation(
                key: "capture_location_dropped", value: .string("invalid_values"), provenance: "hippo_writer"))
        }
        // Filter the caller's observations first, so the marker above is never filtered out.
        let kept = d.observations.filter { isFinite($0.value) }
        out.observations = kept + out.observations.dropFirst(d.observations.count)
        return out
    }

    private static func isValid(_ l: CaptureLocation) -> Bool {
        l.latitude.isFinite && (-90.0...90.0).contains(l.latitude)
            && l.longitude.isFinite && (-180.0...180.0).contains(l.longitude)
            && l.horizontalAccuracyMeters.isFinite && l.horizontalAccuracyMeters >= 0
    }

    private static func isFinite(_ v: JSONValue) -> Bool {
        switch v {
        case .number(let n): n.isFinite
        case .array(let a): a.allSatisfy(isFinite)
        case .object(let o): o.values.allSatisfy(isFinite)
        case .string, .bool, .null: true
        }
    }
}
