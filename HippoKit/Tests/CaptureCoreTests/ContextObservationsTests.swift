import Testing
import Foundation
@testable import CaptureCore

@Suite struct ContextObservationsTests {
    private let t0 = Date(timeIntervalSince1970: 1_794_070_800)

    private func object(_ o: MetadataObservation) -> [String: JSONValue] {
        guard case .object(let d) = o.value else { Issue.record("not an object"); return [:] }
        return d
    }

    private var fullSnapshot: ContextSnapshot {
        ContextSnapshot(
            takenAt: t0,
            audioRoute: .init(outputs: [.init(type: "car_audio", name: "CarPlay")],
                              inputs: [.init(type: "built_in_mic", name: "iPhone Microphone")]),
            device: .init(batteryLevel: 0.62, batteryState: "charging", lowPowerMode: false, thermalState: "nominal",
                          interfaceStyle: "dark", orientation: "portrait", locale: "en_US", uses24HourClock: true),
            network: .init(interface: "wifi", expensive: false, constrained: false))
    }

    @Test func fullSnapshotMapsEveryField() {
        let obs = ContextObservations.observations(from: fullSnapshot)
        #expect(obs.map(\.key) == ["context.audio_route", "context.device", "context.network"])
        #expect(obs.map(\.provenance) == ["av_audio_session", "device_state", "nw_path"])
        #expect(obs[0].value == .object([
            "outputs": .array([.object(["port_type": .string("car_audio"), "port_name": .string("CarPlay")])]),
            "inputs": .array([.object(["port_type": .string("built_in_mic"), "port_name": .string("iPhone Microphone")])])]))
        #expect(obs[1].value == .object([
            "battery_level": .number(0.62), "battery_state": .string("charging"), "low_power_mode": .bool(false),
            "thermal_state": .string("nominal"), "interface_style": .string("dark"), "orientation": .string("portrait"),
            "locale": .string("en_US"), "uses_24_hour_clock": .bool(true)]))
        #expect(obs[2].value == .object([
            "interface": .string("wifi"), "expensive": .bool(false), "constrained": .bool(false)]))
    }

    @Test func emptySnapshotYieldsNoEntries() {
        #expect(ContextObservations.observations(from: ContextSnapshot(takenAt: t0)) == [])
        #expect(ContextObservations.observations(from: ContextSnapshot(takenAt: t0, device: .init())) == [])
        #expect(ContextObservations.observations(
            from: ContextSnapshot(takenAt: t0, audioRoute: .init(outputs: [], inputs: []))) == [])
        let onlyOut = ContextObservations.observations(from: ContextSnapshot(
            takenAt: t0, audioRoute: .init(outputs: [.init(type: "headphones", name: nil)], inputs: [])))
        #expect(onlyOut.count == 1)
        #expect(object(onlyOut[0]).keys.sorted() == ["outputs"])
    }

    @Test func capsApplied() {
        let outs = (0..<12).map { ContextSnapshot.Port(type: "t\($0)", name: nil) }
        let long = String(repeating: "x", count: 300)
        let snap = ContextSnapshot(
            takenAt: t0,
            audioRoute: .init(outputs: outs, inputs: [.init(type: "built_in_mic", name: long)]),
            device: .init(locale: long))
        let obs = ContextObservations.observations(from: snap)
        #expect(obs.count == 2)
        guard case .array(let kept)? = object(obs[0])["outputs"] else { Issue.record("no outputs"); return }
        #expect(kept.count == 8)
        #expect(kept.first == .object(["port_type": .string("t0")]))
        #expect(kept.last == .object(["port_type": .string("t7")]))
        guard case .array(let ins)? = object(obs[0])["inputs"], case .object(let inp)? = ins.first else {
            Issue.record("no inputs"); return
        }
        #expect(inp["port_name"] == .string(String(repeating: "x", count: 100)))
        #expect(object(obs[1])["locale"] == .string(String(repeating: "x", count: 100)))
    }

    @Test func nonFiniteBatteryOmitted() {
        for bad in [Double.nan, 1.7] {
            let obs = ContextObservations.observations(from: ContextSnapshot(
                takenAt: t0, device: .init(batteryLevel: bad, lowPowerMode: true)))
            #expect(object(obs[0])["battery_level"] == nil)
            #expect(object(obs[0])["low_power_mode"] == .bool(true))
        }
        let ok = ContextObservations.observations(from: ContextSnapshot(takenAt: t0, device: .init(batteryLevel: 0.62)))
        #expect(object(ok[0])["battery_level"] == .number(0.62))
    }

    @Test func batteryIsRoundedToTwoDecimals() {
        func level(_ v: Double?) -> JSONValue? {
            object(ContextObservations.observations(from: ContextSnapshot(
                takenAt: t0, device: .init(batteryLevel: v, lowPowerMode: true)))[0])["battery_level"]
        }
        #expect(level(0.8500000238) == .number(0.85))
        #expect(level(0) == .number(0))
        #expect(level(1) == .number(1))
        #expect(level(nil) == nil)
    }

    @Test func burstMath() throws {
        let prev = LastSaved(captureID: "ID-1", capturedAt: t0)
        let e = try #require(ContextObservations.burst(previous: prev, capturedAt: t0.addingTimeInterval(41.24)))
        #expect(e.key == "context.burst" && e.provenance == "last_saved")
        #expect(e.value == .object(["previous_capture_id": .string("ID-1"), "seconds_since_previous": .number(41.2)]))
        #expect(ContextObservations.burst(previous: prev, capturedAt: t0.addingTimeInterval(-1)) == nil)
        #expect(ContextObservations.burst(previous: nil, capturedAt: t0) == nil)
        let zero = try #require(ContextObservations.burst(previous: prev, capturedAt: t0))
        #expect(object(zero)["seconds_since_previous"] == .number(0))
    }

    @Test func enabledAlwaysWritten() {
        let both = ContextObservations.enabled(deviceContext: true, location: true)
        #expect(both.key == "context.enabled" && both.provenance == "settings")
        #expect(both.value == .object(["groups": .array([.string("device_context"), .string("location")])]))
        let none = ContextObservations.enabled(deviceContext: false, location: false)
        #expect(none.value == .object(["groups": .array([])]))
        #expect(none.provenance == "settings")
    }

    @Test func locationExtrasRoundTrip() throws {
        var loc = CaptureLocation(latitude: 1, longitude: 2, horizontalAccuracyMeters: 3, observedAt: t0, provenance: "test")
        var base = CaptureMetadata.sample()
        base.captureLocation = loc
        let plain = String(decoding: try HippoJSON.encode(base), as: UTF8.self)
        for k in ["altitude_meters", "vertical_accuracy_meters", "speed_meters_per_second",
                  "speed_accuracy_meters_per_second", "course_degrees", "course_accuracy_degrees"] {
            #expect(!plain.contains(k))
        }
        loc.altitudeMeters = -12.5; loc.verticalAccuracyMeters = 4; loc.speedMetersPerSecond = 1.5
        loc.speedAccuracyMetersPerSecond = 0.5; loc.courseDegrees = 90; loc.courseAccuracyDegrees = 10
        var m = base
        m.captureLocation = loc
        let json = String(decoding: try HippoJSON.encode(m), as: UTF8.self)
        for k in ["altitude_meters", "vertical_accuracy_meters", "speed_meters_per_second",
                  "speed_accuracy_meters_per_second", "course_degrees", "course_accuracy_degrees"] {
            #expect(json.contains("\"\(k)\""))
        }
        #expect(try HippoJSON.decodeMetadata(HippoJSON.encode(m)).captureLocation == loc)
    }
}
