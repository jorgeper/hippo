import Foundation
import Testing
import CryptoKit
import SyncEngine

private struct StopAfterCheckpoint: Error {}
private struct CallerSignal: Error, Equatable { let tag: Int }

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

    // Errors thrown by saveCheckpoint end the upload and propagate unchanged, never wrapped or
    // translated, including ones that look like I/O errors.
    if adapter.capabilities.supportsResumableUpload {
        let (c, cInt) = try makeFile(scratch, "c.bin", bytes: Int(adapter.capabilities.maxSingleRequestBytes) * 2 + 1,
                                     seed: 3)
        let pathC = "\(dir)/content/c.bin"
        do {
            _ = try await adapter.uploadFile(localURL: c, relativePath: pathC, expected: cInt, checkpoint: nil,
                                             saveCheckpoint: { _ in throw CallerSignal(tag: 42) })
            Issue.record("expected the saveCheckpoint error")
        } catch let e as CallerSignal {
            #expect(e == CallerSignal(tag: 42))
        } catch {
            Issue.record("saveCheckpoint error was replaced by \(error)")
        }
        do {
            _ = try await adapter.uploadFile(localURL: c, relativePath: pathC, expected: cInt, checkpoint: nil,
                                             saveCheckpoint: { _ in throw CocoaError(.fileWriteUnknown) })
            Issue.record("expected the saveCheckpoint error")
        } catch let e as CocoaError {
            #expect(e.code == .fileWriteUnknown)
        } catch {
            Issue.record("saveCheckpoint error was replaced by \(error)")
        }
        #expect(try await adapter.inspectFile(relativePath: pathC) == nil)
    }

    try await runReplaceListDownloadContract(adapter: adapter, scratch: scratch)
}

