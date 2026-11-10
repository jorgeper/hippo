import Foundation
import Testing
import CaptureCore
import LocalRepository
import HippoTestSupport
@testable import SyncEngine
import FilesystemAdapter

private let options = SpaceSaveOptions(olderThan: 30 * 86_400, largerThan: 500)
private let oldDate = Date(timeIntervalSince1970: 1_794_070_800)

private struct Setup {
    let h: SyncHarness

    init() throws { h = try SyncHarness() }

    func saver(_ adapter: (any StorageAdapter)? = nil) -> SpaceSaver {
        let a: any StorageAdapter = adapter ?? h.adapter
        let clock = h.clock
        return SpaceSaver(layout: h.layout, index: h.index, jobs: h.jobs, destinations: h.destinations, trims: h.trims,
                          adapterFor: { _ in a }, now: { clock.now }, log: h.log)
    }

    func sync() async { _ = await h.worker().runOnce() }

    func localFile(_ pkg: CommittedPackage) -> URL {
        h.layout.packageURL(relativeDirectory: pkg.relativeDirectory)
            .appendingPathComponent(pkg.metadata.attachments[0].relativePath)
    }

    func remoteFile(_ pkg: CommittedPackage) -> URL { h.remote.appendingPathComponent(pkg.attachmentPath) }

    func run(_ saver: SpaceSaver) async -> SpaceSaveResult { await saver.run(options, progress: { _, _ in }) }

    /// A synced, old capture with a large (1,000 byte) attachment.
    func syncedOldLarge() async throws -> CommittedPackage {
        let p = try await h.capture()
        await sync()
        return p
    }
}

private final class Progress: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[Int]] = []
    func add(_ done: Int, _ total: Int) { lock.lock(); values.append([done, total]); lock.unlock() }
    var all: [[Int]] { lock.lock(); defer { lock.unlock() }; return values }
}

@Suite struct SpaceSaverTests {
    @Test func candidatesRequireSyncedOnActiveAccountAndBothLimits() async throws {
        let s = try Setup(); defer { s.h.cleanup() }
        // A synced capture bound to a second destination that is then disabled.
        _ = try s.h.destinations.connect(Destination(id: "dest-2", providerKind: "filesystem", accountIdentifier: "other",
                                                     remoteRoot: "/", displayName: "Other", status: .active))
        let elsewhere = try await s.h.capture()
        await s.sync()
        _ = try s.h.destinations.connect(Destination(id: "dest-fs", providerKind: "filesystem", accountIdentifier: "local",
                                                     remoteRoot: "/", displayName: "Local folder", status: .active))

        let good = try await s.h.capture()
        let recent = try await s.h.capture(startedAt: s.h.clock.now.addingTimeInterval(-86_400))
        let small = try await s.h.capture(attachmentBytes: 100)
        await s.sync()
        let pending = try await s.h.capture()

        let saver = s.saver()
        let found = try saver.candidates(options)
        #expect(found.map(\.captureID) == [good.metadata.captureID])
        #expect(found[0].attachment == good.metadata.attachments[0])
        #expect(found[0].relativeDirectory == good.relativeDirectory)
        #expect(found[0].destinationID == "dest-fs")
        #expect(try saver.estimate(options) == SpaceSaveEstimate(captures: 1, files: 1, bytes: 1_000))
        _ = (elsewhere, recent, small, pending)
    }

