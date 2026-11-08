import Foundation
import Testing
import CaptureCore
@testable import LocalRepository

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

@Suite struct EnrichmentTaskStoreTests {
    @Test func taskStoreClaimOrder() async throws {
        let h = try IndexHarness(); defer { h.cleanup() }
        let tasks = EnrichmentTaskStore(db: h.db)
        let older = try await h.add(at: t0, note: "older").metadata.captureID
        let newer = try await h.add(at: t0.addingTimeInterval(60), note: "newer").metadata.captureID
        for id in [older, newer] {
            // data_detection is inserted first so the order can't come from insertion order.
            try tasks.set(captureID: id, kind: .dataDetection, version: 1, status: "pending", now: t0)
            try tasks.set(captureID: id, kind: .textRecognition, version: 1, status: "pending", now: t0)
            try tasks.set(captureID: id, kind: .linkPreview, version: 1, status: "pending", now: t0)
        }
        let kinds: Set<FacetKind> = [.textRecognition, .dataDetection]
        #expect(try tasks.hasDueWork(kinds: kinds, now: t0))

        var claimed: [String] = []
        while let task = try tasks.claimNext(kinds: kinds, now: t0) {
            #expect(task.status == "pending")
            #expect(task.version == 1)
            #expect(task.attemptCount == 0)
            claimed.append("\(task.captureID == newer ? "newer" : "older") \(task.kind.rawValue)")
            // Claiming changes nothing: the same task comes back until its row changes.
            #expect(try tasks.claimNext(kinds: kinds, now: t0) == task)
            try tasks.recordAttempt(captureID: task.captureID, kind: task.kind, status: "ok", errorCode: nil,
                                    nextAttemptAt: nil, incrementAttempts: true, now: t0)
        }
        #expect(claimed == ["newer text_recognition", "newer data_detection",
                            "older text_recognition", "older data_detection"])
        #expect(try !tasks.hasDueWork(kinds: kinds, now: t0))
        #expect(try tasks.hasDueWork(kinds: [.linkPreview], now: t0))
        #expect(try tasks.claimNext(kinds: [], now: t0) == nil)

        // A retry scheduled in the future is not claimed until it is due.
        try tasks.recordAttempt(captureID: newer, kind: .textRecognition, status: "pending", errorCode: "busy",
                                nextAttemptAt: t0.addingTimeInterval(30), incrementAttempts: true, now: t0)
        #expect(try tasks.claimNext(kinds: kinds, now: t0) == nil)
        #expect(try !tasks.hasDueWork(kinds: kinds, now: t0))
        let due = try #require(try tasks.claimNext(kinds: kinds, now: t0.addingTimeInterval(30)))
        #expect(due.captureID == newer)
        #expect(due.kind == .textRecognition)
        #expect(due.attemptCount == 2)
        #expect(due.lastErrorCode == "busy")
        #expect(due.nextAttemptAt == t0.addingTimeInterval(30))

        // An attempt that doesn't count leaves attempt_count alone.
        try tasks.recordAttempt(captureID: newer, kind: .textRecognition, status: "pending", errorCode: nil,
                                nextAttemptAt: nil, incrementAttempts: false, now: t0)
        #expect(try tasks.claimNext(kinds: kinds, now: t0)?.attemptCount == 2)

        // `set` resets attempts, the retry time and the error.
        try tasks.set(captureID: newer, kind: .textRecognition, version: 2, status: "pending", now: t0)
        let reset = try #require(try tasks.claimNext(kinds: kinds, now: t0))
        #expect(reset == EnrichmentTask(captureID: newer, kind: .textRecognition, version: 2, status: "pending",
                                        attemptCount: 0, nextAttemptAt: nil, lastErrorCode: nil))

        #expect(try tasks.counts() == [
            "text_recognition": ["ok": 1, "pending": 1],
            "data_detection": ["ok": 2],
            "link_preview": ["pending": 2],
        ])
    }

    @Test func resetToPendingRules() async throws {
        let h = try IndexHarness(); defer { h.cleanup() }
        let tasks = EnrichmentTaskStore(db: h.db)
        let id = try await h.add(note: "x").metadata.captureID
        try tasks.set(captureID: id, kind: .place, version: 1, status: "failed", now: t0)
        try tasks.recordAttempt(captureID: id, kind: .place, status: "failed", errorCode: "e",
                                nextAttemptAt: t0.addingTimeInterval(99), incrementAttempts: true, now: t0)
        try tasks.set(captureID: id, kind: .transcript, version: 1, status: "not_applicable", now: t0)

        try tasks.resetToPending(captureID: id, kind: .place, now: t0)
        try tasks.resetToPending(captureID: id, kind: .transcript, now: t0)
        try tasks.resetToPending(captureID: id, kind: .linkPreview, now: t0)  // no row: nothing happens

        let place = try #require(try tasks.claimNext(kinds: [.place], now: t0))
        #expect(place.attemptCount == 0)
        #expect(place.lastErrorCode == nil)
        #expect(try tasks.claimNext(kinds: [.transcript, .linkPreview], now: t0) == nil)
        #expect(try tasks.counts() == ["place": ["pending": 1], "transcript": ["not_applicable": 1]])
    }

    @Test func capturesNeedingVersionBump() async throws {
        let h = try IndexHarness(); defer { h.cleanup() }
        let tasks = EnrichmentTaskStore(db: h.db)
        let a = try await h.add(at: t0, note: "a").metadata.captureID
        let b = try await h.add(at: t0.addingTimeInterval(1), note: "b").metadata.captureID
        try tasks.set(captureID: a, kind: .place, version: 1, status: "ok", now: t0)

        #expect(try tasks.capturesNeeding(kind: .place, version: 1, limit: 10) == [b])
        #expect(try tasks.capturesNeeding(kind: .place, version: 2, limit: 10) == [b, a])
        #expect(try tasks.capturesNeeding(kind: .place, version: 2, limit: 1) == [b])
        #expect(try tasks.capturesNeeding(kind: .transcript, version: 1, limit: 10) == [b, a])
    }

    @Test func hasWorkCountsCapturesWithoutTaskRows() async throws {
        let h = try IndexHarness(); defer { h.cleanup() }
        let tasks = EnrichmentTaskStore(db: h.db)
        #expect(try !tasks.hasWork(versions: [.place: 1], now: t0))   // no captures at all

        // A capture with no task rows yet (saved by the Share Extension) is work.
        let id = try await h.add(at: t0, note: "shared").metadata.captureID
        #expect(try tasks.hasWork(versions: [.place: 1], now: t0))
        #expect(try !tasks.hasWork(versions: [:], now: t0))

        // Scheduled and done: no work, until the enricher's version changes.
        try tasks.set(captureID: id, kind: .place, version: 1, status: "ok", now: t0)
        #expect(try !tasks.hasWork(versions: [.place: 1], now: t0))
        #expect(try tasks.hasWork(versions: [.place: 2], now: t0))

        // A pending task is work once due.
        try tasks.set(captureID: id, kind: .place, version: 1, status: "pending", now: t0)
        try tasks.recordAttempt(captureID: id, kind: .place, status: "pending", errorCode: "busy",
                                nextAttemptAt: t0.addingTimeInterval(300), incrementAttempts: true, now: t0)
        #expect(try !tasks.hasWork(versions: [.place: 1], now: t0))
        #expect(try tasks.hasWork(versions: [.place: 1], now: t0.addingTimeInterval(300)))
    }

    @Test func taskRowsCascadeWithCapture() async throws {
        let h = try IndexHarness(); defer { h.cleanup() }
        let tasks = EnrichmentTaskStore(db: h.db)
        let id = try await h.add(note: "x").metadata.captureID
        try tasks.set(captureID: id, kind: .place, version: 1, status: "pending", now: t0)
        try h.index.remove(captureID: id)
        #expect(try tasks.counts().isEmpty)
    }

    @Test func taskReadsOneRowWhateverItsStatus() async throws {
        let h = try IndexHarness(); defer { h.cleanup() }
        let tasks = EnrichmentTaskStore(db: h.db)
        let id = try await h.add(note: "x").metadata.captureID
        #expect(try tasks.task(captureID: id, kind: .place) == nil)
        try tasks.set(captureID: id, kind: .place, version: 2, status: "pending", now: t0)
        try tasks.recordAttempt(captureID: id, kind: .place, status: "failed", errorCode: "gone",
                                nextAttemptAt: t0.addingTimeInterval(5), incrementAttempts: true, now: t0)
        #expect(try tasks.task(captureID: id, kind: .place) == EnrichmentTask(
            captureID: id, kind: .place, version: 2, status: "failed", attemptCount: 1,
            nextAttemptAt: t0.addingTimeInterval(5), lastErrorCode: "gone"))
        #expect(try tasks.task(captureID: id, kind: .transcript) == nil)
    }
}
