import Foundation
import CaptureCore

/// The Context section of Detail: one plain row per recorded signal. Bronze rows come from `metadata.json`, silver
/// rows from the device enrichment document. A signal that is absent, empty or undecodable yields no row.
public enum ContextRows {
    public static func rows(metadata: CaptureMetadata, device: EnrichmentDocument?, locale: Locale) -> [DetailRow] {
        var out: [DetailRow] = []
        func add(_ label: String, _ value: String?, _ layer: Layer) {
            if let value, !value.isEmpty { out.append(DetailRow(label: label, value: value, layer: layer)) }
        }
        func object(_ key: String) -> [String: JSONValue]? {
            guard case .object(let o)? = metadata.metadataObservations.first(where: { $0.key == key })?.value else { return nil }
            return o
        }

        add("Audio", object(ContextKey.audioRoute).flatMap(audio), .bronze)
        add("Battery", object(ContextKey.device).flatMap(battery), .bronze)
        add("Network", object(ContextKey.network).flatMap(network), .bronze)
        add("Previous capture", object(ContextKey.burst).flatMap(previous), .bronze)
        if let l = metadata.captureLocation {
            if let a = l.altitudeMeters, let m = whole(a) { add("Altitude", "\(m) m", .bronze) }
            if let s = l.speedMetersPerSecond, s.isFinite, s >= 0 {
                add("Speed", String(format: "%.1f m/s", locale: Locale(identifier: "en_US_POSIX"), s), .bronze)
            }
        }

        guard let device else { return out }
        func facet<T: Decodable>(_ kind: FacetKind, _ type: T.Type) -> T? {
            guard let f = device[kind], f.status == .ok else { return nil }
            return f.decodeData(type)
        }
        add("Motion", facet(.motionActivity, MotionActivityData.self).flatMap(motion), .silver)
        add("Weather", facet(.weather, WeatherData.self).flatMap(weather), .silver)
        add("Sounds", facet(.soundClassification, SoundClassificationData.self).flatMap(sounds), .silver)
        if let b = facet(.barcodes, BarcodesData.self) {
            for item in b.items.prefix(3) {
                add(item.symbology == "qr" ? "QR code" : "Barcode", barcodeText(item), .silver)
            }
        }
        if let l = facet(.language, LanguageData.self) {
            var seen = Set<String>()
            for item in l.items where seen.insert(item.language).inserted {
                add("Language", languageName(item.language, locale: locale), .silver)
            }
        }
        if let s = facet(.screenshot, ScreenshotData.self), !s.items.isEmpty {
            add("Image", "Looks like a screenshot", .silver)
        }
        return out
    }

    // MARK: Bronze

    private static func audio(_ o: [String: JSONValue]) -> String? {
        guard case .array(let outputs)? = o["outputs"] else { return nil }
        var names: [String] = []
        for case .object(let port) in outputs {
            var name: String?
            if case .string(let n)? = port["port_name"], !n.isEmpty { name = n }
            else if case .string(let t)? = port["port_type"], !t.isEmpty { name = t.replacingOccurrences(of: "_", with: " ") }
            if let name, !names.contains(name) { names.append(name) }
        }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    private static func battery(_ o: [String: JSONValue]) -> String? {
        var percent: Int?
        if case .number(let l)? = o["battery_level"], l.isFinite, let p = whole(l * 100) { percent = p }
        var state: String?
        if case .string(let s)? = o["battery_state"] { state = s }
        switch (percent, state) {
        case (let p?, "charging"?): return "\(p)%, charging"
        case (let p?, "full"?): return "\(p)%, full"
        case (let p?, _): return "\(p)%"
        case (nil, "charging"?): return "Charging"
        case (nil, "full"?): return "Full"
        case (nil, "unplugged"?): return "Unplugged"
        default: return nil
        }
    }

    private static func network(_ o: [String: JSONValue]) -> String? {
        guard case .string(let i)? = o["interface"] else { return nil }
        let name: String
        switch i {
        case "wifi": name = "Wi-Fi"
        case "cellular": name = "Cellular"
        case "wired": name = "Wired"
        case "other": name = "Other"
        case "none": name = "Offline"
        default: return nil
        }
        if case .bool(true)? = o["constrained"] { return name + ", Low Data Mode" }
        return name
    }

    private static func previous(_ o: [String: JSONValue]) -> String? {
        guard case .number(let s)? = o["seconds_since_previous"], s.isFinite, s >= 0 else { return nil }
        let text: Int?
        let unit: String
        if s < 90 { text = whole(s); unit = "s" }
        else if s < 90 * 60 { text = whole(s / 60); unit = "min" }
        else if s < 48 * 3600 { text = whole(s / 3600); unit = "h" }
        else { text = whole(s / 86400); unit = "d" }
        return text.map { "\($0) \(unit) earlier" }
    }

    // MARK: Silver

    private static let motionOrder: [(key: String, name: String)] = [
        ("stationary", "Still"), ("walking", "Walking"), ("running", "Running"),
        ("cycling", "Cycling"), ("automotive", "Driving"), ("unknown", "Unknown"),
    ]

    private static func motion(_ m: MotionActivityData) -> String? {
        guard let sample = m.atCapture ?? m.segments.first else { return nil }
        let names = motionOrder.filter { sample.activities.contains($0.key) }.map(\.name)
        guard !names.isEmpty else { return nil }
        let joined = names.joined(separator: " + ")
        switch sample.confidence {
        case "low", "medium", "high": return "\(joined), \(sample.confidence) confidence"
        default: return joined
        }
    }

    private static func weather(_ w: WeatherData) -> String? {
        var parts: [String] = []
        if let t = w.temperatureCelsius, let r = whole(t) { parts.append("\(r)°C") }
        if let c = w.condition, !c.isEmpty { parts.append(c.replacingOccurrences(of: "_", with: " ")) }
        if let d = w.isDay { parts.append(d ? "day" : "night") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private static func sounds(_ s: SoundClassificationData) -> String? {
        var best: [(label: String, confidence: Double)] = []
        for label in s.items.flatMap(\.labels) where !label.label.isEmpty {
            if let i = best.firstIndex(where: { $0.label == label.label }) {
                if label.confidence > best[i].confidence { best[i].confidence = label.confidence }
            } else {
                best.append((label.label, label.confidence))
            }
        }
        // `sorted` is not stable, so break ties by first-seen position explicitly.
        let ranked = best.enumerated().sorted { a, b in
            a.element.confidence != b.element.confidence ? a.element.confidence > b.element.confidence : a.offset < b.offset
        }.prefix(3).map { $0.element.label.replacingOccurrences(of: "_", with: " ") }
        return ranked.isEmpty ? nil : ranked.joined(separator: ", ")
    }

    private static func barcodeText(_ item: BarcodesData.Item) -> String? {
        var text = item.url ?? item.payload
        for scheme in ["https://", "http://"] where text.lowercased().hasPrefix(scheme) {
            text = String(text.dropFirst(scheme.count))
            break
        }
        guard !text.isEmpty else { return nil }
        return text.count > 40 ? String(text.prefix(39)) + "…" : text
    }

    private static func languageName(_ code: String, locale: Locale) -> String? {
        guard !code.isEmpty else { return nil }
        let name = locale.localizedString(forLanguageCode: code) ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Rounds to the nearest whole number; nil when the value is not finite or too large for an `Int`.
    private static func whole(_ d: Double) -> Int? {
        guard d.isFinite, abs(d) < 1e12 else { return nil }
        return Int(d.rounded())
    }
}