    @Test func runChecksRemoteThenTrims() async throws {
        let s = try Setup(); defer { s.h.cleanup() }
        let png = try MediaMaker.imageData(width: 64, height: 48, type: .png)
        let pkg = try await s.h.capture(image: png)
        await s.sync()
        let attachment = pkg.metadata.attachments[0]
        let progress = Progress()

        let result = await s.saver().run(SpaceSaveOptions(olderThan: 30 * 86_400, largerThan: 100),
                                         progress: { progress.add($0, $1) })

        #expect(result == SpaceSaveResult(trimmed: 1, bytes: attachment.byteCount, skipped: 0, code: nil))
        #expect(progress.all.last == [1, 1])
        #expect(!FileManager.default.fileExists(atPath: s.localFile(pkg).path))
        let row = try #require(try s.h.trims.trimmed(captureID: pkg.metadata.captureID).first)
        #expect(row.sha256 == attachment.sha256)
        #expect(row.byteCount == attachment.byteCount)
        #expect(row.state == .trimmed)
        #expect(row.destinationID == "dest-fs")
        let thumbnail = s.h.layout.thumbnailURL(attachmentID: attachment.attachmentID)
        #expect(try Data(contentsOf: thumbnail).count > 0)
        // The package still loads with its trimmed paths, and the index row stays.
        let directory = s.h.layout.packageURL(relativeDirectory: pkg.relativeDirectory)
        #expect(CommittedPackage.load(directory: directory, layout: s.h.layout,
                                      trimmed: try s.h.trims.trimmedPaths(captureID: pkg.metadata.captureID)) != nil)
        #expect(try s.h.index.relativeDirectory(captureID: pkg.metadata.captureID) == pkg.relativeDirectory)
        // The remote copy is untouched, and the event says what was freed.
        #expect(FileManager.default.fileExists(atPath: s.remoteFile(pkg).path))
        let event = try #require(s.h.log.globalEvents(limit: 20, before: nil).first { $0.event == .trimRun })
        #expect(event.count == 1)
        #expect(event.bytes == attachment.byteCount)
        #expect(event.code == nil)
        // Nothing is left to trim.
        #expect(try s.saver().candidates(SpaceSaveOptions(olderThan: 30 * 86_400, largerThan: 100)).isEmpty)
    }

    @Test func runSkipsWhenRemoteDiffers() async throws {
        let s = try Setup(); defer { s.h.cleanup() }
        let pkg = try await s.syncedOldLarge()
        try Data(count: 1_000).write(to: s.remoteFile(pkg))

        let result = await s.run(s.saver())

        #expect(result == SpaceSaveResult(trimmed: 0, bytes: 0, skipped: 1, code: "remote_mismatch"))
        #expect(FileManager.default.fileExists(atPath: s.localFile(pkg).path))
        #expect(try s.h.trims.trimmed(captureID: pkg.metadata.captureID).isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: s.h.layout.thumbnailURL(attachmentID: pkg.metadata.attachments[0].attachmentID).path))
    }

    @Test func runSkipsWhenRemoteHasSameSizeButOtherBytes() async throws {
        let s = try Setup(); defer { s.h.cleanup() }
        let pkg = try await s.syncedOldLarge()
        var other = try Data(contentsOf: s.remoteFile(pkg))
        other[0] ^= 0xFF
        try other.write(to: s.remoteFile(pkg))

        let result = await s.run(s.saver())

        #expect(result.trimmed == 0 && result.code == "remote_mismatch")
        #expect(FileManager.default.fileExists(atPath: s.localFile(pkg).path))
    }

    @Test func runSkipsWhenRemoteMissing() async throws {
        let s = try Setup(); defer { s.h.cleanup() }
        let pkg = try await s.syncedOldLarge()
        try FileManager.default.removeItem(at: s.remoteFile(pkg))

        let result = await s.run(s.saver())

        #expect(result == SpaceSaveResult(trimmed: 0, bytes: 0, skipped: 1, code: "remote_missing"))
        #expect(FileManager.default.fileExists(atPath: s.localFile(pkg).path))
        #expect(try s.h.trims.trimmed(captureID: pkg.metadata.captureID).isEmpty)
    }

    @Test func trimSkipsCaptureDeletedMidRun() async throws {
        let s = try Setup(); defer { s.h.cleanup() }
        let pkg = try await s.syncedOldLarge()
        let store = try HippoStore.open(root: s.h.root, producer: Producer(appVersion: "0.1.0", build: "1", osVersion: "test"))
        let id = pkg.metadata.captureID
        var hooked = HookedAdapter(inner: s.h.adapter)
        hooked.beforeInspect = { _ in _ = try? await store.delete(captureID: id) }

        let result = await s.run(s.saver(hooked))

        #expect(result.trimmed == 0)
        #expect(result.skipped == 1)
        #expect(result.code == "capture_gone")
        #expect(try s.h.trims.trimmed(captureID: id).isEmpty)
    }

    @Test func cancellationKeepsWhatWasTrimmed() async throws {
        let s = try Setup(); defer { s.h.cleanup() }
        let first = try await s.syncedOldLarge()
        let second = try await s.syncedOldLarge()
        let saver = s.saver()
        let box = TaskBox()
        let task = Task {
            await saver.run(options, progress: { done, _ in if done == 1 { box.cancel() } })
        }
        box.set(task)

        let result = await task.value

        #expect(result.trimmed == 1)
        #expect(result.code == "cancelled")
        let trimmed = [first, second].filter { (try? s.h.trims.trimmed(captureID: $0.metadata.captureID))?.isEmpty == false }
        #expect(trimmed.count == 1)
        let kept = [first, second].filter { FileManager.default.fileExists(atPath: s.localFile($0).path) }
        #expect(kept.count == 1)
    }
}

private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<SpaceSaveResult, Never>?
    func set(_ t: Task<SpaceSaveResult, Never>) { lock.lock(); task = t; lock.unlock() }
    func cancel() { lock.lock(); let t = task; lock.unlock(); t?.cancel() }
}
