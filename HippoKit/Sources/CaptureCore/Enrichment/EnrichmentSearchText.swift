import Foundation

/// The text a capture's enrichments add to timeline search (design §9): the `enrichment` column of
/// `captures_fts`.
public enum EnrichmentSearchText {
    /// Reads the `ok` facets of both layers (silver first, then gold, per kind). Lines are joined with
    /// newlines in this order: link titles, site names, channels and descriptions; place sub-locality,
    /// locality, region, country and nearby name; OCR text; transcript text; summary; tags. Empty
    /// values and repeated lines are skipped.
    public static func make(device: EnrichmentDocument?, server: EnrichmentDocument?) -> String {
        let docs = [device, server].compactMap { $0 }
        func payloads<T: Decodable>(_ kind: FacetKind, _ type: T.Type) -> [T] {
            docs.compactMap { doc in
                guard let facet = doc[kind], facet.status == .ok else { return nil }
                return facet.decodeData(type)
            }
        }

        var lines: [String?] = []
        let links = payloads(.linkPreview, LinkPreviewData.self).flatMap(\.items)
        lines += links.map(\.title) + links.map(\.siteName) + links.map(\.channel) + links.map(\.summary)
        let places = payloads(.place, PlaceData.self).flatMap(\.items)
        lines += places.map(\.subLocality) + places.map(\.locality) + places.map(\.region) + places.map(\.country)
            + places.map(\.nearby?.name)
        lines += payloads(.textRecognition, TextRecognitionData.self).flatMap(\.items).map(\.text)
        lines += payloads(.transcript, TranscriptData.self).flatMap(\.items).map(\.text)
        lines += payloads(.summary, SummaryData.self).map(\.text)
        lines += payloads(.tags, TagsData.self).flatMap(\.values)

        var seen = Set<String>()
        return lines.compactMap { line -> String? in
            guard let line, !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seen.insert(line).inserted else { return nil }
            return line
        }.joined(separator: "\n")
    }
}
