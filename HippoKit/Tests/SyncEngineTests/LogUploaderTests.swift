import Foundation
import Testing
import CaptureCore
import LocalRepository
import SyncEngine
import FilesystemAdapter

/// Wraps the filesystem adapter and runs `duringReplace` inside `replaceFile` (before delegating).
private struct GrowingAdapter: StorageAdapter {
    let inner: FilesystemAdapter
    let duringReplace: @Sendable (String) -> Void
    var afterReplace: @Sendable (String) -> Void = { _ in }

    var capabilities: StorageCapabilities { inner.capabilities }
    func replaceFile(localURL: URL, relativePath: String, expected: FileIntegrity) async throws -> UploadReceipt {
        duringReplace(relativePath)
        let receipt = try await inner.replaceFile(localURL: localURL, relativePath: relativePath, expected: expected)
        afterReplace(relativePath)
        return receipt
    }
    func listChanges(under prefix: String, cursor: String?) async throws -> ChangePage {
        try await inner.listChanges(under: prefix, cursor: cursor)
    }
    func downloadFile(relativePath: String, to localURL: URL, maxBytes: Int64,
                      progress: (@Sendable (Int64) -> Void)?) async throws -> RemoteFileInfo {
        try await inner.downloadFile(relativePath: relativePath, to: localURL, maxBytes: maxBytes, progress: progress)
    }
    func deleteFolder(relativePath: String) async throws { try await inner.deleteFolder(relativePath: relativePath) }
    func latestCursor(under prefix: String) async throws -> String { try await inner.latestCursor(under: prefix) }
    func listFolder(relativePath: String, recursive: Bool, cursor: String?) async throws -> ListPage {
        try await inner.listFolder(relativePath: relativePath, recursive: recursive, cursor: cursor)
    }
    func thumbnail(relativePath: String, maxPixelSize: Int) async throws -> Data? {
        try await inner.thumbnail(relativePath: relativePath, maxPixelSize: maxPixelSize)
    }
    func validateDestination() async throws { try await inner.validateDestination() }
    func ensureContainer(relativePath: String) async throws { try await inner.ensureContainer(relativePath: relativePath) }
    func inspectFile(relativePath: String) async throws -> RemoteFileInfo? {
        try await inner.inspectFile(relativePath: relativePath)
    }
    func verify(remote: RemoteFileInfo, localURL: URL, expected: FileIntegrity) async throws -> VerificationEvidence? {
        try await inner.verify(remote: remote, localURL: localURL, expected: expected)
    }
    func uploadFile(localURL: URL, relativePath: String, expected: FileIntegrity, checkpoint: UploadCheckpoint?,
                    saveCheckpoint: @Sendable (UploadCheckpoint) async throws -> Void) async throws -> UploadReceipt {
        try await inner.uploadFile(localURL: localURL, relativePath: relativePath, expected: expected,
                                   checkpoint: checkpoint, saveCheckpoint: saveCheckpoint)
    }
}

private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<LogUploadResult, Never>?
    private var pendingCancel = false
    func set(_ t: Task<LogUploadResult, Never>) {
        lock.lock(); task = t; let c = pendingCancel; lock.unlock()
        if c { t.cancel() }
    }
    func cancel() {
        lock.lock(); pendingCancel = true; let t = task; lock.unlock()
        t?.cancel()
    }
}

private let installID = "0b6f7d2e-1111-4222-8333-444455556666"

private struct Setup {
    let h: SyncHarness
    init() throws { h = try SyncHarness() }

    func local(_ name: String) -> URL { h.layout.logsDir.appendingPathComponent(name) }
    func remote(_ name: String) -> URL { h.remote.appendingPathComponent("logs/\(installID)/\(name)") }

