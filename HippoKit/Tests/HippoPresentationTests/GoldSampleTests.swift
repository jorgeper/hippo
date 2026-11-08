import Foundation
import Testing
import CaptureCore
@testable import HippoPresentation

private func metadata(urls: [String]) -> CaptureMetadata {
    CaptureMetadata(schemaVersion: 1, captureID: "0b0b0b0b-0000-4000-8000-000000000001",
                    capturedAt: Date(timeIntervalSince1970: 1_794_081_600), localDatetime: "", timezoneIdentifier: "UTC",
                    utcOffsetSeconds: 0, captureMethod: .shareExtension, contentTypes: [], userNote: nil,
                    sharedTitle: nil, sharedText: nil, urls: urls.map { CapturedURL(url: $0, source: "shared") },
                    sourceApplication: nil, captureLocation: nil,
                    producer: Producer(appVersion: "1", build: "1", osVersion: "t"),
                    attachments: [], metadataObservations: [], extensions: [:])
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
}
