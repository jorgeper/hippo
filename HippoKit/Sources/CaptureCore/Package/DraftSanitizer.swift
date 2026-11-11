import Foundation

/// Optional metadata must never fail an otherwise valid capture: invalid location values and
/// observations carrying non-finite numbers are dropped before anything is written.
enum DraftSanitizer {
    static func sanitize(_ d: CaptureDraft) -> CaptureDraft {
        var out = d
        if let loc = d.location {
            if isValid(loc) {
                out.location = withValidExtras(loc)
            } else {
                out.location = nil
                out.observations.append(MetadataObservation(
                    key: "capture_location_dropped", value: .string("invalid_values"), provenance: "hippo_writer"))
            }
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

    /// Each bad extra is dropped on its own; the fix itself stays.
    private static func withValidExtras(_ l: CaptureLocation) -> CaptureLocation {
        var l = l
        func nonNegative(_ v: Double?) -> Double? { v.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
        l.altitudeMeters = l.altitudeMeters.flatMap { $0.isFinite ? $0 : nil }
        l.verticalAccuracyMeters = nonNegative(l.verticalAccuracyMeters)
        l.speedMetersPerSecond = nonNegative(l.speedMetersPerSecond)
        l.speedAccuracyMetersPerSecond = nonNegative(l.speedAccuracyMetersPerSecond)
        l.courseAccuracyDegrees = nonNegative(l.courseAccuracyDegrees)
        l.courseDegrees = l.courseDegrees.flatMap { $0.isFinite && (0.0...360.0).contains($0) ? $0 : nil }
        return l
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
