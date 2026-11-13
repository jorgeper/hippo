import Foundation
import UniformTypeIdentifiers
import CaptureCore

/// Builds a small server-layer ("gold") enrichment document for a capture, so the DEBUG Settings button
/// can exercise the gold pull and override path without a real server. It carries every kind the desktop
/// enricher writes (format 1.2), including an unknown circumstance label.
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
        facets[FacetKind.display.rawValue] = facet(DisplayData(
            title: "Sample title from server", topic: "sample",
            keywords: [DisplayKeyword(word: "sample", weight: 1), DisplayKeyword(word: "hippo", weight: 0.5)]))
        let pictures = metadata.attachments.filter(isPicture)
        if !pictures.isEmpty {
            facets[FacetKind.imageDescription.rawValue] = facet(ImageDescriptionData(items: pictures.map {
                ImageDescriptionItem(attachmentID: $0.attachmentID, text: "Sample description of this picture.")
            }))
        }
        facets[FacetKind.people.rawValue] = facet(PeopleData(items: [PersonItem(name: "Sample Person", source: "user_note")]))
        facets[FacetKind.circumstance.rawValue] = facet(CircumstanceData(items: [
            CircumstanceItem(label: "in_car", confidence: "medium", evidence: ["sample evidence line"]),
            CircumstanceItem(label: "on_a_boat", confidence: "low"),
        ]))
        return EnrichmentDocument(schemaVersion: 1, captureID: metadata.captureID, layer: .server,
                                  packageDigest: packageDigest,
                                  producer: EnrichmentProducer(name: "hippo-gold-sample", version: "1", build: "1"),
                                  generatedAt: now, facets: facets, schemaMinor: FormatVersion.minor)
    }

    private static func isPicture(_ a: Attachment) -> Bool {
        if let type = UTType(a.uti) { return type.conforms(to: .image) }
        return a.mimeType?.hasPrefix("image/") ?? false
    }
}
