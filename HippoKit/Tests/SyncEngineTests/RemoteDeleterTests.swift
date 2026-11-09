import Foundation
import Testing
import CaptureCore
import LocalRepository
@testable import SyncEngine
import FilesystemAdapter

private struct Setup {
    let h: SyncHarness
    let remoteState: RemoteStateStore
    let pkg: CommittedPackage
    var id: String { pkg.metadata.captureID }
    var destination: Destination { try! h.destinations.active()! }

    init() async throws {
        h = try SyncHarness()
        remoteState = RemoteStateStore(db: h.db)
        pkg = try await h.capture()
    }

    var deviceDir: String { try! EnrichmentPaths.remoteDirectory(.device, packageDirectory: pkg.relativeDirectory) }
    var serverDir: String { try! EnrichmentPaths.remoteDirectory(.server, packageDirectory: pkg.relativeDirectory) }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: h.remote.appendingPathComponent(path).path) }

    /// Puts the package and both enrichment folders on the remote.
    func populateRemote() throws {
        for dir in [pkg.relativeDirectory, deviceDir, serverDir] {
            let url = h.remote.appendingPathComponent(dir)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url.appendingPathComponent("file"))
        }
    }

    func tombstone(destination: Destination? = nil) throws {
        let d = destination ?? self.destination
        try remoteState.addTombstone(captureID: id, relativeDirectory: pkg.relativeDirectory, destinationID: d.id,
                                     accountIdentifier: d.accountIdentifier, now: h.clock.now)
    }

    func deleter(_ adapter: (any StorageAdapter)? = nil) -> RemoteDeleter {
        let a: any StorageAdapter = adapter ?? h.adapter
        let clock = h.clock
        return RemoteDeleter(destinations: h.destinations, remoteState: remoteState, adapterFor: { _ in a },
                             now: { clock.now }, random: { 1 }, log: h.log)
    }
}

struct RemoteDeleterTests {
    @Test func deletesPackageAndEnrichmentFoldersThenRemovesTombstone() async throws {
        let s = try await Setup()
        defer { s.h.cleanup() }
        try s.populateRemote()
        try s.tombstone()
        let result = await s.deleter().runOnce()
        #expect(result == RemoteDeleteResult(deleted: 1, failed: 0, idle: false))
        #expect(!s.exists(s.pkg.relativeDirectory) && !s.exists(s.deviceDir) && !s.exists(s.serverDir))
        #expect(try !s.remoteState.hasTombstone(captureID: s.id))
        #expect(await s.deleter().runOnce() == RemoteDeleteResult(deleted: 0, failed: 0, idle: true))
        let events = s.h.log.events(captureID: s.id, from: Date(timeIntervalSince1970: 0)).filter { $0.event == .remoteDelete }
        #expect(events.map(\.outcome) == [.ok])
    }

    @Test func notFoundCountsAsSuccess() async throws {
        let s = try await Setup()
        defer { s.h.cleanup() }
        try s.tombstone()
        let result = await s.deleter().runOnce()
        #expect(result.deleted == 1 && result.failed == 0)
        #expect(try !s.remoteState.hasTombstone(captureID: s.id))
    }

    @Test func tombstoneForAnotherAccountIsNotRun() async throws {
        let s = try await Setup()
        defer { s.h.cleanup() }
        try s.populateRemote()
        try s.tombstone()
        _ = try s.h.destinations.connect(Destination(id: "dest-b", providerKind: "filesystem", accountIdentifier: "other",
                                                     remoteRoot: "/", displayName: "Other", status: .active))
        let result = await s.deleter().runOnce()
        #expect(result == RemoteDeleteResult(deleted: 0, failed: 0, idle: true))
        #expect(try s.remoteState.hasTombstone(captureID: s.id))
        #expect(s.exists(s.pkg.relativeDirectory))
        #expect(!s.h.faults.operations.contains { $0.hasPrefix("deleteFolder") })
    }

