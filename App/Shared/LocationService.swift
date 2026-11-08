import CoreLocation
import Foundation
import CaptureCore
import HippoPresentation

/// One-shot location for captures. Never blocks saving: a denied, disabled or missing fix is nil.
/// One instance per process; the app's sheets share `LocationService.shared`.
@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {
    static let shared = LocationService()

    /// Settings live in the App Group defaults so the Share Extension reads the same switch.
    nonisolated static var settings: AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: AppEnvironment.appGroupID) ?? .standard)
    }

    private let manager = CLLocationManager()
    private var permissionContinuation: CheckedContinuation<Bool, Never>?

    private(set) var sessionFix: LocationFix?

    /// The system's cached position, from `manager.location`.
    var lastKnown: LocationFix? { manager.location.map(Self.fix) }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    private var isAuthorized: Bool {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: true
        default: false
        }
    }

    /// Asks for when-in-use access if not yet decided. True when authorized.
    func requestPermission() async -> Bool {
        switch manager.authorizationStatus {
        case .notDetermined:
            guard permissionContinuation == nil else { return false }
            return await withCheckedContinuation { continuation in
                permissionContinuation = continuation
                manager.requestWhenInUseAuthorization()
            }
        default:
            return isAuthorized
        }
    }

    /// Asks for one fix, only if the setting is on and access is granted.
    func beginSessionFix() {
        sessionFix = nil
        guard Self.settings.locationEnabled, isAuthorized else { return }
        manager.requestLocation()
    }

    /// The location to record for a capture started at `startedAt`, or nil.
    func location(startedAt: Date) -> CaptureLocation? {
        LocationPolicy.pick(enabled: Self.settings.locationEnabled, sessionFix: sessionFix,
                            lastKnown: lastKnown, captureStartedAt: startedAt)
    }

    private static func fix(_ l: CLLocation) -> LocationFix {
        LocationFix(latitude: l.coordinate.latitude, longitude: l.coordinate.longitude,
                    horizontalAccuracy: l.horizontalAccuracy, timestamp: l.timestamp)
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            guard status != .notDetermined, let c = permissionContinuation else { return }
            permissionContinuation = nil
            c.resume(returning: status == .authorizedWhenInUse || status == .authorizedAlways)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        MainActor.assumeIsolated { sessionFix = Self.fix(last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
