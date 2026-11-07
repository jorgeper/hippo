import Foundation
import Testing
import CryptoKit
import SyncEngine

private struct StopAfterCheckpoint: Error {}

private final class CheckpointBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UploadCheckpoint?
    func set(_ c: UploadCheckpoint) { lock.lock(); value = c; lock.unlock() }
    func get() -> UploadCheckpoint? { lock.lock(); defer { lock.unlock() }; return value }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
}

private func makeFile(_ dir: URL, _ name: String, bytes: Int, seed: UInt8) throws -> (URL, FileIntegrity) {
    var data = Data(count: bytes)
    for i in 0..<bytes { data[i] = UInt8(truncatingIfNeeded: i &* 31 &+ Int(seed)) }
    let url = dir.appendingPathComponent(name)
    try data.write(to: url)
    let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return (url, FileIntegrity(byteCount: Int64(bytes), sha256: sha))
}

/// Reusable provider-neutral contract suite. Self-contained so another adapter's tests can copy it.
func runAdapterContract(makeAdapter: () async throws -> any StorageAdapter, scratch: URL) async throws {
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let adapter = try await makeAdapter()
    try await adapter.validateDestination()

    let dir = "captures/2026/11/07/abc"
    try await adapter.ensureContainer(relativePath: dir)
    try await adapter.ensureContainer(relativePath: dir) // idempotent

    let ignore: @Sendable (UploadCheckpoint) async throws -> Void = { _ in }

    // Exact-path write, then inspect.
    let (a, aInt) = try makeFile(scratch, "a.bin", bytes: 1000, seed: 1)
    let pathA = "\(dir)/content/a.bin"
    #expect(try await adapter.inspectFile(relativePath: pathA) == nil)
    let receipt = try await adapter.uploadFile(localURL: a, relativePath: pathA, expected: aInt,
                                               checkpoint: nil, saveCheckpoint: ignore)
    #expect(receipt.relativePath == pathA)
    #expect(receipt.byteCount == aInt.byteCount)
    let info = try #require(try await adapter.inspectFile(relativePath: pathA))
    #expect(info.byteCount == aInt.byteCount)
    #expect(info.relativePath == pathA)

    // Identical repeat is idempotent.
    let again = try await adapter.uploadFile(localURL: a, relativePath: pathA, expected: aInt,
                                             checkpoint: nil, saveCheckpoint: ignore)
    #expect(again.byteCount == aInt.byteCount)

    // Different content at the same path conflicts.
    let (b, bInt) = try makeFile(scratch, "b.bin", bytes: 1000, seed: 9)
    do {
        _ = try await adapter.uploadFile(localURL: b, relativePath: pathA, expected: bInt,
                                         checkpoint: nil, saveCheckpoint: ignore)
        Issue.record("expected conflict")
    } catch let StorageError.conflict(existing) {
        #expect(existing.byteCount == aInt.byteCount)
    }

    // Verify: evidence on match, nil on mismatch.
    #expect(try await adapter.verify(remote: info, localURL: a, expected: aInt) != nil)
    #expect(try await adapter.verify(remote: info, localURL: b, expected: bInt) == nil)

    // Resumed upload from a checkpoint yields correct bytes.
    let (big, bigInt) = try makeFile(scratch, "big.bin", bytes: 3 * 1024 * 1024 + 123, seed: 5)
    let pathBig = "\(dir)/content/big.bin"
    let box = CheckpointBox()
    do {
        _ = try await adapter.uploadFile(localURL: big, relativePath: pathBig, expected: bigInt, checkpoint: nil,
                                         saveCheckpoint: { box.set($0); throw StopAfterCheckpoint() })
    } catch is StopAfterCheckpoint {
        // Adapter checkpointed and was interrupted.
    }
    #expect(try await adapter.inspectFile(relativePath: pathBig) == nil)
    let resumedSaves = Counter()
    let resumed = try await adapter.uploadFile(localURL: big, relativePath: pathBig, expected: bigInt,
                                               checkpoint: box.get(), saveCheckpoint: { _ in resumedSaves.bump() })
    #expect(resumed.byteCount == bigInt.byteCount)
    // Progress proof: a resume must do less work than a fresh upload of the same size.
    if box.get() != nil {
        let freshSaves = Counter()
        let (big2, big2Int) = try makeFile(scratch, "big2.bin", bytes: 3 * 1024 * 1024 + 123, seed: 6)
        _ = try await adapter.uploadFile(localURL: big2, relativePath: "\(dir)/content/big2.bin", expected: big2Int,
                                         checkpoint: nil, saveCheckpoint: { _ in freshSaves.bump() })
        #expect(resumedSaves.count < freshSaves.count)
    }
    let bigInfo = try #require(try await adapter.inspectFile(relativePath: pathBig))
    #expect(bigInfo.byteCount == bigInt.byteCount)
    #expect(try await adapter.verify(remote: bigInfo, localURL: big, expected: bigInt) != nil)
}
