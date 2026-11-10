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

    @Test func remoteDeleteLines() {
        #expect(line(LogEvent(event: .remoteDelete, dest: "dropbox")).text == "Delete queued for Dropbox")
        #expect(line(LogEvent(event: .remoteDelete, outcome: .ok, dest: "dropbox")).text == "Deleted in Dropbox")
        #expect(line(LogEvent(event: .remoteDelete, outcome: .failed, code: "offline", dest: "dropbox")).text
                == "Delete in Dropbox failed · offline")
        #expect(line(LogEvent(event: .remoteDelete, dest: "filesystem")).text == "Delete queued for the Developer folder")
    }

    @Test func authLines() {
        #expect(line(LogEvent(event: .authConnected, dest: "dropbox")).text == "Connected Dropbox")
        #expect(line(LogEvent(event: .authDisconnected, dest: "dropbox")).text == "Disconnected Dropbox")
        #expect(line(LogEvent(event: .authRefreshFailed, dest: "dropbox")).text == "Dropbox sign-in expired")
        #expect(line(LogEvent(event: .authConnected, dest: "filesystem")).text == "Connected the Developer folder")
        #expect(line(LogEvent(event: .authRefreshFailed)).text == "Sign-in expired")
    }

    @Test func remoteChangeLines() {
        #expect(line(LogEvent(event: .remoteChanged, dest: "dropbox")).text == "Changed in Dropbox")
        #expect(line(LogEvent(event: .remoteChanged, code: "unverified", dest: "dropbox")).text
                == "Not removed: upload not verified")
        #expect(line(LogEvent(event: .remoteReview, code: "threshold", count: 25, dest: "dropbox")).text
                == "Dropbox looks different · 25 captures to review")
        #expect(line(LogEvent(event: .remoteReview, code: "cursor_reset", count: 1, dest: "dropbox")).text
                == "Dropbox looks different · 1 capture to review")
        #expect(line(LogEvent(event: .remoteReview, code: "threshold", count: 2, dest: "filesystem")).text
                == "The Developer folder looks different · 2 captures to review")
    }

    @Test func unknownCombinationFallsBack() {
        #expect(line(LogEvent(event: .bgTask, outcome: .skipped, code: "stale")).text == "bg.task · skipped · stale")
        #expect(line(LogEvent(event: .goldSkipped, code: "stale")).text == "Server results skipped · stale")
    }

    @Test func everyKnownEventHasPlainWords() {
        for name in LogEventName.allCases {
            let phases = name == .bgTask ? ["start", "end", "expired"] : ["start", "end"]
            for phase in phases {
                for outcome in [LogOutcome.ok, .empty, .failed, .skipped] {
                    let e = LogEvent(event: name, kind: "link_preview", outcome: outcome, code: "x", attempt: 2, count: 3, ms: 900,
                                     trigger: "manual", dest: "dropbox", on: true, phase: phase, retryAt: now)
                    #expect(!line(e).text.contains(name.rawValue), "\(name) \(phase) \(outcome)")
                }
            }
        }
    }

    @Test func settingsChangedUsesDisplayNames() {
        #expect(line(LogEvent(event: .settingsChanged, kind: "link_preview", on: true)).text == "Link preview turned on")
        #expect(line(LogEvent(event: .settingsChanged, kind: "location", on: false)).text == "Save location turned off")
        #expect(line(LogEvent(event: .settingsChanged, kind: "layer_stripes", on: true)).text
                == "Show where details came from turned on")
        #expect(line(LogEvent(event: .settingsChanged, kind: "developer_mode", on: true)).text == "Developer mode turned on")
        #expect(line(LogEvent(event: .settingsChanged, kind: "odd_thing", on: true)).text == "odd_thing turned on")
    }

    @Test func clockIgnoresTwelveHourLocale() {
        var e = LogEvent(event: .appLaunch)
        e.t = now
        let l = LogLine.make(e, id: 0, now: now, zone: utc, locale: Locale(identifier: "en_US"))
        #expect(l.time == "14:02:11")
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

    // I1: a read that finishes after a newer one must not overwrite it.
    @Test func activityModelDropsSupersededLoad() async throws {
        let t = try TestStore()
        defer { t.cleanup() }
        let id = "cap-1"
        t.store.log.append(LogEvent(event: .captureSaved, captureID: id, trigger: "note"))
        let model = ActivityModel(store: t.store, captureID: id, capturedAt: Date())
        let gate = FirstCallGate()
        model.beforeApply = { await gate.arrive() }

        let first = Task { await model.load() }
        await gate.firstArrived()
        t.store.log.append(LogEvent(event: .packageUploaded, captureID: id, dest: "dropbox"))
        await model.load()
        #expect(model.lines.count == 2)
        await gate.release()
        await first.value
        #expect(model.lines.count == 2)
        #expect(model.lines.last?.text == "Uploaded to Dropbox")
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
        #expect(model.uploadLine == "Logs aren't uploaded: no storage connected")
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

    private func writeUploadState(_ t: TestStore, at: Date, code: String?) throws {
        let f = ISO8601DateFormatter()
        let codeJSON = code.map { "\"\($0)\"" } ?? "null"
        try FileManager.default.createDirectory(at: t.store.layout.logsDir, withIntermediateDirectories: true)
        try Data(#"{"files":{},"last_at":"\#(f.string(from: at))","last_code":\#(codeJSON)}"#.utf8)
            .write(to: t.store.layout.logsDir.appendingPathComponent("upload-state.json"))
    }

    // M5 (spec §8.1): "Logs upload to <destination> · last upload <day and time, or result>".
    @Test func uploadLineNamesDestinationAndDay() throws {
        let t = try TestStore()
        defer { t.cleanup() }
        func line() -> String { GlobalLogModel(store: t.store, now: { now }, locale: us, zone: utc).uploadLine }
        #expect(line() == "Logs aren't uploaded: no storage connected")

        _ = try t.store.destinations.connect(Destination(id: "d1", providerKind: "dropbox", accountIdentifier: "a",
                                                         remoteRoot: "/", displayName: "Dropbox", status: .active))
        #expect(line() == "Logs upload to Dropbox · not uploaded yet")

        try writeUploadState(t, at: now.addingTimeInterval(-3_600), code: nil)        // 13:02 today
        #expect(line() == "Logs upload to Dropbox · last upload today 13:02")
        try writeUploadState(t, at: now.addingTimeInterval(-86_400), code: nil)
        #expect(line() == "Logs upload to Dropbox · last upload yesterday 14:02")
        try writeUploadState(t, at: now.addingTimeInterval(-7 * 86_400), code: nil)
        #expect(line() == "Logs upload to Dropbox · last upload Nov 1 14:02")
        try writeUploadState(t, at: now.addingTimeInterval(-60), code: "http_5xx")
        #expect(line() == "Logs upload to Dropbox · last upload failed today 14:01 (http_5xx)")
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

@Suite struct TrimLogLineTests {
    private func line(_ e: LogEvent) -> LogLine {
        LogLine.make(e, id: 0, now: Date(timeIntervalSince1970: 1_800_000_000), zone: TimeZone(identifier: "UTC")!,
                     locale: Locale(identifier: "en_US_POSIX"))
    }

    @Test func trimAndRestoreLines() {
        #expect(line(LogEvent(event: .trimRun, count: 3, bytes: 12_000_000)).text == "Saved space · 3 files · 12 MB")
        #expect(line(LogEvent(event: .trimRun, count: 1, bytes: 1_000_000)).text == "Saved space · 1 file · 1 MB")
        #expect(line(LogEvent(event: .attachmentRestored, outcome: .ok, dest: "dropbox")).text
                == "Downloaded a file from Dropbox")
        #expect(line(LogEvent(event: .attachmentRestored, outcome: .failed, code: "mismatch", dest: "dropbox")).text
                == "Download failed · mismatch")
    }
}

@Suite struct DownloadLogLineTests {
    private func line(_ e: LogEvent) -> LogLine {
        LogLine.make(e, id: 0, now: Date(timeIntervalSince1970: 1_800_000_000), zone: TimeZone(identifier: "UTC")!,
                     locale: Locale(identifier: "en_US_POSIX"))
    }

    @Test func downloadLines() {
        #expect(line(LogEvent(event: .downloadRun, count: 3, dest: "dropbox")).text == "Downloaded 3 captures from Dropbox")
        #expect(line(LogEvent(event: .downloadRun, count: 1, dest: "dropbox")).text == "Downloaded 1 capture from Dropbox")
        #expect(line(LogEvent(event: .downloadRun, code: "incomplete_package", count: 0, dest: "filesystem")).text
                == "Downloaded 0 captures from the Developer folder · incomplete_package")
        #expect(line(LogEvent(event: .downloadCapture, outcome: .ok, dest: "dropbox")).text == "Downloaded from Dropbox")
        #expect(line(LogEvent(event: .downloadCapture, outcome: .skipped, code: "outside_window", dest: "dropbox")).text
                == "Skipped · outside_window")
        #expect(line(LogEvent(event: .downloadCapture, outcome: .failed, code: "invalid_package", dest: "dropbox")).text
                == "Couldn't download · invalid_package")
    }
}

@Suite struct CameraLogLineTests {
    private func line(_ e: LogEvent) -> LogLine {
        LogLine.make(e, id: 0, now: Date(timeIntervalSince1970: 1_800_000_000), zone: TimeZone(identifier: "UTC")!,
                     locale: Locale(identifier: "en_US_POSIX"))
    }

    @Test func photoLibrarySaveLines() {
        #expect(line(LogEvent(event: .cameraLibrarySave, captureID: "c1", outcome: .ok)).text == "Saved to Photos")
        #expect(line(LogEvent(event: .cameraLibrarySave, captureID: "c1", outcome: .failed, code: "denied")).text
                == "Couldn't save to Photos · denied")
        #expect(line(LogEvent(event: .cameraLibrarySave, captureID: "c1", outcome: .failed, code: "failed")).text
                == "Couldn't save to Photos · failed")
    }
}
