import Foundation
import Testing
import CryptoKit
import CaptureCore
import LocalRepository
@testable import SyncEngine
import FilesystemAdapter
import HippoTestSupport

/// A `HippoStore` opened on a root that does not exist yet, plus a temp "remote" folder for the
/// filesystem adapter.
private struct StoreHarness {
    let base: URL
    let root: URL
    let remote: URL
    let store: HippoStore
    let faults = FaultPlan()

    init(leaseWaitLimit: Duration = HippoStore.defaultLeaseWaitLimit,
         now: @escaping @Sendable () -> Date = Date.init) throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("hippo-store-\(UUID().uuidString)")
        root = base.appendingPathComponent("Library/Application Support/Hippo")
        remote = base.appendingPathComponent("remote")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        store = try HippoStore.open(root: root, producer: Producer(appVersion: "0.1.0", build: "1", osVersion: "test"),
                                    leaseWaitLimit: leaseWaitLimit, now: now)
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }

    var destination: Destination {
        Destination(id: "dest-fs", providerKind: "filesystem", accountIdentifier: "local", remoteRoot: "/",
                    displayName: "Local folder", status: .active)
    }

    var adapter: FilesystemAdapter { FilesystemAdapter(root: remote, faults: faults) }

    var uploads: [String] { faults.operations.filter { $0.hasPrefix("upload ") } }

    /// A second connection to the store's database, as another process would have.
    func rawDatabase() throws -> Database { try Database(url: store.layout.databaseURL) }

    func remoteURL(_ pkg: CommittedPackage) -> URL { remote.appendingPathComponent(pkg.relativeDirectory) }

    /// Where deletion parks a package before removing it (ruling R31).
    func stagedDeletion(_ pkg: CommittedPackage) -> URL {
        store.layout.stagingDir.appendingPathComponent("\(pkg.metadata.captureID).deleted", isDirectory: true)
    }

    func stagingContents() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: store.layout.stagingDir.path)
    }

    /// A share-extension draft with one attachment of `bytes` deterministic bytes.
    func blobDraft(bytes: Int) -> CaptureDraft {
        var data = Data(count: bytes)
        for i in 0..<bytes { data[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7) }
        return CaptureDraft(captureID: UUID(), startedAt: Date(timeIntervalSince1970: 1_794_070_800),
                            timeZone: TimeZone(identifier: "America/Los_Angeles")!, method: .shareExtension,
                            attachments: [AttachmentSource(body: .data(data), originalFilename: "blob.bin",
                                                           uti: "public.data", mimeType: "application/octet-stream",
                                                           representationSource: "item_provider_data")])
    }

    func urlDraft(_ url: String = "https://example.com/a") -> CaptureDraft {
        CaptureDraft(captureID: UUID(), startedAt: Date(timeIntervalSince1970: 1_794_070_800),
                     timeZone: TimeZone(identifier: "America/Los_Angeles")!, method: .shareExtension,
                     urls: [CapturedURL(url: url, source: "shared")])
    }
}

private func isComplete(_ r: ValidationResult) -> Bool {
    if case .complete = r { return true }
    return false
}

@Suite struct HippoStoreTests {
    // Acceptance 1: a screenshot shared offline saves locally, is listed, and uploads later.
    @Test func captureThenSyncEndToEnd() async throws {
        let t = try StoreHarness(); defer { t.cleanup() }
        let fm = FileManager.default
        for url in [t.store.layout.stagingDir, t.store.layout.capturesDir, t.store.layout.databaseURL] {
            #expect(fm.fileExists(atPath: url.path))
        }

        let png = try MediaMaker.imageData(width: 40, height: 30, type: .png)
        let draft = CaptureDraft(captureID: UUID(), startedAt: Date(timeIntervalSince1970: 1_794_070_800),
                                 timeZone: TimeZone(identifier: "America/Los_Angeles")!, method: .shareExtension,
                                 attachments: [AttachmentSource(body: .data(png), originalFilename: "Screenshot.png",
                                                                uti: "public.png", mimeType: "image/png",
                                                                representationSource: "item_provider_file")])
        let pkg = try await t.store.capture(draft)
        let id = pkg.metadata.captureID

        // Saved and listed with nothing connected; no upload job yet.
        #expect(isComplete(PackageValidator.validate(directory: pkg.directoryURL)))
        #expect(try t.store.jobs.jobs(captureID: id).isEmpty)
        let listed = try t.store.index.page(CaptureFilter(), after: nil, limit: 10)
        #expect(listed.map(\.id) == [id])
        #expect(listed.map(\.syncBucket) == [.notSynced])

        // Connecting binds it; the next pass uploads it.
        #expect(try t.store.destinations.connect(t.destination) == 1)
        let adapter = t.adapter
        let pass = await t.store.makeWorker(adapterFor: { _ in adapter }, owner: "app").runOnce()

        #expect(pass == SyncPassResult(synced: 1, failed: 0, idle: false))
        #expect(try t.store.jobs.jobs(captureID: id).map(\.state) == [.synced])
        #expect(t.uploads.last == "upload \(pkg.relativeDirectory)/complete.json")
        #expect(isComplete(PackageValidator.validate(directory: t.remoteURL(pkg))))
        #expect(try t.store.index.page(CaptureFilter(), after: nil, limit: 10).map(\.syncBucket) == [.synced])
    }

