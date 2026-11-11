import Foundation
import Testing
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers
import CaptureCore
@testable import Enrichment

private func image(_ id: String) -> CaptureCore.Attachment {
    CaptureCore.Attachment(attachmentID: id, relativePath: "content/\(id).png", uti: "public.png", byteCount: 1, sha256: "x",
                           representationSource: "item_provider_file")
}

private func audio(_ id: String) -> CaptureCore.Attachment {
    CaptureCore.Attachment(attachmentID: id, relativePath: "content/\(id).m4a", uti: "com.apple.m4a-audio", byteCount: 1,
                           sha256: "x", representationSource: "item_provider_file")
}

private func decode(_ out: EnricherOutput) throws -> BarcodesData {
    try JSONDecoder().decode(BarcodesData.self, from: JSONEncoder().encode(try #require(out.data)))
}

private func run(_ attachments: [CaptureCore.Attachment], packageURL: URL = URL(fileURLWithPath: "/nonexistent"),
                 detect: @escaping BarcodeEnricher.Detector) async throws -> EnricherOutput {
    try await BarcodeEnricher(detect: detect).run(fixtureInput(fixtureMetadata(attachments: attachments), packageURL: packageURL))
}

private struct Boom: Error {}

@Suite struct BarcodeEnricherTests {
    @Test func descriptor() {
        let e = BarcodeEnricher(detect: { _ in [] })
        #expect(e.kind == .barcodes)
        #expect(e.version == 1)
        #expect(!e.usesNetwork)
        #expect(e.inputs.isEmpty)
        #expect(e.readsAttachmentBytes)
        #expect(!e.readsCommentAudio)
        #expect(e.applies(to: fixtureMetadata(attachments: [image("a")])))
        #expect(!e.applies(to: fixtureMetadata(attachments: [audio("a")])))
    }

    @Test func qrUrlRecorded() async throws {
        let out = try await run([image("A")]) { _ in [.init(symbology: "qr", payload: "https://example.com/a")] }
        #expect(out.status == .ok)
        #expect(out.provenance == "vision")
        #expect(try decode(out).items == [.init(attachmentID: "A", symbology: "qr", payload: "https://example.com/a",
                                                url: "https://example.com/a")])
        let json = try JSONEncoder().encode(try #require(out.data))
        #expect(String(decoding: json, as: UTF8.self).contains("\"attachment_id\""))
    }

    @Test func nonUrlPayloadHasNoUrl() async throws {
        let out = try await run([image("A")]) { _ in
            [.init(symbology: "ean13", payload: "4006381333931"), .init(symbology: "qr", payload: "ftp://x"),
             .init(symbology: "qr", payload: "HTTPS://Example.com")]
        }
        let items = try decode(out).items
        #expect(items.count == 3)
        #expect(items[0].url == nil)
        #expect(items[1].url == nil)
        #expect(items[2].url == "HTTPS://Example.com")
        let json = String(decoding: try JSONEncoder().encode(try #require(out.data)), as: UTF8.self)
        #expect(json.components(separatedBy: "\"url\"").count == 2)
    }

    @Test func nonUrlPayloadsHaveNoUrl() async throws {
        let payloads = ["", "example.com", "ftp://x", "https://example.com/a b", "https://example.com/a\nb", "http:", "https://"]
        let out = try await run([image("A")]) { _ in payloads.map { .init(symbology: "qr", payload: $0) } }
        let items = try decode(out).items
        #expect(items.map(\.payload) == payloads)
        #expect(items.allSatisfy { $0.url == nil })
    }

    @Test func truncatedPayloadHasNoUrl() async throws {
        let prefix = "https://example.com/"
        let tooLong = prefix + String(repeating: "x", count: 2048)
        let exact = prefix + String(repeating: "y", count: 2048 - prefix.count)
        let out = try await run([image("A")]) { _ in
            [.init(symbology: "qr", payload: tooLong), .init(symbology: "qr", payload: exact)]
        }
        let items = try decode(out).items
        #expect(items[0].payload.count == 2048)
        #expect(items[0].url == nil)
        #expect(items[1].payload == exact)
        #expect(items[1].url == exact)
    }

    @Test func payloadCapCountsUnicodeScalars() async throws {
        let combining = "https://example.com/" + String(repeating: "x\u{301}", count: 1100)   // 1,120 Characters, 2,220 scalars
        #expect(combining.count < 2048 && combining.unicodeScalars.count > 2048)
        let out = try await run([image("A")]) { _ in [.init(symbology: "qr", payload: combining)] }
        let item = try decode(out).items[0]
        #expect(item.payload.unicodeScalars.count == 2048)
        #expect(item.url == nil)
    }

    @Test func capsApplied() async throws {
        let long = String(repeating: "x", count: 5000)
        var out = try await run([image("A")]) { _ in [.init(symbology: "qr", payload: long)] }
        #expect(try decode(out).items[0].payload.count == 2048)

        out = try await run([image("A")]) { _ in (0..<30).map { .init(symbology: "qr", payload: "p\($0)") } }
        #expect(try decode(out).items.map(\.payload) == (0..<20).map { "p\($0)" })

        out = try await run([image("A"), image("B")]) { _ in (0..<20).map { .init(symbology: "qr", payload: "p\($0)") } }
        #expect(try decode(out).items.count == 40)
    }

    @Test func noBarcodesIsEmpty() async throws {
        let out = try await run([image("A")]) { _ in [] }
        #expect(out.status == .empty)
        #expect(out.data == nil)
        #expect(out.provenance == "vision")
    }

    @Test func nonImageAttachmentsSkipped() async throws {
        let seen = Seen()
        let out = try await run([audio("S"), image("A")]) { url in
            seen.add(url.lastPathComponent)
            return [.init(symbology: "qr", payload: "p")]
        }
        #expect(seen.values == ["A.png"])
        #expect(try decode(out).items.map(\.attachmentID) == ["A"])
    }

    @Test func oneThrowingImageDoesNotBlockTheOther() async throws {
        let out = try await run([image("A"), image("B")]) { url in
            if url.lastPathComponent == "A.png" { throw Boom() }
            return [.init(symbology: "qr", payload: "p")]
        }
        #expect(out.status == .ok)
        #expect(try decode(out).items.map(\.attachmentID) == ["B"])
    }

    @Test func allThrowingIsTransient() async throws {
        await #expect(throws: EnrichmentError.transient(code: "vision_failed")) {
            _ = try await run([image("A"), image("B")]) { _ in throw Boom() }
        }
    }

    @Test func liveDetectorReadsGeneratedQR() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hippo-qr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data("https://example.com/hippo".utf8)
        let ci = try #require(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let cg = try #require(CIContext().createCGImage(ci, from: ci.extent))
        let url = dir.appendingPathComponent("qr.png")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg, nil)
        #expect(CGImageDestinationFinalize(dest))

        let found = try await BarcodeEnricher.liveDetector(url)
        #expect(found == [.init(symbology: "qr", payload: "https://example.com/hippo")])
    }
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return items }
}