    func write(_ name: String, _ text: String) throws {
        try FileManager.default.createDirectory(at: h.layout.logsDir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: local(name))
    }
    func append(_ name: String, _ text: String) throws {
        let fh = try FileHandle(forWritingTo: local(name))
        defer { try? fh.close() }
        try fh.seekToEnd()
        try fh.write(contentsOf: Data(text.utf8))
    }
    func uploader(_ adapter: (any StorageAdapter)? = nil, max: Int = 5,
                  isConstrained: @escaping @Sendable () -> Bool = { false },
                  now: @escaping @Sendable () -> Date = Date.init) -> LogUploader {
        let a: any StorageAdapter = adapter ?? h.adapter
        return LogUploader(layout: h.layout, log: h.log, destinations: h.destinations, installID: installID,
                           adapterFor: { _ in a }, maxFilesPerPass: max, isConstrained: isConstrained,
                           constrainedMinInterval: 900, now: now)
    }
}

@Suite struct LogUploaderTests {
    @Test func uploadsChangedFilesOnly() async throws {
        let s = try Setup(); defer { s.h.cleanup() }
        try s.write("2026-11-07.jsonl", "{\"a\":1}\n")
        try s.write("2026-11-08.jsonl", "{\"b\":2}\n")
        let up = s.uploader()
        #expect(await up.upload() == LogUploadResult(uploaded: 2, code: nil))
        #expect(await up.upload() == LogUploadResult(uploaded: 0, code: nil))
        try s.append("2026-11-08.jsonl", "{\"c\":3}\n")
        #expect(await up.upload() == LogUploadResult(uploaded: 1, code: nil))
        for name in ["2026-11-07.jsonl", "2026-11-08.jsonl"] {
            #expect(try Data(contentsOf: s.remote(name)) == Data(contentsOf: s.local(name)))
        }
        let last = try #require(LogUploader.lastResult(layout: s.h.layout))
        #expect(last.code == nil)
    }

    @Test func growingFileUploadsSnapshotThenRest() async throws {
        let s = try Setup(); defer { s.h.cleanup() }
        try s.write("2026-11-08.jsonl", "{\"a\":1}\n")
        let snapshot = try Data(contentsOf: s.local("2026-11-08.jsonl"))
        let url = s.local("2026-11-08.jsonl")
        let adapter = GrowingAdapter(inner: s.h.adapter) { _ in
            if let fh = try? FileHandle(forWritingTo: url) {
                _ = try? fh.seekToEnd()
                try? fh.write(contentsOf: Data("{\"late\":2}\n".utf8))
                try? fh.close()
            }
        }
        let first = await s.uploader(adapter).upload()
        #expect(first == LogUploadResult(uploaded: 1, code: nil))
        #expect(try Data(contentsOf: s.remote("2026-11-08.jsonl")) == snapshot)

        let second = await s.uploader().upload()
        #expect(second == LogUploadResult(uploaded: 1, code: nil))
        #expect(try Data(contentsOf: s.remote("2026-11-08.jsonl")) == Data(contentsOf: url))
        #expect(try Data(contentsOf: url).count > snapshot.count)
    }

    @Test func cancelKeepsProgressAlreadyMade() async throws {
        let s = try Setup(); defer { s.h.cleanup() }
        try s.write("2026-11-07.jsonl", "{\"a\":1}\n")
        try s.write("2026-11-08.jsonl", "{\"b\":2}\n")
        let box = TaskBox()
        let adapter = GrowingAdapter(inner: s.h.adapter, duringReplace: { _ in }, afterReplace: { _ in box.cancel() })
        let up = s.uploader(adapter)
        let task = Task { await up.upload() }
        box.set(task)
        #expect(await task.value.uploaded == 1)
        #expect(FileManager.default.fileExists(atPath: s.remote("2026-11-07.jsonl").path))
        #expect(!FileManager.default.fileExists(atPath: s.remote("2026-11-08.jsonl").path))
        // The first file is recorded, so only the second goes up next time.
        #expect(await s.uploader().upload() == LogUploadResult(uploaded: 1, code: nil))
    }

