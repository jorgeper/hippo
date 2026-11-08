import Foundation
import Testing
import CaptureCore
@testable import HippoPresentation

private let digest = String(repeating: "a", count: 64)

func enrichmentDoc(_ layer: EnrichmentLayer, facets: [FacetKind: (FacetStatus, any Encodable)]) throws -> EnrichmentDocument {
    var out: [String: Facet] = [:]
    for (kind, (status, payload)) in facets {
        let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(AnyEncodable(payload)))
        out[kind.rawValue] = Facet(version: 1, status: status, generatedAt: Date(timeIntervalSince1970: 0),
                                   provenance: "test", data: json)
    }
    return EnrichmentDocument(schemaVersion: 1, captureID: "00000000-0000-4000-8000-000000000001", layer: layer,
                              packageDigest: digest, producer: EnrichmentProducer(name: "t", version: "1", build: "1"),
                              generatedAt: Date(timeIntervalSince1970: 0), facets: out)
}

struct AnyEncodable: Encodable {
    let base: any Encodable
    init(_ b: any Encodable) { base = b }
    func encode(to encoder: Encoder) throws { try base.encode(to: encoder) }
}

private func assetURL(_ layer: EnrichmentLayer, _ a: AssetRef) -> URL {
    URL(fileURLWithPath: "/enr/\(layer.rawValue)/\(a.relativePath)")
}

private let thumb = AssetRef(relativePath: "assets/t.jpg", byteCount: 3, sha256: digest)

@Suite struct ResolvedEnrichmentTests {
    @Test func goldFieldOverridesSilverField() throws {
        let silver = try enrichmentDoc(.device, facets: [.linkPreview: (.ok, LinkPreviewData(items: [
            LinkPreviewItem(url: "https://a.test/x", title: "S", channel: "C", thumbnail: thumb)]))])
        let gold = try enrichmentDoc(.server, facets: [.linkPreview: (.ok, LinkPreviewData(items: [
            LinkPreviewItem(url: "https://a.test/x", title: "G")]))])
        let r = ResolvedEnrichment.make(device: silver, server: gold, assetURL: assetURL)
        let link = try #require(r.links["https://a.test/x"])
        #expect(link.title == "G" && link.channel == "C" && link.thumbnailURL != nil && link.fromServer)
        #expect(r.usesServer)
    }

    @Test func failedGoldNeverHides() throws {
        let silver = try enrichmentDoc(.device, facets: [.linkPreview: (.ok, LinkPreviewData(items: [
            LinkPreviewItem(url: "https://a.test/x", title: "S")]))])
        let gold = try enrichmentDoc(.server, facets: [.linkPreview: (.failed, LinkPreviewData(items: [
            LinkPreviewItem(url: "https://a.test/x", title: "G")]))])
        let r = ResolvedEnrichment.make(device: silver, server: gold, assetURL: assetURL)
        #expect(r.links["https://a.test/x"]?.title == "S")
        #expect(!r.usesServer)
    }

    @Test func goldOnlyItemAdded() throws {
        let silver = try enrichmentDoc(.device, facets: [.linkPreview: (.ok, LinkPreviewData(items: [
            LinkPreviewItem(url: "https://a.test/x", title: "S")]))])
        let gold = try enrichmentDoc(.server, facets: [.linkPreview: (.ok, LinkPreviewData(items: [
            LinkPreviewItem(url: "https://b.test/y", title: "B")]))])
        let r = ResolvedEnrichment.make(device: silver, server: gold, assetURL: assetURL)
        #expect(r.links.count == 2 && r.links["https://b.test/y"]?.fromServer == true)
        #expect(r.links["https://a.test/x"]?.fromServer == false)
    }

    @Test func placeTextFormats() {
        let p = PlaceItem(target: "capture", subLocality: "Capitol Hill", locality: "Seattle", region: "WA",
                          nearby: NearbyPlace(name: "Victrola Coffee", distanceMeters: 10))
        #expect(PlaceText.line(p) == "Capitol Hill, Seattle · near Victrola Coffee")
        #expect(PlaceText.area(PlaceItem(target: "capture", country: "Spain")) == "Spain")
        #expect(PlaceText.line(PlaceItem(target: "capture")) == nil)
    }

    @Test func emptyDocumentsResolveToEmpty() {
        #expect(ResolvedEnrichment.make(device: nil, server: nil, assetURL: assetURL) == .empty)
    }
}

private func docs(silver: [FacetKind: (FacetStatus, any Encodable)], gold: [FacetKind: (FacetStatus, any Encodable)])
    throws -> ResolvedEnrichment {
    ResolvedEnrichment.make(device: try enrichmentDoc(.device, facets: silver),
                            server: try enrichmentDoc(.server, facets: gold), assetURL: assetURL)
}

private func det(_ t: String) -> Detection { Detection(type: "phone", text: t, value: t, source: "note") }

@Suite struct ResolvedEnrichmentRulesTests {
    @Test func singleItemGoldOkWins() throws {
        let r = try docs(silver: [.dataDetection: (.ok, DataDetectionData(items: [det("s")])),
                                  .sourceAppGuess: (.ok, SourceAppGuessData(app: "S", reason: "r")),
                                  .summary: (.ok, SummaryData(text: "s")), .tags: (.ok, TagsData(values: ["s"]))],
                         gold: [.dataDetection: (.ok, DataDetectionData(items: [det("g")])),
                                .sourceAppGuess: (.ok, SourceAppGuessData(app: "G", reason: "r")),
                                .summary: (.ok, SummaryData(text: "g")), .tags: (.ok, TagsData(values: ["g"]))])
        #expect(r.detections.map(\.text) == ["g"] && r.sourceAppGuess == "G" && r.summary == "g" && r.tags == ["g"])
        #expect(r.usesServer)
    }

