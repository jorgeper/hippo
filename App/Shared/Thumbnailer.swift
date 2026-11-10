import UIKit
import QuickLookThumbnailing

/// Generates and caches thumbnails for attachment files. Keyed by the package's relative directory plus
/// the attachment's package-relative path, so equal names in different captures never collide.
actor Thumbnailer {
    private let cache = NSCache<NSString, UIImage>()
    private var failed = Set<String>()
    private let packageURL: @Sendable (String) -> URL
    /// Where the kept thumbnail of a trimmed attachment lives, by attachment ID.
    private let keptThumbnailURL: @Sendable (String) -> URL

    init(layoutURL: @escaping @Sendable (String) -> URL, thumbnailURL: @escaping @Sendable (String) -> URL) {
        packageURL = layoutURL
        keptThumbnailURL = thumbnailURL
        cache.countLimit = 300
    }

    /// Nil when the file can't be thumbnailed; the caller shows the type's symbol instead.
    func thumbnail(relativeDirectory: String, path: String, scale: CGFloat) async -> UIImage? {
        let key = "\(relativeDirectory)/\(path)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        if failed.contains(key as String) { return nil }
        let url = packageURL(relativeDirectory).appendingPathComponent(path)
        // A trimmed attachment's file is gone: use the thumbnail kept when it was trimmed (the file's name
        // stem is the attachment ID). Neither outcome is cached as a failure: a restore brings the file back.
        guard FileManager.default.fileExists(atPath: url.path) else {
            let kept = keptThumbnailURL(url.deletingPathExtension().lastPathComponent)
            guard let image = UIImage(contentsOfFile: kept.path) else { return nil }
            cache.setObject(image, forKey: key)
            return image
        }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 60, height: 60), scale: scale,
                                                   representationTypes: .thumbnail)
        let representation: QLThumbnailRepresentation
        do {
            representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        } catch {
            // A cancelled task (row scrolled away) is not a definitive failure.
            if !Task.isCancelled && !(error is CancellationError) { recordFailure(key) }
            return nil
        }
        guard representation.type == .thumbnail else { recordFailure(key); return nil }
        let image = representation.uiImage
        cache.setObject(image, forKey: key)
        return image
    }

    private func recordFailure(_ key: NSString) {
        if failed.count >= 500 { failed.removeAll() }
        failed.insert(key as String)
    }
}
