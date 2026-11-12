import Foundation

/// Who wrote an enrichment file. Silver (`device`) is written by the phone, gold (`server`) by a server.
public enum EnrichmentLayer: String, Codable, Sendable, Equatable, Hashable {
    case device, server
}

/// Kind of derived data. Open: readers keep kinds added by future versions.
public struct FacetKind: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
    public static let linkPreview = FacetKind(rawValue: "link_preview")
    public static let place = FacetKind(rawValue: "place")
    public static let textRecognition = FacetKind(rawValue: "text_recognition")
    public static let dataDetection = FacetKind(rawValue: "data_detection")
    public static let transcript = FacetKind(rawValue: "transcript")
    public static let sourceAppGuess = FacetKind(rawValue: "source_app_guess")
    public static let summary = FacetKind(rawValue: "summary")
    public static let tags = FacetKind(rawValue: "tags")
    public static let motionActivity = FacetKind(rawValue: "motion_activity")
    public static let weather = FacetKind(rawValue: "weather")
    public static let barcodes = FacetKind(rawValue: "barcodes")
    public static let language = FacetKind(rawValue: "language")
    public static let soundClassification = FacetKind(rawValue: "sound_classification")
    public static let screenshot = FacetKind(rawValue: "screenshot")
    // Format 1.2: server-layer kinds.
    public static let display = FacetKind(rawValue: "display")
    public static let imageDescription = FacetKind(rawValue: "image_description")
    public static let people = FacetKind(rawValue: "people")
    public static let circumstance = FacetKind(rawValue: "circumstance")
}

/// Outcome of producing a facet. Open: readers accept values added by future versions.
public struct FacetStatus: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
    public static let ok = FacetStatus(rawValue: "ok")
    public static let empty = FacetStatus(rawValue: "empty")
    public static let failed = FacetStatus(rawValue: "failed")
}

/// A binary file beside `enrichment.json`, referenced from facet data.
public struct AssetRef: Codable, Sendable, Equatable, Hashable {
    public var relativePath: String
    public var byteCount: Int64
    public var sha256: String
    public var mimeType: String?
    public init(relativePath: String, byteCount: Int64, sha256: String, mimeType: String? = nil) {
        self.relativePath = relativePath; self.byteCount = byteCount; self.sha256 = sha256; self.mimeType = mimeType
    }
    enum CodingKeys: String, CodingKey {
        case relativePath = "relative_path", byteCount = "byte_count", sha256, mimeType = "mime_type"
    }
}

public struct EnrichmentProducer: Codable, Sendable, Equatable {
    public var name: String
    public var version: String
    public var build: String
    public init(name: String, version: String, build: String) {
        self.name = name; self.version = version; self.build = build
    }
    enum CodingKeys: String, CodingKey { case name, version, build }
}

public struct Facet: Codable, Sendable, Equatable {
    public var version: Int
    public var status: FacetStatus
    public var generatedAt: Date
    public var provenance: String
    public var data: JSONValue?
    public init(version: Int, status: FacetStatus, generatedAt: Date, provenance: String, data: JSONValue?) {
        self.version = version; self.status = status; self.generatedAt = generatedAt
        self.provenance = provenance; self.data = data
    }
    enum CodingKeys: String, CodingKey {
        case version, status, generatedAt = "generated_at", provenance, data
    }

    /// Decodes `data` as a known payload; nil when absent or not of that shape.
    public func decodeData<T: Decodable>(_ type: T.Type) -> T? {
        guard let data, let bytes = try? JSONEncoder().encode(data) else { return nil }
        return try? JSONDecoder().decode(type, from: bytes)
    }
}

/// Contents of `enrichment.json` (schema v1).
public struct EnrichmentDocument: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var schemaMinor: Int?
    public var captureID: String
    public var layer: EnrichmentLayer
    public var packageDigest: String
    public var producer: EnrichmentProducer
    public var generatedAt: Date
    public var facets: [String: Facet]

    public init(schemaVersion: Int, captureID: String, layer: EnrichmentLayer, packageDigest: String,
                producer: EnrichmentProducer, generatedAt: Date, facets: [String: Facet], schemaMinor: Int? = nil) {
        self.schemaVersion = schemaVersion; self.schemaMinor = schemaMinor; self.captureID = captureID; self.layer = layer
        self.packageDigest = packageDigest; self.producer = producer; self.generatedAt = generatedAt
        self.facets = facets
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", schemaMinor = "schema_minor", captureID = "capture_id", layer
        case packageDigest = "package_digest", producer, generatedAt = "generated_at", facets
    }

    public subscript(kind: FacetKind) -> Facet? { facets[kind.rawValue] }

    /// Every JSON object anywhere in any facet's data with string `relative_path` and `sha256` and integer
    /// `byte_count`, deduplicated by path (first seen wins, in facet-key order).
    public func referencedAssets() -> [AssetRef] {
        var seen = Set<String>()
        var out: [AssetRef] = []
        func walk(_ v: JSONValue) {
            switch v {
            case .array(let items): items.forEach(walk)
            case .object(let o):
                if case .string(let path)? = o["relative_path"], case .string(let sha)? = o["sha256"],
                   case .number(let n)? = o["byte_count"], n == n.rounded(), abs(n) < 9e15 {
                    if seen.insert(path).inserted {
                        var mime: String?
                        if case .string(let m)? = o["mime_type"] { mime = m }
                        out.append(AssetRef(relativePath: path, byteCount: Int64(n), sha256: sha, mimeType: mime))
                    }
                }
                for key in o.keys.sorted() { walk(o[key]!) }
            default: break
            }
        }
        for key in facets.keys.sorted() { if let d = facets[key]?.data { walk(d) } }
        return out
    }
}

public enum EnrichmentJSON {
    public static func encode(_ d: EnrichmentDocument) throws -> Data { try HippoJSON.encode(d) }

    public static func decode(_ data: Data) throws -> EnrichmentDocument {
        let doc = try HippoJSON.decode(EnrichmentDocument.self, from: data)
        guard EnrichmentPaths.isLowercaseUUID(doc.captureID) else {
            throw FormatError.malformed("capture_id is not a lowercase UUID")
        }
        guard EnrichmentPaths.isLowercaseHex(doc.packageDigest, 64) else {
            throw FormatError.malformed("package_digest is not 64 lowercase hex characters")
        }
        for asset in doc.referencedAssets() where !EnrichmentPaths.isValidAssetPath(asset.relativePath) {
            throw FormatError.unsafePath(asset.relativePath)
        }
        return doc
    }
}
