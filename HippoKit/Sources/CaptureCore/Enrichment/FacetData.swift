import Foundation

// Payloads for known facet kinds, carried in `Facet.data`. Optional fields are omitted when unknown.

public struct LinkPreviewItem: Codable, Sendable, Equatable {
    public var url: String
    public var title: String?
    public var siteName: String?
    public var channel: String?
    public var summary: String?
    public var canonicalURL: String?
    public var thumbnail: AssetRef?
    public init(url: String, title: String? = nil, siteName: String? = nil, channel: String? = nil,
                summary: String? = nil, canonicalURL: String? = nil, thumbnail: AssetRef? = nil) {
        self.url = url; self.title = title; self.siteName = siteName; self.channel = channel
        self.summary = summary; self.canonicalURL = canonicalURL; self.thumbnail = thumbnail
    }
    enum CodingKeys: String, CodingKey {
        case url, title, siteName = "site_name", channel, summary = "description"
        case canonicalURL = "canonical_url", thumbnail
    }
}

public struct LinkPreviewData: Codable, Sendable, Equatable {
    public var items: [LinkPreviewItem]
    public init(items: [LinkPreviewItem]) { self.items = items }
}

public struct NearbyPlace: Codable, Sendable, Equatable {
    public var name: String
    public var distanceMeters: Double
    public init(name: String, distanceMeters: Double) { self.name = name; self.distanceMeters = distanceMeters }
    enum CodingKeys: String, CodingKey { case name, distanceMeters = "distance_meters" }
}

public struct PlaceItem: Codable, Sendable, Equatable {
    /// `"capture"` or an attachment ID.
    public var target: String
    public var subLocality: String?
    public var locality: String?
    public var region: String?
    public var country: String?
    public var nearby: NearbyPlace?
    public init(target: String, subLocality: String? = nil, locality: String? = nil, region: String? = nil,
                country: String? = nil, nearby: NearbyPlace? = nil) {
        self.target = target; self.subLocality = subLocality; self.locality = locality
        self.region = region; self.country = country; self.nearby = nearby
    }
    enum CodingKeys: String, CodingKey {
        case target, subLocality = "sub_locality", locality, region, country, nearby
    }
}

public struct PlaceData: Codable, Sendable, Equatable {
    public var items: [PlaceItem]
    public init(items: [PlaceItem]) { self.items = items }
}

public struct RecognizedText: Codable, Sendable, Equatable {
    public var attachmentID: String
    public var text: String
    public var languages: [String]
    public init(attachmentID: String, text: String, languages: [String]) {
        self.attachmentID = attachmentID; self.text = text; self.languages = languages
    }
    enum CodingKeys: String, CodingKey { case attachmentID = "attachment_id", text, languages }
}

public struct TextRecognitionData: Codable, Sendable, Equatable {
    public var items: [RecognizedText]
    public init(items: [RecognizedText]) { self.items = items }
}

public struct TranscriptSegment: Codable, Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }
}

public struct TranscriptItem: Codable, Sendable, Equatable {
    public var attachmentID: String
    public var text: String
    public var locale: String
    public var segments: [TranscriptSegment]
    public init(attachmentID: String, text: String, locale: String, segments: [TranscriptSegment]) {
        self.attachmentID = attachmentID; self.text = text; self.locale = locale; self.segments = segments
    }
    enum CodingKeys: String, CodingKey { case attachmentID = "attachment_id", text, locale, segments }
}

public struct TranscriptData: Codable, Sendable, Equatable {
    public var items: [TranscriptItem]
    public init(items: [TranscriptItem]) { self.items = items }
}

public struct Detection: Codable, Sendable, Equatable {
    /// `date`, `phone`, `address` or `link`.
    public var type: String
    public var text: String
    public var value: String?
    public var components: [String: String]?
    public var source: String
    public init(type: String, text: String, value: String? = nil, components: [String: String]? = nil, source: String) {
        self.type = type; self.text = text; self.value = value; self.components = components; self.source = source
    }
}

public struct DataDetectionData: Codable, Sendable, Equatable {
    public var items: [Detection]
    public init(items: [Detection]) { self.items = items }
}

public struct SourceAppGuessData: Codable, Sendable, Equatable {
    public var app: String
    public var reason: String
    public init(app: String, reason: String) { self.app = app; self.reason = reason }
}

public struct SummaryData: Codable, Sendable, Equatable {
    public var text: String
    public init(text: String) { self.text = text }
}

public struct TagsData: Codable, Sendable, Equatable {
    public var values: [String]
    public init(values: [String]) { self.values = values }
}
