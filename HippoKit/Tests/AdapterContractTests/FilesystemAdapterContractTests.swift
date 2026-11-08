import Foundation
import Testing
import CryptoKit
import SyncEngine
import FilesystemAdapter

private func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("hippo-fs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func write(_ dir: URL, _ name: String, bytes: Int) throws -> (URL, FileIntegrity, Data) {
    var data = Data(count: bytes)
    for i in 0..<bytes { data[i] = UInt8(truncatingIfNeeded: i &* 7 &+ 3) }
    let url = dir.appendingPathComponent(name)
    try data.write(to: url)
    let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return (url, FileIntegrity(byteCount: Int64(bytes), sha256: sha), data)
}

private final class Offsets: @unchecked Sendable {
    private let lock = NSLock()
    private var v: [Int64] = []
    func add(_ cp: UploadCheckpoint) {
        let o = (try? JSONSerialization.jsonObject(with: cp.opaque) as? [String: Any])?["offset"] as? Int ?? -1
        lock.lock(); v.append(Int64(o)); lock.unlock()
    }
    var all: [Int64] { lock.lock(); defer { lock.unlock() }; return v }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var v: UploadCheckpoint?
    func set(_ c: UploadCheckpoint) { lock.lock(); v = c; lock.unlock() }
    func get() -> UploadCheckpoint? { lock.lock(); defer { lock.unlock() }; return v }
}

@Suite struct FilesystemAdapterContractTests {
    @Test func filesystemAdapterPassesContract() async throws {
        let root = try tempDir(), scratch = try tempDir()
        try await runAdapterContract(makeAdapter: { FilesystemAdapter(root: root) }, scratch: scratch)
    }

    @Test func deletedFilesAreReported() async throws {
        let root = try tempDir(), scratch = try tempDir()
        let adapter = FilesystemAdapter(root: root)
        let (url, integrity, _) = try write(scratch, "g.bin", bytes: 64)
        let path = "enrichments/server/2026/11/07/gone/enrichment.json"
        _ = try await adapter.uploadFile(localURL: url, relativePath: path, expected: integrity,
                                         checkpoint: nil, saveCheckpoint: { _ in })
        let first = try await adapter.listChanges(under: "enrichments/server/", cursor: nil)
        #expect(first.changes.count == 1)
        try FileManager.default.removeItem(at: root.appendingPathComponent(path))
        let next = try await adapter.listChanges(under: "enrichments/server/", cursor: first.cursor)
        #expect(next.changes == [.deleted(relativePath: path)])
        let quiet = try await adapter.listChanges(under: "enrichments/server/", cursor: next.cursor)
        #expect(quiet.changes.isEmpty)
    }

