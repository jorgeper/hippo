import Foundation
import Testing
@testable import CaptureCore

@Suite struct ContextFacetDataTests {
    private static func keys(_ data: Data) throws -> Set<String> {
        Set(try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any]).keys)
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func kindsHaveSpecRawValues() {
        #expect(FacetKind.motionActivity.rawValue == "motion_activity")
        #expect(FacetKind.weather.rawValue == "weather")
        #expect(FacetKind.barcodes.rawValue == "barcodes")
        #expect(FacetKind.language.rawValue == "language")
        #expect(FacetKind.soundClassification.rawValue == "sound_classification")
        #expect(FacetKind.screenshot.rawValue == "screenshot")
    }

    @Test func motionActivityRoundTrips() throws {
        let json = Data("""
        { "window_start": "2026-11-10T21:50:00.000Z", "window_end": "2026-11-10T22:10:00.000Z",
          "at_capture": { "activities": ["automotive"], "confidence": "high", "started_at": "2026-11-10T21:58:00.000Z" },
          "segments": [ { "started_at": "2026-11-10T21:52:00.000Z", "activities": ["walking"], "confidence": "medium" },
                        { "started_at": "2026-11-10T21:58:00.000Z", "activities": ["automotive"], "confidence": "high" } ] }
        """.utf8)
        let value = try JSONDecoder().decode(MotionActivityData.self, from: json)
        #expect(value.windowStart == HippoJSON.wholeMilliseconds(Date(timeIntervalSince1970: 1_794_347_400)))
        #expect(value.atCapture?.activities == ["automotive"])
        #expect(value.atCapture?.confidence == "high")
        #expect(value.segments.map(\.confidence) == ["medium", "high"])
        let encoded = try JSONEncoder().encode(value)
        #expect(try Self.keys(encoded) == ["window_start", "window_end", "at_capture", "segments"])
        let segment = try #require((try Self.object(encoded)["segments"] as? [[String: Any]])?.first)
        #expect(Set(segment.keys) == ["started_at", "activities", "confidence"])
        #expect(segment["started_at"] as? String == "2026-11-10T21:52:00.000Z")
        #expect(try JSONDecoder().decode(MotionActivityData.self, from: encoded) == value)
    }

    @Test func motionActivityOmitsAbsentAtCapture() throws {
        let value = MotionActivityData(windowStart: Date(timeIntervalSince1970: 0), windowEnd: Date(timeIntervalSince1970: 60),
                                       atCapture: nil, segments: [])
        let encoded = try JSONEncoder().encode(value)
        #expect(try Self.keys(encoded) == ["window_start", "window_end", "segments"])
        #expect(try JSONDecoder().decode(MotionActivityData.self, from: encoded) == value)
    }

    @Test func weatherRoundTrips() throws {
        let json = Data("""
        { "observed_hour": "2026-11-10T22:00:00.000Z",
          "temperature_celsius": 14.2, "apparent_temperature_celsius": 12.9,
          "relative_humidity_percent": 81, "precipitation_millimeters": 0.4,
          "cloud_cover_percent": 100, "wind_speed_meters_per_second": 3.1,
          "weather_code": 61, "condition": "rain", "is_day": false,
          "source": "open-meteo.com", "requested_latitude": 47.61, "requested_longitude": -122.33 }
        """.utf8)
        let value = try JSONDecoder().decode(WeatherData.self, from: json)
        #expect(value.temperatureCelsius == 14.2)
        #expect(value.weatherCode == 61)
        #expect(value.isDay == false)
        #expect(value.requestedLongitude == -122.33)
        #expect(value.observedHour == HippoJSON.wholeMilliseconds(Date(timeIntervalSince1970: 1_794_348_000)))
        let encoded = try JSONEncoder().encode(value)
        #expect(try Self.keys(encoded) == [
            "observed_hour", "temperature_celsius", "apparent_temperature_celsius", "relative_humidity_percent",
            "precipitation_millimeters", "cloud_cover_percent", "wind_speed_meters_per_second", "weather_code",
            "condition", "is_day", "source", "requested_latitude", "requested_longitude"])
        #expect(try Self.object(encoded)["observed_hour"] as? String == "2026-11-10T22:00:00.000Z")
        #expect(try JSONDecoder().decode(WeatherData.self, from: encoded) == value)
    }

    @Test func weatherOmitsUnknownFields() throws {
        let value = WeatherData(observedHour: Date(timeIntervalSince1970: 0), source: "open-meteo.com",
                                requestedLatitude: 1, requestedLongitude: 2)
        #expect(try Self.keys(JSONEncoder().encode(value)) == [
            "observed_hour", "source", "requested_latitude", "requested_longitude"])
    }

    @Test func otherPayloadsEncodeSnakeCaseKeys() throws {
        let barcodes = BarcodesData(items: [.init(attachmentID: "a", symbology: "qr", payload: "https://x.test", url: "https://x.test"),
                                            .init(attachmentID: "b", symbology: "ean13", payload: "123")])
        let b = try JSONEncoder().encode(barcodes)
        let items = try #require(try Self.object(b)["items"] as? [[String: Any]])
        #expect(Set(items[0].keys) == ["attachment_id", "symbology", "payload", "url"])
        #expect(Set(items[1].keys) == ["attachment_id", "symbology", "payload"])
        #expect(try JSONDecoder().decode(BarcodesData.self, from: b) == barcodes)

        let language = LanguageData(items: [.init(source: "user_note", language: "en", confidence: 0.9)])
        let l = try JSONEncoder().encode(language)
        let litems = try #require(try Self.object(l)["items"] as? [[String: Any]])
        #expect(Set(litems[0].keys) == ["source", "language", "confidence"])
        #expect(try JSONDecoder().decode(LanguageData.self, from: l) == language)

        let sound = SoundClassificationData(items: [.init(attachmentID: "a", labels: [.init(label: "speech", confidence: 0.8)])])
        let s = try JSONEncoder().encode(sound)
        let sitems = try #require(try Self.object(s)["items"] as? [[String: Any]])
        #expect(Set(sitems[0].keys) == ["attachment_id", "labels"])
        #expect(Set(try #require(sitems[0]["labels"] as? [[String: Any]])[0].keys) == ["label", "confidence"])
        #expect(try JSONDecoder().decode(SoundClassificationData.self, from: s) == sound)

        let shot = ScreenshotData(items: [.init(attachmentID: "a", reason: "exif_user_comment")])
        let sh = try JSONEncoder().encode(shot)
        let shitems = try #require(try Self.object(sh)["items"] as? [[String: Any]])
        #expect(Set(shitems[0].keys) == ["attachment_id", "reason"])
        #expect(try JSONDecoder().decode(ScreenshotData.self, from: sh) == shot)
    }
}
