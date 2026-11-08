import Foundation
import CaptureCore

/// A position reading from CoreLocation, reduced to what the policy needs.
public struct LocationFix: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var horizontalAccuracy: Double
    public var timestamp: Date

    public init(latitude: Double, longitude: Double, horizontalAccuracy: Double, timestamp: Date) {
        self.latitude = latitude; self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy; self.timestamp = timestamp
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
        return CaptureLocation(latitude: fix.latitude, longitude: fix.longitude,
                               horizontalAccuracyMeters: fix.horizontalAccuracy,
                               observedAt: fix.timestamp, provenance: provenance)
    }
}
