import Foundation
import CaptureCore
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Recognizes text in image attachments with Vision (design §5.3).
public struct TextRecognitionEnricher: Enricher {
    static let minSide = 32
    static let maxSide = 4096

    public var kind: FacetKind { .textRecognition }
    public var version: Int { 1 }
    public var usesNetwork: Bool { false }
    public var inputs: Set<FacetKind> { [] }

    public init() {}

    public func applies(to m: CaptureMetadata) -> Bool { m.attachments.contains(where: Self.isImage) }

    private static func isImage(_ a: Attachment) -> Bool { UTType(a.uti)?.conforms(to: .image) ?? false }

    public func run(_ input: EnricherInput) async throws -> EnricherOutput {
        var items: [CaptureCore.RecognizedText] = []
        for a in input.metadata.attachments where Self.isImage(a) {
            try Task.checkCancellation()
            let url = input.packageURL.appendingPathComponent(a.relativePath)
            guard let (image, orientation) = Self.loadImage(url) else { continue }
            var request = RecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            let observations: [RecognizedTextObservation]
            do { observations = try await request.perform(on: image, orientation: orientation) }
            catch is CancellationError { throw CancellationError() }
            catch { throw EnrichmentError.transient(code: "vision_failed") }
            let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !lines.isEmpty else { continue }
            var languages: [String] = []
            for o in observations {
                for l in o.recognitionLanguages where !languages.contains(l.maximalIdentifier) {
                    languages.append(l.maximalIdentifier)
                }
            }
            items.append(CaptureCore.RecognizedText(attachmentID: a.attachmentID, text: lines.joined(separator: "\n"),
                                                    languages: languages))
        }
        if items.isEmpty { return EnricherOutput(status: .empty, data: nil, provenance: "vision_accurate") }
        return EnricherOutput(status: .ok, data: try .payload(TextRecognitionData(items: items)),
                              provenance: "vision_accurate")
    }

    /// The image downsampled to at most `maxSide`, or nil when unreadable or under `minSide` on a side.
    private static func loadImage(_ url: URL) -> (CGImage, CGImagePropertyOrientation)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              min(w, h) >= minSide else { return nil }
        if max(w, h) > maxSide {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxSide,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return (image, .up)
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let raw = (props[kCGImagePropertyOrientation] as? UInt32) ?? 1
        return (image, CGImagePropertyOrientation(rawValue: raw) ?? .up)
    }
}
