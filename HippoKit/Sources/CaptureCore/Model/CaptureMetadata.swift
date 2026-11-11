import Foundation

public enum FormatError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
    case malformed(String)
    case unsafePath(String)
}

public indirect enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

public struct CapturedURL: Codable, Sendable, Equatable {
    public var url: String
    public var source: String
    public init(url: String, source: String) { self.url = url; self.source = source }
    enum CodingKeys: String, CodingKey { case url, source }
}

public struct CaptureLocation: Codable, Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var horizontalAccuracyMeters: Double
    public var observedAt: Date
    public var provenance: String
    public var altitudeMeters: Double?
    public var verticalAccuracyMeters: Double?
    public var speedMetersPerSecond: Double?
    public var speedAccuracyMetersPerSecond: Double?
    public var courseDegrees: Double?
    public var courseAccuracyDegrees: Double?
    public init(latitude: Double, longitude: Double, horizontalAccuracyMeters: Double, observedAt: Date, provenance: String,
                altitudeMeters: Double? = nil, verticalAccuracyMeters: Double? = nil,
                speedMetersPerSecond: Double? = nil, speedAccuracyMetersPerSecond: Double? = nil,
                courseDegrees: Double? = nil, courseAccuracyDegrees: Double? = nil) {
        self.latitude = latitude; self.longitude = longitude
        self.horizontalAccuracyMeters = horizontalAccuracyMeters
        self.observedAt = observedAt; self.provenance = provenance
        self.altitudeMeters = altitudeMeters; self.verticalAccuracyMeters = verticalAccuracyMeters
        self.speedMetersPerSecond = speedMetersPerSecond
        self.speedAccuracyMetersPerSecond = speedAccuracyMetersPerSecond
        self.courseDegrees = courseDegrees; self.courseAccuracyDegrees = courseAccuracyDegrees
    }
    enum CodingKeys: String, CodingKey {
        case latitude, longitude
        case horizontalAccuracyMeters = "horizontal_accuracy_meters"
        case observedAt = "observed_at"
        case provenance
        case altitudeMeters = "altitude_meters"
        case verticalAccuracyMeters = "vertical_accuracy_meters"
        case speedMetersPerSecond = "speed_meters_per_second"
        case speedAccuracyMetersPerSecond = "speed_accuracy_meters_per_second"
        case courseDegrees = "course_degrees"
        case courseAccuracyDegrees = "course_accuracy_degrees"
    }
}

public struct Producer: Codable, Sendable, Equatable {
    public var appVersion: String
    public var build: String
    public var osVersion: String
    public init(appVersion: String, build: String, osVersion: String) {
        self.appVersion = appVersion; self.build = build; self.osVersion = osVersion
    }
    enum CodingKeys: String, CodingKey {
        case appVersion = "app_version"
        case build
        case osVersion = "os_version"
    }
}

public struct EmbeddedTimestamp: Codable, Sendable, Equatable {
    public var value: String
    public var hasUTCOffset: Bool
    public init(value: String, hasUTCOffset: Bool) { self.value = value; self.hasUTCOffset = hasUTCOffset }
    enum CodingKeys: String, CodingKey {
        case value
        case hasUTCOffset = "has_utc_offset"
    }
}

public struct EmbeddedLocation: Codable, Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var altitudeMeters: Double?
    public init(latitude: Double, longitude: Double, altitudeMeters: Double? = nil) {
        self.latitude = latitude; self.longitude = longitude; self.altitudeMeters = altitudeMeters
    }
    enum CodingKeys: String, CodingKey {
        case latitude, longitude
        case altitudeMeters = "altitude_meters"
    }
}

public struct MediaFacts: Codable, Sendable, Equatable {
    public var widthPixels: Int?
    public var heightPixels: Int?
    public var durationSeconds: Double?
    public var embeddedCreatedAt: EmbeddedTimestamp?
    public var embeddedLocation: EmbeddedLocation?
    public var cameraMake: String?
    public var cameraModel: String?
    public init(widthPixels: Int? = nil, heightPixels: Int? = nil, durationSeconds: Double? = nil,
                embeddedCreatedAt: EmbeddedTimestamp? = nil, embeddedLocation: EmbeddedLocation? = nil,
                cameraMake: String? = nil, cameraModel: String? = nil) {
        self.widthPixels = widthPixels; self.heightPixels = heightPixels
        self.durationSeconds = durationSeconds; self.embeddedCreatedAt = embeddedCreatedAt
        self.embeddedLocation = embeddedLocation; self.cameraMake = cameraMake; self.cameraModel = cameraModel
    }
    enum CodingKeys: String, CodingKey {
        case widthPixels = "width_pixels"
        case heightPixels = "height_pixels"
        case durationSeconds = "duration_seconds"
        case embeddedCreatedAt = "embedded_created_at"
        case embeddedLocation = "embedded_location"
        case cameraMake = "camera_make"
        case cameraModel = "camera_model"
    }
}

