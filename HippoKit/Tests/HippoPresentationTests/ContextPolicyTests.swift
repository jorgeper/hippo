import Foundation
import Testing
import CaptureCore
@testable import HippoPresentation

private func field(_ v: JSONValue?, _ key: String) -> JSONValue? {
    guard case .object(let d)? = v else { return nil }
    return d[key]
}

private let start = Date(timeIntervalSince1970: 1_794_070_860)

private func snapshot(age: TimeInterval, network: ContextSnapshot.Network? = .init(interface: "wifi", expensive: false, constrained: false)) -> ContextSnapshot {
    ContextSnapshot(takenAt: start.addingTimeInterval(-age),
                    audioRoute: .init(outputs: [.init(type: "Speaker")]),
                    device: .init(batteryLevel: 0.5), network: network)
}

private func keys(_ o: [MetadataObservation]) -> [String] { o.map(\.key) }

@Suite struct ContextPolicyTests {
    @Test func disabledYieldsNothing() {
        #expect(ContextPolicy.observations(enabled: false, snapshot: snapshot(age: 1), captureStartedAt: start,
                                           networkAtSave: .init(interface: "wifi", expensive: false, constrained: false)).isEmpty)
    }

    @Test func freshSnapshotUsed() {
        let o = ContextPolicy.observations(enabled: true, snapshot: snapshot(age: 30), captureStartedAt: start, networkAtSave: nil)
        #expect(keys(o) == ["context.audio_route", "context.device", "context.network"])
    }

    @Test func staleSnapshotIgnored() {
        let wifi = ContextSnapshot.Network(interface: "wifi", expensive: false, constrained: false)
        let o = ContextPolicy.observations(enabled: true, snapshot: snapshot(age: 121), captureStartedAt: start, networkAtSave: wifi)
        #expect(keys(o) == ["context.network"])
        let edge = ContextPolicy.observations(enabled: true, snapshot: snapshot(age: 120), captureStartedAt: start, networkAtSave: nil)
        #expect(edge.count == 3)
    }

    @Test func networkFilledAtSave() {
        let cell = ContextSnapshot.Network(interface: "cellular", expensive: true, constrained: false)
        let o = ContextPolicy.observations(enabled: true, snapshot: snapshot(age: 5, network: nil), captureStartedAt: start,
                                           networkAtSave: cell)
        let net = o.first { $0.key == "context.network" }
        #expect(field(net?.value, "interface") == .string("cellular"))
        #expect(field(net?.value, "expensive") == .bool(true))
    }

    @Test func snapshotNetworkWins() {
        let cell = ContextSnapshot.Network(interface: "cellular", expensive: true, constrained: false)
        let o = ContextPolicy.observations(enabled: true, snapshot: snapshot(age: 5), captureStartedAt: start, networkAtSave: cell)
        #expect(field(o.first { $0.key == "context.network" }?.value, "interface") == .string("wifi"))
    }

    @Test func nothingAtAllYieldsNothing() {
        #expect(ContextPolicy.observations(enabled: true, snapshot: nil, captureStartedAt: start, networkAtSave: nil).isEmpty)
    }

    // MARK: - LocationPolicy extras

    private func fix(alt: Double? = nil, vAcc: Double? = nil, speed: Double? = nil, sAcc: Double? = nil,
                     course: Double? = nil, cAcc: Double? = nil) -> LocationFix {
        LocationFix(latitude: 47.6, longitude: -122.3, horizontalAccuracy: 5, timestamp: start,
                    altitude: alt, verticalAccuracy: vAcc, speed: speed, speedAccuracy: sAcc, course: course, courseAccuracy: cAcc)
    }
    private func pick(_ f: LocationFix) -> CaptureLocation? {
        LocationPolicy.pick(enabled: true, sessionFix: f, lastKnown: nil, captureStartedAt: start)
    }

    @Test func pickCopiesOnlyValidExtras() throws {
        let l = try #require(pick(fix(alt: 52, vAcc: 3, speed: -1, sAcc: -1, course: -1, cAcc: -1)))
        #expect(l.altitudeMeters == 52)
        #expect(l.verticalAccuracyMeters == 3)
        #expect(l.speedMetersPerSecond == nil)
        #expect(l.speedAccuracyMetersPerSecond == nil)
        #expect(l.courseDegrees == nil)
        #expect(l.courseAccuracyDegrees == nil)
        let bad = try #require(pick(fix(alt: 52, vAcc: -1)))
        #expect(bad.altitudeMeters == nil)
        #expect(bad.verticalAccuracyMeters == nil)
    }

    @Test func pickKeepsGoodMotionExtrasAndDropsPairsTogether() throws {
        let good = try #require(pick(fix(speed: 1.5, sAcc: 0.5, course: 360, cAcc: 10)))
        #expect(good.speedMetersPerSecond == 1.5 && good.speedAccuracyMetersPerSecond == 0.5)
        #expect(good.courseDegrees == 360 && good.courseAccuracyDegrees == 10)
        let badSpeed = try #require(pick(fix(speed: 2, sAcc: -1, course: 361, cAcc: 5)))
        #expect(badSpeed.speedMetersPerSecond == nil && badSpeed.speedAccuracyMetersPerSecond == nil)
        #expect(badSpeed.courseDegrees == nil && badSpeed.courseAccuracyDegrees == nil)
        let nonFinite = try #require(pick(fix(alt: .infinity, vAcc: 3)))
        #expect(nonFinite.altitudeMeters == nil && nonFinite.verticalAccuracyMeters == nil)
        let nilAcc = try #require(pick(fix(alt: 10, speed: 1)))
        #expect(nilAcc.altitudeMeters == 10 && nilAcc.verticalAccuracyMeters == nil)
        #expect(nilAcc.speedMetersPerSecond == 1 && nilAcc.speedAccuracyMetersPerSecond == nil)
        #expect(try #require(pick(fix())).altitudeMeters == nil)
    }

    // MARK: - Settings

    private func settings() -> (AppSettings, String) {
        let suite = "hippo-ctx-\(UUID().uuidString)"
        return (AppSettings(defaults: UserDefaults(suiteName: suite)!), suite)
    }

    @Test func deviceContextDefaultsOn() {
        let (s, suite) = settings()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        #expect(s.deviceContextEnabled)
        s.deviceContextEnabled = false
        #expect(!s.deviceContextEnabled)
        s.deviceContextEnabled = true
        #expect(s.deviceContextEnabled)
    }

    @Test func lastSavedRoundTrips() {
        let (s, suite) = settings()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        #expect(s.lastSaved == nil)
        let value = LastSaved(captureID: "abc", capturedAt: start)
        s.lastSaved = value
        #expect(s.lastSaved == value)
        s.lastSaved = nil
        #expect(s.lastSaved == nil)
    }

    @Test func garbageLastSavedIsNil() {
        let suite = "hippo-ctx-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not json".utf8), forKey: "last_saved_capture")
        #expect(AppSettings(defaults: defaults).lastSaved == nil)
        defaults.set("a string", forKey: "last_saved_capture")
        #expect(AppSettings(defaults: defaults).lastSaved == nil)
    }
}
