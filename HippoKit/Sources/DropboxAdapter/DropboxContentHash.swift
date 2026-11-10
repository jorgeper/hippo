import Foundation
import CryptoKit

/// Dropbox's `content_hash`: SHA-256 of each 4 MiB block, then SHA-256 of the concatenated
/// block digests, as lowercase hex. An empty file has zero blocks, so its hash is SHA-256 of nothing.
public enum DropboxContentHash {
    public static let blockSize = 4 * 1024 * 1024

    /// Streams the file one block at a time; never holds more than one block in memory. Throws
    /// `CancellationError` between blocks once the calling task is cancelled.
    public static func of(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var overall = SHA256()
        while true {
            try Task.checkCancellation()
            let block: Data? = try autoreleasepool { try handle.read(upToCount: blockSize) }
            guard let block, !block.isEmpty else { break }
            overall.update(data: Data(SHA256.hash(data: block)))
        }
        return hex(overall.finalize())
    }

    public static func of(_ data: Data) -> String {
        var overall = SHA256()
        var start = data.startIndex
        while start < data.endIndex {
            let end = data.index(start, offsetBy: blockSize, limitedBy: data.endIndex) ?? data.endIndex
            overall.update(data: Data(SHA256.hash(data: data[start..<end])))
            start = end
        }
        return hex(overall.finalize())
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
