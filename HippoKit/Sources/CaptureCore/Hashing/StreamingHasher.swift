import Foundation
import CryptoKit

public struct FileDigest: Sendable, Equatable {
    public let byteCount: Int64
    public let sha256: String   // lowercase hex

    public init(byteCount: Int64, sha256: String) {
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public enum StreamingHasher {
    /// Hashes the file at `url` in `chunkSize` pieces, never holding more than one chunk in memory.
    public static func digest(of url: URL, chunkSize: Int = 1 << 20) throws -> FileDigest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            let chunk: Data? = try autoreleasepool { try handle.read(upToCount: chunkSize) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            total += Int64(chunk.count)
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return FileDigest(byteCount: total, sha256: hex)
    }
}