private func runReplaceListDownloadContract(adapter: any StorageAdapter, scratch: URL) async throws {
    let ignore: @Sendable (UploadCheckpoint) async throws -> Void = { _ in }

    // Replace: second content wins under enrichments/.
    let enrichPath = "enrichments/device/2026/11/07/abc/enrichment.json"
    let (r1, r1Int) = try makeFile(scratch, "r1.bin", bytes: 300, seed: 11)
    let (r2, r2Int) = try makeFile(scratch, "r2.bin", bytes: 450, seed: 12)
    _ = try await adapter.replaceFile(localURL: r1, relativePath: enrichPath, expected: r1Int)
    let second = try await adapter.replaceFile(localURL: r2, relativePath: enrichPath, expected: r2Int)
    #expect(second.relativePath == enrichPath)
    #expect(second.byteCount == r2Int.byteCount)
    let replaced = try #require(try await adapter.inspectFile(relativePath: enrichPath))
    #expect(replaced.byteCount == r2Int.byteCount)
    #expect(try await adapter.verify(remote: replaced, localURL: r2, expected: r2Int) != nil)

    // Replace is also allowed under logs/.
    let logPath = "logs/abc/2026-11-08.jsonl"
    _ = try await adapter.replaceFile(localURL: r1, relativePath: logPath, expected: r1Int)
    _ = try await adapter.replaceFile(localURL: r2, relativePath: logPath, expected: r2Int)
    let logInfo = try #require(try await adapter.inspectFile(relativePath: logPath))
    #expect(logInfo.byteCount == r2Int.byteCount)
    #expect(try await adapter.verify(remote: logInfo, localURL: r2, expected: r2Int) != nil)

    // Replace is refused outside enrichments/ and logs/.
    do {
        _ = try await adapter.replaceFile(localURL: r1, relativePath: "captures/2026/11/07/abc/x.bin", expected: r1Int)
        Issue.record("expected replace_not_allowed")
    } catch let e as StorageError {
        #expect(e == .permanent(code: "replace_not_allowed"))
    }

    // List changes.
    let (s1, s1Int) = try makeFile(scratch, "s1.bin", bytes: 100, seed: 21)
    let (s2, s2Int) = try makeFile(scratch, "s2.bin", bytes: 110, seed: 22)
    let (s3, s3Int) = try makeFile(scratch, "s3.bin", bytes: 120, seed: 23)
    let (s1b, s1bInt) = try makeFile(scratch, "s1b.bin", bytes: 130, seed: 24)
    let p1 = "enrichments/server/2026/11/07/one/enrichment.json"
    let p2 = "enrichments/server/2026/11/07/two/enrichment.json"
    let p3 = "enrichments/server/2026/11/08/three/enrichment.json"
    _ = try await adapter.uploadFile(localURL: s1, relativePath: p1, expected: s1Int, checkpoint: nil, saveCheckpoint: ignore)
    _ = try await adapter.uploadFile(localURL: s2, relativePath: p2, expected: s2Int, checkpoint: nil, saveCheckpoint: ignore)

    let first = try await adapter.listChanges(under: "enrichments/server/", cursor: nil)
    #expect(Set(first.changes.map(\.upsertedPath)) == [p1, p2])
    #expect(first.changes.count == 2)
    #expect(!first.cursor.isEmpty)
    var cursor = first.cursor
    var page = first
    while page.hasMore {
        page = try await adapter.listChanges(under: "enrichments/server/", cursor: cursor)
        cursor = page.cursor
    }

    _ = try await adapter.replaceFile(localURL: s1b, relativePath: p1, expected: s1bInt)
    _ = try await adapter.uploadFile(localURL: s3, relativePath: p3, expected: s3Int, checkpoint: nil, saveCheckpoint: ignore)
    let delta = try await adapter.listChanges(under: "enrichments/server/", cursor: cursor)
    #expect(delta.changes.count == 2)
    #expect(Set(delta.changes.map(\.upsertedPath)) == [p1, p3])
    #expect(!delta.hasMore)

    let quiet = try await adapter.listChanges(under: "enrichments/server/", cursor: delta.cursor)
    #expect(quiet.changes.isEmpty)

    // A same-size replace with different bytes is still a change.
    let (s3b, s3bInt) = try makeFile(scratch, "s3b.bin", bytes: 120, seed: 99)
    _ = try await adapter.replaceFile(localURL: s3b, relativePath: p3, expected: s3bInt)
    let sameSize = try await adapter.listChanges(under: "enrichments/server/", cursor: quiet.cursor)
    #expect(sameSize.changes.map(\.upsertedPath) == [p3])

    do {
        _ = try await adapter.listChanges(under: "enrichments/server/", cursor: "garbage")
        Issue.record("expected cursorReset")
    } catch let e as StorageError {
        #expect(e == .cursorReset)
    }

    // Download.
    let (d, dInt) = try makeFile(scratch, "d.bin", bytes: 1000, seed: 31)
    let pathD = "enrichments/server/2026/11/07/dl/asset.bin"
    _ = try await adapter.uploadFile(localURL: d, relativePath: pathD, expected: dInt, checkpoint: nil, saveCheckpoint: ignore)
    let dest = scratch.appendingPathComponent("downloaded.bin")
    let got = try await adapter.downloadFile(relativePath: pathD, to: dest, maxBytes: 5000)
    #expect(got.byteCount == dInt.byteCount)
    #expect(got.relativePath == pathD)
    let downloaded = try Data(contentsOf: dest)
    #expect(SHA256.hash(data: downloaded).map { String(format: "%02x", $0) }.joined() == dInt.sha256)

    let small = scratch.appendingPathComponent("small.bin")
    do {
        _ = try await adapter.downloadFile(relativePath: pathD, to: small, maxBytes: 10)
        Issue.record("expected too_large")
    } catch let e as StorageError {
        #expect(e == .permanent(code: "too_large"))
    }
    #expect(!FileManager.default.fileExists(atPath: small.path))

    let missing = scratch.appendingPathComponent("missing.bin")
    do {
        _ = try await adapter.downloadFile(relativePath: "enrichments/server/nope.bin", to: missing, maxBytes: 5000)
        Issue.record("expected not_found")
    } catch let e as StorageError {
        #expect(e == .permanent(code: "not_found"))
    }
    #expect(!FileManager.default.fileExists(atPath: missing.path))
}

private extension RemoteChange {
    var upsertedPath: String {
        switch self {
        case .upserted(let info): info.relativePath
        case .deleted(let path): "deleted:\(path)"
        }
    }
}
