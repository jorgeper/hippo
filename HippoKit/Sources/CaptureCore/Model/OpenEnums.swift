import Foundation

/// How a capture was created. Open: readers accept values added by future versions.
public struct CaptureMethod: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
    public static let shareExtension = CaptureMethod(rawValue: "share_extension")
    public static let typedNote = CaptureMethod(rawValue: "typed_note")
    public static let fileImport = CaptureMethod(rawValue: "file_import")
    public static let voiceRecording = CaptureMethod(rawValue: "voice_recording")
    public static let camera = CaptureMethod(rawValue: "camera")
}

/// Kind of content in a capture. Open: readers accept values added by future versions.
public struct ContentType: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
    public static let text = ContentType(rawValue: "text")
    public static let url = ContentType(rawValue: "url")
    public static let image = ContentType(rawValue: "image")
    public static let video = ContentType(rawValue: "video")
    public static let audio = ContentType(rawValue: "audio")
    public static let pdf = ContentType(rawValue: "pdf")
    public static let file = ContentType(rawValue: "file")
}
