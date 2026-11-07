import Testing
import Foundation
@testable import CaptureCore

@Suite struct MetadataCodingTests {
    @Test func encodesSnakeCaseRFC3339AndOmitsNil() throws {
        let m = CaptureMetadata.sample(userNote: nil)
        let json = String(decoding: try HippoJSON.encode(m), as: UTF8.self)
        #expect(json.contains("\"schema_version\" : 1"))
        #expect(json.contains("\"captured_at\" : \"2026-11-07T17:00:00.000Z\""))
        #expect(json.contains("\"utc_offset_seconds\" : -28800"))
        #expect(!json.contains("user_note"))
        #expect(!json.contains("null"))
    }

    @Test func roundTrips() throws {
        let m = CaptureMetadata.sample(userNote: "Gift idea")
        #expect(try HippoJSON.decodeMetadata(HippoJSON.encode(m)) == m)
    }

    @Test func ignoresUnknownFieldsAndAcceptsUnknownEnumValues() throws {
        var obj = try JSONSerialization.jsonObject(with: HippoJSON.encode(CaptureMetadata.sample())) as! [String: Any]
        obj["future_field"] = ["x": 1]
        obj["capture_method"] = "watch_dictation"
        let m = try HippoJSON.decodeMetadata(JSONSerialization.data(withJSONObject: obj))
        #expect(m.captureMethod.rawValue == "watch_dictation")
    }

    @Test func rejectsUnsupportedMajorVersion() throws {
        var obj = try JSONSerialization.jsonObject(with: HippoJSON.encode(CaptureMetadata.sample())) as! [String: Any]
        obj["schema_version"] = 2
        #expect(throws: FormatError.unsupportedSchemaVersion(2)) {
            try HippoJSON.decodeMetadata(JSONSerialization.data(withJSONObject: obj))
        }
    }

    @Test func decodesDatesWithAndWithoutFractionalSeconds() throws {
        var obj = try JSONSerialization.jsonObject(with: HippoJSON.encode(CaptureMetadata.sample())) as! [String: Any]
        obj["captured_at"] = "2026-11-07T17:00:00Z"
        let m = try HippoJSON.decodeMetadata(JSONSerialization.data(withJSONObject: obj))
        #expect(m.capturedAt == CaptureMetadata.sample().capturedAt)
    }

    @Test func fullyPopulatedModelUsesExplicitSnakeCaseKeysAndRoundTrips() throws {
        let m = CaptureMetadata.sample(userNote: "n", withAttachment: true)
        let data = try HippoJSON.encode(m)
        let json = String(decoding: data, as: UTF8.self)
        for key in ["capture_id", "attachment_id", "sha256", "has_utc_offset", "byte_count",
                    "horizontal_accuracy_meters", "altitude_meters", "relative_path", "embedded_created_at"] {
            #expect(json.contains("\"\(key)\""), "missing \(key)")
        }
        #expect(!json.contains("_i_d"))
        #expect(try HippoJSON.decodeMetadata(data) == m)
    }

    @Test func markerRoundTripsAndGatesVersion() throws {
        let marker = CompletionMarker(schemaVersion: 1, captureID: "abc",
            files: [ManifestEntry(relativePath: "metadata.json", byteCount: 10, sha256: "ab")])
        let data = try HippoJSON.encode(marker)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"capture_id\"") && json.contains("\"relative_path\""))
        #expect(try HippoJSON.decodeMarker(data) == marker)
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        obj["schema_version"] = 3
        #expect(throws: FormatError.unsupportedSchemaVersion(3)) {
            try HippoJSON.decodeMarker(JSONSerialization.data(withJSONObject: obj))
        }
    }

    @Test func malformedInputThrowsFormatError() {
        #expect(throws: FormatError.self) { try HippoJSON.decodeMetadata(Data("{".utf8)) }
        #expect(throws: FormatError.self) { try HippoJSON.decodeMetadata(Data("{\"schema_version\":1}".utf8)) }
    }
}
