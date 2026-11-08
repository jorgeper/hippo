import Foundation

/// Shared encoder/decoder for package JSON. No key strategies: every Codable type declares explicit snake_case keys.
public enum HippoJSON {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plain = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(timestamp(date))
        }
        return try encoder.encode(value)
    }

    /// RFC 3339 UTC with exactly three fractional digits, rounded to the nearest millisecond.
    /// (`ISO8601FormatStyle` truncates the binary fraction, so e.g. a parsed `.123` can re-encode as `.122`.)
    public static func timestamp(_ date: Date) -> String {
        let ms = (date.timeIntervalSince1970 * 1000).rounded()
        let seconds = (ms / 1000).rounded(.down)
        let millis = Int(ms - seconds * 1000)
        let whole = Date(timeIntervalSince1970: seconds).formatted(plain)   // "…T17:00:00Z"
        return "\(whole.dropLast()).\(millis < 100 ? "0" : "")\(millis < 10 ? "0" : "")\(millis)Z"
    }

    /// `date` truncated to whole milliseconds, exactly as it decodes back from package JSON, so
    /// encode → decode returns an equal `Date`.
    public static func wholeMilliseconds(_ date: Date) -> Date {
        let truncated = Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded(.down) / 1000)
        return (try? fractional.parse(timestamp(truncated))) ?? truncated
    }

    public static func decodeMetadata(_ data: Data) throws -> CaptureMetadata {
        try decode(CaptureMetadata.self, from: data)
    }

    public static func decodeMarker(_ data: Data) throws -> CompletionMarker {
        try decode(CompletionMarker.self, from: data)
    }

    private struct VersionProbe: Decodable {
        let schemaVersion: Int
        enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version" }
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            let version = try JSONDecoder().decode(VersionProbe.self, from: data).schemaVersion
            guard version == 1 else { throw FormatError.unsupportedSchemaVersion(version) }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { dec in
                let s = try dec.singleValueContainer().decode(String.self)
                if let d = try? fractional.parse(s) { return d }
                if let d = try? plain.parse(s) { return d }
                throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "Invalid RFC 3339 date"))
            }
            return try decoder.decode(type, from: data)
        } catch let e as FormatError {
            throw e
        } catch {
            throw FormatError.malformed(String(describing: error))
        }
    }
}
