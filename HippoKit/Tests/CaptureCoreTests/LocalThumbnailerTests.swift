import Foundation
import ImageIO
import Testing
import HippoTestSupport
@testable import CaptureCore

@Suite struct LocalThumbnailerTests {
    private func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("thumb-\(UUID().uuidString).\(ext)")
    }

    private func longestSide(_ data: Data) -> Int? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return max(w, h)
    }

    @Test func imageAndVideoProduceJPEG() async throws {
        let image = tempURL("png")
        let video = tempURL("mov")
        defer { try? FileManager.default.removeItem(at: image); try? FileManager.default.removeItem(at: video) }
        try MediaMaker.imageData(width: 400, height: 200, type: .png).write(to: image)
        try await MediaMaker.writeVideo(to: video)

        let fromImage = try #require(await LocalThumbnailer.jpeg(for: image, uti: "public.png", maxPixelSize: 100))
        #expect(Array(fromImage.prefix(2)) == [0xFF, 0xD8])
        #expect(longestSide(fromImage) == 100)
        let fromVideo = try #require(await LocalThumbnailer.jpeg(for: video, uti: "com.apple.quicktime-movie", maxPixelSize: 32))
        #expect(Array(fromVideo.prefix(2)) == [0xFF, 0xD8])
        #expect(try #require(longestSide(fromVideo)) <= 32)
    }

    @Test func unknownTypeIsNil() async throws {
        let url = tempURL("bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 7, count: 64).write(to: url)
        #expect(await LocalThumbnailer.jpeg(for: url, uti: "public.data", maxPixelSize: 100) == nil)
        #expect(await LocalThumbnailer.jpeg(for: url, uti: "not a uti", maxPixelSize: 100) == nil)
        // An image type over bytes that aren't an image also yields nil.
        #expect(await LocalThumbnailer.jpeg(for: url, uti: "public.png", maxPixelSize: 100) == nil)
    }
}
