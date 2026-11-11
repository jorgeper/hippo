import Foundation
import CaptureCore

/// A position reading from CoreLocation, reduced to what the policy needs.
public struct LocationFix: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var horizontalAccuracy: Double
    public var timestamp: Date
    public var altitude: Double?
    public var verticalAccuracy: Double?
    public var speed: Double?
    public var speedAccuracy: Double?
    public var course: Double?
    public var courseAccuracy: Double?

    public init(latitude: Double, longitude: Double, horizontalAccuracy: Double, timestamp: Date,
                altitude: Double? = nil, verticalAccuracy: Double? = nil,
                speed: Double? = nil, speedAccuracy: Double? = nil,
                course: Double? = nil, courseAccuracy: Double? = nil) {
        self.latitude = latitude; self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy; self.timestamp = timestamp
        self.altitude = altitude; self.verticalAccuracy = verticalAccuracy
        self.speed = speed; self.speedAccuracy = speedAccuracy
        self.course = course; self.courseAccuracy = courseAccuracy
    }
}

/// Chooses which fix, if any, is recorded with a capture.
public enum LocationPolicy {
    /// Fixes further than this from the capture start are too stale (or too far in the future) to use.
    static let maxAge: TimeInterval = 3600

    public static func pick(enabled: Bool, sessionFix: LocationFix?, lastKnown: LocationFix?,
                            captureStartedAt: Date) -> CaptureLocation? {
        guard enabled else { return nil }
        func usable(_ fix: LocationFix?) -> LocationFix? {
            guard let fix, fix.horizontalAccuracy >= 0,
                  fix.latitude.isFinite, fix.longitude.isFinite, fix.horizontalAccuracy.isFinite,
                  abs(fix.timestamp.timeIntervalSince(captureStartedAt)) <= maxAge else { return nil }
            return fix
        }
        let session = usable(sessionFix), last = usable(lastKnown)
        let (fix, provenance): (LocationFix, String)
        switch (session, last) {
        case (nil, nil): return nil
        case (let s?, nil): (fix, provenance) = (s, "core_location_request")
        case (nil, let l?): (fix, provenance) = (l, "core_location_last_known")
        case (let s?, let l?):
            // The session fix wins a tie.
            (fix, provenance) = l.timestamp > s.timestamp ? (l, "core_location_last_known") : (s, "core_location_request")
        }
        var location = CaptureLocation(latitude: fix.latitude, longitude: fix.longitude,
                                       horizontalAccuracyMeters: fix.horizontalAccuracy,
                                       observedAt: fix.timestamp, provenance: provenance)
        // Core Location semantics: a value is kept with its accuracy only when both are valid; otherwise
        // the pair is dropped. A missing accuracy keeps a valid value.
        if let alt = pair(fix.altitude, fix.verticalAccuracy, valid: { $0.isFinite }) {
            location.altitudeMeters = alt.value; location.verticalAccuracyMeters = alt.accuracy
        }
        if let speed = pair(fix.speed, fix.speedAccuracy, valid: { $0.isFinite && $0 >= 0 }) {
            location.speedMetersPerSecond = speed.value; location.speedAccuracyMetersPerSecond = speed.accuracy
        }
        if let course = pair(fix.course, fix.courseAccuracy, valid: { $0.isFinite && (0...360).contains($0) }) {
            location.courseDegrees = course.value; location.courseAccuracyDegrees = course.accuracy
        }
        return location
    }

    private static func pair(_ value: Double?, _ accuracy: Double?,
                             valid: (Double) -> Bool) -> (value: Double, accuracy: Double?)? {
        guard let value, valid(value) else { return nil }
        if let accuracy {
            guard accuracy.isFinite, accuracy >= 0 else { return nil }
            return (value, accuracy)
        }
        return (value, nil)
    }
}
