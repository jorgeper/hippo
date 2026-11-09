import Foundation
import Testing
import CaptureCore
import LocalRepository
@testable import SyncEngine
import FilesystemAdapter

/// A harness with `captures` captures synced through the worker, and a `HippoStore` on the same root that
/// the detector removes captures with (as the app wires it).
private struct Setup {
    let h: SyncHarness
    let store: HippoStore
    let pkgs: [CommittedPackage]
    let dest = "dest-fs"

    init(captures: Int = 2) async throws {
        h = try SyncHarness()
        let clock = h.clock
        store = try HippoStore.open(root: h.root, producer: Producer(appVersion: "0.1.0", build: "1", osVersion: "test"),
                                    leaseWaitLimit: .seconds(1), now: { clock.now })
        var made: [CommittedPackage] = []
        for _ in 0..<captures { made.append(try await h.capture()) }
        pkgs = made
        let pass = await h.worker().runOnce(maxJobs: 100)
        precondition(pass.synced == captures)
    }

    func id(_ i: Int) -> String { pkgs[i].metadata.captureID }

    func detector(_ adapter: (any StorageAdapter)? = nil,
                  removeLocally: (@Sendable (String) async throws -> Void)? = nil) -> RemoteChangeDetector {
        let a: any StorageAdapter = adapter ?? h.adapter
        let clock = h.clock, store = store
        return RemoteChangeDetector(layout: h.layout, index: h.index, jobs: h.jobs, remoteState: h.remoteState,
                                    trims: h.trims, destinations: h.destinations, adapterFor: { _ in a },
                                    removeLocally: removeLocally ?? { try await store.removeAfterRemoteDelete(captureID: $0) },
                                    now: { clock.now }, log: h.log)
    }

    var cursor: String? { try? h.remoteState.changeCursor(destinationID: dest) }

    /// The first run: saves a cursor and lists nothing.
    func baseline() async {
        let r = await detector().run()
        precondition(r == RemoteChangeReport())
    }

    /// A detector whose `listChanges` returns `changes` once, as one page.
    func scripted(_ changes: [RemoteChange]) -> RemoteChangeDetector {
        detector(HookedAdapter(inner: h.adapter, changes: { _, _ in
            ChangePage(changes: changes, cursor: UUID().uuidString.lowercased(), hasMore: false)
        }))
    }

    func removeRemote(_ path: String) throws {
        try FileManager.default.removeItem(at: h.remote.appendingPathComponent(path))
    }

    func isIndexed(_ i: Int) -> Bool { (try? h.index.relativeDirectory(captureID: id(i))) != nil }

    func events(_ i: Int, _ name: LogEventName) -> [LogEvent] {
        h.log.events(captureID: id(i), from: Date(timeIntervalSince1970: 0)).filter { $0.event == name }
    }

    func globalEvents(_ name: LogEventName) -> [LogEvent] {
        h.log.globalEvents(limit: 200, before: nil).filter { $0.event == name }
    }

    func reviewItems() throws -> [ReviewItem] { try h.remoteState.reviewItems(destinationID: dest) }
}

private func isComplete(_ r: ValidationResult) -> Bool {
    if case .complete = r { return true }
    return false
}

@Suite struct RemoteChangeDetectorTests {
    @Test func firstRunBaselinesWithoutListing() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        // Changed in the destination before the baseline: history is never enumerated.
        try Data("{}".utf8).write(to: s.h.remote.appendingPathComponent(s.pkgs[0].metadataPath))

        let first = await s.detector().run()

        #expect(first == RemoteChangeReport())
        #expect(try s.h.remoteState.changeCursor(destinationID: s.dest) != nil)
        #expect(s.h.faults.operations.contains("latestCursor captures/"))
        #expect(!s.h.faults.operations.contains("list captures/"))

