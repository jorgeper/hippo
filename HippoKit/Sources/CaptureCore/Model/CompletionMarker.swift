import Foundation

public struct ManifestEntry: Codable, Sendable, Equatable {
    public var relativePath: String
    public var byteCount: Int64
    public var sha256: String

    public init(relativePath: String, byteCount: Int64, sha256: String) {
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sha256 = sha256
    }

    enum CodingKeys: String, CodingKey {
        case relativePath = "relative_path"
        case byteCount = "byte_count"
        case sha256
    }
}

/// `complete.json`: lists every file in the package except itself.
public struct CompletionMarker: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var schemaMinor: Int?
    public var captureID: String
    public var files: [ManifestEntry]

    public init(schemaVersion: Int, captureID: String, files: [ManifestEntry], schemaMinor: Int? = nil) {
        self.schemaVersion = schemaVersion
        self.schemaMinor = schemaMinor
        self.captureID = captureID
        self.files = files
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case schemaMinor = "schema_minor"
        case captureID = "capture_id"
        case files
    }
}
