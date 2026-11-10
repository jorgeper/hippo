import Testing
import Foundation
import CryptoKit
@testable import DropboxAdapter

private func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
    digest.map { String(format: "%02x", $0) }.joined()
}

@Suite struct ContentHashTests {
    @Test func smallFileHashIsDoubleSHA256() {
        let data = Data((0..<1000).map { UInt8($0 % 251) })
        let inner = Data(SHA256.hash(data: data))
        #expect(DropboxContentHash.of(data) == hex(SHA256.hash(data: inner)))
    }

    @Test func multiBlockHashConcatenatesBlockDigests() throws {
        let size = DropboxContentHash.blockSize + 123
        let data = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let block0 = Data(SHA256.hash(data: data.prefix(DropboxContentHash.blockSize)))
        let block1 = Data(SHA256.hash(data: data.suffix(123)))
        #expect(DropboxContentHash.of(data) == hex(SHA256.hash(data: block0 + block1)))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hash-\(UUID().uuidString).bin")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try DropboxContentHash.of(url) == DropboxContentHash.of(data))
    }

    @Test func fileHashStopsWhenCancelled() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hash-\(UUID().uuidString).bin")
        try Data(count: 2 * DropboxContentHash.blockSize).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try DropboxContentHash.of(url)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func emptyFileHashIsSHA256OfNothing() throws {
        #expect(DropboxContentHash.of(Data()) == hex(SHA256.hash(data: Data())))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hash-\(UUID().uuidString).bin")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try DropboxContentHash.of(url) == DropboxContentHash.of(Data()))
    }
}