public struct Attachment: Codable, Sendable, Equatable {
    public var attachmentID: String
    public var relativePath: String
    public var originalFilename: String?
    public var uti: String
    public var mimeType: String?
    public var byteCount: Int64
    public var sha256: String
    public var representationSource: String
    public var media: MediaFacts?
    public init(attachmentID: String, relativePath: String, originalFilename: String? = nil, uti: String,
                mimeType: String? = nil, byteCount: Int64, sha256: String, representationSource: String,
                media: MediaFacts? = nil) {
        self.attachmentID = attachmentID; self.relativePath = relativePath
        self.originalFilename = originalFilename; self.uti = uti; self.mimeType = mimeType
        self.byteCount = byteCount; self.sha256 = sha256
        self.representationSource = representationSource; self.media = media
    }
    enum CodingKeys: String, CodingKey {
        case attachmentID = "attachment_id"
        case relativePath = "relative_path"
        case originalFilename = "original_filename"
        case uti
        case mimeType = "mime_type"
        case byteCount = "byte_count"
        case sha256
        case representationSource = "representation_source"
        case media
    }
}

public struct MetadataObservation: Codable, Sendable, Equatable {
    public var key: String
    public var value: JSONValue
    public var provenance: String
    public init(key: String, value: JSONValue, provenance: String) {
        self.key = key; self.value = value; self.provenance = provenance
    }
    enum CodingKeys: String, CodingKey { case key, value, provenance }
}

/// Contents of `metadata.json` (schema v1). Unavailable optional fields are omitted when encoded.
public struct CaptureMetadata: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var schemaMinor: Int?
    public var captureID: String
    public var capturedAt: Date
    public var localDatetime: String
    public var timezoneIdentifier: String
    public var utcOffsetSeconds: Int
    public var captureMethod: CaptureMethod
    public var contentTypes: [ContentType]
    public var userNote: String?
    public var sharedTitle: String?
    public var sharedText: String?
    public var urls: [CapturedURL]
    public var sourceApplication: String?
    public var captureLocation: CaptureLocation?
    public var producer: Producer
    public var attachments: [Attachment]
    public var metadataObservations: [MetadataObservation]
    public var extensions: [String: JSONValue]

    public init(schemaVersion: Int, captureID: String, capturedAt: Date, localDatetime: String,
                timezoneIdentifier: String, utcOffsetSeconds: Int, captureMethod: CaptureMethod,
                contentTypes: [ContentType], userNote: String?, sharedTitle: String?, sharedText: String?,
                urls: [CapturedURL], sourceApplication: String?, captureLocation: CaptureLocation?,
                producer: Producer, attachments: [Attachment], metadataObservations: [MetadataObservation],
                extensions: [String: JSONValue], schemaMinor: Int? = nil) {
        self.schemaVersion = schemaVersion; self.schemaMinor = schemaMinor; self.captureID = captureID; self.capturedAt = capturedAt
        self.localDatetime = localDatetime; self.timezoneIdentifier = timezoneIdentifier
        self.utcOffsetSeconds = utcOffsetSeconds; self.captureMethod = captureMethod
        self.contentTypes = contentTypes; self.userNote = userNote; self.sharedTitle = sharedTitle
        self.sharedText = sharedText; self.urls = urls; self.sourceApplication = sourceApplication
        self.captureLocation = captureLocation; self.producer = producer; self.attachments = attachments
        self.metadataObservations = metadataObservations; self.extensions = extensions
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case schemaMinor = "schema_minor"
        case captureID = "capture_id"
        case capturedAt = "captured_at"
        case localDatetime = "local_datetime"
        case timezoneIdentifier = "timezone_identifier"
        case utcOffsetSeconds = "utc_offset_seconds"
        case captureMethod = "capture_method"
        case contentTypes = "content_types"
        case userNote = "user_note"
        case sharedTitle = "shared_title"
        case sharedText = "shared_text"
        case urls
        case sourceApplication = "source_application"
        case captureLocation = "capture_location"
        case producer, attachments
        case metadataObservations = "metadata_observations"
        case extensions
    }
}
