import Foundation
import Testing
import CaptureCore
@testable import HippoPresentation

private let en = Locale(identifier: "en_US")
private let at = Date(timeIntervalSince1970: 1_794_081_600)

private func meta(_ observations: [MetadataObservation] = [], location: CaptureLocation? = nil) -> CaptureMetadata {
    CaptureMetadata(schemaVersion: 1, captureID: "c1", capturedAt: at, localDatetime: "2026-11-07T12:00:00-08:00",
                    timezoneIdentifier: "America/Los_Angeles", utcOffsetSeconds: -28800, captureMethod: .shareExtension,
                    contentTypes: [], userNote: nil, sharedTitle: nil, sharedText: nil, urls: [], sourceApplication: nil,
                    captureLocation: location, producer: Producer(appVersion: "1", build: "1", osVersion: "t"),
                    attachments: [], metadataObservations: observations, extensions: [:])
}

private func obs(_ key: String, _ value: JSONValue) -> MetadataObservation {
    MetadataObservation(key: key, value: value, provenance: "test")
}

private func json<T: Encodable>(_ v: T) -> JSONValue {
    // swiftlint:disable:next force_try
    try! JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(v))
}

private func doc(_ facets: [FacetKind: (FacetStatus, JSONValue?)]) -> EnrichmentDocument {
    EnrichmentDocument(schemaVersion: 1, captureID: "c1", layer: .device, packageDigest: "d",
                       producer: EnrichmentProducer(name: "t", version: "1", build: "1"), generatedAt: at,
                       facets: Dictionary(uniqueKeysWithValues: facets.map {
                           ($0.key.rawValue, Facet(version: 1, status: $0.value.0, generatedAt: at, provenance: "t", data: $0.value.1))
                       }))
}

private func rows(_ m: CaptureMetadata, _ d: EnrichmentDocument? = nil) -> [DetailRow] {
    ContextRows.rows(metadata: m, device: d, locale: en)
}

private func value(_ rows: [DetailRow], _ label: String) -> String? { rows.first { $0.label == label }?.value }

private func device(level: Double? = nil, state: String? = nil) -> MetadataObservation {
    var o: [String: JSONValue] = [:]
    if let level { o["battery_level"] = .number(level) }
    if let state { o["battery_state"] = .string(state) }
    return obs("context.device", .object(o))
}

private func network(_ interface: String, constrained: Bool = false) -> MetadataObservation {
    obs("context.network", .object(["interface": .string(interface), "expensive": .bool(false), "constrained": .bool(constrained)]))
}

private func burst(_ seconds: Double) -> MetadataObservation {
    obs("context.burst", .object(["previous_capture_id": .string("p"), "seconds_since_previous": .number(seconds)]))
}

private func sample(_ acts: [String], _ conf: String = "high") -> MotionActivityData.Sample {
    .init(startedAt: at, activities: acts, confidence: conf)
}

private func motion(at cap: MotionActivityData.Sample?, segments: [MotionActivityData.Sample] = []) -> EnrichmentDocument {
    doc([.motionActivity: (.ok, json(MotionActivityData(windowStart: at, windowEnd: at, atCapture: cap, segments: segments)))])
}

private func weather(temp: Double? = nil, condition: String? = nil, isDay: Bool? = nil) -> EnrichmentDocument {
    doc([.weather: (.ok, json(WeatherData(observedHour: at, temperatureCelsius: temp, condition: condition, isDay: isDay,
                                          source: "open-meteo.com", requestedLatitude: 1, requestedLongitude: 2)))])
}

private func barcodes(_ items: [BarcodesData.Item]) -> EnrichmentDocument {
    doc([.barcodes: (.ok, json(BarcodesData(items: items)))])
}

