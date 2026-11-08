import Foundation
import os
import CaptureCore
import LocalRepository
import SyncEngine

public struct ResolvedLink: Equatable, Sendable {
    public var url: String
    public var title: String?
    public var siteName: String?
    public var channel: String?
    public var summary: String?
    public var thumbnailURL: URL?
    public var fromServer: Bool
    public init(url: String, title: String? = nil, siteName: String? = nil, channel: String? = nil,
                summary: String? = nil, thumbnailURL: URL? = nil, fromServer: Bool = false) {
        self.url = url; self.title = title; self.siteName = siteName; self.channel = channel
        self.summary = summary; self.thumbnailURL = thumbnailURL; self.fromServer = fromServer
    }
}

/// Gold over silver over bronze, per item key and per field. A gold field wins only when its facet is `ok`
/// and the field is present; an empty or failed gold facet never hides silver.
public struct ResolvedEnrichment: Equatable, Sendable {
    public var links: [String: ResolvedLink]
    public var places: [String: PlaceItem]
    public var recognizedText: [String: String]
    public var transcripts: [String: TranscriptItem]
    public var detections: [Detection]
    public var sourceAppGuess: String?
    public var summary: String?
    public var tags: [String]
    /// Any field came from gold.
    public var usesServer: Bool

    public static let empty = ResolvedEnrichment(links: [:], places: [:], recognizedText: [:], transcripts: [:],
                                                 detections: [], sourceAppGuess: nil, summary: nil, tags: [],
                                                 usesServer: false)

    private static let log = Logger(subsystem: "com.jorgeper.hippo", category: "presentation")

    /// Reads both layers for the capture. A missing or unreadable document counts as no document.
    public static func load(store: HippoStore, captureID: String) -> ResolvedEnrichment {
        func read(_ layer: EnrichmentLayer) -> EnrichmentDocument? {
            do { return try store.enrichments.document(layer, captureID: captureID) } catch {
                log.error("\("enrichment_read_failed", privacy: .public)")
                return nil
            }
        }
        let enrichments = store.enrichments
        return make(device: read(.device), server: read(.server),
                    assetURL: { enrichments.assetURL($0, captureID: captureID, asset: $1) })
    }

    public static func make(device: EnrichmentDocument?, server: EnrichmentDocument?,
                            assetURL: (EnrichmentLayer, AssetRef) -> URL) -> ResolvedEnrichment {
        var out = ResolvedEnrichment.empty
        func data<T: Decodable>(_ doc: EnrichmentDocument?, _ kind: FacetKind, _ type: T.Type) -> T? {
            guard let f = doc?[kind], f.status == .ok else { return nil }
            return f.decodeData(type)
        }

        // Links, keyed by URL; silver order first, then gold-only.
        let silverLinks = data(device, .linkPreview, LinkPreviewData.self)?.items ?? []
        let goldLinks = data(server, .linkPreview, LinkPreviewData.self)?.items ?? []
        var order: [String] = []
        for item in silverLinks + goldLinks where !order.contains(item.url) { order.append(item.url) }
        for url in order {
            let s = silverLinks.first { $0.url == url }, g = goldLinks.first { $0.url == url }
            var fromServer = false
            func pick<V>(_ gold: V?, _ silver: V?) -> V? {
                if let gold { fromServer = true; return gold }
                return silver
            }
            let thumb: URL? = {
                if let a = g?.thumbnail { fromServer = true; return assetURL(.server, a) }
                return s?.thumbnail.map { assetURL(.device, $0) }
            }()
            out.links[url] = ResolvedLink(
                url: url, title: pick(g?.title, s?.title), siteName: pick(g?.siteName, s?.siteName),
                channel: pick(g?.channel, s?.channel), summary: pick(g?.summary, s?.summary),
                thumbnailURL: thumb, fromServer: fromServer)
            if fromServer { out.usesServer = true }
        }

        // Places, by target, per field.
        let silverPlaces = data(device, .place, PlaceData.self)?.items ?? []
        let goldPlaces = data(server, .place, PlaceData.self)?.items ?? []
        var targets: [String] = []
        for p in silverPlaces + goldPlaces where !targets.contains(p.target) { targets.append(p.target) }
        for t in targets {
            let s = silverPlaces.first { $0.target == t }, g = goldPlaces.first { $0.target == t }
            var fromServer = false
            func pick<V>(_ gold: V?, _ silver: V?) -> V? {
                if let gold { fromServer = true; return gold }
                return silver
            }
            out.places[t] = PlaceItem(
                target: t, subLocality: pick(g?.subLocality, s?.subLocality), locality: pick(g?.locality, s?.locality),
                region: pick(g?.region, s?.region), country: pick(g?.country, s?.country),
                nearby: pick(g?.nearby, s?.nearby))
            if fromServer { out.usesServer = true }
        }

        // Recognized text and transcripts: one item per attachment.
        for i in data(device, .textRecognition, TextRecognitionData.self)?.items ?? [] { out.recognizedText[i.attachmentID] = i.text }
        for i in data(server, .textRecognition, TextRecognitionData.self)?.items ?? [] {
            out.recognizedText[i.attachmentID] = i.text; out.usesServer = true
        }
        for i in data(device, .transcript, TranscriptData.self)?.items ?? [] { out.transcripts[i.attachmentID] = i }
        for i in data(server, .transcript, TranscriptData.self)?.items ?? [] {
            out.transcripts[i.attachmentID] = i; out.usesServer = true
        }

        // Single items.
        if let g = data(server, .dataDetection, DataDetectionData.self)?.items, !g.isEmpty {
            out.detections = g; out.usesServer = true
        } else {
            out.detections = data(device, .dataDetection, DataDetectionData.self)?.items ?? []
        }
        if let g = data(server, .sourceAppGuess, SourceAppGuessData.self) {
            out.sourceAppGuess = g.app; out.usesServer = true
        } else {
            out.sourceAppGuess = data(device, .sourceAppGuess, SourceAppGuessData.self)?.app
        }
        if let g = data(server, .summary, SummaryData.self) {
            out.summary = g.text; out.usesServer = true
        } else {
            out.summary = data(device, .summary, SummaryData.self)?.text
        }
        if let g = data(server, .tags, TagsData.self), !g.values.isEmpty {
            out.tags = g.values; out.usesServer = true
        } else {
            out.tags = data(device, .tags, TagsData.self)?.values ?? []
        }
        return out
    }
}
