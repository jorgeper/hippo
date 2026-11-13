import Foundation

/// The audio file of an audio comment, described like an attachment but without an id.
public struct CommentAudio: Codable, Sendable, Equatable {
    public var relativePath: String
    public var uti: String
    public var mimeType: String?
    public var byteCount: Int64
    public var sha256: String
    public var media: MediaFacts?

    public init(relativePath: String, uti: String, mimeType: String?, byteCount: Int64, sha256: String, media: MediaFacts?) {
        self.relativePath = relativePath; self.uti = uti; self.mimeType = mimeType
        self.byteCount = byteCount; self.sha256 = sha256; self.media = media
    }

    enum CodingKeys: String, CodingKey {
        case relativePath = "relative_path", uti, mimeType = "mime_type"
        case byteCount = "byte_count", sha256, media
    }
}

/// One append-only comment: `comments/<comment-id>.json` in a package (spec §3). Exactly one of
/// `text` / `audio` is set.
public struct CaptureComment: Codable, Sendable, Equatable, Identifiable {
    public var schemaVersion: Int
    public var captureID: String
    public var commentID: String
    public var addedAt: Date
    public var localDatetime: String
    public var timezoneIdentifier: String
    public var utcOffsetSeconds: Int
    public var producer: Producer
    public var text: String?
    public var audio: CommentAudio?

    public init(schemaVersion: Int = 1, captureID: String, commentID: String, addedAt: Date, localDatetime: String,
                timezoneIdentifier: String, utcOffsetSeconds: Int, producer: Producer,
                text: String? = nil, audio: CommentAudio? = nil) {
        self.schemaVersion = schemaVersion; self.captureID = captureID; self.commentID = commentID
        self.addedAt = addedAt; self.localDatetime = localDatetime
        self.timezoneIdentifier = timezoneIdentifier; self.utcOffsetSeconds = utcOffsetSeconds
        self.producer = producer; self.text = text; self.audio = audio
    }

    public var id: String { commentID }
    public var relativePath: String { "comments/\(commentID).json" }
    /// The json path, preceded by the audio path when present (upload order).
    public var filePaths: [String] { (audio.map { [$0.relativePath] } ?? []) + [relativePath] }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", captureID = "capture_id", commentID = "comment_id"
        case addedAt = "added_at", localDatetime = "local_datetime"
        case timezoneIdentifier = "timezone_identifier", utcOffsetSeconds = "utc_offset_seconds"
        case producer, text, audio
    }
}

public enum CommentDraft: Sendable, Equatable {
    case text(String)
    case audio(fileURL: URL, uti: String, mimeType: String?, durationSeconds: Double?)
}
