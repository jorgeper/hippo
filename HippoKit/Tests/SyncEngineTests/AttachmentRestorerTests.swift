import Foundation
import Testing
import CaptureCore
import LocalRepository
@testable import SyncEngine
import FilesystemAdapter

private struct Setup {
    let h: SyncHarness
    let pkg: CommittedPackage
    var attachment: CaptureCore.Attachment { pkg.metadata.attachments[0] }
    var id: String { pkg.metadata.captureID }
    var localFile: URL {
        h.layout.packageURL(relativeDirectory: pkg.relativeDirectory).appendingPathComponent(attachment.relativePath)
    }

    /// A synced capture whose only attachment was trimmed.
    init() async throws {
        h = try SyncHarness()
        pkg = try await h.capture()
        _ = await h.worker().runOnce()
        let clock = h.clock, adapter = h.adapter
        let saver = SpaceSaver(layout: h.layout, index: h.index, jobs: h.jobs, destinations: h.destinations, trims: h.trims,
                               adapterFor: { _ in adapter }, now: { clock.now })
        let result = await saver.run(SpaceSaveOptions(olderThan: 86_400, largerThan: 500), progress: { _, _ in })
        precondition(result.trimmed == 1)
    }

    func restorer(_ adapter: (any StorageAdapter)? = nil) -> AttachmentRestorer {
        let a: any StorageAdapter = adapter ?? h.adapter
        return AttachmentRestorer(layout: h.layout, index: h.index, trims: h.trims, destinations: h.destinations,
                                  adapterFor: { _ in a }, log: h.log, tasks: EnrichmentTaskStore(db: h.db))
    }

    func restore(_ r: AttachmentRestorer, progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws {
        try await r.restore(captureID: id, attachmentID: attachment.attachmentID, progress: progress)
    }

    var events: [LogEvent] { h.log.events(captureID: id, from: Date(timeIntervalSince1970: 0)).filter { $0.event == .attachmentRestored } }
    var transferLeftovers: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: h.layout.transfersDir.path)) ?? []) }
}

private final class Last: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [Int64] = []
    func set(_ a: Int64, _ b: Int64) { lock.lock(); value = [a, b]; lock.unlock() }
    var get: [Int64] { lock.lock(); defer { lock.unlock() }; return value }
}

@Suite struct AttachmentRestorerTests {
    @Test func restoreVerifiesAndRemovesRow() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        let last = Last()

        try await s.restore(s.restorer(), progress: { last.set($0, $1) })

        #expect(try Data(contentsOf: s.localFile) == Data(contentsOf: s.h.remote.appendingPathComponent(s.pkg.attachmentPath)))
        #expect(last.get == [1_000, 1_000])
        #expect(try s.h.trims.trimmed(captureID: s.id).isEmpty)
        #expect(s.transferLeftovers.isEmpty)
        #expect(s.events.map(\.outcome) == [.ok])
        // The package validates with nothing trimmed again.
        let directory = s.h.layout.packageURL(relativeDirectory: s.pkg.relativeDirectory)
        #expect(CommittedPackage.load(directory: directory, layout: s.h.layout) != nil)
    }

    @Test func restoreMismatchMarksRowAndKeepsThumbnail() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        let thumbnail = s.h.layout.thumbnailURL(attachmentID: s.attachment.attachmentID)
        try FileManager.default.createDirectory(at: s.h.layout.thumbnailsDir, withIntermediateDirectories: true)
        try Data("thumb".utf8).write(to: thumbnail)
        var changed = try Data(contentsOf: s.h.remote.appendingPathComponent(s.pkg.attachmentPath))
        changed[0] ^= 0xFF
        try changed.write(to: s.h.remote.appendingPathComponent(s.pkg.attachmentPath))

        await #expect(throws: RestoreError.mismatch) { try await s.restore(s.restorer()) }

        let row = try #require(try s.h.trims.trimmed(captureID: s.id).first)
        #expect(row.state == .mismatch)
        #expect(!FileManager.default.fileExists(atPath: s.localFile.path))
        #expect(FileManager.default.fileExists(atPath: thumbnail.path))
        #expect(s.transferLeftovers.isEmpty)
        #expect(s.events.map(\.outcome) == [.failed])
        #expect(s.events.first?.code == "mismatch")
    }

    @Test func restoreMissingRemoteMarksRow() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        try FileManager.default.removeItem(at: s.h.remote.appendingPathComponent(s.pkg.attachmentPath))

        await #expect(throws: RestoreError.notFound) { try await s.restore(s.restorer()) }

        #expect(try s.h.trims.trimmed(captureID: s.id).first?.state == .mismatch)
    }

    @Test func restoreNeedsSameAccount() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        _ = try s.h.destinations.connect(Destination(id: "dest-2", providerKind: "filesystem", accountIdentifier: "other",
                                                     remoteRoot: "/", displayName: "Other", status: .active))

        await #expect(throws: RestoreError.notConnected(destinationName: "Local folder")) {
            try await s.restore(s.restorer())
        }
        #expect(try s.h.trims.trimmed(captureID: s.id).count == 1)
    }

    @Test func restoreOfflineThrowsOffline() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        var hooked = HookedAdapter(inner: s.h.adapter)
        hooked.beforeDownload = { _ in throw StorageError.offline }

        await #expect(throws: RestoreError.offline) { try await s.restore(s.restorer(hooked)) }

        #expect(try s.h.trims.trimmed(captureID: s.id).first?.state == .trimmed)
        #expect(s.events.first?.code == "offline")
    }

    @Test func restoreMakesByteReadingKindsSchedulableAgain() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        let tasks = EnrichmentTaskStore(db: s.h.db)
        try tasks.set(captureID: s.id, kind: .textRecognition, version: 1, status: "not_applicable", now: t0)
        try tasks.set(captureID: s.id, kind: .transcript, version: 1, status: "ok", now: t0)

        try await s.restore(s.restorer())

        #expect(try tasks.task(captureID: s.id, kind: .textRecognition) == nil)
        #expect(try tasks.task(captureID: s.id, kind: .transcript)?.status == "ok")
    }

    @Test func restoreNeverRecreatesADeletedPackage() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        let store = try HippoStore.open(root: s.h.root, producer: Producer(appVersion: "0.1.0", build: "1", osVersion: "test"))
        let id = s.id
        var hooked = HookedAdapter(inner: s.h.adapter)
        hooked.afterDownload = { _ in _ = try? await store.delete(captureID: id) }
        let rowBefore = try s.h.trims.trimmed(captureID: id)
        #expect(rowBefore.count == 1)

        await #expect(throws: RestoreError.notFound) { try await s.restore(s.restorer(hooked)) }

        #expect(!FileManager.default.fileExists(atPath: s.h.layout.packageURL(relativeDirectory: s.pkg.relativeDirectory).path))
        #expect(s.transferLeftovers.isEmpty)
    }

    @Test func restoreRetryAfterRowRemovalFailedSkipsTheDownload() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        try FileManager.default.copyItem(at: s.h.remote.appendingPathComponent(s.pkg.attachmentPath), to: s.localFile)
        var hooked = HookedAdapter(inner: s.h.adapter)
        hooked.beforeDownload = { _ in throw StorageError.offline }

        try await s.restore(s.restorer(hooked))

        #expect(try s.h.trims.trimmed(captureID: s.id).isEmpty)
    }
}