    @Test func commitSurvivesRegisterFailure() async throws {
        let t = try StoreHarness(); defer { t.cleanup() }
        _ = try t.store.destinations.connect(t.destination)
        // Another connection takes the index table away, so registering fails after the commit.
        let raw = try t.rawDatabase()
        try raw.execute("ALTER TABLE captures RENAME TO captures_unavailable")

        let pkg = try await t.store.capture(t.urlDraft())

        #expect(isComplete(PackageValidator.validate(directory: pkg.directoryURL)))
        try raw.execute("ALTER TABLE captures_unavailable RENAME TO captures")
        #expect(try t.store.index.count() == 0)

        let report = try t.store.recover()
        #expect(report.registered == 1)
        #expect(try t.store.index.count() == 1)
        #expect(try t.store.index.relativeDirectory(captureID: pkg.metadata.captureID) == pkg.relativeDirectory)
        #expect(try t.store.jobs.jobs(captureID: pkg.metadata.captureID).map(\.state) == [.pending])
        #expect(try t.store.recover().registered == 0)
    }

    // Acceptance 12. The worker stalls mid-file and never answers the cancel: deletion sees its lease
    // live, then sees it expire while waiting, proceeds, and the worker then finds its job row gone and
    // aborts silently. Both clocks are fixed, so how long the test task takes to reach `delete` (under
    // a loaded parallel run) can't change the outcome.
    @Test func deleteDuringActiveUploadCancelsAndNeverTouchesRemote() async throws {
        // Deletion's first lease check reads t0 (the lease is live); every later check reads a time past
        // the lease, as if the stalled worker's lease ran out while deletion waited.
        let storeClock = TestClock(t0)
        let t = try StoreHarness(now: {
            let now = storeClock.now
            storeClock.set(t0.addingTimeInterval(SyncWorker.lease + 1))
            return now
        })
        defer { t.cleanup() }
        _ = try t.store.destinations.connect(t.destination)
        let pkg = try await t.store.capture(t.blobDraft(bytes: 3 * FilesystemAdapter.chunkSize))
        let id = pkg.metadata.captureID
        let adapter = PausingAdapter(inner: t.adapter, path: pkg.attachmentPath)
        let s = t.store
        let worker = SyncWorker(layout: s.layout, jobs: s.jobs, destinations: s.destinations, index: s.index,
                                adapterFor: { _ in adapter }, owner: "stalled-worker", now: { t0 })
        // Opening `paused` on exit too means a worker that never reaches the file fails the test, not hangs it.
        let run = Task { let r = await worker.runOnce(); adapter.paused.open(); return r }
        await adapter.paused.wait()

        let result = try await t.store.delete(captureID: id)
        adapter.release.open()
        let pass = await run.value

        #expect(result == HippoStore.DeletionResult(wasSynced: false, hadActiveUpload: true))
        #expect(pass == SyncPassResult(synced: 0, failed: 0, idle: false))
        #expect(!t.uploads.contains("upload \(pkg.markerPath)"))
        // The remote partial package stays: metadata.json was uploaded, there is no marker.
        #expect(FileManager.default.fileExists(atPath: t.remote.appendingPathComponent(pkg.metadataPath).path))
        #expect(!FileManager.default.fileExists(atPath: t.remote.appendingPathComponent(pkg.markerPath).path))
        #expect(!FileManager.default.fileExists(atPath: pkg.directoryURL.path))
        #expect(try t.store.index.count() == 0)
        #expect(try t.store.jobs.jobs(captureID: id).isEmpty)
    }

