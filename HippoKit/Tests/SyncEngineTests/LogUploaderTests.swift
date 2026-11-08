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

    var capabilities: StorageCapabilities { inner.capabilities }
    func replaceFile(localURL: URL, relativePath: String, expected: FileIntegrity) async throws -> UploadReceipt {
        duringReplace(relativePath)
        return try await inner.replaceFile(localURL: localURL, relativePath: relativePath, expected: expected)
    }
    func listChanges(under prefix: String, cursor: String?) async throws -> ChangePage {
        try await inner.listChanges(under: prefix, cursor: cursor)
    }
    func downloadFile(relativePath: String, to localURL: URL, maxBytes: Int64) async throws -> RemoteFileInfo {
        try await inner.downloadFile(relativePath: relativePath, to: localURL, maxBytes: maxBytes)
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
    func uploader(_ adapter: (any StorageAdapter)? = nil, max: Int = 5) -> LogUploader {
        let a: any StorageAdapter = adapter ?? h.adapter
        return LogUploader(layout: h.layout, log: h.log, destinations: h.destinations, installID: installID,
                           adapterFor: { _ in a }, maxFilesPerPass: max)
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
