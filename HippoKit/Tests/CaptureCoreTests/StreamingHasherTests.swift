import Testing
import Foundation
import CryptoKit
@testable import CaptureCore

@Suite struct StreamingHasherTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("hasher-\(UUID().uuidString)")
    }

    @Test func emptyFileHash() throws {
        let url = tempURL()
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let d = try StreamingHasher.digest(of: url)
        #expect(d.byteCount == 0)
        #expect(d.sha256 == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func abcHash() throws {
        let url = tempURL()
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let d = try StreamingHasher.digest(of: url)
        #expect(d.byteCount == 3)
        #expect(d.sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func missingFileThrows() {
        #expect(throws: (any Error).self) { try StreamingHasher.digest(of: tempURL()) }
    }

    @Test func largeSparseFileMatchesOneShotAndStaysSmall() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let size: UInt64 = 268_435_456
        let writer = try FileHandle(forWritingTo: url)
        try writer.truncate(atOffset: size)
        for offset in [UInt64(0), 1_000_003, size / 2, size - 1] {
            try writer.seek(toOffset: offset)
            try writer.write(contentsOf: Data("x".utf8))
        }
        try writer.close()

        // Reference: 8 MiB chunks.
        var reference = SHA256()
        let reader = try FileHandle(forReadingFrom: url)
        while let chunk = try reader.read(upToCount: 8 << 20), !chunk.isEmpty { reference.update(data: chunk) }
        try reader.close()
        let expected = reference.finalize().map { String(format: "%02x", $0) }.joined()

        let before = currentPhysFootprint()
        let d = try StreamingHasher.digest(of: url)
        let after = currentPhysFootprint()

        #expect(d.byteCount == 268_435_456)
        #expect(d.sha256 == expected)
        let growth = after > before ? after - before : 0
        #expect(growth < 64 << 20, "footprint grew \(growth) bytes")
    }
}
