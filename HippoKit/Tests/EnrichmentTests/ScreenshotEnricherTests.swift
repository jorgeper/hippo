import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CaptureCore
@testable import Enrichment

private func image(_ id: String) -> CaptureCore.Attachment {
    CaptureCore.Attachment(attachmentID: id, relativePath: "content/\(id).png", uti: "public.png", byteCount: 1, sha256: "x",
                           representationSource: "item_provider_file")
}

private func run(_ attachments: [CaptureCore.Attachment] = [image("A")], screen: (width: Int, height: Int)? = (1206, 2622),
                 inspect: @escaping ScreenshotEnricher.Inspector) async throws -> EnricherOutput {
    try await ScreenshotEnricher(screenPixelSize: screen, inspect: inspect)
        .run(fixtureInput(fixtureMetadata(attachments: attachments), packageURL: URL(fileURLWithPath: "/nonexistent")))
}

private func reasons(_ out: EnricherOutput) throws -> [String] {
    try JSONDecoder().decode(ScreenshotData.self, from: JSONEncoder().encode(try #require(out.data))).items.map(\.reason)
}

@Suite struct ScreenshotEnricherTests {
    @Test func descriptor() {
        let e = ScreenshotEnricher(screenPixelSize: nil, inspect: { _ in nil })
        #expect(e.kind == .screenshot)
        #expect(e.version == 1)
        #expect(!e.usesNetwork)
        #expect(e.readsAttachmentBytes)
        #expect(e.applies(to: fixtureMetadata(attachments: [image("a")])))
        #expect(!e.applies(to: fixtureMetadata(attachments: [])))
    }

    @Test func exifCommentMatches() async throws {
        let out = try await run { _ in .init(exifUserComment: "Screenshot") }
        #expect(out.status == .ok)
        #expect(out.provenance == "heuristic")
        #expect(try reasons(out) == ["exif_user_comment"])
    }

    @Test func screenSizeMatchesEitherOrientation() async throws {
        for (w, h) in [(1206, 2622), (2622, 1206)] {
            let out = try await run { _ in .init(pixelWidth: w, pixelHeight: h) }
            #expect(try reasons(out) == ["screen_size_match"])
        }
        let withMake = try await run { _ in .init(pixelWidth: 1206, pixelHeight: 2622, cameraMake: "Apple") }
        #expect(withMake.status == .empty)
        let withModel = try await run { _ in .init(pixelWidth: 1206, pixelHeight: 2622, cameraModel: "iPhone") }
        #expect(withModel.status == .empty)
        let noScreen = try await run(screen: nil) { _ in .init(pixelWidth: 1206, pixelHeight: 2622) }
        #expect(noScreen.status == .empty)
    }

    @Test func blankMakeAndModelCountAsAbsent() async throws {
        let out = try await run { _ in .init(pixelWidth: 1206, pixelHeight: 2622, cameraMake: "", cameraModel: "  \n") }
        #expect(try reasons(out) == ["screen_size_match"])
    }

    @Test func exifWins() async throws {
        let out = try await run { _ in .init(pixelWidth: 1206, pixelHeight: 2622, exifUserComment: "Screenshot") }
        #expect(try reasons(out) == ["exif_user_comment"])
    }

    @Test func noMatchIsEmpty() async throws {
        let out = try await run { _ in .init(pixelWidth: 4032, pixelHeight: 3024, exifUserComment: "Holiday") }
        #expect(out.status == .empty)
        #expect(out.data == nil)
        #expect(out.provenance == "heuristic")
    }

    @Test func nilInspectionIsSkippedNotFailed() async throws {
        let out = try await run([image("A"), image("B")]) { url in
            url.lastPathComponent == "A.png" ? nil : .init(exifUserComment: "Screenshot")
        }
        #expect(out.status == .ok)
        let items = try JSONDecoder().decode(ScreenshotData.self, from: JSONEncoder().encode(try #require(out.data))).items
        #expect(items.map(\.attachmentID) == ["B"])
        let none = try await run { _ in nil }
        #expect(none.status == .empty)
    }

    @Test func liveInspectorReadsSizeWithoutCameraMake() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hippo-shot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ctx = try #require(CGContext(data: nil, width: 30, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let url = dir.appendingPathComponent("s.png")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try #require(ctx.makeImage()), nil)
        #expect(CGImageDestinationFinalize(dest))

        let facts = try #require(ScreenshotEnricher.liveInspector(url))
        #expect(facts.pixelWidth == 30)
        #expect(facts.pixelHeight == 20)
        #expect(facts.cameraMake == nil)
        #expect(ScreenshotEnricher.liveInspector(dir.appendingPathComponent("missing.png")) == nil)
    }

    @Test func liveInspectorReadsCommentAndMake() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hippo-shot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ctx = try #require(CGContext(data: nil, width: 30, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(ctx.makeImage())
        func write(_ name: String, _ props: [CFString: Any]) throws -> URL {
            let url = dir.appendingPathComponent(name)
            let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(dest, image, props as CFDictionary)
            #expect(CGImageDestinationFinalize(dest))
            return url
        }
        let commented = try write("c.jpg", [kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Screenshot"]])
        let made = try write("m.jpg", [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple",
                                                                        kCGImagePropertyTIFFModel: "iPhone"]])
        #expect(try #require(ScreenshotEnricher.liveInspector(commented)).exifUserComment == "Screenshot")
        let facts = try #require(ScreenshotEnricher.liveInspector(made))
        #expect(facts.cameraMake == "Apple")
        #expect(facts.cameraModel == "iPhone")
    }
}
