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

    /// A value and its accuracy are dropped together when either is invalid (the same rule as
    /// `LocationPolicy.pick`); a valid value with no accuracy is kept. The fix itself stays.
    private static func withValidExtras(_ l: CaptureLocation) -> CaptureLocation {
        var l = l
        (l.altitudeMeters, l.verticalAccuracyMeters) = pair(l.altitudeMeters, l.verticalAccuracyMeters) { $0.isFinite }
        (l.speedMetersPerSecond, l.speedAccuracyMetersPerSecond) = pair(l.speedMetersPerSecond, l.speedAccuracyMetersPerSecond) {
            $0.isFinite && $0 >= 0
        }
        (l.courseDegrees, l.courseAccuracyDegrees) = pair(l.courseDegrees, l.courseAccuracyDegrees) {
            $0.isFinite && (0.0...360.0).contains($0)
        }
        return l
    }

    private static func pair(_ value: Double?, _ accuracy: Double?,
                             valid: (Double) -> Bool) -> (Double?, Double?) {
        guard let value, valid(value) else { return (nil, nil) }
        if let accuracy {
            guard accuracy.isFinite, accuracy >= 0 else { return (nil, nil) }
            return (value, accuracy)
        }
        return (value, nil)
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