    @Test func singleItemFailedOrEmptyGoldLeavesSilver() throws {
        let silver: [FacetKind: (FacetStatus, any Encodable)] = [
            .dataDetection: (.ok, DataDetectionData(items: [det("s")])),
            .sourceAppGuess: (.ok, SourceAppGuessData(app: "S", reason: "r")),
            .summary: (.ok, SummaryData(text: "s")), .tags: (.ok, TagsData(values: ["s"]))]
        let failed = try docs(silver: silver, gold: [
            .dataDetection: (.failed, DataDetectionData(items: [det("g")])),
            .sourceAppGuess: (.failed, SourceAppGuessData(app: "G", reason: "r")),
            .summary: (.failed, SummaryData(text: "g")), .tags: (.empty, TagsData(values: ["g"]))])
        let blank = try docs(silver: silver, gold: [
            .dataDetection: (.ok, DataDetectionData(items: [])),
            .sourceAppGuess: (.ok, SourceAppGuessData(app: "", reason: "r")),
            .summary: (.ok, SummaryData(text: "")), .tags: (.ok, TagsData(values: []))])
        for r in [failed, blank] {
            #expect(r.detections.map(\.text) == ["s"] && r.sourceAppGuess == "S" && r.summary == "s" && r.tags == ["s"])
            #expect(!r.usesServer)
        }
    }

    @Test func placePerFieldAndGoldNonOkIgnored() throws {
        let s = PlaceData(items: [PlaceItem(target: "capture", locality: "Seattle", country: "US")])
        let ok = try docs(silver: [.place: (.ok, s)], gold: [.place: (.ok, PlaceData(items: [
            PlaceItem(target: "capture", locality: "Tacoma", region: "")]))])
        let p = try #require(ok.places["capture"])
        #expect(p.locality == "Tacoma" && p.country == "US" && p.region == nil && ok.usesServer)
        for status in [FacetStatus.failed, .empty] {
            let r = try docs(silver: [.place: (.ok, s)], gold: [.place: (status, PlaceData(items: [
                PlaceItem(target: "capture", locality: "Tacoma")]))])
            #expect(r.places["capture"]?.locality == "Seattle" && !r.usesServer)
        }
        let blank = try docs(silver: [.place: (.ok, s)], gold: [.place: (.ok, PlaceData(items: [
            PlaceItem(target: "capture", locality: "")]))])
        #expect(blank.places["capture"]?.locality == "Seattle" && !blank.usesServer)
    }

    @Test func transcriptsAndRecognizedTextPerAttachment() throws {
        func t(_ id: String, _ text: String) -> TranscriptItem { TranscriptItem(attachmentID: id, text: text, locale: "en_US", segments: []) }
        let silver: [FacetKind: (FacetStatus, any Encodable)] = [
            .transcript: (.ok, TranscriptData(items: [t("a1", "s1"), t("a2", "s2")])),
            .textRecognition: (.ok, TextRecognitionData(items: [
                RecognizedText(attachmentID: "a1", text: "s1", languages: []),
                RecognizedText(attachmentID: "a2", text: "s2", languages: [])]))]
        let r = try docs(silver: silver, gold: [
            .transcript: (.ok, TranscriptData(items: [t("a1", "g1"), t("a2", "")])),
            .textRecognition: (.ok, TextRecognitionData(items: [
                RecognizedText(attachmentID: "a1", text: "g1", languages: []),
                RecognizedText(attachmentID: "a2", text: "", languages: [])]))])
        #expect(r.transcripts["a1"]?.text == "g1" && r.transcripts["a2"]?.text == "s2")
        #expect(r.recognizedText == ["a1": "g1", "a2": "s2"] && r.usesServer)
        let f = try docs(silver: silver, gold: [
            .transcript: (.failed, TranscriptData(items: [t("a1", "g1")])),
            .textRecognition: (.failed, TextRecognitionData(items: [RecognizedText(attachmentID: "a1", text: "g", languages: [])]))])
        #expect(f.transcripts["a1"]?.text == "s1" && f.recognizedText["a1"] == "s1" && !f.usesServer)
    }

    @Test func serverOriginPerItem() throws {
        func t(_ id: String, _ text: String) -> TranscriptItem { TranscriptItem(attachmentID: id, text: text, locale: "en_US", segments: []) }
        let r = try docs(silver: [.transcript: (.ok, TranscriptData(items: [t("A", "s"), t("B", "s")])),
                                  .summary: (.ok, SummaryData(text: "s"))],
                         gold: [.transcript: (.ok, TranscriptData(items: [t("A", "g")])),
                                .place: (.ok, PlaceData(items: [PlaceItem(target: "capture", locality: "Tacoma")])),
                                .summary: (.ok, SummaryData(text: ""))])
        #expect(r.fromServer.transcripts == ["A"])
        #expect(r.fromServer.places == ["capture"])
        #expect(!r.fromServer.summary)
    }

    @Test func silverOnlyAndNonOkSilver() throws {
        let only = ResolvedEnrichment.make(device: try enrichmentDoc(.device, facets: [
            .summary: (.ok, SummaryData(text: "s"))]), server: nil, assetURL: assetURL)
        #expect(only.summary == "s" && !only.usesServer)
        let bad = ResolvedEnrichment.make(device: try enrichmentDoc(.device, facets: [
            .summary: (.failed, SummaryData(text: "s")), .tags: (.empty, TagsData(values: ["x"])),
            .place: (.failed, PlaceData(items: [PlaceItem(target: "capture", locality: "X")])),
            .linkPreview: (.failed, LinkPreviewData(items: [LinkPreviewItem(url: "https://a.test", title: "t")]))]),
            server: nil, assetURL: assetURL)
        #expect(bad == .empty)
    }
}