    // A live worker sees the cancel at its next chunk and lets go; deletion waits for that, not for the
    // 10 s limit.
    @Test func deleteWaitsForWorkerToReleaseCancelledUpload() async throws {
        let t = try StoreHarness(); defer { t.cleanup() }
        _ = try t.store.destinations.connect(t.destination)
        let pkg = try await t.store.capture(t.blobDraft(bytes: 3 * FilesystemAdapter.chunkSize))
        let id = pkg.metadata.captureID
        let adapter = PausingAdapter(inner: t.adapter, path: pkg.attachmentPath)
        let worker = t.store.makeWorker(adapterFor: { _ in adapter }, owner: "app")
        // Opening `paused` on exit too means a worker that never reaches the file fails the test, not hangs it.
        let run = Task { let r = await worker.runOnce(); adapter.paused.open(); return r }
        await adapter.paused.wait()

        let started = ContinuousClock.now
        let store = t.store
        let deletion = Task { try await store.delete(captureID: id) }
        let deadline = ContinuousClock.now + .seconds(5)
        while try t.store.jobs.jobs(captureID: id).first?.cancelRequested == false, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(300))
        // Still holding off: the upload's lease is live.
        #expect(FileManager.default.fileExists(atPath: pkg.directoryURL.path))
        #expect(try t.store.index.count() == 1)

        adapter.release.open()
        let result = try await deletion.value
        let pass = await run.value

