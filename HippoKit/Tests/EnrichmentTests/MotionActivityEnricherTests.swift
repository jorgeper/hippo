import Foundation
import Testing
import CaptureCore
@testable import Enrichment

private final class FakeHistory: MotionHistoryProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(Date, Date)] = []
    let result: @Sendable () throws -> [MotionSample]
    init(_ samples: [MotionSample]) { result = { samples } }
    init(throwing error: any Error) { result = { throw error } }
    var calls: [(Date, Date)] { lock.withLock { _calls } }
    func samples(from: Date, to: Date) async throws -> [MotionSample] {
        lock.withLock { _calls.append((from, to)) }
        return try result()
    }
}

private struct OtherError: Error {}

private let T = Date(timeIntervalSince1970: 1_794_148_632)

private func sample(_ offset: TimeInterval, _ activities: [String], _ confidence: String) -> MotionSample {
    MotionSample(startedAt: T.addingTimeInterval(offset), activities: activities, confidence: confidence)
}

private func metadata() -> CaptureMetadata {
    var m = fixtureMetadata()
    m.capturedAt = T
    return m
}

private func enricher(_ history: FakeHistory, nowOffset: TimeInterval = 700) -> MotionActivityEnricher {
    let now = T.addingTimeInterval(nowOffset)
    return MotionActivityEnricher(history: history, now: { now })
}

