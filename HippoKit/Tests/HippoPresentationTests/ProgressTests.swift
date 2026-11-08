import Foundation
import Testing
import CaptureCore
import LocalRepository
@testable import HippoPresentation

private let now = Date(timeIntervalSince1970: 1_794_081_600)
private let locale = Locale(identifier: "en_US")
private let la = TimeZone(identifier: "America/Los_Angeles")!

private func task(_ kind: FacetKind, _ status: String, next: Date? = nil, code: String? = nil) -> EnrichmentTask {
    EnrichmentTask(captureID: "c1", kind: kind, version: 1, status: status, attemptCount: 0, nextAttemptAt: next,
                   lastErrorCode: code)
}

private func steps(_ tasks: [EnrichmentTask], off: Set<FacetKind> = [], online: Bool = true) -> [FacetKind: StepState] {
    EnrichmentProgress.steps(tasks, isEnabled: { !off.contains($0) }, isOnline: online, now: now)
}

@Suite struct ProgressTests {
    @Test func pendingDueIsWorking() {
        #expect(steps([task(.transcript, "pending"), task(.place, "pending", next: now.addingTimeInterval(-5))])
                == [.transcript: .working, .place: .working])
    }

    @Test func pendingFutureIsWaitingWithCode() {
        let s = steps([task(.place, "pending", next: now.addingTimeInterval(60), code: "throttled")])
        #expect(s[.place] == .waiting(code: "throttled"))
        #expect(EnrichmentProgress.row(s) == .waiting)
    }

    @Test func offlineNetworkKindIsWaiting() {
        let t = [task(.linkPreview, "pending")]
        #expect(steps(t, online: false)[.linkPreview] == .waiting(code: "offline"))
        #expect(steps(t, online: true)[.linkPreview] == .working)
        #expect(steps([task(.textRecognition, "pending")], online: false)[.textRecognition] == .working)
        #expect(EnrichmentProgress.row(steps(t, online: false)) == .waiting)
    }

    @Test func switchedOffIsOff() {
        let s = steps([task(.linkPreview, "pending")], off: [.linkPreview])
        #expect(s[.linkPreview] == .off)
        #expect(EnrichmentProgress.row(s) == .none)
    }

    @Test func notApplicableAbsent() {
        #expect(steps([task(.place, "not_applicable")]).isEmpty)
    }

    @Test func doneStates() {
        let s = steps([task(.place, "ok"), task(.transcript, "empty"), task(.linkPreview, "failed", code: "http_4xx")])
        #expect(s == [.place: .done, .transcript: .nothingFound, .linkPreview: .failed(code: "http_4xx")])
        #expect(EnrichmentProgress.row(s) == .none)
    }

    @Test func dataDetectionWaitsForTranscript() {
        let s = steps([task(.dataDetection, "empty"),
                       task(.transcript, "pending", next: now.addingTimeInterval(60), code: "model_missing")])
        #expect(s[.dataDetection] == .waitingForInput(.transcript))
        #expect(EnrichmentProgress.row(s) == .waiting)
        let working = steps([task(.dataDetection, "ok"), task(.textRecognition, "pending")])
        #expect(working[.dataDetection] == .waitingForInput(.textRecognition))
        #expect(EnrichmentProgress.row(working) == .working)
    }

    @Test func rowProgressPrecedence() {
        #expect(EnrichmentProgress.row([.place: .working, .linkPreview: .waiting(code: nil)]) == .working)
        #expect(EnrichmentProgress.row([.linkPreview: .waiting(code: nil)]) == .waiting)
        #expect(EnrichmentProgress.row([.place: .done, .transcript: .failed(code: nil)]) == .none)
    }

    @Test func pendingLineCopy() {
        func line(_ k: FacetKind, _ s: StepState) -> PendingLine? { EnrichmentProgress.pendingLine(k, s) }
        #expect(line(.linkPreview, .working) == PendingLine(text: "Fetching link preview…", working: true))
        #expect(line(.place, .working)?.text == "Looking up the place…")
        #expect(line(.transcript, .working)?.text == "Transcribing…")
        #expect(line(.textRecognition, .working)?.text == "Reading text in the image…")
        #expect(line(.dataDetection, .working)?.text == "Looking for dates, phone numbers and addresses…")
        #expect(line(.sourceAppGuess, .working) == nil)
        #expect(line(.linkPreview, .waiting(code: "offline")) == PendingLine(text: "Link preview: waiting for a connection", working: false))
        #expect(line(.place, .waiting(code: "offline"))?.text == "Place: waiting for a connection")
        #expect(line(.place, .waiting(code: "throttled"))?.text == "Place: Apple Maps is busy, will retry")
        #expect(line(.transcript, .waiting(code: "model_missing"))?.text == "Transcript: waiting for the speech model to download")
        #expect(line(.linkPreview, .waiting(code: "http_5xx"))?.text == "Link preview: couldn't finish yet. Hippo will retry.")
        #expect(line(.place, .waiting(code: "weird"))?.text == "Place: couldn't finish yet. Hippo will retry.")
        #expect(line(.transcript, .waiting(code: nil))?.text == "Transcript: couldn't finish yet. Hippo will retry.")
        #expect(line(.dataDetection, .waitingForInput(.transcript)) == PendingLine(
            text: "Dates, phone numbers and addresses: will check again after the transcript", working: false))
        #expect(line(.dataDetection, .waitingForInput(.textRecognition))?.text
                == "Dates, phone numbers and addresses: will check again after the image text")
        #expect(line(.place, .done) == nil && line(.place, .failed(code: nil)) == nil && line(.place, .off) == nil)
    }

    @Test func statusLinesForTypedNoteNothingFound() {
        let lines = StatusLine.lines(saved: now, steps: [.dataDetection: .nothingFound], goldKinds: [],
                                     goldArrivedAt: nil, locale: locale, zone: la)
        #expect(lines.map(\.text) == ["Saved on this iPhone · \(DetailFormat.dateTime(now, zone: la, locale: locale))",
                                      "Dates, phone numbers and addresses: nothing found"])
        #expect(lines.map(\.layer) == [.bronze, .silver])
        #expect(lines.allSatisfy { $0.layer != .gold })
    }

    @Test func statusOrderLayersAndGold() {
        let arrived = now.addingTimeInterval(3600)
        let lines = StatusLine.lines(
            saved: now,
            steps: [.sourceAppGuess: .done, .linkPreview: .done, .transcript: .working, .place: .done,
                    .textRecognition: .off],
            goldKinds: [.place], goldArrivedAt: arrived, locale: locale, zone: la)
        #expect(lines.map(\.text).dropFirst().dropLast() == [
            "Link preview: done", "Place: done", "Transcribing…", "Text in image: off in Settings",
            "App guess: done"])
        #expect(lines.map(\.layer) == [.bronze, .silver, .gold, .silver, .silver, .silver, .gold])
        #expect(lines.last?.text == "From your server · \(DetailFormat.dateTime(arrived, zone: la, locale: locale))")
        #expect(lines.map(\.state) == [.done, .done, .done, .working, .done, .done, .done])
    }

    @Test func statusFailedReason() {
        func text(_ code: String?) -> String? {
            StatusLine.lines(saved: now, steps: [.linkPreview: .failed(code: code)], goldKinds: [], goldArrivedAt: nil,
                             locale: locale, zone: la).dropFirst().first?.text
        }
        #expect(text("http_4xx") == "Link preview: couldn't fetch the page — the page didn't respond")
        #expect(text("http_5xx")?.hasSuffix("— the page didn't respond") == true)
        #expect(text("too_large")?.hasSuffix("— the file is too large") == true)
        #expect(text("bad_url")?.hasSuffix("— the link isn't valid") == true)
        #expect(text("whatever") == "Link preview: couldn't fetch the page")
        #expect(text(nil) == "Link preview: couldn't fetch the page")
    }

    @Test @MainActor func statusIgnoresLog() async throws {
        let t = try TestStore(); defer { t.cleanup() }
        let p = try await t.note("hello", at: now)
        let id = p.metadata.captureID
        try t.store.enrichmentTasks.set(captureID: id, kind: .dataDetection, version: 1, status: "empty", now: now)
        try t.store.enrichmentTasks.set(captureID: id, kind: .linkPreview, version: 1, status: "pending", now: now)
        let model = CaptureDetailModel(store: t.store, captureID: id, now: { now }, locale: locale)
        await model.load()
        let before = try #require(model.detail)
        #expect(before.status.map(\.text).contains("Dates, phone numbers and addresses: nothing found"))
        #expect(before.pending[.linkPreview]?.working == true)
        let logs = t.store.layout.root.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let junk = logs.appendingPathComponent("2026-11-07.jsonl")
        try Data("{\"event\":\"enrich.fail\",\"kind\":\"data_detection\"}\n\u{0}garbage\n".utf8).write(to: junk)
        await model.load()
        #expect(model.detail?.status == before.status)
        try FileManager.default.removeItem(at: logs)
        await model.load()
        #expect(model.detail?.status == before.status)
        #expect(model.detail?.pending == before.pending)
    }
}