    @Test func failureBacksOffAndRetries() async throws {
        let s = try await Setup()
        defer { s.h.cleanup() }
        try s.populateRemote()
        try s.tombstone()
        var failing = HookedAdapter(inner: s.h.adapter)
        failing.beforeDelete = { _ in throw StorageError.transient(code: "boom") }
        let result = await s.deleter(failing).runOnce()
        #expect(result == RemoteDeleteResult(deleted: 0, failed: 1, idle: false))
        let row = try #require(try s.remoteState.dueTombstones(destinationID: s.destination.id,
                                                               accountIdentifier: s.destination.accountIdentifier,
                                                               now: .distantFuture, limit: 10).first)
        #expect(row.attemptCount == 1 && row.lastErrorCode == "transient:boom")
        #expect(try #require(row.nextAttemptAt) > s.h.clock.now)
        #expect(await s.deleter().runOnce().idle)
        #expect(s.exists(s.pkg.relativeDirectory))

        s.h.clock.set(try #require(row.nextAttemptAt).addingTimeInterval(1))
        let retry = await s.deleter().runOnce()
        #expect(retry.deleted == 1)
        #expect(!s.exists(s.pkg.relativeDirectory))
        let events = s.h.log.events(captureID: s.id, from: Date(timeIntervalSince1970: 0)).filter { $0.event == .remoteDelete }
        #expect(events.map(\.outcome) == [.failed, .ok])
        #expect(events.first?.code == "transient:boom")
    }

    @Test func needsAuthenticationStopsPass() async throws {
        let s = try await Setup()
        defer { s.h.cleanup() }
        try s.populateRemote()
        try s.tombstone()
        var failing = HookedAdapter(inner: s.h.adapter)
        failing.beforeDelete = { _ in throw StorageError.needsAuthentication }
        let result = await s.deleter(failing).runOnce()
        #expect(result.deleted == 0 && result.failed == 0)
        let row = try #require(try s.remoteState.dueTombstones(destinationID: s.destination.id,
                                                               accountIdentifier: s.destination.accountIdentifier,
                                                               now: s.h.clock.now, limit: 10).first)
        #expect(row.attemptCount == 0 && row.lastErrorCode == nil)
        #expect(s.h.log.events(captureID: s.id, from: Date(timeIntervalSince1970: 0)).filter { $0.event == .remoteDelete }.isEmpty)
    }

    @Test func deleteDuringUploadCancelsThenDeletesRemote() async throws {
        let h = try SyncHarness()
        defer { h.cleanup() }
        let store = try HippoStore.open(root: h.root.appendingPathComponent("store"),
                                        producer: Producer(appVersion: "0.1.0", build: "1", osVersion: "test"),
                                        leaseWaitLimit: .seconds(5))
        _ = try store.destinations.connect(Destination(id: "dest-fs", providerKind: "filesystem",
                                                       accountIdentifier: "local", remoteRoot: "/",
                                                       displayName: "Local folder", status: .active))
        var data = Data(count: 3 * FilesystemAdapter.chunkSize)
        for i in 0..<data.count { data[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7) }
        let draft = CaptureDraft(captureID: UUID(), startedAt: Date(timeIntervalSince1970: 1_794_070_800),
                                 timeZone: TimeZone(identifier: "America/Los_Angeles")!, method: .shareExtension,
                                 attachments: [AttachmentSource(body: .data(data), originalFilename: "blob.bin",
                                                                uti: "public.data", mimeType: "application/octet-stream",
                                                                representationSource: "item_provider_data")])
        let pkg = try await store.capture(draft)
        let pausing = PausingAdapter(inner: h.adapter, path: pkg.attachmentPath)
        let worker = store.makeWorker(adapterFor: { _ in pausing }, owner: "w")
        let run = Task { let r = await worker.runOnce(); pausing.paused.open(); return r }
        await pausing.paused.wait()

        // The upload is genuinely mid-file: a partial remote package exists, with no marker.
        let remoteDir = h.remote.appendingPathComponent(pkg.relativeDirectory)
        #expect(FileManager.default.fileExists(atPath: remoteDir.path))
        #expect(!FileManager.default.fileExists(atPath: remoteDir.appendingPathComponent("complete.json").path))

        let id = pkg.metadata.captureID
        let deletion = Task { try await store.deleteEverywhere(captureID: id) }
        // Deletion waits for the worker's lease; wait until its cancel request is visible, then let go.
        let deadline = ContinuousClock.now + .seconds(5)
        while try !store.jobs.jobs(captureID: id).contains(where: \.cancelRequested) {
            guard ContinuousClock.now < deadline else {
                Issue.record("the deletion's cancel request never appeared")
                pausing.release.open()
                _ = try? await deletion.value
                _ = await run.value
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        pausing.release.open()
        let deletionResult = try await deletion.value
        _ = await run.value
        #expect(deletionResult.hadActiveUpload)

        #expect(!FileManager.default.fileExists(atPath: remoteDir.appendingPathComponent("complete.json").path))
        #expect(FileManager.default.fileExists(atPath: remoteDir.path))
        #expect(try store.remoteState.hasTombstone(captureID: id))
        let deleter = store.makeRemoteDeleter(adapterFor: { _ in h.adapter })
        let result = await deleter.runOnce()
        #expect(result.deleted == 1)
        #expect(!FileManager.default.fileExists(atPath: remoteDir.path))
        #expect(try !store.remoteState.hasTombstone(captureID: id))
    }
}
