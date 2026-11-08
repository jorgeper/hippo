import Foundation
import Testing
import CaptureCore
@testable import LocalRepository
import SyncEngine
@testable import HippoPresentation

private let utc = TimeZone(identifier: "UTC")!
private let us = Locale(identifier: "en_US_POSIX")
/// 2026-11-08 14:02:11 UTC
private let now = Date(timeIntervalSince1970: 1_794_146_531)

private func line(_ e: LogEvent, at t: Date = now) -> LogLine {
    var e = e
    e.t = t
    return LogLine.make(e, id: 1, now: now, zone: utc, locale: us)
}

@MainActor
struct LogLineTests {
    @Test func pinnedTexts() {
        #expect(line(LogEvent(event: .enrichFinished, kind: "transcript", outcome: .empty, ms: 2100)).text
                == "Transcript · nothing found · 2.1 s")
        let at1432 = Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: utc, year: 2026, month: 11, day: 8, hour: 14, minute: 32))!
        #expect(line(LogEvent(event: .enrichDeferred, kind: "link_preview", code: "offline", retryAt: at1432)).text
                == "Link preview · waiting: offline · retry 14:32")
        #expect(line(LogEvent(event: .packageUploaded, dest: "dropbox")).text == "Uploaded to Dropbox")
        #expect(line(LogEvent(event: .packageUploaded, dest: "filesystem")).text == "Uploaded to the Developer folder")
        var shared = LogEvent(event: .captureSaved, trigger: "share_extension")
        shared.proc = .share
        #expect(LogLine.make(shared, id: 1, now: now, zone: utc, locale: us).text == "Saved from the share sheet")
        #expect(line(LogEvent(event: .syncPass, count: 3, trigger: "activation", phase: "end")).text
                == "Sync finished (activation) · 3 uploaded")
    }

    @Test func unknownCombinationFallsBack() {
        #expect(line(LogEvent(event: .goldSkipped, outcome: .skipped, code: "stale")).text == "gold.skipped · skipped · stale")
    }

    @Test func timeShowsDateOnlyWhenNotToday() {
        #expect(line(LogEvent(event: .appLaunch)).time == "14:02:11")
        #expect(line(LogEvent(event: .appLaunch), at: now.addingTimeInterval(-86_400)).time == "Nov 7 14:02:11")
    }

    @Test func layerPerFamily() {
        let expected: [(LogEventName, Layer)] = [
            (.captureSaved, .bronze), (.enrichFinished, .silver), (.goldApplied, .gold), (.packageUploaded, .sync),
            (.silverUploaded, .sync), (.syncPass, .sync), (.bgTask, .sync), (.appLaunch, .bronze), (.settingsChanged, .bronze),
        ]
        for (name, layer) in expected { #expect(line(LogEvent(event: name)).layer == layer, "\(name)") }
    }

    @Test func activityModelOldestFirstAndCopy() async throws {
        let t = try TestStore()
        defer { t.cleanup() }
        let id = "cap-1"
        t.store.log.append(LogEvent(event: .captureSaved, captureID: id, trigger: "note"))
        t.store.log.append(LogEvent(event: .packageUploaded, captureID: id, dest: "dropbox"))
        t.store.log.append(LogEvent(event: .packageUploaded, captureID: "other", dest: "dropbox"))
        let model = ActivityModel(store: t.store, captureID: id, capturedAt: Date())
        await model.load()
        #expect(model.lines.count == 2)
        #expect(model.lines.first?.text.hasPrefix("Saved") == true)
        #expect(model.lines.last?.text == "Uploaded to Dropbox")
        let copy = model.copyText(appVersion: "0.1.0")
        let rows = copy.split(separator: "\n")
        #expect(rows.first == "Hippo activity · capture cap-1 · app 0.1.0")
        #expect(rows.count == 3)
        #expect(rows[2].hasSuffix("  Uploaded to Dropbox"))
        #expect(!model.mayBePruned)
    }

    @Test func mayBePrunedAfter30Days() throws {
        let t = try TestStore()
        defer { t.cleanup() }
        let old = ActivityModel(store: t.store, captureID: "a", capturedAt: Date().addingTimeInterval(-31 * 86_400))
        let recent = ActivityModel(store: t.store, captureID: "a", capturedAt: Date().addingTimeInterval(-29 * 86_400))
        #expect(old.mayBePruned)
        #expect(!recent.mayBePruned)
    }

    @Test func globalModelPagesAndClear() async throws {
        let t = try TestStore()
        defer { t.cleanup() }
        for _ in 0..<5 { t.store.log.append(LogEvent(event: .appLaunch, code: "1-1")) }
        t.store.log.append(LogEvent(event: .captureSaved, captureID: "c", trigger: "note"))
        let model = GlobalLogModel(store: t.store, pageSize: 2)
        #expect(model.lastUpload == nil)
        await model.load()
        #expect(model.lines.count == 2)
        #expect(model.canLoadMore)
        await model.loadMore()
        await model.loadMore()
        #expect(model.lines.count == 5)
        #expect(!model.canLoadMore)
        #expect(model.copyText(appVersion: "9").hasPrefix("Hippo log · app 9\n"))
        await model.clear()
        #expect(model.lines.count == 1)   // the log.cleared marker
    }

    @Test func readerSkipsGarbageLines() async throws {
        let t = try TestStore()
        defer { t.cleanup() }
        t.store.log.append(LogEvent(event: .appLaunch, code: "1-1"))
        let file = try #require(t.store.log.segmentFiles().first)
        let h = try FileHandle(forWritingTo: file)
        try h.seekToEnd()
        try h.write(contentsOf: Data("not json at all\n{\"half\":\n".utf8))
        try h.close()
        t.store.log.append(LogEvent(event: .appLaunch, code: "2-2"))
        let model = GlobalLogModel(store: t.store)
        await model.load()
        #expect(model.lines.count == 2)
    }
}
