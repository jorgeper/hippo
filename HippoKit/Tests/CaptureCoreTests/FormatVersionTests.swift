import Testing
import Foundation
@testable import CaptureCore
import HippoTestSupport

private struct FakeSpace: SpaceChecking {
    let bytes: Int64
    func availableBytes(at url: URL) throws -> Int64 { bytes }
}

@Suite struct FormatVersionTests {
    private let root: URL
    private let layout: StoreLayout
    private let producer = Producer(appVersion: "0.1.0", build: "1", osVersion: "test")
    private let la = TimeZone(identifier: "America/Los_Angeles")!
    private let now = Date(timeIntervalSince1970: 1_794_070_800)
    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let day = "fixtures/packages/captures/2026/11/07/"

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hippo-format-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        layout = StoreLayout(root: root)
    }

    private func commit() async throws -> CommittedPackage {
        let draft = CaptureDraft(captureID: UUID(), startedAt: now, timeZone: la, method: .typedNote, userNote: "a capture")
        return try await PackageWriter(layout: layout, producer: producer).commit(draft)
    }

    private static func fixture(_ path: String) throws -> Data {
        try Data(contentsOf: repo.appendingPathComponent(path))
    }

    /// The fixture's top-level object with `extra` merged in.
    private static func object(_ path: String, adding extra: [String: Any]) throws -> Data {
        var o = try #require(JSONSerialization.jsonObject(with: fixture(path)) as? [String: Any])
        o.merge(extra) { $1 }
        return try JSONSerialization.data(withJSONObject: o)
    }

    private static let metadataPath = day + "00000000-0000-4000-8000-000000000001/metadata.json"
    private static let completePath = day + "00000000-0000-4000-8000-000000000001/complete.json"
    private static let commentPath = day + "00000000-0000-4000-8000-000000000004/comments/00000000-0000-4000-8000-00000000c001.json"
    private static let enrichmentPath = "fixtures/packages/enrichments/device/2026/11/07/00000000-0000-4000-8000-000000000002/enrichment.json"

    @Test func constantsAreOnePointOne() {
        #expect(FormatVersion.major == 1)
        #expect(FormatVersion.minor == 1)
    }

    @Test func writerStampsMinor() async throws {
        let pkg = try await commit()
        let metadataData = try Data(contentsOf: pkg.directoryURL.appendingPathComponent("metadata.json"))
        let markerData = try Data(contentsOf: pkg.directoryURL.appendingPathComponent("complete.json"))
        let metadata = try HippoJSON.decodeMetadata(metadataData)
        let marker = try HippoJSON.decodeMarker(markerData)
        #expect(metadata.schemaVersion == 1)
        #expect(metadata.schemaMinor == 1)
        #expect(marker.schemaVersion == 1)
        #expect(marker.schemaMinor == 1)
        #expect(String(decoding: metadataData, as: UTF8.self).contains("\"schema_minor\" : 1"))
        #expect(String(decoding: markerData, as: UTF8.self).contains("\"schema_minor\" : 1"))
    }

    @Test func commentWriterStampsMinor() async throws {
        let pkg = try await commit()
        let writer = CommentWriter(layout: layout, producer: producer, space: FakeSpace(bytes: 1 << 40))
        let comment = try writer.add(.text("x"), to: pkg, now: now, timeZone: la)
        #expect(comment.schemaMinor == 1)
        let url = pkg.directoryURL.appendingPathComponent(comment.relativePath)
        let onDisk = try HippoJSON.decodeComment(Data(contentsOf: url))
        #expect(onDisk.schemaMinor == 1)
    }

    @Test func legacyFilesDecodeWithNilMinor() throws {
        let metadata = try HippoJSON.decodeMetadata(Self.fixture(Self.metadataPath))
        let marker = try HippoJSON.decodeMarker(Self.fixture(Self.completePath))
        let comment = try HippoJSON.decodeComment(Self.fixture(Self.commentPath))
        let enrichment = try EnrichmentJSON.decode(Self.fixture(Self.enrichmentPath))
        #expect(metadata.schemaMinor == nil)
        #expect(marker.schemaMinor == nil)
        #expect(comment.schemaMinor == nil)
        #expect(enrichment.schemaMinor == nil)
        for data in [try HippoJSON.encode(metadata), try HippoJSON.encode(marker),
                     try HippoJSON.encode(comment), try EnrichmentJSON.encode(enrichment)] {
            #expect(!String(decoding: data, as: UTF8.self).contains("schema_minor"))
        }
    }

    @Test func higherMinorAndUnknownKeysDecode() throws {
        let extra: [String: Any] = ["schema_minor": 7, "future_field": ["a": 1]]
        let metadata = try HippoJSON.decodeMetadata(Self.object(Self.metadataPath, adding: extra))
        let marker = try HippoJSON.decodeMarker(Self.object(Self.completePath, adding: extra))
        let comment = try HippoJSON.decodeComment(Self.object(Self.commentPath, adding: extra))
        let enrichment = try EnrichmentJSON.decode(Self.object(Self.enrichmentPath, adding: extra))
        #expect(metadata.schemaMinor == 7)
        #expect(marker.schemaMinor == 7)
        #expect(comment.schemaMinor == 7)
        #expect(enrichment.schemaMinor == 7)
    }

    @Test func unknownMajorRejected() throws {
        let extra: [String: Any] = ["schema_version": 2, "schema_minor": 0]
        #expect(throws: FormatError.unsupportedSchemaVersion(2)) {
            try HippoJSON.decodeMetadata(Self.object(Self.metadataPath, adding: extra))
        }
        #expect(throws: FormatError.unsupportedSchemaVersion(2)) {
            try HippoJSON.decodeComment(Self.object(Self.commentPath, adding: extra))
        }
    }

    @Test func negativeOrFractionalMinorRejected() throws {
        for bad in [-1, 1.5] as [Any] {
            let extra: [String: Any] = ["schema_minor": bad]
            #expect(throws: FormatError.self) { try HippoJSON.decodeMetadata(Self.object(Self.metadataPath, adding: extra)) }
            #expect(throws: FormatError.self) { try HippoJSON.decodeMarker(Self.object(Self.completePath, adding: extra)) }
            #expect(throws: FormatError.self) { try HippoJSON.decodeComment(Self.object(Self.commentPath, adding: extra)) }
            #expect(throws: FormatError.self) { try EnrichmentJSON.decode(Self.object(Self.enrichmentPath, adding: extra)) }
        }
    }
}
