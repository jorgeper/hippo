import Foundation
import ImageIO
import AVFoundation
import UniformTypeIdentifiers

/// Makes small JPEG thumbnails of local image and video files. Never throws, never logs, and returns nil
/// for anything it can't handle.
public enum LocalThumbnailer {
    private static let videoTimeout: Duration = .seconds(2)

    public static func jpeg(for url: URL, uti: String, maxPixelSize: Int) async -> Data? {
        guard maxPixelSize > 0, let type = UTType(uti) else { return nil }
        if type.conforms(to: .image) {
            return imageJPEG(url, maxPixelSize: maxPixelSize)
        } else if type.conforms(to: .movie) || type.conforms(to: .video) {
            return await videoJPEG(url, maxPixelSize: maxPixelSize)
        }
        return nil
    }

    // MARK: Images

    private static func imageJPEG(_ url: URL, maxPixelSize: Int) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixelSize, max(w, h)),   // never upscale
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return encode(image)
    }

    private static func encode(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    // MARK: Video

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func fire(_ body: () -> Void) {
            lock.lock(); let first = !fired; fired = true; lock.unlock()
            if first { body() }
        }
    }

    /// The frame at 0 s, or nil when it can't be read within the deadline. Returns at the deadline even if
    /// the generator ignores cancellation.
    private static func videoJPEG(_ url: URL, maxPixelSize: Int) async -> Data? {
        let once = Once()
        return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            let loader = Task {
                let data = await frameJPEG(url, maxPixelSize: maxPixelSize)
                once.fire { cont.resume(returning: data) }
            }
            Task {
                try? await Task.sleep(for: videoTimeout)
                loader.cancel()
                once.fire { cont.resume(returning: nil) }
            }
        }
    }

    private static func frameJPEG(_ url: URL, maxPixelSize: Int) async -> Data? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        guard let result = try? await generator.image(at: .zero) else { return nil }
        return encode(result.image)
    }
}
