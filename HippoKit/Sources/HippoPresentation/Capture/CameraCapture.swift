import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CaptureCore
import ShareIntake

/// The picker's metadata dictionary (CGImageProperties keys), passed through untouched. The dictionary
/// is immutable once the picker hands it over.
public struct PhotoMetadata: @unchecked Sendable {
    public let properties: [String: Any]
    public init(_ p: [String: Any]) { properties = p }
}

public enum CameraResult: Sendable {
    /// `orientation` is a `CGImagePropertyOrientation` raw value.
    case photo(CGImage, orientation: Int32, metadata: PhotoMetadata)
    /// The picker's temporary .mov.
    case video(URL)
}

public enum CameraCapture {
    struct StagingError: Error { let reason: String }

    /// Writes the shot into `intake/<captureID>/0.heic` (JPEG when HEIC encoding is unavailable) or moves
    /// the video to `intake/<captureID>/0.mov`, and returns the draft (method `.camera`,
    /// representationSource "camera", location as given).
    public static func stage(_ result: CameraResult, intake: IntakeDirectory, captureID: UUID,
                             startedAt: Date, timeZone: TimeZone, location: CaptureLocation?,
                             context: [MetadataObservation] = []) throws -> PreparedCapture {
        let fm = FileManager.default
        let dir = intake.directory(for: captureID)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let file: URL, uti: String, mime: String, isPhoto: Bool
        switch result {
        case .photo(let image, let orientation, let metadata):
            isPhoto = true
            let heic = dir.appendingPathComponent("0.heic")
            if write(image, to: heic, type: .heic, orientation: orientation, metadata: metadata) {
                (file, uti, mime) = (heic, UTType.heic.identifier, "image/heic")
            } else {
                try? fm.removeItem(at: heic)
                let jpg = dir.appendingPathComponent("0.jpg")
                guard write(image, to: jpg, type: .jpeg, orientation: orientation, metadata: metadata) else {
                    throw StagingError(reason: "image_write_failed")
                }
                (file, uti, mime) = (jpg, UTType.jpeg.identifier, "image/jpeg")
            }
        case .video(let source):
            isPhoto = false
            let target = dir.appendingPathComponent("0.mov")
            try? fm.removeItem(at: target)
            do { try fm.moveItem(at: source, to: target) } catch {
                try fm.copyItem(at: source, to: target)
                try? fm.removeItem(at: source)
            }
            (file, uti, mime) = (target, "com.apple.quicktime-movie", "video/quicktime")
        }

        let size = (try fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        let attachment = AttachmentSource(body: .file(file), originalFilename: nil, uti: uti, mimeType: mime,
                                          representationSource: "camera")
        let draft = CaptureDraft(captureID: captureID, startedAt: startedAt, timeZone: timeZone, method: .camera,
                                 attachments: [attachment], location: location, observations: context)
        return PreparedCapture(draft: draft, previewImageURL: isPhoto ? file : nil, totalBytes: size)
    }

    private static func write(_ image: CGImage, to url: URL, type: UTType, orientation: Int32,
                              metadata: PhotoMetadata) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        else { return false }
        var properties = metadata.properties
        properties[kCGImagePropertyOrientation as String] = orientation
        // Keep the TIFF copy in step so no reader sees two different orientations.
        var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        tiff[kCGImagePropertyTIFFOrientation as String] = orientation
        properties[kCGImagePropertyTIFFDictionary as String] = tiff
        properties[kCGImageDestinationLossyCompressionQuality as String] = 0.9
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }
}
