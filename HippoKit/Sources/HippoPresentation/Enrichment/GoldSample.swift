import Foundation
import CaptureCore

/// Builds a small server-layer ("gold") enrichment document for a capture, so the DEBUG Settings button
/// can exercise the gold pull and override path without a real server.
public enum GoldSample {
    public static func make(metadata: CaptureMetadata, packageDigest: String, now: Date) -> EnrichmentDocument {
        func facet<T: Encodable>(_ payload: T) -> Facet {
            let value = (try? JSONEncoder().encode(payload)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
            return Facet(version: 1, status: .ok, generatedAt: now, provenance: "server_model", data: value)
        }
        var facets: [String: Facet] = [
            FacetKind.summary.rawValue: facet(SummaryData(text: "Sample server summary for testing.")),
            FacetKind.tags.rawValue: facet(TagsData(values: ["sample", "hippo"])),
        ]
        if let first = metadata.urls.first {
            facets[FacetKind.linkPreview.rawValue] = facet(
                LinkPreviewData(items: [LinkPreviewItem(url: first.url, title: "Sample title from server")]))
        }
        return EnrichmentDocument(schemaVersion: 1, captureID: metadata.captureID, layer: .server,
                                  packageDigest: packageDigest,
                                  producer: EnrichmentProducer(name: "hippo-gold-sample", version: "1", build: "1"),
                                  generatedAt: now, facets: facets)
    }
}
