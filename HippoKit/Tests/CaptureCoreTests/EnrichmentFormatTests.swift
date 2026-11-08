import Foundation
import Testing
@testable import CaptureCore

@Suite struct EnrichmentFormatTests {
    static let id = "00000000-0000-4000-8000-000000000002"
    static let digest = String(repeating: "a", count: 64)
    static func sha(_ c: Character) -> String { String(repeating: c, count: 64) }
    static let date = HippoJSON.wholeMilliseconds(Date(timeIntervalSince1970: 1_794_074_400.123))
    static let producer = EnrichmentProducer(name: "test", version: "1", build: "1")

    static func thumb(_ c: Character) -> AssetRef {
        AssetRef(relativePath: "assets/\(sha(c)).jpg", byteCount: 10, sha256: sha(c), mimeType: "image/jpeg")
    }

    static func facet(_ data: some Encodable, status: FacetStatus = .ok) throws -> Facet {
        let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(data))
        return Facet(version: 1, status: status, generatedAt: date, provenance: "test", data: json)
    }

    static func document(facets: [String: Facet]) -> EnrichmentDocument {
        EnrichmentDocument(schemaVersion: 1, captureID: id, layer: .device, packageDigest: digest,
                           producer: producer, generatedAt: date, facets: facets)
    }

    static func json(version: Int = 1, captureID: String = id, digest: String = digest, facets: String = "{}",
                     extra: String = "") -> Data {
        Data("""
        {"schema_version": \(version), "capture_id": "\(captureID)", "layer": "server", "package_digest": "\(digest)",
         "producer": {"name": "p", "version": "1", "build": "1"}, "generated_at": "2026-11-07T18:00:00.000Z",
         "facets": \(facets)\(extra)}
        """.utf8)
    }

    static func linkFacetJSON(thumbnailPath: String) -> String {
        """
        {"link_preview": {"version": 1, "status": "ok", "generated_at": "2026-11-07T18:00:00.000Z", "provenance": "x",
         "data": {"items": [{"url": "https://a", "thumbnail": {"relative_path": "\(thumbnailPath)", "byte_count": 3, "sha256": "\(sha("b"))"}}]}}}
        """
    }

    @Test func roundTripPreservesFacets() throws {
        let link = LinkPreviewData(items: [LinkPreviewItem(url: "https://example.com", title: nil, siteName: "example.com",
            channel: nil, summary: nil, canonicalURL: "https://example.com/", thumbnail: Self.thumb("c"))])
        let guess = SourceAppGuessData(app: "Safari", reason: "uti:public.url")
        let doc = Self.document(facets: [
            FacetKind.linkPreview.rawValue: try Self.facet(link),
            FacetKind.sourceAppGuess.rawValue: try Self.facet(guess),
        ])
        let data = try EnrichmentJSON.encode(doc)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"site_name\""))
        #expect(text.contains("\"canonical_url\""))
        #expect(text.contains("\"package_digest\""))
        #expect(!text.contains("\"title\""))
        #expect(try EnrichmentJSON.decode(data) == doc)
    }

    @Test func unknownKindsAndKeysSurvive() throws {
        let facets = """
        {"weather": {"version": 2, "status": "ok", "generated_at": "2026-11-07T18:00:00Z", "provenance": "x", "data": {"temp": 3}, "more": true}}
        """
        let doc = try EnrichmentJSON.decode(Self.json(facets: facets, extra: ", \"extra\": 1"))
        #expect(doc.facets["weather"] != nil)
        #expect(doc.facets["weather"]?.data == .object(["temp": .number(3)]))
    }

    @Test func rejectsOtherSchemaVersion() {
        #expect(throws: FormatError.unsupportedSchemaVersion(2)) { try EnrichmentJSON.decode(Self.json(version: 2)) }
    }

    @Test func rejectsMalformedIdentity() {
        #expect(throws: FormatError.self) { try EnrichmentJSON.decode(Self.json(captureID: "ABCDEF01-0000-4000-8000-000000000002")) }
        #expect(throws: FormatError.self) { try EnrichmentJSON.decode(Self.json(digest: "abc")) }
    }

    @Test func rejectsUnsafeAssetPath() {
        for path in ["../x.jpg", "assets/abc.jpg", "assets/\(Self.sha("b")).JPG"] {
            #expect(throws: FormatError.unsafePath(path)) {
                try EnrichmentJSON.decode(Self.json(facets: Self.linkFacetJSON(thumbnailPath: path)))
            }
        }
        #expect(throws: Never.self) {
            try EnrichmentJSON.decode(Self.json(facets: Self.linkFacetJSON(thumbnailPath: "assets/\(Self.sha("b")).jpg")))
        }
    }

    @Test func referencedAssetsFindsNested() throws {
        func item(_ url: String, _ c: Character) -> LinkPreviewItem {
            LinkPreviewItem(url: url, thumbnail: Self.thumb(c))
        }
        let doc = Self.document(facets: ["link_preview": try Self.facet(LinkPreviewData(items: [item("a", "1"), item("b", "2")]))])
        #expect(doc.referencedAssets().count == 2)
        let dup = Self.document(facets: ["link_preview": try Self.facet(LinkPreviewData(items: [item("a", "1"), item("b", "1")]))])
        #expect(dup.referencedAssets().count == 1)
    }

    @Test func remoteDirectoryMapping() throws {
        let dir = try EnrichmentPaths.remoteDirectory(.server, packageDirectory: "captures/2026/11/07/\(Self.id)")
        #expect(dir == "enrichments/server/2026/11/07/\(Self.id)")
        #expect(throws: FormatError.self) { try EnrichmentPaths.remoteDirectory(.server, packageDirectory: "captures/x") }
    }

    @Test func parseRemoteCases() throws {
        let base = "enrichments/server/2026/11/07/\(Self.id)"
        let doc = try #require(EnrichmentPaths.parseRemote("\(base)/enrichment.json"))
        #expect(doc.file == .document && doc.layer == .server && doc.captureID == Self.id && doc.directory == base)
        let name = "\(Self.sha("d")).jpg"
        #expect(EnrichmentPaths.parseRemote("\(base)/assets/\(name)")?.file == .asset(name))
        #expect(EnrichmentPaths.parseRemote("\(base)/other.json") == nil)
        #expect(EnrichmentPaths.parseRemote("enrichments/server/../x") == nil)
        #expect(EnrichmentPaths.parseRemote("enrichments/server/2026/11/07/ABCDEF01-0000-4000-8000-000000000002/enrichment.json") == nil)
        #expect(EnrichmentPaths.parseRemote("\(base)/assets/bad.jpg") == nil)
    }

    @Test func decodeDataTyped() throws {
        let facet = try Self.facet(LinkPreviewData(items: [LinkPreviewItem(url: "https://a", title: "T")]))
        #expect(facet.decodeData(LinkPreviewData.self)?.items.first?.title == "T")
        let wrong = try Self.facet(TagsData(values: ["x"]))
        #expect(wrong.decodeData(LinkPreviewData.self) == nil)
        let none = Facet(version: 1, status: .empty, generatedAt: Self.date, provenance: "x", data: nil)
        #expect(none.decodeData(LinkPreviewData.self) == nil)
    }
}