@Suite struct ContextRowsTests {
    @Test func audio() {
        let route = JSONValue.object(["outputs": .array([
            .object(["port_type": .string("car_audio"), "port_name": .string("CarPlay")]),
            .object(["port_type": .string("bluetooth_a2dp")]),
            .object(["port_type": .string("car_audio"), "port_name": .string("CarPlay")]),
        ]), "inputs": .array([.object(["port_type": .string("built_in_mic"), "port_name": .string("iPhone Microphone")])])])
        #expect(value(rows(meta([obs("context.audio_route", route)])), "Audio") == "CarPlay, bluetooth a2dp")
        let inputsOnly = JSONValue.object(["inputs": .array([.object(["port_type": .string("built_in_mic")])])])
        #expect(value(rows(meta([obs("context.audio_route", inputsOnly)])), "Audio") == nil)
    }

    @Test func battery() {
        func b(_ l: Double?, _ s: String?) -> String? { value(rows(meta([device(level: l, state: s)])), "Battery") }
        #expect(b(0.62, "unplugged") == "62%")
        #expect(b(0.62, "charging") == "62%, charging")
        #expect(b(1.0, "full") == "100%, full")
        #expect(b(0.97, "full") == "97%, full")
        #expect(b(0.62, "unknown") == "62%")
        #expect(b(0.62, nil) == "62%")
        #expect(b(nil, "charging") == "Charging")
        #expect(b(nil, "full") == "Full")
        #expect(b(nil, "unplugged") == "Unplugged")
        #expect(b(nil, nil) == nil)
    }

    @Test func networkValues() {
        func n(_ i: String, _ c: Bool = false) -> String? { value(rows(meta([network(i, constrained: c)])), "Network") }
        #expect(n("wifi") == "Wi-Fi")
        #expect(n("cellular") == "Cellular")
        #expect(n("wired") == "Wired")
        #expect(n("other") == "Other")
        #expect(n("none") == "Offline")
        #expect(n("wifi", true) == "Wi-Fi, Low Data Mode")
        #expect(n("satellite") == nil)
    }

    @Test func previousCapture() {
        func p(_ s: Double) -> String? { value(rows(meta([burst(s)])), "Previous capture") }
        #expect(p(41.2) == "41 s earlier")
        #expect(p(89) == "89 s earlier")
        #expect(p(300) == "5 min earlier")
        #expect(p(89 * 60) == "89 min earlier")
        #expect(p(90 * 60) == "2 h earlier")
        #expect(p(47 * 3600) == "47 h earlier")
        #expect(p(48 * 3600) == "2 d earlier")
        #expect(p(2 * 3600) == "2 h earlier")
        #expect(p(4 * 86400) == "4 d earlier")
        #expect(p(-1) == nil)
    }

    @Test func altitudeAndSpeed() {
        let loc = CaptureLocation(latitude: 1, longitude: 2, horizontalAccuracyMeters: 5, observedAt: at, provenance: "t",
                                  altitudeMeters: 52.4, speedMetersPerSecond: 13.44)
        let r = rows(meta(location: loc))
        #expect(value(r, "Altitude") == "52 m")
        #expect(value(r, "Speed") == "13.4 m/s")
        let bad = CaptureLocation(latitude: 1, longitude: 2, horizontalAccuracyMeters: 5, observedAt: at, provenance: "t",
                                  speedMetersPerSecond: -1)
        #expect(rows(meta(location: bad)).isEmpty)
    }

