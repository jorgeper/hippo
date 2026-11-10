import Foundation
import Testing
import CaptureCore
@testable import LocalRepository

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private struct Fixture {
    let h: IndexHarness
    let store: RemoteStateStore
    let destinations: DestinationStore

    init() throws {
        h = try IndexHarness()
        store = RemoteStateStore(db: h.db)
        destinations = DestinationStore(db: h.db)
        _ = try destinations.connect(Destination(id: "d", providerKind: "dropbox", accountIdentifier: "acct-1",
                                                 remoteRoot: "/Hippo", displayName: "Dropbox", status: .active))
    }
}

@Suite struct RemoteStateStoreTests {
    @Test func tombstoneLifecycle() throws {
        let f = try Fixture(); defer { f.h.cleanup() }
        try f.store.addTombstone(captureID: "a", relativeDirectory: "captures/2026/11/07/a", destinationID: "d",
                                 accountIdentifier: "acct-1", now: t0)
        try f.store.addTombstone(captureID: "b", relativeDirectory: "captures/2026/11/07/b", destinationID: "d",
                                 accountIdentifier: "acct-1", now: t0.addingTimeInterval(5))
        #expect(try f.store.hasTombstone(captureID: "a"))
        #expect(try f.store.pendingTombstoneCount(destinationID: "d") == 2)
        let due = try f.store.dueTombstones(destinationID: "d", accountIdentifier: "acct-1", now: t0.addingTimeInterval(10), limit: 10)
        #expect(due.map(\.captureID) == ["a", "b"])
        #expect(due[0].attemptCount == 0)
        #expect(due[0].nextAttemptAt == nil)
        #expect(try f.store.dueTombstones(destinationID: "d", accountIdentifier: "acct-1", now: t0, limit: 1).count == 1)

        let retry = t0.addingTimeInterval(600)
        try f.store.markTombstoneFailed(captureID: "a", code: "network", nextAttemptAt: retry, now: t0.addingTimeInterval(10))
        let later = try f.store.dueTombstones(destinationID: "d", accountIdentifier: "acct-1", now: t0.addingTimeInterval(20), limit: 10)
        #expect(later.map(\.captureID) == ["b"])
        let due2 = try f.store.dueTombstones(destinationID: "d", accountIdentifier: "acct-1", now: retry, limit: 10)
        #expect(due2.map(\.captureID) == ["a", "b"])
        #expect(due2[0].attemptCount == 1)
        #expect(due2[0].lastErrorCode == "network")
        #expect(due2[0].nextAttemptAt == retry)

        try f.store.removeTombstone(captureID: "a")
        #expect(try !f.store.hasTombstone(captureID: "a"))
        #expect(try f.store.pendingTombstoneCount(destinationID: "d") == 1)
    }

    @Test func dueTombstonesFilterByAccount() throws {
        let f = try Fixture(); defer { f.h.cleanup() }
        try f.store.addTombstone(captureID: "a", relativeDirectory: "x", destinationID: "d", accountIdentifier: "acct-1", now: t0)
        try f.store.addTombstone(captureID: "b", relativeDirectory: "y", destinationID: "d", accountIdentifier: "acct-2", now: t0)
        #expect(try f.store.dueTombstones(destinationID: "d", accountIdentifier: "acct-1", now: t0, limit: 10).map(\.captureID) == ["a"])
        #expect(try f.store.dueTombstones(destinationID: "d", accountIdentifier: "acct-2", now: t0, limit: 10).map(\.captureID) == ["b"])
        #expect(try f.store.dueTombstones(destinationID: "other", accountIdentifier: "acct-1", now: t0, limit: 10).isEmpty)
    }

    @Test func localDeleteRecordsSurviveAndCanBeRemoved() throws {
        let f = try Fixture(); defer { f.h.cleanup() }
        try f.store.recordLocalDelete(captureID: "a", relativeDirectory: "x", accountIdentifier: "acct-1", now: t0)
        try f.store.recordLocalDelete(captureID: "b", relativeDirectory: "y", accountIdentifier: nil, now: t0)
        try f.store.recordLocalDelete(captureID: "b", relativeDirectory: "y", accountIdentifier: nil, now: t0)
        #expect(try f.store.localDeletedCaptureIDs() == ["a", "b"])
        let reopened = RemoteStateStore(db: try Database(url: f.h.layout.databaseURL))
        #expect(try reopened.localDeletedCaptureIDs() == ["a", "b"])
        try f.store.removeLocalDelete(captureID: "a")
        #expect(try f.store.localDeletedCaptureIDs() == ["b"])
    }

