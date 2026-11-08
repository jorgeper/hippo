import Foundation
import Synchronization
import Testing
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import CaptureCore
@testable import Enrichment

/// A PNG of `text` in black on white, drawn with CoreGraphics and CoreText only.
private func renderPNG(width: Int, height: Int, text: String?, fontSize: CGFloat = 96) throws -> Data {
    let space = CGColorSpaceCreateDeviceRGB()
    let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    if let text {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attrs: [CFString: Any] = [kCTFontAttributeName: font,
                                      kCTForegroundColorAttributeName: CGColor(red: 0, green: 0, blue: 0, alpha: 1)]
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary))
        ctx.textPosition = CGPoint(x: 40, y: CGFloat(height) / 2 - fontSize / 3)
        CTLineDraw(line, ctx)
    }
    let image = try #require(ctx.makeImage())
    let data = NSMutableData()
    let dest = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(dest, image, nil)
    #expect(CGImageDestinationFinalize(dest))
    return data as Data
}

private struct Package {
    let dir: URL
    init(_ files: [String: Data]) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("hippo-ocr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("content"), withIntermediateDirectories: true)
        for (name, bytes) in files { try bytes.write(to: dir.appendingPathComponent("content/\(name)")) }
    }
    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

private func png(_ id: String) -> CaptureCore.Attachment {
    CaptureCore.Attachment(attachmentID: id, relativePath: "content/\(id).png", uti: "public.png", byteCount: 1, sha256: "x",
               representationSource: "item_provider_file")
}

@Suite struct TextRecognitionEnricherTests {
    @Test func ocrReadsRenderedText() async throws {
        let pkg = try Package(["a1.png": try renderPNG(width: 600, height: 200, text: "HIPPO 42")])
        defer { pkg.cleanup() }
        let m = fixtureMetadata(attachments: [png("a1")])
        let out = try await TextRecognitionEnricher().run(fixtureInput(m, packageURL: pkg.dir))
        #expect(out.status == .ok)
        #expect(out.provenance == "vision_accurate")
        let data = try JSONDecoder().decode(TextRecognitionData.self, from: JSONEncoder().encode(try #require(out.data)))
        #expect(data.items.count == 1)
        let item = try #require(data.items.first)
        #expect(item.attachmentID == "a1")
        #expect(item.text.contains("HIPPO"))
        #expect(item.text.contains("42"))
    }

    @Test func ocrSkipsTinyAndTextless() async throws {
        // a1 is a readable strip (large text) that is only 28 px tall: only the size gate keeps it out.
        let pkg = try Package(["a1.png": try renderPNG(width: 600, height: 28, text: "HIPPO 42", fontSize: 24),
                               "a2.png": try renderPNG(width: 300, height: 300, text: nil)])
        defer { pkg.cleanup() }
        let m = fixtureMetadata(attachments: [png("a1"), png("a2")])
        let out = try await TextRecognitionEnricher().run(fixtureInput(m, packageURL: pkg.dir))
        #expect(out.status == .empty)
        #expect(out.data == nil)
    }

    @Test func appliesToImagesOnly() {
        let e = TextRecognitionEnricher()
        #expect(e.applies(to: fixtureMetadata(attachments: [png("a1")])))
        let txt = CaptureCore.Attachment(attachmentID: "t", relativePath: "content/t.txt", uti: "public.plain-text", byteCount: 1,
                             sha256: "x", representationSource: "typed_note")
        #expect(!e.applies(to: fixtureMetadata(attachments: [txt])))
        #expect(e.kind == .textRecognition && e.version == 1 && !e.usesNetwork)
    }

    @Test func oneFailingImageKeepsTheOthers() async throws {
        let pkg = try Package(["a1.png": try renderPNG(width: 600, height: 200, text: "HIPPO 42"),
                               "a2.png": try renderPNG(width: 600, height: 200, text: "HIPPO 42")])
        defer { pkg.cleanup() }
        struct Boom: Error {}
        let calls = CallCounter()
        let flaky = TextRecognitionEnricher(recognize: { _, _ in
            if calls.next() == 1 { throw Boom() }
            return (["kept text"], ["en-US"])
        })
        let m = fixtureMetadata(attachments: [png("a1"), png("a2")])
        let out = try await flaky.run(fixtureInput(m, packageURL: pkg.dir))
        #expect(out.status == .ok)
        let data = try JSONDecoder().decode(TextRecognitionData.self, from: JSONEncoder().encode(try #require(out.data)))
        #expect(data.items.map(\.attachmentID) == ["a2"])

        let allFail = TextRecognitionEnricher(recognize: { _, _ in throw Boom() })
        await #expect(throws: EnrichmentError.transient(code: "vision_failed")) {
            _ = try await allFail.run(fixtureInput(m, packageURL: pkg.dir))
        }
    }

    @Test func missingFileDoesNotBlockReadableImage() async throws {
        let pkg = try Package(["a2.png": try renderPNG(width: 600, height: 200, text: "HIPPO 42")])
        defer { pkg.cleanup() }
        let m = fixtureMetadata(attachments: [png("a1"), png("a2")])  // a1's file does not exist
        let out = try await TextRecognitionEnricher().run(fixtureInput(m, packageURL: pkg.dir))
        let data = try JSONDecoder().decode(TextRecognitionData.self, from: JSONEncoder().encode(try #require(out.data)))
        #expect(data.items.map(\.attachmentID) == ["a2"])
        #expect(data.items[0].text.contains("HIPPO"))
    }

    @Test func largeImageIsDownsampledAndStillRead() async throws {
        let pkg = try Package(["a1.png": try renderPNG(width: 6000, height: 1200, text: "HIPPO 42", fontSize: 600)])
        defer { pkg.cleanup() }
        let out = try await TextRecognitionEnricher().run(fixtureInput(fixtureMetadata(attachments: [png("a1")]), packageURL: pkg.dir))
        #expect(out.status == .ok)
        let data = try JSONDecoder().decode(TextRecognitionData.self, from: JSONEncoder().encode(try #require(out.data)))
        #expect(data.items.first?.text.contains("HIPPO") == true)
    }
}

private final class CallCounter: Sendable {
    private let m = Mutex(0)
    func next() -> Int { m.withLock { $0 += 1; return $0 } }
}
