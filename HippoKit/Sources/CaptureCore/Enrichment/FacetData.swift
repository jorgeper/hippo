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

// MARK: Context facets (design §5)

/// A `Date` that encodes as an RFC 3339 UTC millisecond string, as everywhere else in package JSON.
private func encodeDate<K: CodingKey>(_ date: Date, _ c: inout KeyedEncodingContainer<K>, _ key: K) throws {
    try c.encode(HippoJSON.timestamp(date), forKey: key)
}

private func decodeDate<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) throws -> Date {
    let text = try c.decode(String.self, forKey: key)
    guard let date = HippoJSON.parseTimestamp(text) else {
        throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "Invalid RFC 3339 date")
    }
    return date
}

public struct MotionActivityData: Codable, Sendable, Equatable {
    public struct Sample: Codable, Sendable, Equatable {
        public var startedAt: Date
        /// Core Motion flags raised for the sample: `stationary`, `walking`, `running`, `cycling`, `automotive`, `unknown`.
        public var activities: [String]
        /// `low`, `medium` or `high`.
        public var confidence: String
        public init(startedAt: Date, activities: [String], confidence: String) {
            self.startedAt = startedAt; self.activities = activities; self.confidence = confidence
        }
        enum CodingKeys: String, CodingKey { case startedAt = "started_at", activities, confidence }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            startedAt = try decodeDate(c, .startedAt)
            activities = try c.decode([String].self, forKey: .activities)
            confidence = try c.decode(String.self, forKey: .confidence)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try encodeDate(startedAt, &c, CodingKeys.startedAt)
            try c.encode(activities, forKey: .activities)
            try c.encode(confidence, forKey: .confidence)
        }
    }

    public var windowStart: Date
    public var windowEnd: Date
    /// The last sample that started at or before the capture; omitted when there is none.
    public var atCapture: Sample?
    public var segments: [Sample]
    public init(windowStart: Date, windowEnd: Date, atCapture: Sample?, segments: [Sample]) {
        self.windowStart = windowStart; self.windowEnd = windowEnd; self.atCapture = atCapture; self.segments = segments
    }
    enum CodingKeys: String, CodingKey {
        case windowStart = "window_start", windowEnd = "window_end", atCapture = "at_capture", segments
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        windowStart = try decodeDate(c, .windowStart)
        windowEnd = try decodeDate(c, .windowEnd)
        atCapture = try c.decodeIfPresent(Sample.self, forKey: .atCapture)
        segments = try c.decode([Sample].self, forKey: .segments)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try encodeDate(windowStart, &c, CodingKeys.windowStart)
        try encodeDate(windowEnd, &c, CodingKeys.windowEnd)
        try c.encodeIfPresent(atCapture, forKey: .atCapture)
        try c.encode(segments, forKey: .segments)
    }
}

