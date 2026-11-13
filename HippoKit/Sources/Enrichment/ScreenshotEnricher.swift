import Foundation
import CaptureCore
import ImageIO

/// Guesses which image attachments are screenshots (design §5.6). Reads image properties only; pixels are
/// never decoded.
public struct ScreenshotEnricher: Enricher {
    public struct ImageFacts: Sendable, Equatable {
        public var pixelWidth: Int?
        public var pixelHeight: Int?
        public var exifUserComment: String?
        public var cameraMake: String?
        public var cameraModel: String?
        public init(pixelWidth: Int? = nil, pixelHeight: Int? = nil, exifUserComment: String? = nil,
                    cameraMake: String? = nil, cameraModel: String? = nil) {
            self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.exifUserComment = exifUserComment
            self.cameraMake = cameraMake; self.cameraModel = cameraModel
        }
    }
    /// Reads one image file's properties, or nil when unreadable. Tests substitute a fake.
    public typealias Inspector = @Sendable (URL) -> ImageFacts?

    public var kind: FacetKind { .screenshot }
    public var version: Int { 1 }
    public var usesNetwork: Bool { false }
    public var readsAttachmentBytes: Bool { true }
    public var inputs: Set<FacetKind> { [] }

    private let screenPixelSize: (width: Int, height: Int)?
    private let inspect: Inspector

    /// `screenPixelSize` is this phone's screen in pixels (portrait or landscape order does not matter).
    public init(screenPixelSize: (width: Int, height: Int)?, inspect: @escaping Inspector = ScreenshotEnricher.liveInspector) {
        self.screenPixelSize = screenPixelSize; self.inspect = inspect
    }

    public func applies(to m: CaptureMetadata) -> Bool { m.attachments.contains(where: \.isImage) }

    public static let liveInspector: Inspector = { url in
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        return ImageFacts(pixelWidth: props[kCGImagePropertyPixelWidth] as? Int,
                          pixelHeight: props[kCGImagePropertyPixelHeight] as? Int,
                          exifUserComment: exif?[kCGImagePropertyExifUserComment] as? String,
                          cameraMake: tiff?[kCGImagePropertyTIFFMake] as? String,
                          cameraModel: tiff?[kCGImagePropertyTIFFModel] as? String)
    }

    public func run(_ input: EnricherInput) async throws -> EnricherOutput {
        var items: [ScreenshotData.Item] = []
        for a in input.metadata.attachments where a.isImage {
            try Task.checkCancellation()
            guard let facts = inspect(input.packageURL.appendingPathComponent(a.relativePath)) else { continue }
            if let reason = reason(for: facts) { items.append(ScreenshotData.Item(attachmentID: a.attachmentID, reason: reason)) }
        }
        if items.isEmpty { return EnricherOutput(status: .empty, data: nil, provenance: "heuristic") }
        return EnricherOutput(status: .ok, data: try .payload(ScreenshotData(items: items)), provenance: "heuristic")
    }

    private func reason(for f: ImageFacts) -> String? {
        if f.exifUserComment?.trimmingCharacters(in: .whitespacesAndNewlines) == "Screenshot" { return "exif_user_comment" }
        guard let screen = screenPixelSize, let w = f.pixelWidth, let h = f.pixelHeight,
              Self.isBlank(f.cameraMake), Self.isBlank(f.cameraModel) else { return nil }
        let matches = (w == screen.width && h == screen.height) || (w == screen.height && h == screen.width)
        return matches ? "screen_size_match" : nil
    }

    private static func isBlank(_ s: String?) -> Bool { s?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true }
}
