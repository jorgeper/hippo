import Foundation
import Testing
import Synchronization
import CaptureCore
import LocalRepository
import SyncEngine
@testable import HippoPresentation

private let day = Date(timeIntervalSince1970: 1_794_081_600)  // 2026-11-07 12:00 in Los Angeles
private let la = TimeZone(identifier: "America/Los_Angeles")!
private let dropbox = Destination(id: "dest-x", providerKind: "dropbox", accountIdentifier: "acct", remoteRoot: "/",
                                  displayName: "Dropbox", status: .active)

/// ICU may use thin or narrow no-break spaces; tests compare with plain ones.
private func spaced(_ s: String) -> String {
    s.replacingOccurrences(of: "\u{2009}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
}

private final class Counter: Sendable {
    private let n = Mutex(0)
    func bump() { n.withLock { $0 += 1 } }
    var value: Int { n.withLock { $0 } }
}

@MainActor
private struct Harness {
    let t: TestStore
    let ids: [String]
    let calls = Counter()

    init(captures offsets: [TimeInterval] = [0, 86_400 * 2], connect: Bool = true) async throws {
        t = try TestStore()
        if connect { _ = try t.store.destinations.connect(dropbox) }
        var out: [String] = []
        for (i, offset) in offsets.enumerated() {
            out.append(try await t.note("capture \(i)", at: day.addingTimeInterval(offset)).metadata.captureID)
        }
        ids = out
    }

    func queue(_ which: [Int]) throws {
        try t.store.remoteState.addReviewItems(which.map {
            ReviewItem(captureID: ids[$0], destinationID: dropbox.id, reason: "threshold", createdAt: day)
        })
    }

    func model() -> RemoteReviewModel {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = la
        let calls = calls
        return RemoteReviewModel(store: t.store, sync: { calls.bump() },
                                 locale: Locale(identifier: "en_US"), calendar: calendar)
    }

    /// Marks every capture's job synced, as after a finished upload.
    func markAllSynced() throws {
        while let job = try t.store.jobs.claimNext(owner: "test", now: Date(), lease: 60) {
            try t.store.jobs.markSynced(jobID: job.jobID, owner: "test")
        }
    }

    func jobState(_ index: Int) throws -> JobState {
        try #require(try t.store.jobs.jobs(captureID: ids[index]).first).state
    }

    func trim(_ index: Int) throws {
        let pkg = try #require(try t.store.index.metadata(captureID: ids[index], layout: t.store.layout))
        let a = try #require(pkg.attachments.first)
        try t.store.trims.record(TrimmedAttachment(captureID: ids[index], attachmentID: a.attachmentID,
                                                   relativePath: a.relativePath, byteCount: 1, sha256: "x",
                                                   destinationID: dropbox.id, state: .trimmed, trimmedAt: day))
    }
}

@MainActor
struct RemoteReviewTests {
    @Test func loadsItemsDateRangeAndTrimmedCount() async throws {
        let h = try await Harness(captures: [0, 86_400 * 2, 86_400])
        defer { h.t.cleanup() }
        try h.queue([0, 1])
        try h.trim(1)
        let m = h.model()
        await m.load()
        #expect(m.isPending && m.count == 2 && m.items.map(\.captureID).sorted() == [h.ids[0], h.ids[1]].sorted())
        #expect(m.trimmedCount == 1)
        #expect(m.destinationName == "Dropbox")
        #expect(m.title == "Dropbox looks different")
        #expect(spaced(m.summaryLine) == "2 captures, Nov 7 – 9, 2026")
        #expect(m.trimmedLine == "1 of these have large files only in Dropbox")
        #expect(m.footer == "You can restore deleted files on dropbox.com for a while.")
        #expect(m.keepTitle == "Keep and upload again")
    }

    @Test func singleDayAndSingularCopy() async throws {
        let h = try await Harness(captures: [0])
        defer { h.t.cleanup() }
        try h.queue([0])
        try h.trim(0)
        let m = h.model()
        await m.load()
        #expect(spaced(m.summaryLine) == "1 capture, Nov 7, 2026")
        #expect(m.trimmedLine == "1 of these have large files only in Dropbox")
        #expect(m.keepTitle == "Keep on iPhone as they are")
    }

    @Test func nothingPendingWithoutDestinationOrItems() async throws {
        let h = try await Harness(captures: [0], connect: false)
        defer { h.t.cleanup() }
        let m = h.model()
        await m.load()
        #expect(!m.isPending && m.items.isEmpty && m.dateRange == nil)
        _ = try h.t.store.destinations.connect(dropbox)
        await m.load()
        #expect(!m.isPending)
    }

    @Test func removeFromPhoneRemovesAndClears() async throws {
        let h = try await Harness()
        defer { h.t.cleanup() }
        try h.queue([0, 1])
        let m = h.model()
        await m.load()
        await m.removeFromPhone()
        #expect(try h.t.store.index.count() == 0)
        #expect(try h.t.store.remoteState.reviewItems(destinationID: dropbox.id).isEmpty)
        #expect(!m.isPending && m.count == 0)
        #expect(h.calls.value == 0)
    }

    @Test func keepRequeuesNonTrimmedAndClears() async throws {
        let h = try await Harness()
        defer { h.t.cleanup() }
        try h.markAllSynced()
        try h.queue([0, 1])
        try h.trim(1)
        let m = h.model()
        await m.load()
        #expect(try h.jobState(0) == .synced && h.jobState(1) == .synced)
        await m.keepAndUploadAgain()
        #expect(!m.resolveFailed)
        #expect(try h.jobState(0) == .pending)
        #expect(try h.jobState(1) == .synced)
        #expect(try h.t.store.index.count() == 2)
        #expect(try h.t.store.remoteState.reviewItems(destinationID: dropbox.id).isEmpty)
        #expect(h.calls.value == 1)
        #expect(!m.isPending)
        m.decideLater()
    }
}