public struct WeatherData: Codable, Sendable, Equatable {
    public var observedHour: Date
    public var temperatureCelsius: Double?
    public var apparentTemperatureCelsius: Double?
    public var relativeHumidityPercent: Double?
    public var precipitationMillimeters: Double?
    public var cloudCoverPercent: Double?
    public var windSpeedMetersPerSecond: Double?
    /// The WMO code Open-Meteo returns.
    public var weatherCode: Int?
    /// A coarse reading of `weatherCode`; an open set.
    public var condition: String?
    public var isDay: Bool?
    public var source: String
    public var requestedLatitude: Double
    public var requestedLongitude: Double
    public init(observedHour: Date, temperatureCelsius: Double? = nil, apparentTemperatureCelsius: Double? = nil,
                relativeHumidityPercent: Double? = nil, precipitationMillimeters: Double? = nil,
                cloudCoverPercent: Double? = nil, windSpeedMetersPerSecond: Double? = nil, weatherCode: Int? = nil,
                condition: String? = nil, isDay: Bool? = nil, source: String,
                requestedLatitude: Double, requestedLongitude: Double) {
        self.observedHour = observedHour; self.temperatureCelsius = temperatureCelsius
        self.apparentTemperatureCelsius = apparentTemperatureCelsius
        self.relativeHumidityPercent = relativeHumidityPercent; self.precipitationMillimeters = precipitationMillimeters
        self.cloudCoverPercent = cloudCoverPercent; self.windSpeedMetersPerSecond = windSpeedMetersPerSecond
        self.weatherCode = weatherCode; self.condition = condition; self.isDay = isDay; self.source = source
        self.requestedLatitude = requestedLatitude; self.requestedLongitude = requestedLongitude
    }
    enum CodingKeys: String, CodingKey {
        case observedHour = "observed_hour", temperatureCelsius = "temperature_celsius",
             apparentTemperatureCelsius = "apparent_temperature_celsius",
             relativeHumidityPercent = "relative_humidity_percent", precipitationMillimeters = "precipitation_millimeters",
             cloudCoverPercent = "cloud_cover_percent", windSpeedMetersPerSecond = "wind_speed_meters_per_second",
             weatherCode = "weather_code", condition, isDay = "is_day", source,
             requestedLatitude = "requested_latitude", requestedLongitude = "requested_longitude"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        observedHour = try decodeDate(c, .observedHour)
        temperatureCelsius = try c.decodeIfPresent(Double.self, forKey: .temperatureCelsius)
        apparentTemperatureCelsius = try c.decodeIfPresent(Double.self, forKey: .apparentTemperatureCelsius)
        relativeHumidityPercent = try c.decodeIfPresent(Double.self, forKey: .relativeHumidityPercent)
        precipitationMillimeters = try c.decodeIfPresent(Double.self, forKey: .precipitationMillimeters)
        cloudCoverPercent = try c.decodeIfPresent(Double.self, forKey: .cloudCoverPercent)
        windSpeedMetersPerSecond = try c.decodeIfPresent(Double.self, forKey: .windSpeedMetersPerSecond)
        weatherCode = try c.decodeIfPresent(Int.self, forKey: .weatherCode)
        condition = try c.decodeIfPresent(String.self, forKey: .condition)
        isDay = try c.decodeIfPresent(Bool.self, forKey: .isDay)
        source = try c.decode(String.self, forKey: .source)
        requestedLatitude = try c.decode(Double.self, forKey: .requestedLatitude)
        requestedLongitude = try c.decode(Double.self, forKey: .requestedLongitude)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try encodeDate(observedHour, &c, CodingKeys.observedHour)
        try c.encodeIfPresent(temperatureCelsius, forKey: .temperatureCelsius)
        try c.encodeIfPresent(apparentTemperatureCelsius, forKey: .apparentTemperatureCelsius)
        try c.encodeIfPresent(relativeHumidityPercent, forKey: .relativeHumidityPercent)
        try c.encodeIfPresent(precipitationMillimeters, forKey: .precipitationMillimeters)
        try c.encodeIfPresent(cloudCoverPercent, forKey: .cloudCoverPercent)
        try c.encodeIfPresent(windSpeedMetersPerSecond, forKey: .windSpeedMetersPerSecond)
        try c.encodeIfPresent(weatherCode, forKey: .weatherCode)
        try c.encodeIfPresent(condition, forKey: .condition)
        try c.encodeIfPresent(isDay, forKey: .isDay)
        try c.encode(source, forKey: .source)
        try c.encode(requestedLatitude, forKey: .requestedLatitude)
        try c.encode(requestedLongitude, forKey: .requestedLongitude)
    }
}

public struct BarcodesData: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        public var attachmentID: String
        /// Lowercase (`qr`, `ean13`, `code128`, ...); an open set.
        public var symbology: String
        public var payload: String
        /// Present when the payload is an `http` or `https` URL.
        public var url: String?
        public init(attachmentID: String, symbology: String, payload: String, url: String? = nil) {
            self.attachmentID = attachmentID; self.symbology = symbology; self.payload = payload; self.url = url
        }
        enum CodingKeys: String, CodingKey { case attachmentID = "attachment_id", symbology, payload, url }
    }
    public var items: [Item]
    public init(items: [Item]) { self.items = items }
}

