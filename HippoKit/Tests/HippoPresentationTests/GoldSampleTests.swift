import Foundation
import Testing
import CaptureCore
@testable import HippoPresentation

private func attachment(_ id: String, uti: String, mime: String) -> CaptureCore.Attachment {
    Attachment(attachmentID: id, relativePath: "attachments/\(id)", uti: uti, mimeType: mime, byteCount: 1,
               sha256: String(repeating: "c", count: 64), representationSource: "test")
}

private func metadata(urls: [String], attachments: [CaptureCore.Attachment] = []) -> CaptureMetadata {
    CaptureMetadata(schemaVersion: 1, captureID: "0b0b0b0b-0000-4000-8000-000000000001",
                    capturedAt: Date(timeIntervalSince1970: 1_794_081_600), localDatetime: "", timezoneIdentifier: "UTC",
                    utcOffsetSeconds: 0, captureMethod: .shareExtension, contentTypes: [], userNote: nil,
                    sharedTitle: nil, sharedText: nil, urls: urls.map { CapturedURL(url: $0, source: "shared") },
                    sourceApplication: nil, captureLocation: nil,
                    producer: Producer(appVersion: "1", build: "1", osVersion: "t"),
                    attachments: attachments, metadataObservations: [], extensions: [:])
}

@Suite struct GoldSampleTests {
    let digest = String(repeating: "ab", count: 32)
    let now = Date(timeIntervalSince1970: 1_794_081_700)

    @Test func goldSampleValid() throws {
        let sample = GoldSample.make(metadata: metadata(urls: ["https://example.com/a", "https://example.com/b"]),
                                     packageDigest: digest, now: now)
        let decoded = try EnrichmentJSON.decode(EnrichmentJSON.encode(sample))
        #expect(decoded == sample)
        #expect(decoded.layer == .server)
        #expect(decoded.producer == EnrichmentProducer(name: "hippo-gold-sample", version: "1", build: "1"))
        #expect(decoded[.summary]?.decodeData(SummaryData.self)?.text == "Sample server summary for testing.")
        #expect(decoded[.tags]?.decodeData(TagsData.self)?.values == ["sample", "hippo"])
        #expect(decoded[.summary]?.status == .ok)
        let items = decoded[.linkPreview]?.decodeData(LinkPreviewData.self)?.items
        #expect(items?.count == 1)
        #expect(items?.first?.url == "https://example.com/a")
        #expect(items?.first?.title == "Sample title from server")
        #expect(decoded.referencedAssets().isEmpty)
    }

    @Test func noURLMeansNoLinkPreview() {
        let sample = GoldSample.make(metadata: metadata(urls: []), packageDigest: digest, now: now)
        #expect(sample[.linkPreview] == nil)
        #expect(sample[.summary] != nil)
    }

    @Test func serverKindsWritten() throws {
        let picture = "0b0b0b0b-0000-4000-8000-0b0b00000001"
        let m = metadata(urls: ["https://example.com/a"], attachments: [
            attachment(picture, uti: "public.jpeg", mime: "image/jpeg"),
            attachment("0b0b0b0b-0000-4000-8000-0b0b00000002", uti: "com.apple.m4a-audio", mime: "audio/mp4")])
        let sample = GoldSample.make(metadata: m, packageDigest: digest, now: now)
        let decoded = try EnrichmentJSON.decode(EnrichmentJSON.encode(sample))
        #expect(decoded == sample)
        #expect(decoded.schemaMinor == FormatVersion.minor)
        #expect(Set(decoded.facets.keys) == ["summary", "tags", "link_preview", "display", "image_description",
                                             "people", "circumstance"])
        for (_, facet) in decoded.facets { #expect(facet.status == .ok) }
        let display = try #require(decoded[.display]?.decodeData(DisplayData.self))
        #expect(display.title == "Sample title from server" && display.topic == "sample")
        #expect(display.keywords?.count == 2)
        let images = try #require(decoded[.imageDescription]?.decodeData(ImageDescriptionData.self))
        #expect(images.items == [ImageDescriptionItem(attachmentID: picture, text: "Sample description of this picture.")])
        let people = try #require(decoded[.people]?.decodeData(PeopleData.self))
        #expect(people.items == [PersonItem(name: "Sample Person", source: "user_note")])
        let circumstance = try #require(decoded[.circumstance]?.decodeData(CircumstanceData.self))
        #expect(circumstance.items == [
            CircumstanceItem(label: "in_car", confidence: "medium", evidence: ["sample evidence line"]),
            CircumstanceItem(label: "on_a_boat", confidence: "low")])
    }

    @Test func textOnlyMeansNoImageDescription() throws {
        let m = metadata(urls: [], attachments: [
            attachment("0b0b0b0b-0000-4000-8000-0b0b00000003", uti: "public.plain-text", mime: "text/plain")])
        let sample = GoldSample.make(metadata: m, packageDigest: digest, now: now)
        #expect(sample[.imageDescription] == nil)
        #expect(sample[.display] != nil && sample[.people] != nil && sample[.circumstance] != nil)
        #expect(try EnrichmentJSON.decode(EnrichmentJSON.encode(sample)) == sample)
    }
}
