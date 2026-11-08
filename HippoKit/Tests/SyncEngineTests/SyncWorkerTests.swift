import Foundation
import Testing
import CaptureCore
import LocalRepository
import SyncEngine
import FilesystemAdapter

private func isComplete(_ r: ValidationResult) -> Bool {
    if case .complete = r { return true }
    return false
}

/// Relative paths of every regular file under `dir`, sorted.
private func files(under dir: URL) -> [String] {
    let base = dir.resolvingSymlinksInPath().path
    let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])
    var out: [String] = []
    while let url = e?.nextObject() as? URL {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
        out.append(String(url.resolvingSymlinksInPath().path.dropFirst(base.count + 1)))
    }
    return out.sorted()
}

private func expectByteIdentical(_ h: SyncHarness, _ pkg: CommittedPackage) throws {
    let local = files(under: pkg.directoryURL)
    #expect(files(under: h.remoteURL(pkg)) == local)
    for path in local {
        #expect(try Data(contentsOf: h.remoteURL(pkg).appendingPathComponent(path))
                == Data(contentsOf: pkg.directoryURL.appendingPathComponent(path)))
    }
}

@Suite struct SyncWorkerTests {
    @Test func uploadsAllFilesThenMarkerLast() async throws {
        let h = try SyncHarness(); defer { h.cleanup() }
        let pkg = try await h.capture()

        let result = await h.worker().runOnce()

        #expect(result == SyncPassResult(synced: 1, failed: 0, idle: false))
        let job = try h.job(pkg)
        #expect(job.state == .synced)
        #expect(job.lastErrorCode == nil)
        #expect(h.uploads == ["upload \(pkg.metadataPath)", "upload \(pkg.attachmentPath)", "upload \(pkg.markerPath)"])
        // Every other file was verified remotely before the marker went up.
        let ops = h.faults.operations
        #expect(Array(ops.prefix(2)) == ["ensure \(pkg.relativeDirectory)", "ensure \(pkg.relativeDirectory)/content"])
        let markerUpload = try #require(ops.firstIndex(of: "upload \(pkg.markerPath)"))
        for path in [pkg.metadataPath, pkg.attachmentPath] {
            #expect(try #require(ops.lastIndex(of: "inspect \(path)")) < markerUpload)
        }
        #expect(isComplete(PackageValidator.validate(directory: h.remoteURL(pkg))))
        try expectByteIdentical(h, pkg)
        #expect(try h.jobs.receipts(jobID: job.jobID).map(\.relativePath).sorted()
                == (pkg.marker.files.map(\.relativePath) + ["complete.json"]).sorted())
    }

    @Test func urlOnlyCaptureHasNoRemoteContentFolder() async throws {
        let h = try SyncHarness(); defer { h.cleanup() }
        let pkg = try await h.capture(attachmentBytes: nil)

        #expect(await h.worker().runOnce().synced == 1)
        #expect(h.uploads == ["upload \(pkg.metadataPath)", "upload \(pkg.markerPath)"])
        #expect(!h.faults.operations.contains("ensure \(pkg.relativeDirectory)/content"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: h.remoteURL(pkg).path).sorted()
                == ["complete.json", "metadata.json"])
        #expect(isComplete(PackageValidator.validate(directory: h.remoteURL(pkg))))
    }

    @Test func failureMidPackageNeverUploadsMarker() async throws {
        let h = try SyncHarness(); defer { h.cleanup() }
        let pkg = try await h.capture()
        h.faults.failBeforeWrite(pkg.attachmentPath, .transient(code: "server_500"))

        let result = await h.worker().runOnce()

        #expect(result == SyncPassResult(synced: 0, failed: 1, idle: false))
        let job = try h.job(pkg)
        #expect(job.state == .retryableFailure)
        #expect(job.lastErrorCode == "transient:server_500")
        #expect(job.attemptCount == 1)
        #expect(job.nextAttemptAt == t0.addingTimeInterval(30))
        #expect(!h.uploads.contains("upload \(pkg.markerPath)"))
        #expect(!FileManager.default.fileExists(atPath: h.remoteURL(pkg).appendingPathComponent("complete.json").path))
        #expect(!isComplete(PackageValidator.validate(directory: h.remoteURL(pkg))))

        // Not due yet; then due, and it completes.
        #expect(await h.worker().runOnce().idle)
        h.clock.set(t0.addingTimeInterval(30))
        #expect(await h.worker().runOnce() == SyncPassResult(synced: 1, failed: 0, idle: false))
        #expect(isComplete(PackageValidator.validate(directory: h.remoteURL(pkg))))
    }

    @Test func interruptedUploadResumesWithoutDuplicates() async throws {
        let h = try SyncHarness(); defer { h.cleanup() }
        let pkg = try await h.capture(attachmentBytes: 3 << 20)
        h.faults.failAfterBytes(pkg.attachmentPath, 2 << 20, .offline)

        #expect(await h.worker().runOnce() == SyncPassResult(synced: 0, failed: 1, idle: false))
        var job = try h.job(pkg)
        #expect(job.state == .retryableFailure)
        #expect(job.lastErrorCode == "offline")
        #expect(try h.jobs.checkpoint(jobID: job.jobID, relativePath: pkg.metadata.attachments[0].relativePath) != nil)
        #expect(!h.uploads.contains("upload \(pkg.markerPath)"))

        h.clock.set(try #require(job.nextAttemptAt))
        #expect(await h.worker().runOnce() == SyncPassResult(synced: 1, failed: 0, idle: false))
        job = try h.job(pkg)
        #expect(job.state == .synced)
        #expect(try h.jobs.checkpoint(jobID: job.jobID, relativePath: pkg.metadata.attachments[0].relativePath) == nil)
        try expectByteIdentical(h, pkg)
        // Exactly one package directory and no leftover temp files.
        #expect(try FileManager.default.contentsOfDirectory(atPath: h.remote.path) == ["captures"])
        let day = h.remoteURL(pkg).deletingLastPathComponent()
        #expect(try FileManager.default.contentsOfDirectory(atPath: day.path) == [pkg.metadata.captureID])
        #expect(isComplete(PackageValidator.validate(directory: h.remoteURL(pkg))))
    }

    @Test func writeButThrowIsResolvedByInspection() async throws {
        let h = try SyncHarness(); defer { h.cleanup() }
        let pkg = try await h.capture()
        h.faults.writeButThrow(pkg.attachmentPath, .transient(code: "response_lost"))

        #expect(await h.worker().runOnce().failed == 1)
        let failed = try h.job(pkg)
        #expect(failed.state == .retryableFailure)
        #expect(failed.lastErrorCode == "transient:response_lost")

        h.clock.set(try #require(failed.nextAttemptAt))
        #expect(await h.worker().runOnce() == SyncPassResult(synced: 1, failed: 0, idle: false))
        #expect(try h.job(pkg).state == .synced)
        // The second pass found the file by inspection and did not upload it again.
        #expect(h.uploads.filter { $0 == "upload \(pkg.attachmentPath)" }.count == 1)
        try expectByteIdentical(h, pkg)
        #expect(isComplete(PackageValidator.validate(directory: h.remoteURL(pkg))))
    }

    @Test func differentRemoteContentBlocks() async throws {
        let h = try SyncHarness(); defer { h.cleanup() }
        let pkg = try await h.capture()
        let squatter = Data("{\"not\":\"ours\"}".utf8)
        try FileManager.default.createDirectory(at: h.remoteURL(pkg), withIntermediateDirectories: true)
        try squatter.write(to: h.remoteURL(pkg).appendingPathComponent("metadata.json"))

        #expect(await h.worker().runOnce() == SyncPassResult(synced: 0, failed: 1, idle: false))
        let job = try h.job(pkg)
        #expect(job.state == .blocked)
        #expect(job.lastErrorCode == "remote_conflict")
        #expect(job.nextAttemptAt == nil)
        #expect(h.uploads.isEmpty)
        #expect(try Data(contentsOf: h.remoteURL(pkg).appendingPathComponent("metadata.json")) == squatter)
        #expect(files(under: h.remoteURL(pkg)) == ["metadata.json"])
        // Blocked jobs are not retried automatically.
        h.clock.set(t0.addingTimeInterval(86_400))
        #expect(await h.worker().runOnce().idle)
    }

    @Test func conflictFromUploadBlocks() async throws {
        let h = try SyncHarness(); defer { h.cleanup() }
        let pkg = try await h.capture()
        let other = Data("different bytes".utf8)
        let remoteAttachment = h.remote.appendingPathComponent(pkg.attachmentPath)
        try FileManager.default.createDirectory(at: remoteAttachment.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try other.write(to: remoteAttachment)
        // Inspection misses the file (e.g. a stale listing), so the upload itself reports the conflict.
        let path = pkg.attachmentPath
        let adapter = HookedAdapter(inner: h.adapter, hideFromInspect: { $0 == path })

        #expect(await h.worker(adapter).runOnce().failed == 1)
        let job = try h.job(pkg)
        #expect(job.state == .blocked)
        #expect(job.lastErrorCode == "remote_conflict")
        #expect(try Data(contentsOf: remoteAttachment) == other)
        #expect(!h.uploads.contains("upload \(pkg.markerPath)"))
    }

    @Test func uploadThatDoesNotVerifyIsRetried() async throws {
        let h = try SyncHarness(); defer { h.cleanup() }
        let pkg = try await h.capture()
        // The upload succeeds but the file is not (yet) visible: the receipt alone is not trusted.
        let path = pkg.attachmentPath
        let adapter = HookedAdapter(inner: h.adapter, hideFromInspect: { $0 == path })

        #expect(await h.worker(adapter).runOnce().failed == 1)
        let job = try h.job(pkg)
        #expect(job.state == .retryableFailure)
        #expect(job.lastErrorCode == "verify_failed")
        #expect(job.nextAttemptAt == t0.addingTimeInterval(30))
        #expect(!h.uploads.contains("upload \(pkg.markerPath)"))
        #expect(try h.jobs.receipts(jobID: job.jobID).map(\.relativePath) == ["metadata.json"])
    }

    @Test func authFailureNeedsAuthentication() async throws {
        let h = try SyncHarness(); defer { h.cleanup() }
        let pkg = try await h.capture()
        h.faults.failBeforeWrite(pkg.metadataPath, .needsAuthentication)

        #expect(await h.worker().runOnce().failed == 1)
        let job = try h.job(pkg)
        #expect(job.state == .needsAuthentication)
        #expect(job.lastErrorCode == "needs_authentication")
        #expect(job.nextAttemptAt == nil)
        h.clock.set(t0.addingTimeInterval(86_400))
        #expect(await h.worker().runOnce().idle)
        #expect(FileManager.default.fileExists(atPath: pkg.directoryURL.appendingPathComponent("complete.json").path))
    }

    @Test func quotaBlocks() async throws {
        let h = try SyncHarness(); defer { h.cleanup() }
        let pkg = try await h.capture()
        h.faults.failBeforeWrite(pkg.attachmentPath, .quotaExceeded)

        #expect(await h.worker().runOnce().failed == 1)
        let job = try h.job(pkg)
        #expect(job.state == .blocked)
        #expect(job.lastErrorCode == "quota_exceeded")
        #expect(job.nextAttemptAt == nil)
        #expect(!h.uploads.contains("upload \(pkg.markerPath)"))
    }

    @Test func permanentErrorBlocks() async throws {
        let h = try SyncHarness(); defer { h.cleanup() }
        let pkg = try await h.capture()
        h.faults.failBeforeWrite(pkg.attachmentPath, .permanent(code: "invalid_path"))

        #expect(await h.worker().runOnce().failed == 1)
        let job = try h.job(pkg)
        #expect(job.state == .blocked)
        #expect(job.lastErrorCode == "permanent:invalid_path")
        #expect(job.nextAttemptAt == nil)
    }

    @Test func rateLimitedSchedulesRetryAfter() async throws {
        let h = try SyncHarness(); defer { h.cleanup() }
        let pkg = try await h.capture()
        h.faults.failBeforeWrite(pkg.attachmentPath, .rateLimited(retryAfter: 900))

        #expect(await h.worker(random: { 0 }).runOnce().failed == 1)
        let job = try h.job(pkg)
        #expect(job.state == .retryableFailure)
        #expect(job.lastErrorCode == "rate_limited")
        #expect(job.nextAttemptAt == t0.addingTimeInterval(900))

        h.clock.set(t0.addingTimeInterval(899))
        #expect(await h.worker().runOnce().idle)
        h.clock.set(t0.addingTimeInterval(900))
        #expect(await h.worker().runOnce().synced == 1)
    }

    @Test func expiredCheckpointRestartsOnceWithinThePass() async throws {
        let h = try SyncHarness(); defer { h.cleanup() }
        let pkg = try await h.capture()
        let jobID = try h.job(pkg).jobID
        let entry = pkg.metadata.attachments[0].relativePath
        try h.jobs.saveCheckpoint(jobID: jobID, relativePath: entry, data: Data("{\"temp\":\"gone\"}".utf8))

        #expect(await h.worker().runOnce() == SyncPassResult(synced: 1, failed: 0, idle: false))
        #expect(h.uploads.filter { $0 == "upload \(pkg.attachmentPath)" }.count == 2)
        #expect(try h.jobs.checkpoint(jobID: jobID, relativePath: entry) == nil)
        try expectByteIdentical(h, pkg)
    }

    @Test func checkpointExpiredTwiceIsRetryable() async throws {
        let h = try SyncHarness(); defer { h.cleanup() }
        let pkg = try await h.capture()
        let path = pkg.attachmentPath
        let adapter = HookedAdapter(inner: h.adapter, beforeUpload: { p in
            if p == path { throw StorageError.checkpointExpired }
        })

        #expect(await h.worker(adapter).runOnce().failed == 1)
        let job = try h.job(pkg)
        #expect(job.state == .retryableFailure)
        #expect(job.lastErrorCode == "checkpoint_expired")
        #expect(job.nextAttemptAt == t0.addingTimeInterval(30))
    }

    @Test func cancelRequestedStopsBeforeMarker() async throws {
        let h = try SyncHarness(); defer { h.cleanup() }
        let pkg = try await h.capture()
        let (jobs, path, captureID) = (h.jobs, pkg.attachmentPath, pkg.metadata.captureID)
        // metadata.json is receipted first; the cancel arrives while the attachment uploads.
        let adapter = HookedAdapter(inner: h.adapter, beforeUpload: { p in
            if p == path { try jobs.requestCancel(captureID: captureID) }
        })

        #expect(await h.worker(adapter).runOnce() == SyncPassResult(synced: 0, failed: 1, idle: false))
        let job = try h.job(pkg)
        #expect(job.state == .paused)
        #expect(job.lastErrorCode == "cancelled")
        #expect(job.nextAttemptAt == nil)
        #expect(!h.faults.operations.contains("upload \(pkg.markerPath)"))
        #expect(!FileManager.default.fileExists(atPath: h.remoteURL(pkg).appendingPathComponent("complete.json").path))
    }

    @Test func cancelDuringLongUploadStopsAtNextChunk() async throws {
        let h = try SyncHarness(); defer { h.cleanup() }
        let pkg = try await h.capture(attachmentBytes: 3 << 20)
        let (jobs, path, captureID) = (h.jobs, pkg.attachmentPath, pkg.metadata.captureID)
        let adapter = HookedAdapter(inner: h.adapter, onCheckpoint: { p in
            if p == path { try jobs.requestCancel(captureID: captureID) }
        })

        #expect(await h.worker(adapter).runOnce() == SyncPassResult(synced: 0, failed: 1, idle: false))
        let job = try h.job(pkg)
        #expect(job.state == .paused)
        #expect(job.lastErrorCode == "cancelled")
        #expect(try h.jobs.receipts(jobID: job.jobID).map(\.relativePath) == ["metadata.json"])
        #expect(try h.jobs.checkpoint(jobID: job.jobID, relativePath: pkg.metadata.attachments[0].relativePath) == nil)
        #expect(h.uploads.filter { $0 == "upload \(path)" }.count == 1)
        #expect(!FileManager.default.fileExists(atPath: h.remote.appendingPathComponent(path).path))
        #expect(!h.uploads.contains("upload \(pkg.markerPath)"))
    }

    @Test func leaseStolenMidUploadAbortsWithoutTouchingTheJob() async throws {
        let h = try SyncHarness(); defer { h.cleanup() }
        let pkg = try await h.capture(attachmentBytes: 3 << 20)
        let (jobs, clock, path) = (h.jobs, h.clock, pkg.attachmentPath)
        let saves = Counter()
        // After the first chunk is checkpointed, the upload stalls past the lease and another worker claims the job.
        let adapter = HookedAdapter(inner: h.adapter, onCheckpoint: { p in
            guard p == path, saves.next() == 2 else { return }
            clock.set(t0.addingTimeInterval(500))
            guard try jobs.claimNext(owner: "thief", now: clock.now, lease: 120) != nil else {
                throw StorageError.permanent(code: "test_claim_failed")
            }
        })

        #expect(await h.worker(adapter).runOnce() == SyncPassResult(synced: 0, failed: 0, idle: false))
        let job = try h.job(pkg)
        #expect(job.state == .uploading)
        // Only the thief's reclaim counted the expired lease; the old owner recorded nothing.
        #expect(job.attemptCount == 1)
        #expect(job.lastErrorCode == "lease_expired")
        #expect(try h.db.query("SELECT lease_owner FROM jobs WHERE job_id = ?", [.text(job.jobID)])[0]
                    .string("lease_owner") == "thief")
        #expect(try h.jobs.receipts(jobID: job.jobID).map(\.relativePath) == ["metadata.json"])
        // The old owner's second checkpoint was never written over the first.
        let saved = try #require(try h.jobs.checkpoint(jobID: job.jobID,
                                                       relativePath: pkg.metadata.attachments[0].relativePath))
        let offset = (try JSONSerialization.jsonObject(with: saved) as? [String: Any])?["offset"] as? Int
        #expect(offset == 1 << 20)
        #expect(!FileManager.default.fileExists(atPath: h.remote.appendingPathComponent(path).path))
        #expect(!h.uploads.contains("upload \(pkg.markerPath)"))
    }

    @Test func workersWithSamePrefixHaveDistinctLeaseOwners() async throws {
        let h = try SyncHarness(); defer { h.cleanup() }
        let pkg = try await h.capture(attachmentBytes: 3 * FilesystemAdapter.chunkSize)
        let adapter = PausingAdapter(inner: h.adapter, path: pkg.attachmentPath)
        let a = h.worker(adapter, owner: "app")
        let b = h.worker(owner: "app")
        #expect(a.leaseOwner != b.leaseOwner)
        #expect(a.leaseOwner.hasPrefix("app#"))
        #expect(b.leaseOwner.hasPrefix("app#"))
        let suffix = String(a.leaseOwner.dropFirst("app#".count))
        #expect(UUID(uuidString: suffix) != nil)
        #expect(suffix == suffix.lowercased())

        let run = Task { let r = await a.runOnce(); adapter.paused.open(); return r }
        await adapter.paused.wait()
        // A is suspended mid-file holding the job under its own lease owner.
        let jobID = try h.job(pkg).jobID
        #expect(try h.db.query("SELECT lease_owner FROM jobs WHERE job_id = ?", [.text(jobID)])[0]
                    .string("lease_owner") == a.leaseOwner)
        #expect(await b.runOnce().idle)
        // The bare prefix owns nothing.
        #expect(try h.jobs.renewLease(jobID: jobID, owner: "app", now: h.clock.now, lease: 120) == false)
        adapter.release.open()

        #expect(await run.value == SyncPassResult(synced: 1, failed: 0, idle: false))
        #expect(try h.job(pkg).state == .synced)
    }

    @Test func claimErrorIsNotIdle() async throws {
        let h = try SyncHarness(); defer { h.cleanup() }
        _ = try await h.capture()
        try h.db.execute("ALTER TABLE jobs RENAME TO jobs_unavailable")
        #expect(await h.worker().runOnce() == SyncPassResult(synced: 0, failed: 1, idle: false))
        #expect(h.faults.operations.isEmpty)
    }

    @Test func taskCancellationLeavesTheJobToItsLease() async throws {
        let h = try SyncHarness(); defer { h.cleanup() }
        let pkg = try await h.capture()
        let path = pkg.attachmentPath
        let adapter = HookedAdapter(inner: h.adapter, beforeUpload: { p in
            if p == path { throw CancellationError() }
        })

        #expect(await h.worker(adapter).runOnce() == SyncPassResult(synced: 0, failed: 0, idle: false))
        let job = try h.job(pkg)
        #expect(job.state == .uploading)
        #expect(job.attemptCount == 0)
        #expect(job.lastErrorCode == nil)

        // Still leased: nobody can take it until the 120 s lease runs out.
        h.clock.set(t0.addingTimeInterval(119))
        #expect(await h.worker().runOnce().idle)
        h.clock.set(t0.addingTimeInterval(120))
        #expect(await h.worker().runOnce().synced == 1)
        #expect(isComplete(PackageValidator.validate(directory: h.remoteURL(pkg))))
    }

    @Test func invalidLocalPackageBlocks() async throws {
        let h = try SyncHarness(); defer { h.cleanup() }
        let pkg = try await h.capture()
        let attachment = pkg.directoryURL.appendingPathComponent(pkg.metadata.attachments[0].relativePath)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: attachment.path)
        try Data("tampered".utf8).write(to: attachment)

        #expect(await h.worker().runOnce().failed == 1)
        let job = try h.job(pkg)
        #expect(job.state == .blocked)
        #expect(job.lastErrorCode == "local_package_invalid")
        #expect(h.faults.operations.isEmpty)
    }

    @Test func reclaimBackoffUsesTheWorkersPolicyAndRandomSource() async throws {
        let h = try SyncHarness(); defer { h.cleanup() }
        let pkg = try await h.capture()
        let job = try h.job(pkg)
        // Two earlier lease expiries; the worker's claim is the third and parks the job with a backoff.
        try h.db.execute("""
            UPDATE jobs SET state = 'uploading', attempt_count = 2, lease_owner = 'ghost', lease_expires_at_ms = ?
            WHERE job_id = ?
            """, [.int(Int64(t0.timeIntervalSince1970 * 1000) - 1), .text(job.jobID)])
        let adapter = h.adapter
        let clock = h.clock
        let worker = SyncWorker(layout: h.layout, jobs: h.jobs, destinations: h.destinations, index: h.index,
                                adapterFor: { _ in adapter }, owner: "w", policy: RetryPolicy(base: 1000, cap: 1000),
                                now: { clock.now }, random: { 0.5 })

        _ = await worker.runOnce()

        let parked = try h.job(pkg)
        #expect(parked.state == .retryableFailure)
        // 0.5 * min(1000, 1000 * 2^2) = 500 s; the default policy would give 0.5 * 120 = 60 s.
        let retryAt = try #require(try h.db.query("SELECT next_attempt_at_ms FROM jobs WHERE job_id = ?",
                                                  [.text(job.jobID)])[0].int("next_attempt_at_ms"))
        #expect(retryAt == Int64(t0.timeIntervalSince1970 * 1000) + 500_000)
    }

    @Test func syncedJobIsNotReclaimed() async throws {
        let h = try SyncHarness(); defer { h.cleanup() }
        let pkg = try await h.capture()
        #expect(await h.worker().runOnce().synced == 1)
        let ops = h.faults.operations

        h.clock.set(t0.addingTimeInterval(86_400))
        #expect(await h.worker().runOnce() == SyncPassResult(synced: 0, failed: 0, idle: true))
        #expect(h.faults.operations == ops)
        #expect(try h.job(pkg).state == .synced)
    }

    @Test func runOnceStopsAtMaxJobs() async throws {
        let h = try SyncHarness(); defer { h.cleanup() }
        for _ in 0..<3 { _ = try await h.capture() }
        #expect(await h.worker().runOnce(maxJobs: 2) == SyncPassResult(synced: 2, failed: 0, idle: false))
        #expect(await h.worker().runOnce() == SyncPassResult(synced: 1, failed: 0, idle: false))
        #expect(await h.worker().runOnce().idle)
    }

    @Test func noOneDriveOrDropboxImports() throws {
        let kit = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let allowed: Set<String> = ["Foundation", "CryptoKit", "SQLite3", "CaptureCore", "LocalRepository", "os",
                                    "Darwin", "Dispatch"]
        let forbidden = try Regex("Dropbox|OneDrive|Graph|SwiftyDropbox")
        var scanned = 0
        for dir in ["Sources/SyncEngine", "Sources/LocalRepository"] {
            let base = kit.appendingPathComponent(dir)
            let e = try #require(FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil))
            while let url = e.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                scanned += 1
                let name = url.lastPathComponent
                let text = try String(contentsOf: url, encoding: .utf8)
                #expect(text.firstMatch(of: forbidden) == nil, "provider name in \(dir)/\(name)")
                for line in text.split(separator: "\n") {
                    let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
                    guard let i = words.firstIndex(of: "import"),
                          words[..<i].allSatisfy({ $0.hasPrefix("@") || ["public", "internal", "package", "private", "fileprivate"].contains($0) }),
                          i + 1 < words.count else { continue }
                    let kinds: Set<String> = ["struct", "class", "enum", "protocol", "typealias", "func", "var", "let"]
                    let j = kinds.contains(words[i + 1]) && i + 2 < words.count ? i + 2 : i + 1
                    let module = String(words[j].split(separator: ".")[0])
                    #expect(allowed.contains(module), "\(dir)/\(name) imports \(module)")
                }
            }
        }
        #expect(scanned >= 8)
    }

    @Test func missingAttachmentBlocksUntilManualRetry() async throws {
        let h = try SyncHarness(); defer { h.cleanup() }
        let pkg = try await h.capture()
        let attachment = pkg.directoryURL.appendingPathComponent(pkg.metadata.attachments[0].relativePath)
        let hidden = attachment.appendingPathExtension("away")
        try FileManager.default.moveItem(at: attachment, to: hidden)

        #expect(await h.worker().runOnce().failed == 1)
        var job = try h.job(pkg)
        #expect(job.state == .blocked)
        #expect(job.lastErrorCode == "local_package_invalid")
        #expect(h.faults.operations.isEmpty)

        // Once the file is back, the user's Retry syncs it.
        try FileManager.default.moveItem(at: hidden, to: attachment)
        #expect(try h.jobs.retryNow(captureID: pkg.metadata.captureID) == 1)
        #expect(await h.worker().runOnce().synced == 1)
        job = try h.job(pkg)
        #expect(job.state == .synced)
    }

    @Test func quotaBlockedThenRetrySyncs() async throws {
        let h = try SyncHarness(); defer { h.cleanup() }
        let pkg = try await h.capture()
        h.faults.failBeforeWrite(pkg.attachmentPath, .quotaExceeded)
        #expect(await h.worker().runOnce().failed == 1)
        #expect(try h.job(pkg).state == .blocked)
        #expect(await h.worker().runOnce().idle)

        #expect(try h.jobs.retryAll(destinationID: "dest-fs") == 1)
        #expect(await h.worker().runOnce().synced == 1)
        let job = try h.job(pkg)
        #expect(job.state == .synced)
        #expect(isComplete(PackageValidator.validate(directory: h.remoteURL(pkg))))
    }

    @Test func retryDoesNotReviveCancelledJobs() async throws {
        let h = try SyncHarness(); defer { h.cleanup() }
        let pkg = try await h.capture()
        h.faults.failBeforeWrite(pkg.attachmentPath, .quotaExceeded)
        #expect(await h.worker().runOnce().failed == 1)
        try h.jobs.requestCancel(captureID: pkg.metadata.captureID)

        #expect(try h.jobs.retryNow(captureID: pkg.metadata.captureID) == 0)
        #expect(try h.jobs.retryAll(destinationID: "dest-fs") == 0)
        #expect(try h.job(pkg).state == .blocked)
        #expect(await h.worker().runOnce().idle)
    }
}