public struct LanguageData: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        /// `user_note`, `shared_text` or `note_body`.
        public var source: String
        /// A BCP 47 tag.
        public var language: String
        public var confidence: Double
        public init(source: String, language: String, confidence: Double) {
            self.source = source; self.language = language; self.confidence = confidence
        }
    }
    public var items: [Item]
    public init(items: [Item]) { self.items = items }
}

public struct SoundClassificationData: Codable, Sendable, Equatable {
    public struct Label: Codable, Sendable, Equatable {
        public var label: String
        public var confidence: Double
        public init(label: String, confidence: Double) { self.label = label; self.confidence = confidence }
    }
    public struct Item: Codable, Sendable, Equatable {
        /// The `comment_id` for a comment's audio.
        public var attachmentID: String
        public var labels: [Label]
        public init(attachmentID: String, labels: [Label]) { self.attachmentID = attachmentID; self.labels = labels }
        enum CodingKeys: String, CodingKey { case attachmentID = "attachment_id", labels }
    }
    public var items: [Item]
    public init(items: [Item]) { self.items = items }
}

public struct ScreenshotData: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        public var attachmentID: String
        /// `exif_user_comment` or `screen_size_match`.
        public var reason: String
        public init(attachmentID: String, reason: String) { self.attachmentID = attachmentID; self.reason = reason }
        enum CodingKeys: String, CodingKey { case attachmentID = "attachment_id", reason }
    }
    public var items: [Item]
    public init(items: [Item]) { self.items = items }
}

// MARK: Server facets (format 1.2)

public struct DisplayKeyword: Codable, Sendable, Equatable {
    public var word: String
    /// 0 to 1.
    public var weight: Double
    public init(word: String, weight: Double) { self.word = word; self.weight = weight }
}

public struct DisplayData: Codable, Sendable, Equatable {
    /// At most 60 characters.
    public var title: String?
    public var topic: String?
    /// At most 12.
    public var keywords: [DisplayKeyword]?
    public init(title: String? = nil, topic: String? = nil, keywords: [DisplayKeyword]? = nil) {
        self.title = title; self.topic = topic; self.keywords = keywords
    }
}

public struct ImageDescriptionItem: Codable, Sendable, Equatable {
    public var attachmentID: String
    public var text: String
    public init(attachmentID: String, text: String) { self.attachmentID = attachmentID; self.text = text }
    enum CodingKeys: String, CodingKey { case attachmentID = "attachment_id", text }
}

public struct ImageDescriptionData: Codable, Sendable, Equatable {
    public var items: [ImageDescriptionItem]
    public init(items: [ImageDescriptionItem]) { self.items = items }
}

public struct PersonItem: Codable, Sendable, Equatable {
    public var name: String
    /// `user_note`, `shared_text`, `shared_title`, an attachment ID or a comment ID.
    public var source: String
    public init(name: String, source: String) { self.name = name; self.source = source }
}

public struct PeopleData: Codable, Sendable, Equatable {
    public var items: [PersonItem]
    public init(items: [PersonItem]) { self.items = items }
}

public struct CircumstanceItem: Codable, Sendable, Equatable {
    /// An open set: `in_car`, `walking`, `running`, `cycling`, `on_headphones`, `in_a_burst`, `daylight`, `dark`, ...
    public var label: String
    /// `low`, `medium` or `high`; an open set.
    public var confidence: String
    /// Short plain sentences, e.g. "audio route was CarPlay".
    public var evidence: [String]?
    public init(label: String, confidence: String, evidence: [String]? = nil) {
        self.label = label; self.confidence = confidence; self.evidence = evidence
    }
}

public struct CircumstanceData: Codable, Sendable, Equatable {
    public var items: [CircumstanceItem]
    public init(items: [CircumstanceItem]) { self.items = items }
}