        #expect(result == HippoStore.DeletionResult(wasSynced: false, hadActiveUpload: true))
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(pass == SyncPassResult(synced: 0, failed: 1, idle: false))
        #expect(!t.uploads.contains("upload \(pkg.markerPath)"))
        #expect(FileManager.default.fileExists(atPath: t.remote.appendingPathComponent(pkg.metadataPath).path))
        #expect(!FileManager.default.fileExists(atPath: pkg.directoryURL.path))
        #expect(try t.store.index.count() == 0)
    }

    // The worker holds a live lease and never answers the cancel: deletion gives up waiting at the
    // limit (10 s in production) and the worker then aborts on its vanished job row.
    @Test func deleteProceedsAfterLeaseWaitLimit() async throws {
        let t = try StoreHarness(leaseWaitLimit: .milliseconds(200)); defer { t.cleanup() }
        _ = try t.store.destinations.connect(t.destination)
        let pkg = try await t.store.capture(t.blobDraft(bytes: 3 * FilesystemAdapter.chunkSize))
        let id = pkg.metadata.captureID
        let adapter = PausingAdapter(inner: t.adapter, path: pkg.attachmentPath)
        let worker = t.store.makeWorker(adapterFor: { _ in adapter }, owner: "app")
        let run = Task { let r = await worker.runOnce(); adapter.paused.open(); return r }
        await adapter.paused.wait()

        let started = ContinuousClock.now
        let result = try await t.store.delete(captureID: id)
        let waited = ContinuousClock.now - started
        // Gone while the worker is still suspended mid-file with its 120 s lease.
        #expect(!FileManager.default.fileExists(atPath: pkg.directoryURL.path))
        #expect(try t.store.index.count() == 0)
        adapter.release.open()
        let pass = await run.value

        #expect(result == HippoStore.DeletionResult(wasSynced: false, hadActiveUpload: true))
        #expect(waited >= .milliseconds(200))
        #expect(waited < .seconds(3))
        #expect(pass == SyncPassResult(synced: 0, failed: 0, idle: false))
        #expect(!t.uploads.contains("upload \(pkg.markerPath)"))
        #expect(FileManager.default.fileExists(atPath: t.remote.appendingPathComponent(pkg.metadataPath).path))
        #expect(try t.stagingContents().isEmpty)
    }

    // Crash after the package was parked in staging but before the index row was removed.
    @Test func recoveryFinishesDeletionInterruptedAfterRename() async throws {
        let t = try StoreHarness(); defer { t.cleanup() }
        _ = try t.store.destinations.connect(t.destination)
        let pkg = try await t.store.capture(t.urlDraft())
        try FileManager.default.moveItem(at: pkg.directoryURL, to: t.stagedDeletion(pkg))

        let report = try t.store.recover()

        #expect(report.orphanedIndexRows == 1)
        #expect(report.removedStaging == 1)
        #expect(report.registered == 0)
        #expect(try t.store.index.count() == 0)
        #expect(try t.store.jobs.jobs(captureID: pkg.metadata.captureID).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: pkg.directoryURL.path))
        #expect(try t.stagingContents().isEmpty)
    }

    // Crash after the index row was removed but before the parked package was removed.
    @Test func recoveryFinishesDeletionInterruptedAfterRowRemoval() async throws {
        let t = try StoreHarness(); defer { t.cleanup() }
        let pkg = try await t.store.capture(t.urlDraft())
        try FileManager.default.moveItem(at: pkg.directoryURL, to: t.stagedDeletion(pkg))
        try t.store.index.remove(captureID: pkg.metadata.captureID)

        let report = try t.store.recover()

        #expect(report.removedStaging == 1)
        #expect(report.registered == 0)
        #expect(try t.store.index.count() == 0)
        #expect(!FileManager.default.fileExists(atPath: pkg.directoryURL.path))
        #expect(try t.stagingContents().isEmpty)
    }

    @Test func deleteToleratesLeftoversAndMissingPackage() async throws {
        let t = try StoreHarness(); defer { t.cleanup() }
        let fm = FileManager.default
        // A parked copy from an earlier attempt that crashed after its rename.
        let leftover = try await t.store.capture(t.urlDraft())
        try fm.createDirectory(at: t.stagedDeletion(leftover), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: t.stagedDeletion(leftover).appendingPathComponent("metadata.json"))
        // A package that vanished from disk while its row stayed.
        let missing = try await t.store.capture(t.urlDraft("https://example.com/b"))
        try fm.removeItem(at: missing.directoryURL)

        _ = try await t.store.delete(captureID: leftover.metadata.captureID)
        _ = try await t.store.delete(captureID: missing.metadata.captureID)

        #expect(try t.store.index.count() == 0)
        #expect(!fm.fileExists(atPath: leftover.directoryURL.path))
        #expect(try t.stagingContents().isEmpty)
    }

    @Test func deleteReportsSyncedAndIsIdempotent() async throws {
        let t = try StoreHarness(); defer { t.cleanup() }
        _ = try t.store.destinations.connect(t.destination)
        let synced = try await t.store.capture(t.urlDraft())
        let adapter = t.adapter
        #expect(await t.store.makeWorker(adapterFor: { _ in adapter }, owner: "app").runOnce().synced == 1)
        let pending = try await t.store.capture(t.urlDraft("https://example.com/b"))

        #expect(try await t.store.delete(captureID: synced.metadata.captureID)
                == HippoStore.DeletionResult(wasSynced: true, hadActiveUpload: false))
        #expect(try await t.store.delete(captureID: pending.metadata.captureID)
                == HippoStore.DeletionResult(wasSynced: false, hadActiveUpload: false))
        // Deleting again, or an unknown ID, is a no-op.
        #expect(try await t.store.delete(captureID: synced.metadata.captureID)
                == HippoStore.DeletionResult(wasSynced: false, hadActiveUpload: false))
        #expect(try await t.store.delete(captureID: "no-such-capture")
                == HippoStore.DeletionResult(wasSynced: false, hadActiveUpload: false))
        #expect(try t.store.index.count() == 0)
        #expect(!FileManager.default.fileExists(atPath: synced.directoryURL.path))
        #expect(!FileManager.default.fileExists(atPath: pending.directoryURL.path))
        #expect(try t.stagingContents().isEmpty)
        // The uploaded remote copy is untouched.
        #expect(isComplete(PackageValidator.validate(directory: t.remoteURL(synced))))
    }

    @Test func diagnosticsContainNoContent() async throws {
        let t = try StoreHarness(); defer { t.cleanup() }
        let account = Destination(id: "dest-private-id", providerKind: "filesystem", accountIdentifier: "dbid:ABC",
                                  remoteRoot: "/Apps/HippoPrivateRoot", displayName: "Private Display Name",
                                  status: .active)
        _ = try t.store.destinations.connect(account)
        var draft = t.urlDraft("https://private.example/x")
        draft.userNote = "SECRET-NOTE-123"
        draft.location = CaptureLocation(latitude: 47.6205123, longitude: -122.3493456, horizontalAccuracyMeters: 5,
                                         observedAt: Date(timeIntervalSince1970: 1_794_070_800),
                                         provenance: "core_location")
        let pkg = try await t.store.capture(draft)
        t.faults.failBeforeWrite(pkg.metadataPath, .transient(code: "server_500"))
        let adapter = t.adapter
        #expect(await t.store.makeWorker(adapterFor: { _ in adapter }, owner: "app").runOnce().failed == 1)
        let job = try #require(try t.store.jobs.jobs(captureID: pkg.metadata.captureID).first)

        try t.store.writeDiagnostics(appVersion: "1.4.2")

        let data = try Data(contentsOf: t.store.layout.diagnosticsURL)
        let text = String(decoding: data, as: UTF8.self)
        for secret in ["SECRET-NOTE-123", "private.example", "dbid:ABC", "Private Display Name", "HippoPrivateRoot",
                       "dest-private-id", pkg.metadata.captureID, job.jobID, pkg.relativeDirectory,
                       t.root.path, "47.6205", "122.3493"] {
            #expect(!text.contains(secret), "diagnostics leak: \(secret)")
        }

        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["generated_at", "app_version", "schema_version", "capture_count", "jobs_by_state",
                                   "recent_error_codes", "destinations",
                                   "enrichment_tasks", "enrichment_uploads_pending", "gold"])
        #expect(json["app_version"] as? String == "1.4.2")
        #expect(json["schema_version"] as? Int == 3)
        #expect(json["capture_count"] as? Int == 1)
        #expect(json["jobs_by_state"] as? [String: Int] == [
            "pending": 0, "uploading": 0, "synced": 0, "retryable_failure": 1, "needs_authentication": 0,
            "blocked": 0, "paused": 0,
        ])
        #expect(json["recent_error_codes"] as? [String] == ["transient:server_500"])
        #expect(json["destinations"] as? [[String: String]] == [["provider_kind": "filesystem", "status": "active"]])
        let generated = try #require(json["generated_at"] as? String)
        #expect(generated.wholeMatch(of: /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z/) != nil)
    }

    @Test func diagnosticsListTwentyMostRecentErrorCodes() async throws {
        let t = try StoreHarness(); defer { t.cleanup() }
        _ = try t.store.destinations.connect(t.destination)
        var ids: [String] = []
        for i in 0..<26 { ids.append(try await t.store.capture(t.urlDraft("https://example.com/\(i)")).metadata.captureID) }
        let raw = try t.rawDatabase()
        for (i, id) in ids.enumerated() {
            // The newest job has no error code and is skipped.
            try raw.execute("UPDATE jobs SET last_error_code = ?, updated_at_ms = ? WHERE capture_id = ?",
                            [i == 25 ? .null : .text("code_\(i)"), .int(Int64(1_000 + i)), .text(id)])
        }

        let data = try Diagnostics.make(db: raw, appVersion: "1.0", now: t0)

        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["generated_at"] as? String == "2027-01-15T08:00:00.000Z")
        #expect(json["capture_count"] as? Int == 26)
        #expect(json["recent_error_codes"] as? [String] == (5..<25).reversed().map { "code_\($0)" })
        #expect((json["jobs_by_state"] as? [String: Int])?["pending"] == 26)
        // HippoJSON conventions: sorted keys.
        let text = String(decoding: data, as: UTF8.self)
        let keys = ["app_version", "capture_count", "destinations", "generated_at", "jobs_by_state",
                    "recent_error_codes", "schema_version"]
        let offsets = keys.compactMap { text.range(of: "\"\($0)\"")?.lowerBound }
        #expect(offsets.count == keys.count)
        #expect(offsets == offsets.sorted())
    }

    @Test func diagnosticsReplaceUnrecognizedErrorCodes() async throws {
        let t = try StoreHarness(); defer { t.cleanup() }
        _ = try t.store.destinations.connect(t.destination)
        let codes = ["transient:server_500", "transient:/Users/someone/photo.png", "permanent:https://private.example/x",
                     "Offline", String(repeating: "a", count: 65), "rate_limited", "permanent:v2.bad-request"]
        let raw = try t.rawDatabase()
        for (i, code) in codes.enumerated() {
            let id = try await t.store.capture(t.urlDraft("https://example.com/\(i)")).metadata.captureID
            try raw.execute("UPDATE jobs SET last_error_code = ?, updated_at_ms = ? WHERE capture_id = ?",
                            [.text(code), .int(Int64(1_000 - i)), .text(id)])
        }

        let data = try Diagnostics.make(db: raw, appVersion: "1.0", now: t0)

        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["recent_error_codes"] as? [String] == [
            "transient:server_500", "unrecognized", "unrecognized", "unrecognized", "unrecognized", "rate_limited",
            "permanent:v2.bad-request",
        ])
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("someone"))
        #expect(!text.contains("private.example"))
    }

    @Test func deleteSucceedsWhenCleanupAfterRowRemovalFails() async throws {
        let t = try StoreHarness(); defer { t.cleanup() }
        let pkg = try await t.store.capture(t.blobDraft(bytes: 100))
        // Removing the parked package fails after the row is gone: content/ cannot be modified.
        let content = pkg.directoryURL.appendingPathComponent("content")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: content.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath:
                    t.stagedDeletion(pkg).appendingPathComponent("content").path) }

        _ = try await t.store.delete(captureID: pkg.metadata.captureID)

        #expect(try t.store.index.count() == 0)
        #expect(!FileManager.default.fileExists(atPath: pkg.directoryURL.path))
    }

    @Test func deleteFailingBeforeRemovalLeavesJobsClaimable() async throws {
        let t = try StoreHarness(); defer { t.cleanup() }
        _ = try t.store.destinations.connect(t.destination)
        let pkg = try await t.store.capture(t.blobDraft(bytes: 100))
        // A stuck leftover from an earlier attempt makes the delete throw before the row is removed.
        let leftover = t.stagedDeletion(pkg).appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: leftover.appendingPathComponent("f"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: leftover.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: leftover.path) }

        await #expect(throws: (any Error).self) { _ = try await t.store.delete(captureID: pkg.metadata.captureID) }

        #expect(try t.store.index.count() == 1)
        #expect(try t.store.jobs.jobs(captureID: pkg.metadata.captureID).map(\.cancelRequested) == [false])
        let adapter = t.adapter
        #expect(await t.store.makeWorker(adapterFor: { _ in adapter }, owner: "app").runOnce().synced == 1)
    }

    @Test func facadeRetryRevivesBlockedJob() async throws {
        let t = try StoreHarness(); defer { t.cleanup() }
        #expect(try t.store.retryAll() == 0)  // no destination
        _ = try t.store.destinations.connect(t.destination)
        let pkg = try await t.store.capture(t.blobDraft(bytes: 100))
        t.faults.failBeforeWrite("\(pkg.relativeDirectory)/\(pkg.metadata.attachments[0].relativePath)", .quotaExceeded)
        let adapter = t.adapter
        let worker = t.store.makeWorker(adapterFor: { _ in adapter }, owner: "app")
        #expect(await worker.runOnce().failed == 1)

        #expect(try t.store.retry(captureID: pkg.metadata.captureID) == 1)
        #expect(await worker.runOnce().synced == 1)
        #expect(try t.store.retryAll() == 0)
    }

    // Design §6.2: local delete also removes the capture's silver and gold, and their rows.
    @Test func deleteRemovesLocalEnrichments() async throws {
        let t = try StoreHarness(); defer { t.cleanup() }
        let fm = FileManager.default
        let pkg = try await t.store.capture(t.urlDraft())
        let other = try await t.store.capture(t.urlDraft("https://example.com/b"))
        let id = pkg.metadata.captureID
        for capture in [pkg, other] {
            for layer in [EnrichmentLayer.device, .server] {
                try t.store.enrichments.write(try enrichmentDocument(capture, layer, t.store), newAssets: [:])
            }
            try t.store.enrichmentTasks.set(captureID: capture.metadata.captureID, kind: .place, version: 1,
                                            status: "pending", now: Date())
        }

        _ = try await t.store.delete(captureID: id)

        #expect(!fm.fileExists(atPath: t.store.layout.enrichmentDirectory(.device, captureID: id).path))
        #expect(!fm.fileExists(atPath: t.store.layout.enrichmentDirectory(.server, captureID: id).path))
        let rows = try t.rawDatabase().query("SELECT capture_id FROM enrichment_tasks").map { $0.string("capture_id") }
        #expect(rows == [other.metadata.captureID])
        #expect(try t.store.enrichments.document(.server, captureID: other.metadata.captureID) != nil)
    }

    @Test func recoverSweepsEnrichmentLeftovers() async throws {
        let t = try StoreHarness(); defer { t.cleanup() }
        let fm = FileManager.default
        let pkg = try await t.store.capture(t.urlDraft())
        try t.store.enrichments.write(try enrichmentDocument(pkg, .device, t.store), newAssets: [:])
        let leftover = t.store.layout.enrichmentStagingDir.appendingPathComponent("x", isDirectory: true)
        try fm.createDirectory(at: leftover, withIntermediateDirectories: true)
        let orphan = t.store.layout.enrichmentDirectory(.server, captureID: UUID().uuidString.lowercased())
        try fm.createDirectory(at: orphan, withIntermediateDirectories: true)

        let report = try t.store.recover()

        // Enrichment staging belongs to the enrichment sweep, not to package staging recovery.
        #expect(report.removedStaging == 0)
        #expect(report.failed == 0)
        #expect(!fm.fileExists(atPath: leftover.path))
        #expect(!fm.fileExists(atPath: orphan.path))
        #expect(try t.store.enrichments.document(.device, captureID: pkg.metadata.captureID) != nil)
        #expect(try t.stagingContents().filter { $0 != "enrichments" }.isEmpty)
    }

    // The files were swapped in but the index update never happened (crash or failed transaction).
    @Test func recoverResyncsIndexWithEnrichmentFiles() async throws {
        let t = try StoreHarness(); defer { t.cleanup() }
        let pkg = try await t.store.capture(t.urlDraft())
        let untouched = try await t.store.capture(t.urlDraft("https://example.com/b"))
        let id = pkg.metadata.captureID
        try t.store.enrichments.write(try enrichmentDocument(pkg, .device, t.store, text: "quokka"), newAssets: [:])
        try t.store.enrichments.write(try enrichmentDocument(untouched, .server, t.store, text: "wombat"), newAssets: [:])
        let oldRevision = try #require(try deviceRevision(t, id))
        // A newer device document reaches disk; the database still describes the old one.
        try t.store.enrichments.write(try enrichmentDocument(pkg, .device, t.store, text: "platypus"), newAssets: [:])
        let raw = try t.rawDatabase()
        try raw.execute("UPDATE captures SET device_revision = ? WHERE capture_id = ?", [.text(oldRevision), .text(id)])
        try raw.execute("UPDATE captures_fts SET enrichment = 'quokka' WHERE capture_id = ?", [.text(id)])
        #expect(try search(t, "platypus").isEmpty)

        _ = try t.store.recover()

        let json = try Data(contentsOf: t.store.layout.enrichmentDirectory(.device, captureID: id)
            .appendingPathComponent(EnrichmentPaths.documentName))
        #expect(try deviceRevision(t, id) == sha256Hex(json))
        #expect(try search(t, "platypus") == [id])
        #expect(try search(t, "quokka").isEmpty)
        #expect(try search(t, "wombat") == [untouched.metadata.captureID])
        #expect(try t.store.enrichments.reconcileIndex() == 0)

        // Files removed without the index update: the revision and the text are cleared.
        try FileManager.default.removeItem(at: t.store.layout.enrichmentDirectory(.device, captureID: id))
        #expect(try t.store.enrichments.reconcileIndex() == 1)
        #expect(try deviceRevision(t, id) == nil)
        #expect(try search(t, "platypus").isEmpty)
    }

    // The index row was rebuilt (register resets the enrichment text) while the files survived.
    @Test func recoverRestoresSearchForReregisteredCapture() async throws {
        let t = try StoreHarness(); defer { t.cleanup() }
        let pkg = try await t.store.capture(t.urlDraft())
        let id = pkg.metadata.captureID
        try t.store.enrichments.write(try enrichmentDocument(pkg, .device, t.store, text: "quokka"), newAssets: [:])
        try t.store.enrichments.write(try enrichmentDocument(pkg, .server, t.store, text: "wombat"), newAssets: [:])
        let revision = try deviceRevision(t, id)
        try t.store.index.remove(captureID: id)

        let report = try t.store.recover()

        #expect(report.registered == 1)
        #expect(try search(t, "quokka") == [id])
        #expect(try search(t, "wombat") == [id])
        #expect(try deviceRevision(t, id) == revision)
    }

    // Recovery failed to register a valid package: its enrichments must survive the sweep.
    @Test func recoverKeepsEnrichmentsWhenRegistrationFails() async throws {
        let t = try StoreHarness(); defer { t.cleanup() }
        let fm = FileManager.default
        let pkg = try await t.store.capture(t.urlDraft())
        let id = pkg.metadata.captureID
        try t.store.enrichments.write(try enrichmentDocument(pkg, .server, t.store, text: "wombat"), newAssets: [:])
        try t.store.index.remove(captureID: id)
        let raw = try t.rawDatabase()
        try raw.execute("""
            CREATE TRIGGER boom BEFORE INSERT ON captures WHEN NEW.capture_id = '\(id)'
            BEGIN SELECT RAISE(ABORT, 'boom'); END
            """)
        let leftover = t.store.layout.enrichmentStagingDir.appendingPathComponent("x", isDirectory: true)
        try fm.createDirectory(at: leftover, withIntermediateDirectories: true)

        let report = try t.store.recover()

        #expect(report.failed > 0)
        #expect(fm.fileExists(atPath: t.store.layout.enrichmentDirectory(.server, captureID: id).path))
        #expect(!fm.fileExists(atPath: leftover.path))

        try raw.execute("DROP TRIGGER boom")
        #expect(try t.store.recover().registered == 1)
        #expect(try search(t, "wombat") == [id])
    }
}

