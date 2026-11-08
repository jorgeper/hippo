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