    @Test func consecutiveListsLeaveOneSnapshot() async throws {
        let root = try tempDir(), scratch = try tempDir()
        let adapter = FilesystemAdapter(root: root)
        let (url, integrity, _) = try write(scratch, "p.bin", bytes: 32)
        _ = try await adapter.uploadFile(localURL: url, relativePath: "enrichments/server/p.bin", expected: integrity,
                                         checkpoint: nil, saveCheckpoint: { _ in })
        let first = try await adapter.listChanges(under: "enrichments/server/", cursor: nil)
        let second = try await adapter.listChanges(under: "enrichments/server/", cursor: first.cursor)
        _ = try await adapter.listChanges(under: "enrichments/server/", cursor: second.cursor)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".hippo-cursors").path)
        #expect(files.count == 1)
        await #expect(throws: StorageError.cursorReset) {
            _ = try await adapter.listChanges(under: "enrichments/server/", cursor: first.cursor)
        }
    }

    @Test func faultWriteButThrowLeavesFileForInspection() async throws {
        let root = try tempDir(), scratch = try tempDir()
        let faults = FaultPlan()
        let adapter = FilesystemAdapter(root: root, faults: faults)
        let (url, integrity, _) = try write(scratch, "x.png", bytes: 5000)
        let path = "content/x.png"
        faults.writeButThrow(path, .transient(code: "lost_response"))
        await #expect(throws: StorageError.transient(code: "lost_response")) {
            _ = try await adapter.uploadFile(localURL: url, relativePath: path, expected: integrity,
                                             checkpoint: nil, saveCheckpoint: { _ in })
        }
        let info = try #require(try await adapter.inspectFile(relativePath: path))
        #expect(info.byteCount == 5000)
        // Fault is consumed; a retry is an idempotent success.
        let receipt = try await adapter.uploadFile(localURL: url, relativePath: path, expected: integrity,
                                                   checkpoint: nil, saveCheckpoint: { _ in })
        #expect(receipt.evidence.value == integrity.sha256)
        #expect(faults.operations == ["upload content/x.png", "inspect content/x.png", "upload content/x.png"])
    }

    @Test func failBeforeWriteWritesNothingAndFiresOnce() async throws {
        let root = try tempDir(), scratch = try tempDir()
        let faults = FaultPlan()
        let adapter = FilesystemAdapter(root: root, faults: faults)
        let (url, integrity, _) = try write(scratch, "x.bin", bytes: 10)
        faults.failBeforeWrite("x.bin", .offline)
        await #expect(throws: StorageError.offline) {
            _ = try await adapter.uploadFile(localURL: url, relativePath: "x.bin", expected: integrity,
                                             checkpoint: nil, saveCheckpoint: { _ in })
        }
        #expect(try await adapter.inspectFile(relativePath: "x.bin") == nil)
        _ = try await adapter.uploadFile(localURL: url, relativePath: "x.bin", expected: integrity,
                                         checkpoint: nil, saveCheckpoint: { _ in })
    }

    @Test func resumeFromCheckpointProducesCorrectBytes() async throws {
        let root = try tempDir(), scratch = try tempDir()
        let faults = FaultPlan()
        let adapter = FilesystemAdapter(root: root, faults: faults)
        let size = 5 * 1024 * 1024
        let (url, integrity, data) = try write(scratch, "big.bin", bytes: size)
        let path = "captures/big.bin"
        let box = Box()
        faults.failAfterBytes(path, 2 * 1024 * 1024, .transient(code: "dropped"))
        await #expect(throws: StorageError.transient(code: "dropped")) {
            _ = try await adapter.uploadFile(localURL: url, relativePath: path, expected: integrity,
                                             checkpoint: nil, saveCheckpoint: { box.set($0) })
        }
        #expect(try await adapter.inspectFile(relativePath: path) == nil)
        let cp = try #require(box.get())
        let offsets = Offsets()
        let receipt = try await adapter.uploadFile(localURL: url, relativePath: path, expected: integrity,
                                                   checkpoint: cp, saveCheckpoint: { box.set($0); offsets.add($0) })
        #expect(receipt.byteCount == Int64(size))
        // Resume continued from the 2 MiB offset: first chunk saved is 3 MiB, not 1 MiB.
        #expect(offsets.all.first == Int64(3 * 1024 * 1024))
        let stored = try Data(contentsOf: root.appendingPathComponent(path))
        #expect(stored == data)
        // Resume continued from 2 MiB: the last saved checkpoint is the full length.
        let state = try JSONSerialization.jsonObject(with: try #require(box.get()).opaque) as? [String: Any]
        #expect(state?["offset"] as? Int == size)
    }

    @Test func corruptedTempOnResumeExpiresCheckpoint() async throws {
        let root = try tempDir(), scratch = try tempDir()
        let faults = FaultPlan()
        let adapter = FilesystemAdapter(root: root, faults: faults)
        let (url, integrity, _) = try write(scratch, "big.bin", bytes: 3 * 1024 * 1024)
        let box = Box()
        faults.failAfterBytes("big.bin", 2 * 1024 * 1024, .offline)
        await #expect(throws: StorageError.offline) {
            _ = try await adapter.uploadFile(localURL: url, relativePath: "big.bin", expected: integrity,
                                             checkpoint: nil, saveCheckpoint: { box.set($0) })
        }
        let cp = try #require(box.get())
        let temp = try #require((try JSONSerialization.jsonObject(with: cp.opaque) as? [String: Any])?["temp"] as? String)
        let tempURL = root.appendingPathComponent(temp)
        let handle = try FileHandle(forUpdating: tempURL)
        try handle.seek(toOffset: UInt64(2 * 1024 * 1024 - 1))
        try handle.write(contentsOf: Data([0xFF, 0xFE]).prefix(1))
        try handle.close()
        await #expect(throws: StorageError.checkpointExpired) {
            _ = try await adapter.uploadFile(localURL: url, relativePath: "big.bin", expected: integrity,
                                             checkpoint: cp, saveCheckpoint: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: tempURL.path))
        #expect(try await adapter.inspectFile(relativePath: "big.bin") == nil)
    }

    @Test func missingTempFileExpiresCheckpoint() async throws {
        let root = try tempDir(), scratch = try tempDir()
        let adapter = FilesystemAdapter(root: root)
        let (url, integrity, _) = try write(scratch, "a.bin", bytes: 100)
        let cp = UploadCheckpoint(opaque: Data(#"{"temp":".tmp-gone","offset":50}"#.utf8))
        await #expect(throws: StorageError.checkpointExpired) {
            _ = try await adapter.uploadFile(localURL: url, relativePath: "a.bin", expected: integrity,
                                             checkpoint: cp, saveCheckpoint: { _ in })
        }
    }

    @Test func invalidPathsAreRejected() async throws {
        let adapter = FilesystemAdapter(root: try tempDir())
        for p in ["", "/abs", "a/../b", "a/./b", "a//b", "a\\b", "a\0b", ".."] {
            await #expect(throws: StorageError.permanent(code: "invalid_path")) {
                _ = try await adapter.inspectFile(relativePath: p)
            }
        }
    }

    @Test func cancellationStopsUpload() async throws {
        let root = try tempDir(), scratch = try tempDir()
        let adapter = FilesystemAdapter(root: root)
        let (url, integrity, _) = try write(scratch, "c.bin", bytes: 3 * 1024 * 1024)
        let task = Task {
            try await adapter.uploadFile(localURL: url, relativePath: "c.bin", expected: integrity,
                                         checkpoint: nil, saveCheckpoint: { _ in })
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
}
