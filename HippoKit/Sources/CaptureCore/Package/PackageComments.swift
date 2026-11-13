import Foundation

/// Reads the append-only `comments/` directory of a package.
public enum PackageComments {
    public static let directoryName = "comments"

    public struct Listing: Sendable, Equatable {
        public var comments: [CaptureComment]
        public var pendingCount: Int
    }

    /// Every decodable json under comments/ whose audio (if any) exists and matches byte_count + sha256,
    /// sorted by addedAt then commentID. Others count as pending. A json with another schema_version
    /// or no decodable body counts as pending too (never throws).
    public static func load(directory: URL) -> Listing {
        let dir = directory.appendingPathComponent(directoryName, isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".json") }.sorted()
        var comments: [CaptureComment] = []
        var pending = 0
        for name in names {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                  let comment = try? HippoJSON.decodeComment(data),
                  name == "\(comment.commentID).json",
                  comment.captureID == directory.lastPathComponent,
                  comment.text.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? true,
                  (comment.text == nil) != (comment.audio == nil),
                  isComplete(comment, in: directory)
            else { pending += 1; continue }
            comments.append(comment)
        }
        comments.sort { ($0.addedAt, $0.commentID) < ($1.addedAt, $1.commentID) }
        return Listing(comments: comments, pendingCount: pending)
    }

    private static func isComplete(_ comment: CaptureComment, in directory: URL) -> Bool {
        guard let audio = comment.audio else { return true }
        guard isSafeAudioPath(audio.relativePath, commentID: comment.commentID),
              let digest = try? StreamingHasher.digest(of: directory.appendingPathComponent(audio.relativePath))
        else { return false }
        return digest.byteCount == audio.byteCount && digest.sha256 == audio.sha256
    }
}

extension PackageComments {
    /// `comments/<comment-id>.<ext>` with a short lowercase alphanumeric extension: nothing that can escape the directory.
    public static func isSafeAudioPath(_ path: String, commentID: String) -> Bool {
        let prefix = "\(directoryName)/\(commentID)."
        guard path.hasPrefix(prefix) else { return false }
        let ext = path.dropFirst(prefix.count)
        return (1...10).contains(ext.utf8.count)
            && ext.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7a) || ($0 >= 0x30 && $0 <= 0x39) }
    }
}