        let second = await s.detector().run()
        #expect(second == RemoteChangeReport())
        #expect(try s.h.remoteState.changed(captureID: s.id(0)) == nil)
        #expect(s.isIndexed(0) && s.isIndexed(1))
    }

    @Test func fileDeletesRemoveCapture() async throws {
        let s = try await Setup(captures: 10); defer { s.h.cleanup() }
        await s.baseline()
        let fm = FileManager.default
        let enrichmentDirs = [EnrichmentLayer.device, .server].map { s.h.layout.enrichmentDirectory($0, captureID: s.id(0)) }
        for dir in enrichmentDirs {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appendingPathComponent("enrichment.json"))
        }
        // The filesystem adapter reports each file of the folder as deleted.
        try s.removeRemote(s.pkgs[0].relativeDirectory)

        let r = await s.detector().run()

        #expect(r == RemoteChangeReport(removed: 1))
        #expect(!s.isIndexed(0))
        #expect((1..<10).allSatisfy(s.isIndexed))
        #expect(!fm.fileExists(atPath: s.pkgs[0].directoryURL.path))
        #expect(enrichmentDirs.allSatisfy { !fm.fileExists(atPath: $0.path) })
        #expect(s.events(0, .captureDeleted).map(\.trigger) == ["remote"])
        #expect(try s.h.remoteState.localDeletedCaptureIDs().isEmpty)
        #expect(try s.h.remoteState.changed(captureID: s.id(0)) == nil)
        #expect(try s.reviewItems().isEmpty)
    }

    @Test func folderDeleteEntryRemovesCapture() async throws {
        let s = try await Setup(captures: 10); defer { s.h.cleanup() }
        await s.baseline()

        let r = await s.scripted([.deleted(relativePath: s.pkgs[0].relativeDirectory)]).run()

        #expect(r == RemoteChangeReport(removed: 1))
        #expect(!s.isIndexed(0))
        #expect(s.events(0, .captureDeleted).map(\.trigger) == ["remote"])
    }

    @Test func markerDeleteAloneRemovesCapture() async throws {
        let s = try await Setup(captures: 10); defer { s.h.cleanup() }
        await s.baseline()
        try s.removeRemote(s.pkgs[0].markerPath)

        let r = await s.detector().run()

        #expect(r == RemoteChangeReport(removed: 1))
        #expect(!s.isIndexed(0))
    }

    @Test func attachmentDeleteMarksChangedNotRemoved() async throws {
        let s = try await Setup(captures: 10); defer { s.h.cleanup() }
        await s.baseline()
        try s.removeRemote(s.pkgs[0].attachmentPath)

        let r = await s.detector().run()

        #expect(r == RemoteChangeReport(changed: 1))
        #expect(s.isIndexed(0))
        let record = try #require(try s.h.remoteState.changed(captureID: s.id(0)))
        #expect(record.paths == [s.pkgs[0].metadata.attachments[0].relativePath])
        #expect(record.destinationID == s.dest)
        let logged = s.events(0, .remoteChanged)
        #expect(logged.count == 1)
        #expect(logged.first?.code == nil)
        #expect(logged.first?.dest == "filesystem")
    }

    @Test func metadataEditMarksChanged() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        await s.baseline()
        try Data("{}".utf8).write(to: s.h.remote.appendingPathComponent(s.pkgs[0].metadataPath))

        let r = await s.detector().run()

        #expect(r == RemoteChangeReport(changed: 1))
        #expect(try s.h.remoteState.changed(captureID: s.id(0))?.paths == ["metadata.json"])
        #expect(try s.h.remoteState.changed(captureID: s.id(1)) == nil)
        #expect(s.isIndexed(0))
    }

    @Test func matchingUpsertClearsChangedPath() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        await s.baseline()
        let url = s.h.remote.appendingPathComponent(s.pkgs[0].metadataPath)
        let original = try Data(contentsOf: url)
        try Data("{}".utf8).write(to: url)
        _ = await s.detector().run()
        try s.h.remoteState.markChanged(captureID: s.id(0), destinationID: s.dest, paths: ["content/other"], now: t0)

        try original.write(to: url)
        let r = await s.detector().run()

        #expect(r == RemoteChangeReport())
        #expect(try s.h.remoteState.changed(captureID: s.id(0))?.paths == ["content/other"])
    }

    @Test func unknownCaptureChangesAreIgnored() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        await s.baseline()
        let stranger = "captures/2026/11/08/" + UUID().uuidString.lowercased()
        let dir = s.h.remote.appendingPathComponent(stranger)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["metadata.json", "complete.json"] { try Data("{}".utf8).write(to: dir.appendingPathComponent(name)) }
        try Data("x".utf8).write(to: s.h.remote.appendingPathComponent("captures/notes.txt"))

        #expect(await s.detector().run() == RemoteChangeReport())
        try FileManager.default.removeItem(at: dir)
        #expect(await s.detector().run() == RemoteChangeReport())
        #expect(try s.h.remoteState.changedCount(destinationID: s.dest) == 0)
        #expect(try s.reviewItems().isEmpty)
        #expect(s.isIndexed(0) && s.isIndexed(1))
    }

    @Test func unverifiedCaptureIsProtected() async throws {
        let s = try await Setup(captures: 10); defer { s.h.cleanup() }
        await s.baseline()
        try s.h.jobs.requeue(jobID: try s.h.job(s.pkgs[0]).jobID)
        try s.removeRemote(s.pkgs[0].relativeDirectory)

        let r = await s.detector().run()

        #expect(r == RemoteChangeReport(protected: 1))
        #expect(s.isIndexed(0))
        #expect(s.events(0, .remoteChanged).map(\.code) == ["unverified"])
        #expect(try s.h.remoteState.changed(captureID: s.id(0)) == nil)
        #expect(try s.reviewItems().isEmpty)
        // Its receipts described files that are gone, so the next upload sends the whole package again.
        #expect(try s.h.jobs.receipts(jobID: try s.h.job(s.pkgs[0]).jobID).isEmpty)
        #expect(await s.h.worker().runOnce().synced == 1)
        #expect(isComplete(PackageValidator.validate(directory: s.h.remoteURL(s.pkgs[0]))))
    }

    @Test func unsyncedCaptureDropsStaleReceiptsInsteadOfChanged() async throws {
        let s = try await Setup(captures: 10); defer { s.h.cleanup() }
        await s.baseline()
        let job = try s.h.job(s.pkgs[0])
        try s.h.jobs.requeue(jobID: job.jobID)
        try s.removeRemote(s.pkgs[0].attachmentPath)

        let r = await s.detector().run()

        #expect(r == RemoteChangeReport())
        #expect(try s.h.remoteState.changed(captureID: s.id(0)) == nil)
        #expect(try s.h.jobs.receipts(jobID: job.jobID).map(\.relativePath) == ["metadata.json"])
        #expect(await s.h.worker().runOnce().synced == 1)
        #expect(FileManager.default.fileExists(atPath: s.h.remote.appendingPathComponent(s.pkgs[0].attachmentPath).path))
        #expect(isComplete(PackageValidator.validate(directory: s.h.remoteURL(s.pkgs[0]))))
    }

    @Test func failedLaterPageAppliesNothingAndKeepsCursor() async throws {
        let s = try await Setup(captures: 15); defer { s.h.cleanup() }
        await s.baseline()
        let start = s.cursor
        let dirs = s.pkgs.map(\.relativeDirectory)
        let adapter = HookedAdapter(inner: s.h.adapter, changes: { _, cursor in
            if cursor == "p1" { throw StorageError.offline }
            return ChangePage(changes: dirs.map { .deleted(relativePath: $0) }, cursor: "p1", hasMore: true)
        })

        let r = await s.detector(adapter).run()

        #expect(r == RemoteChangeReport(code: "offline"))
        #expect((0..<15).allSatisfy(s.isIndexed))
        #expect(try s.reviewItems().isEmpty)
        #expect(s.cursor == start)
    }

    @Test func softLimitQueuesReviewAndSavesCursor() async throws {
        let s = try await Setup(captures: 10); defer { s.h.cleanup() }
        await s.baseline()
        let dir = s.pkgs[0].relativeDirectory, attachment = s.pkgs[1].attachmentPath
        // Paths that aren't capture directories: listed and counted, never applied.
        let junk = (0..<1998).map { RemoteChange.deleted(relativePath: "captures/junk-\($0).txt") }
        let first = [RemoteChange.deleted(relativePath: dir), .deleted(relativePath: attachment)] + junk[..<998]
        let second = Array(junk[998...])
        let adapter = HookedAdapter(inner: s.h.adapter, changes: { _, cursor in
            cursor == "p1" ? ChangePage(changes: second, cursor: "p2", hasMore: true)
                : ChangePage(changes: first, cursor: "p1", hasMore: true)
        })

        let r = await s.detector(adapter).run()

        // One of ten would be removed from a complete listing; an unfinished one only queues it for review.
        #expect(r == RemoteChangeReport(changed: 1, reviewQueued: 1))
        #expect(s.isIndexed(0))
        #expect(try s.reviewItems().map(\.captureID) == [s.id(0)])
        #expect(try s.reviewItems().map(\.reason) == ["threshold"])
        #expect(try s.h.remoteState.changed(captureID: s.id(1))?.paths == [s.pkgs[1].metadata.attachments[0].relativePath])
        #expect(s.cursor == "p2")
    }

    @Test func cancelDuringRemovalsSavesNothing() async throws {
        let s = try await Setup(captures: 30); defer { s.h.cleanup() }
        await s.baseline()
        let start = try #require(s.cursor)
        let deletions = (0..<3).map { RemoteChange.deleted(relativePath: s.pkgs[$0].relativeDirectory) }
        let adapter = HookedAdapter(inner: s.h.adapter, changes: { _, cursor in
            ChangePage(changes: cursor == start ? deletions : [], cursor: "after", hasMore: false)
        })
        let calls = Counter(), store = s.store
        let interrupted = s.detector(adapter, removeLocally: { id in
            // The second removal is interrupted by the pass being cancelled.
            if calls.next() == 2 {
                withUnsafeCurrentTask { $0?.cancel() }
                throw CancellationError()
            }
            try await store.removeAfterRemoteDelete(captureID: id)
        })

        let r = await Task { await interrupted.run() }.value

        #expect(r.removed == 1)
        #expect((0..<3).filter { !s.isIndexed($0) }.count == 1)
        #expect(s.cursor == start)

        // The next run lists the same changes again; the capture already removed is no longer indexed.
        #expect(await s.detector(adapter).run() == RemoteChangeReport(removed: 2))
        #expect((0..<3).allSatisfy { !s.isIndexed($0) })
        #expect((3..<30).allSatisfy(s.isIndexed))
        #expect(s.cursor == "after")
    }

    @Test func thresholdQueuesReviewInsteadOfDeleting() async throws {
        let s = try await Setup(captures: 25); defer { s.h.cleanup() }
        await s.baseline()
        for pkg in s.pkgs { try s.removeRemote(pkg.relativeDirectory) }

        let r = await s.detector().run()

        #expect(r == RemoteChangeReport(reviewQueued: 25))
        #expect((0..<25).allSatisfy(s.isIndexed))
        let items = try s.reviewItems()
        #expect(Set(items.map(\.captureID)) == Set(s.pkgs.map(\.metadata.captureID)))
        #expect(items.allSatisfy { $0.reason == "threshold" })
        let review = s.globalEvents(.remoteReview)
        #expect(review.count == 1)
        #expect(review.first?.count == 25)
        #expect(review.first?.code == "threshold")
        #expect(review.first?.dest == "filesystem")
        #expect(s.events(0, .captureDeleted).isEmpty)
    }

    @Test func fractionThresholdWithFewCaptures() async throws {
        let two = try await Setup(captures: 10); defer { two.h.cleanup() }
        await two.baseline()
        for i in 0..<2 { try two.removeRemote(two.pkgs[i].relativeDirectory) }
        // 2 of 10 synced is more than 10 %.
        #expect(await two.detector().run() == RemoteChangeReport(reviewQueued: 2))
        #expect(two.isIndexed(0) && two.isIndexed(1))
        #expect(try two.reviewItems().map(\.reason) == ["threshold", "threshold"])

        let one = try await Setup(captures: 10); defer { one.h.cleanup() }
        await one.baseline()
        try one.removeRemote(one.pkgs[0].relativeDirectory)
        // 1 of 10 is exactly 10 %, not more.
        #expect(await one.detector().run() == RemoteChangeReport(removed: 1))
        #expect(!one.isIndexed(0))
    }

    @Test func rootGoneQueuesReview() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        await s.baseline()

        let r = await s.scripted([.deleted(relativePath: "captures")]).run()

        #expect(r == RemoteChangeReport(reviewQueued: 2))
        #expect(s.isIndexed(0) && s.isIndexed(1))
        #expect(try s.reviewItems().map(\.reason) == ["root_missing", "root_missing"])
        #expect(s.globalEvents(.remoteReview).map(\.code) == ["root_missing"])
    }

    @Test func partitionFolderDeleteIsJudgedByTheValve() async throws {
        let s = try await Setup(captures: 10); defer { s.h.cleanup() }
        await s.baseline()
        // Every capture is under one day; its month folder going takes all of them.
        let month = s.pkgs[0].relativeDirectory.split(separator: "/").prefix(3).joined(separator: "/")

        let r = await s.scripted([.deleted(relativePath: month)]).run()

        #expect(r == RemoteChangeReport(reviewQueued: 10))
        #expect((0..<10).allSatisfy(s.isIndexed))
    }

    @Test func cursorResetListsAndQueuesReviewOnly() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        try s.h.remoteState.saveChangeCursor(destinationID: s.dest, cursor: "garbage", now: t0)
        try s.removeRemote(s.pkgs[0].relativeDirectory)

        let r = await s.detector().run()

        #expect(r == RemoteChangeReport(reviewQueued: 1, cursorReset: true))
        #expect(s.isIndexed(0) && s.isIndexed(1))
        let items = try s.reviewItems()
        #expect(items.map(\.captureID) == [s.id(0)])
        #expect(items.map(\.reason) == ["cursor_reset"])
        #expect(s.globalEvents(.remoteReview).map(\.code) == ["cursor_reset"])
        let cursor = try s.h.remoteState.changeCursor(destinationID: s.dest)
        #expect(cursor != nil && cursor != "garbage")
        // The new cursor works: the next pass sees no change.
        #expect(await s.detector().run() == RemoteChangeReport())
    }

    @Test func cursorResetListingFailureKeepsOldCursor() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        try s.h.remoteState.saveChangeCursor(destinationID: s.dest, cursor: "garbage", now: t0)
        try s.removeRemote(s.pkgs[0].relativeDirectory)
        let failing = HookedAdapter(inner: s.h.adapter, beforeListFolder: { _ in throw StorageError.offline })

        #expect(await s.detector(failing).run() == RemoteChangeReport(cursorReset: true, code: "offline"))
        #expect(s.cursor == "garbage")
        #expect(try s.reviewItems().isEmpty)
        #expect(s.globalEvents(.remoteReview).isEmpty)

        // The next run resets again and this time queues the review.
        #expect(await s.detector().run() == RemoteChangeReport(reviewQueued: 1, cursorReset: true))
        #expect(s.cursor != "garbage")
    }

    @Test func duplicateReviewItemsAreNotCountedTwice() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        await s.baseline()
        #expect(await s.scripted([.deleted(relativePath: "captures")]).run() == RemoteChangeReport(reviewQueued: 2))
        #expect(await s.scripted([.deleted(relativePath: "captures")]).run() == RemoteChangeReport())
        #expect(s.globalEvents(.remoteReview).map(\.count) == [2])
    }

    @Test func restoredMarkerCancelsDeletionInSamePass() async throws {
        let s = try await Setup(captures: 10); defer { s.h.cleanup() }
        await s.baseline()
        let marker = try #require(try await s.h.adapter.inspectFile(relativePath: s.pkgs[0].markerPath))

        let r = await s.scripted([.deleted(relativePath: s.pkgs[0].markerPath), .upserted(marker)]).run()

        #expect(r == RemoteChangeReport())
        #expect(s.isIndexed(0))
    }

    @Test func listingErrorEndsWithCode() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        await s.baseline()
        let adapter = HookedAdapter(inner: s.h.adapter, changes: { _, _ in throw StorageError.offline })

        #expect(await s.detector(adapter).run() == RemoteChangeReport(code: "offline"))
        #expect(s.isIndexed(0) && s.isIndexed(1))
    }

    @Test func resolveReviewRemoveAndKeep() async throws {
        let s = try await Setup(captures: 3); defer { s.h.cleanup() }
        func queue(_ ids: [String]) throws {
            try s.store.remoteState.addReviewItems(ids.map {
                ReviewItem(captureID: $0, destinationID: s.dest, reason: "threshold", createdAt: t0)
            })
        }

        // Keep: captures without trimmed files are requeued with every receipt cleared; a trimmed one is left.
        let attachment = s.pkgs[2].metadata.attachments[0]
        try s.store.trims.record(TrimmedAttachment(captureID: s.id(2), attachmentID: attachment.attachmentID,
                                                   relativePath: attachment.relativePath, byteCount: 1, sha256: "x",
                                                   destinationID: s.dest, state: .trimmed, trimmedAt: t0))
        try queue([s.id(0), s.id(1), s.id(2)])
        #expect(try await s.store.resolveReview(destinationID: s.dest, keep: true) == 3)
        for i in 0..<2 {
            let job = try s.h.job(s.pkgs[i])
            #expect(job.state == .pending)
            #expect(try s.h.jobs.receipts(jobID: job.jobID).isEmpty)
        }
        let trimmedJob = try s.h.job(s.pkgs[2])
        #expect(trimmedJob.state == .synced)
        #expect(try !s.h.jobs.receipts(jobID: trimmedJob.jobID).isEmpty)
        #expect(try s.reviewItems().isEmpty)
        #expect((0..<3).allSatisfy(s.isIndexed))

        // Remove: every item's capture leaves the phone.
        try queue([s.id(0), s.id(1)])
        #expect(try await s.store.resolveReview(destinationID: s.dest, keep: false) == 2)
        #expect(!s.isIndexed(0) && !s.isIndexed(1) && s.isIndexed(2))
        #expect(s.events(0, .captureDeleted).map(\.trigger) == ["remote"])
        #expect(try s.reviewItems().isEmpty)
    }
}