    @Test func cursorPerDestinationSurvivesSignOut() throws {
        let f = try Fixture(); defer { f.h.cleanup() }
        #expect(try f.store.changeCursor(destinationID: "d") == nil)
        try f.store.saveChangeCursor(destinationID: "d", cursor: "c1", now: t0)
        _ = try f.destinations.connect(Destination(id: "e", providerKind: "dropbox", accountIdentifier: "acct-2",
                                                   remoteRoot: "/Hippo", displayName: "Other", status: .active))
        try f.store.saveChangeCursor(destinationID: "e", cursor: "c2", now: t0)
        try f.destinations.signOut(destinationID: "d")
        #expect(try f.store.changeCursor(destinationID: "d") == "c1")
        #expect(try f.store.changeCursor(destinationID: "e") == "c2")
        try f.store.saveChangeCursor(destinationID: "d", cursor: nil, now: t0)
        #expect(try f.store.changeCursor(destinationID: "d") == nil)
        #expect(try f.store.changeCursor(destinationID: "e") == "c2")
    }

    @Test func reviewItemsCascadeWithCapture() async throws {
        let f = try Fixture(); defer { f.h.cleanup() }
        let a = try await f.h.add(note: "a").metadata.captureID
        let b = try await f.h.add(note: "b").metadata.captureID
        try f.store.addReviewItems([
            ReviewItem(captureID: b, destinationID: "d", reason: "missing", createdAt: t0.addingTimeInterval(1)),
            ReviewItem(captureID: a, destinationID: "d", reason: "missing", createdAt: t0),
        ])
        try f.store.addReviewItems([ReviewItem(captureID: a, destinationID: "d", reason: "other", createdAt: t0.addingTimeInterval(9))])
        let items = try f.store.reviewItems(destinationID: "d")
        #expect(items.map(\.captureID) == [a, b])
        #expect(items[0].reason == "missing")
        #expect(items[0].createdAt == t0)
        try f.h.index.remove(captureID: a)
        #expect(try f.store.reviewItems(destinationID: "d").map(\.captureID) == [b])
        try f.store.clearReview(destinationID: "d")
        #expect(try f.store.reviewItems(destinationID: "d").isEmpty)
    }

    @Test func changedUnionsPaths() async throws {
        let f = try Fixture(); defer { f.h.cleanup() }
        let a = try await f.h.add(note: "a").metadata.captureID
        #expect(try f.store.changed(captureID: a) == nil)
        try f.store.markChanged(captureID: a, destinationID: "d", paths: ["z.txt", "a.txt"], now: t0)
        try f.store.markChanged(captureID: a, destinationID: "d", paths: ["a.txt", "m.txt"], now: t0.addingTimeInterval(60))
        let record = try #require(try f.store.changed(captureID: a))
        #expect(record.paths == ["a.txt", "m.txt", "z.txt"])
        #expect(record.detectedAt == t0)
        #expect(try f.store.changedCount(destinationID: "d") == 1)
        try f.store.clearChanged(captureID: a)
        #expect(try f.store.changed(captureID: a) == nil)
        #expect(try f.store.changedCount(destinationID: "d") == 0)
    }

    @Test func removeChangedPathsKeepsTheRestAndDropsAnEmptyRecord() async throws {
        let f = try Fixture(); defer { f.h.cleanup() }
        let a = try await f.h.add(note: "a").metadata.captureID
        try f.store.removeChangedPaths(captureID: a, paths: ["x"])
        #expect(try f.store.changed(captureID: a) == nil)
        try f.store.markChanged(captureID: a, destinationID: "d", paths: ["a.txt", "m.txt", "z.txt"], now: t0)
        try f.store.removeChangedPaths(captureID: a, paths: ["m.txt", "other"])
        let record = try #require(try f.store.changed(captureID: a))
        #expect(record.paths == ["a.txt", "z.txt"])
        #expect(record.detectedAt == t0)
        try f.store.removeChangedPaths(captureID: a, paths: ["a.txt", "z.txt"])
        #expect(try f.store.changed(captureID: a) == nil)
    }

    @Test func addReviewItemsReturnsInsertedCount() async throws {
        let f = try Fixture(); defer { f.h.cleanup() }
        let a = try await f.h.add(note: "a").metadata.captureID
        let b = try await f.h.add(note: "b").metadata.captureID
        #expect(try f.store.addReviewItems([ReviewItem(captureID: a, destinationID: "d", reason: "threshold", createdAt: t0)]) == 1)
        #expect(try f.store.addReviewItems([
            ReviewItem(captureID: a, destinationID: "d", reason: "threshold", createdAt: t0),
            ReviewItem(captureID: b, destinationID: "d", reason: "threshold", createdAt: t0),
        ]) == 1)
    }
}