private func deviceRevision(_ t: StoreHarness, _ captureID: String) throws -> String? {
    try t.rawDatabase().query("SELECT device_revision FROM captures WHERE capture_id = ?", [.text(captureID)]).first?
        .string("device_revision")
}

private func search(_ t: StoreHarness, _ q: String) throws -> [String] {
    try t.store.index.page(CaptureFilter(searchText: q), after: nil, limit: 50).map(\.id)
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func enrichmentDocument(_ pkg: CommittedPackage, _ layer: EnrichmentLayer, _ store: HippoStore,
                                text: String = "summary") throws -> EnrichmentDocument {
    let digest = try #require(try store.index.packageDigest(captureID: pkg.metadata.captureID))
    let facet = Facet(version: 1, status: .ok, generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                      provenance: "test", data: .object(["text": .string(text)]))
    return EnrichmentDocument(schemaVersion: 1, captureID: pkg.metadata.captureID, layer: layer,
                              packageDigest: digest, producer: EnrichmentProducer(name: "t", version: "1", build: "1"),
                              generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                              facets: [FacetKind.summary.rawValue: facet])
}

@Suite struct HippoStoreLogTests {
    @Test func captureLogsSaved() async throws {
        let t = try StoreHarness(); defer { t.cleanup() }
        let pkg = try await t.store.capture(t.urlDraft())
        let events = t.store.log.events(captureID: pkg.metadata.captureID.description, from: Date().addingTimeInterval(-86_400))
        #expect(events.map(\.event) == [.captureSaved])
        #expect(events.first?.trigger == "share_extension")
        #expect(events.first?.proc == .app)

        let share = try HippoStore.open(root: t.root, producer: Producer(appVersion: "0.1.0", build: "1", osVersion: "test"),
                                        process: .share)
        let pkg2 = try await share.capture(t.urlDraft("https://example.com/b"))
        #expect(share.log.events(captureID: pkg2.metadata.captureID.description, from: Date().addingTimeInterval(-86_400)).first?.proc == .share)
    }

    @Test func deleteLogsDeleted() async throws {
        let t = try StoreHarness(); defer { t.cleanup() }
        let pkg = try await t.store.capture(t.urlDraft())
        let id = pkg.metadata.captureID
        _ = try await t.store.delete(captureID: id)
        let events = t.store.log.events(captureID: id, from: Date().addingTimeInterval(-86_400))
        #expect(events.map(\.event) == [.captureSaved, .captureDeleted])
    }

    @Test func failedCommitLogsGlobalSaveFailed() async throws {
        let t = try StoreHarness(); defer { t.cleanup() }
        let empty = CaptureDraft(captureID: UUID(), startedAt: Date(), timeZone: TimeZone(identifier: "UTC")!,
                                 method: .shareExtension)
        await #expect(throws: CaptureError.emptyCapture) { try await t.store.capture(empty) }
        let globals = t.store.log.globalEvents(limit: 10, before: nil)
        #expect(globals.map(\.event) == [.captureSaveFailed])
        #expect(globals.first?.code == "empty_capture")
    }
}