    @Test func motionRow() {
        #expect(value(rows(meta(), motion(at: sample(["automotive"]))), "Motion") == "Driving, high confidence")
        #expect(value(rows(meta(), motion(at: nil, segments: [sample(["walking"], "low")])), "Motion") == "Walking, low confidence")
        #expect(value(rows(meta(), motion(at: sample(["automotive", "stationary"], "medium"))), "Motion")
                == "Still + Driving, medium confidence")
        #expect(value(rows(meta(), motion(at: sample(["running"], "weird"))), "Motion") == "Running")
    }

    @Test func weatherRow() {
        #expect(value(rows(meta(), weather(temp: 14.2, condition: "partly_cloudy", isDay: false)), "Weather") == "14°C, partly cloudy, night")
        #expect(value(rows(meta(), weather(temp: 14.6, condition: "rain", isDay: false)), "Weather") == "15°C, rain, night")
        #expect(value(rows(meta(), weather(isDay: true)), "Weather") == "day")
        #expect(value(rows(meta(), weather()), "Weather") == nil)
    }

    @Test func soundsRow() {
        let data = SoundClassificationData(items: [
            .init(attachmentID: "a", labels: [.init(label: "speech", confidence: 0.6), .init(label: "traffic_noise", confidence: 0.5)]),
            .init(attachmentID: "b", labels: [.init(label: "music", confidence: 0.9), .init(label: "traffic_noise", confidence: 0.7),
                                              .init(label: "dog", confidence: 0.4)]),
        ])
        let d = doc([.soundClassification: (.ok, json(data))])
        #expect(value(rows(meta(), d), "Sounds") == "music, traffic noise, speech")
    }

    @Test func barcodeRows() {
        let d = barcodes([
            .init(attachmentID: "a", symbology: "qr", payload: "https://example.com/x", url: "https://example.com/x"),
            .init(attachmentID: "a", symbology: "ean13", payload: "5901234123457"),
            .init(attachmentID: "b", symbology: "qr", payload: String(repeating: "z", count: 60)),
            .init(attachmentID: "b", symbology: "qr", payload: "fourth"),
        ])
        let r = rows(meta(), d)
        #expect(r.map(\.label) == ["QR code", "Barcode", "QR code"])
        #expect(r[0].value == "example.com/x")
        #expect(r[1].value == "5901234123457")
        #expect(r[2].value == String(repeating: "z", count: 39) + "…")
        #expect(r[2].value.count == 40)
    }

    @Test func languageRows() {
        let d = doc([.language: (.ok, json(LanguageData(items: [
            .init(source: "user_note", language: "es", confidence: 0.9),
            .init(source: "shared_text", language: "es", confidence: 0.8),
            .init(source: "note_body", language: "fr", confidence: 0.7),
        ])))])
        let r = rows(meta(), d)
        #expect(r.map(\.value) == ["Spanish", "French"])
        #expect(Set(r.map(\.label)) == ["Language"])
    }

    @Test func imageRow() {
        let d = doc([.screenshot: (.ok, json(ScreenshotData(items: [.init(attachmentID: "a", reason: "exif_user_comment")])))])
        #expect(value(rows(meta(), d), "Image") == "Looks like a screenshot")
        let none = doc([.screenshot: (.ok, json(ScreenshotData(items: [])))])
        #expect(rows(meta(), none).isEmpty)
    }

    @Test func nothingRecordedIsEmpty() {
        #expect(rows(meta(), nil).isEmpty)
    }

    @Test func contextEnabledAloneShowsNothing() {
        let e = obs("context.enabled", .object(["groups": .array([.string("device_context")])]))
        #expect(rows(meta([e])).isEmpty)
    }

    @Test func malformedValuesAreSkipped() {
        let d = doc([.weather: (.failed, nil), .barcodes: (.empty, json(BarcodesData(items: [])))])
        let wrong = [obs("context.device", .string("oops")), obs("context.network", .number(3)),
                     obs("context.burst", .array([])), obs("context.audio_route", .bool(true))]
        #expect(rows(meta(wrong), d).isEmpty)
        let badShape = doc([.weather: (.ok, .string("x")), .motionActivity: (.ok, .object([:]))])
        #expect(rows(meta(), badShape).isEmpty)
    }

    @Test func layers() {
        let route = JSONValue.object(["outputs": .array([.object(["port_type": .string("car_audio"), "port_name": .string("CarPlay")])])])
        let r = rows(meta([obs("context.audio_route", route)]), motion(at: sample(["automotive"])))
        #expect(r.first { $0.label == "Audio" }?.layer == .bronze)
        #expect(r.first { $0.label == "Motion" }?.layer == .silver)
    }
}