private func decode(_ out: EnricherOutput) throws -> MotionActivityData {
    try JSONDecoder().decode(MotionActivityData.self, from: try JSONEncoder().encode(try #require(out.data)))
}

private func errorOf(_ e: MotionActivityEnricher) async -> EnrichmentError? {
    do { _ = try await e.run(fixtureInput(metadata())); return nil } catch { return error as? EnrichmentError }
}

@Suite struct MotionActivityEnricherTests {
    @Test func identity() {
        let e = MotionActivityEnricher(history: FakeHistory([]))
        #expect(e.kind == .motionActivity)
        #expect(e.version == 1)
        #expect(!e.usesNetwork)
        #expect(e.applies(to: metadata()))
    }

    @Test func recentCaptureIsDeferred() async {
        let h = FakeHistory([])
        let error = await errorOf(enricher(h, nowOffset: 120))
        #expect(error == .deferred(code: "motion_window_open", retryAfter: 480))
        #expect(h.calls.isEmpty)
    }

    @Test func windowEdgeIsNotDeferred() async throws {
        let h = FakeHistory([])
        let out = try await enricher(h, nowOffset: 600).run(fixtureInput(metadata()))
        #expect(out.status == .empty)
        #expect(h.calls.count == 1)
    }

    @Test func expiredHistoryIsNotApplicable() async {
        let h = FakeHistory([])
        let error = await errorOf(enricher(h, nowOffset: 7 * 86_400 + 1))
        #expect(error == .notApplicable(code: "motion_history_expired"))
        #expect(h.calls.isEmpty)
    }

    @Test func exactlySevenDaysIsStillQueried() async throws {
        let h = FakeHistory([])
        _ = try await enricher(h, nowOffset: 7 * 86_400).run(fixtureInput(metadata()))
        #expect(h.calls.count == 1)
    }

    @Test func windowAndAtCapture() async throws {
        let h = FakeHistory([sample(-500, ["walking"], "medium"),
                             sample(-100, ["automotive", "stationary"], "high"),
                             sample(200, ["automotive"], "high")])
        let out = try await enricher(h).run(fixtureInput(metadata()))
        #expect(h.calls.count == 1)
        #expect(h.calls[0].0 == T.addingTimeInterval(-600) && h.calls[0].1 == T.addingTimeInterval(600))
        let d = try decode(out)
        #expect(out.status == .ok)
        #expect(out.provenance == "core_motion")
        #expect(d.windowStart == T.addingTimeInterval(-600) && d.windowEnd == T.addingTimeInterval(600))
        #expect(d.atCapture?.activities == ["stationary", "automotive"])
        #expect(d.atCapture?.startedAt == T.addingTimeInterval(-100))
        #expect(d.segments.map(\.startedAt) == [-500, -100, 200].map { T.addingTimeInterval($0) })
    }

    @Test func sampleExactlyAtCaptureCounts() async throws {
        let h = FakeHistory([sample(-100, ["walking"], "low"), sample(0, ["cycling"], "high")])
        let d = try decode(try await enricher(h).run(fixtureInput(metadata())))
        #expect(d.atCapture?.activities == ["cycling"])
    }

    @Test func mergesIdenticalNeighbours() async throws {
        let walking = (0..<5).map { sample(-500 + Double($0) * 10, ["walking"], "medium") }
        let d = try decode(try await enricher(FakeHistory(walking)).run(fixtureInput(metadata())))
        #expect(d.segments.count == 1)
        #expect(d.segments[0].startedAt == T.addingTimeInterval(-500))

        let split = walking + [sample(-440, ["walking"], "high")]
        let d2 = try decode(try await enricher(FakeHistory(split)).run(fixtureInput(metadata())))
        #expect(d2.segments.count == 2)
        #expect(d2.segments[1].confidence == "high")
    }

    @Test func capsSegmentsKeepingTheFirst() async throws {
        let many = (0..<100).map { sample(-590 + Double($0) * 5, [$0 % 2 == 0 ? "walking" : "stationary"], "medium") }
        let d = try decode(try await enricher(FakeHistory(many)).run(fixtureInput(metadata())))
        #expect(d.segments.count == 60)
        #expect(d.segments.first?.startedAt == many.first?.startedAt)
        #expect(d.segments.last?.startedAt == many[59].startedAt)
        // All 100 samples start before T, so the true last one is the 100th, outside the kept 60.
        #expect(d.atCapture?.startedAt == many[99].startedAt)
    }

    @Test func unorderedSamplesAreSorted() async throws {
        let h = FakeHistory([sample(200, ["automotive"], "high"), sample(-500, ["walking"], "medium"),
                             sample(-100, ["stationary"], "high")])
        let d = try decode(try await enricher(h).run(fixtureInput(metadata())))
        #expect(d.segments.map(\.startedAt) == [-500, -100, 200].map { T.addingTimeInterval($0) })
        #expect(d.atCapture?.activities == ["stationary"])
    }

    @Test func noSampleBeforeCaptureOmitsAtCapture() async throws {
        let h = FakeHistory([sample(100, ["walking"], "low")])
        let d = try decode(try await enricher(h).run(fixtureInput(metadata())))
        #expect(d.atCapture == nil)
        #expect(d.segments.count == 1)
    }

    @Test func noSamplesIsEmpty() async throws {
        let out = try await enricher(FakeHistory([])).run(fixtureInput(metadata()))
        #expect(out.status == .empty)
        #expect(out.data == nil)
    }

    @Test func activityOrderIsFixed() async throws {
        let h = FakeHistory([sample(-100, ["unknown", "automotive", "cycling", "running", "walking", "stationary"], "low")])
        let d = try decode(try await enricher(h).run(fixtureInput(metadata())))
        #expect(d.segments[0].activities == ["stationary", "walking", "running", "cycling", "automotive", "unknown"])
    }

    @Test func emptyActivitiesAreUnknownAndMerge() async throws {
        let h = FakeHistory([sample(-300, [], "low"), sample(-200, [], "low"), sample(-100, ["walking"], "low")])
        let d = try decode(try await enricher(h).run(fixtureInput(metadata())))
        #expect(d.segments.map(\.activities) == [["unknown"], ["walking"]])
        #expect(d.segments[0].startedAt == T.addingTimeInterval(-300))
    }

    @Test func providerErrorsAreClassified() async {
        let now = 700.0
        #expect(await errorOf(enricher(FakeHistory(throwing: MotionHistoryError.unauthorized), nowOffset: now))
                == .deferred(code: "motion_unauthorized", retryAfter: 86_400))
        #expect(await errorOf(enricher(FakeHistory(throwing: MotionHistoryError.unavailable), nowOffset: now))
                == .notApplicable(code: "motion_unavailable"))
        #expect(await errorOf(enricher(FakeHistory(throwing: OtherError()), nowOffset: now))
                == .transient(code: "motion_query"))
    }

    @Test func cancellationIsRethrown() async {
        let e = enricher(FakeHistory(throwing: CancellationError()))
        await #expect(throws: CancellationError.self) { _ = try await e.run(fixtureInput(metadata())) }
    }
}
