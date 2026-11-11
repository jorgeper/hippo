import Foundation

public enum ContextKey {
    public static let audioRoute = "context.audio_route"
    public static let device = "context.device"
    public static let network = "context.network"
    public static let burst = "context.burst"
    public static let enabled = "context.enabled"
}

/// Pure mapping from capture-time signals to `metadata_observations` entries.
public enum ContextObservations {
    public static let maxStringLength = 100
    public static let maxPorts = 8

    /// 0-3 entries in the order audio_route, device, network. Applies the caps; omits empty objects.
    public static func observations(from s: ContextSnapshot) -> [MetadataObservation] {
        var out: [MetadataObservation] = []
        if let route = s.audioRoute {
            var o: [String: JSONValue] = [:]
            if !route.outputs.isEmpty { o["outputs"] = ports(route.outputs) }
            if !route.inputs.isEmpty { o["inputs"] = ports(route.inputs) }
            if !o.isEmpty {
                out.append(MetadataObservation(key: ContextKey.audioRoute, value: .object(o), provenance: "av_audio_session"))
            }
        }
        if let d = s.device {
            var o: [String: JSONValue] = [:]
            if let v = d.batteryLevel, v.isFinite, (0.0...1.0).contains(v) { o["battery_level"] = .number((v * 100).rounded() / 100) }
            if let v = d.batteryState { o["battery_state"] = capped(v) }
            if let v = d.lowPowerMode { o["low_power_mode"] = .bool(v) }
            if let v = d.thermalState { o["thermal_state"] = capped(v) }
            if let v = d.interfaceStyle { o["interface_style"] = capped(v) }
            if let v = d.orientation { o["orientation"] = capped(v) }
            if let v = d.locale { o["locale"] = capped(v) }
            if let v = d.uses24HourClock { o["uses_24_hour_clock"] = .bool(v) }
            if !o.isEmpty {
                out.append(MetadataObservation(key: ContextKey.device, value: .object(o), provenance: "device_state"))
            }
        }
        if let n = s.network {
            out.append(MetadataObservation(
                key: ContextKey.network,
                value: .object(["interface": capped(n.interface), "expensive": .bool(n.expensive),
                                "constrained": .bool(n.constrained)]),
                provenance: "nw_path"))
        }
        return out
    }

    /// nil when `previous` is nil or the gap is negative. Seconds rounded to one decimal.
    public static func burst(previous: LastSaved?, capturedAt: Date) -> MetadataObservation? {
        guard let previous else { return nil }
        let gap = capturedAt.timeIntervalSince(previous.capturedAt)
        guard gap.isFinite, gap >= 0 else { return nil }
        return MetadataObservation(
            key: ContextKey.burst,
            value: .object(["previous_capture_id": capped(previous.captureID),
                            "seconds_since_previous": .number((gap * 10).rounded() / 10)]),
            provenance: "last_saved")
    }

    /// Always returns an entry; `groups` in the order device_context, location.
    public static func enabled(deviceContext: Bool, location: Bool) -> MetadataObservation {
        var groups: [JSONValue] = []
        if deviceContext { groups.append(.string("device_context")) }
        if location { groups.append(.string("location")) }
        return MetadataObservation(key: ContextKey.enabled, value: .object(["groups": .array(groups)]), provenance: "settings")
    }

    private static func capped(_ s: String) -> JSONValue { .string(String(s.prefix(maxStringLength))) }

    private static func ports(_ ports: [ContextSnapshot.Port]) -> JSONValue {
        .array(ports.prefix(maxPorts).map { p in
            var o: [String: JSONValue] = ["port_type": capped(p.type)]
            if let n = p.name { o["port_name"] = capped(n) }
            return .object(o)
        })
    }
}