    @Test func idlePassRefreshesLastAt() async throws {
        let s = try Setup(); defer { s.h.cleanup() }
        try s.write("2026-11-08.jsonl", "{\"a\":1}\n")
        let up = s.uploader()
        _ = await up.upload()
        let first = try #require(LogUploader.lastResult(layout: s.h.layout)).at
        try await Task.sleep(for: .milliseconds(1100))
        #expect(await up.upload().uploaded == 0)
        let second = try #require(LogUploader.lastResult(layout: s.h.layout)).at
        #expect(second > first)
    }

    @Test func cellularThrottleSkipsWithinInterval() async throws {
        let s = try Setup(); defer { s.h.cleanup() }
        try s.write("2026-11-08.jsonl", "{\"a\":1}\n")
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        // A first, unconstrained pass at t0 records last_at and uploads the file.
        #expect(await s.uploader(now: { t0 }).upload() == LogUploadResult(uploaded: 1, code: nil))
        try s.append("2026-11-08.jsonl", "{\"b\":2}\n")
        let stateURL = s.h.layout.logsDir.appendingPathComponent("upload-state.json")
        let before = try Data(contentsOf: stateURL)

        let soon = s.uploader(isConstrained: { true }, now: { t0.addingTimeInterval(60) })
        #expect(await soon.upload() == LogUploadResult(uploaded: 0, code: "throttled"))
        #expect(try Data(contentsOf: stateURL) == before)
        #expect(try Data(contentsOf: s.remote("2026-11-08.jsonl")) != Data(contentsOf: s.local("2026-11-08.jsonl")))

        let later = s.uploader(isConstrained: { true }, now: { t0.addingTimeInterval(1000) })
        #expect(await later.upload() == LogUploadResult(uploaded: 1, code: nil))

        // Unconstrained passes are never throttled.
        try s.append("2026-11-08.jsonl", "{\"c\":3}\n")
        let free = s.uploader(isConstrained: { false }, now: { t0.addingTimeInterval(1001) })
        #expect(await free.upload() == LogUploadResult(uploaded: 1, code: nil))
    }

    @Test func respectsMaxFilesPerPass() async throws {
        let s = try Setup(); defer { s.h.cleanup() }
        for d in 1...7 { try s.write(String(format: "2026-11-%02d.jsonl", d), "{\"d\":\(d)}\n") }
        let up = s.uploader(max: 5)
        #expect(await up.upload().uploaded == 5)
        #expect(await up.upload().uploaded == 2)
        #expect(await up.upload().uploaded == 0)
    }

    @Test func noDestinationKeepsLocal() async throws {
        let s = try Setup(); defer { s.h.cleanup() }
        try s.write("2026-11-08.jsonl", "{\"a\":1}\n")
        try s.h.destinations.signOut(destinationID: "dest-fs")
        let up = s.uploader()
        let r = await up.upload()
        #expect(r == LogUploadResult(uploaded: 0, code: "no_destination"))
        #expect(!FileManager.default.fileExists(atPath: s.h.remote.appendingPathComponent("logs").path))
        #expect(!FileManager.default.fileExists(atPath: s.h.layout.logsDir.appendingPathComponent("upload-state.json").path))
        #expect(FileManager.default.fileExists(atPath: s.local("2026-11-08.jsonl").path))
    }

    @Test func segmentsUploadSeparately() async throws {
        let s = try Setup(); defer { s.h.cleanup() }
        let day = Date()
        let name0 = ActivityLog.fileName(day: day, segment: 0)
        let name1 = ActivityLog.fileName(day: day, segment: 1)
        s.h.log.append(LogEvent(event: .syncPass, trigger: "manual", phase: "start"))
        let up = s.uploader()
        #expect(await up.upload().uploaded == 1)
        let firstRemote = try Data(contentsOf: s.remote(name0))
        s.h.log.clear()
        s.h.log.append(LogEvent(event: .syncPass, trigger: "manual", phase: "end"))
        #expect(await up.upload().uploaded == 1)
        #expect(try Data(contentsOf: s.remote(name1)) == Data(contentsOf: s.local(name1)))
        #expect(try Data(contentsOf: s.remote(name0)) == firstRemote)
    }
}
