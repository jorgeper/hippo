import Foundation
import Testing
import CaptureCore
@testable import LocalRepository

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    var now: Date { lock.withLock { date } }
    func set(_ d: Date) { lock.withLock { date = d } }
}

private func utc(_ s: String) -> Date { try! Date.ISO8601FormatStyle().parse(s) }

private struct LogHarness {
    let root: URL
    let layout: StoreLayout
    let clock: Clock

    init(at s: String = "2026-11-08T12:00:00Z") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hippo-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        layout = StoreLayout(root: root)
        clock = Clock(utc(s))
    }

    func log(_ process: LogProcess = .app, lockTimeout: Duration = .milliseconds(100),
             segmentCap: Int = 2_097_152) -> ActivityLog {
        let clock = clock
        return ActivityLog(layout: layout, process: process, now: { clock.now }, lockTimeout: lockTimeout,
                           segmentCap: segmentCap)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func url(_ name: String) -> URL { layout.logsDir.appendingPathComponent(name) }

    func lines(_ name: String) throws -> [String] {
        try String(contentsOf: url(name), encoding: .utf8).split(separator: "\n").map(String.init)
    }
}

@Suite struct ActivityLogTests {
    @Test func appendWritesOneJSONLinePerEvent() throws {
        let t = try LogHarness(); defer { t.cleanup() }
        let log = t.log()
        let e1 = LogEvent(event: .captureSaved, captureID: "c1", trigger: "share_extension")
        log.append(e1)
        log.append(LogEvent(event: .appLaunch, code: "1.0-1"))

        let lines = try t.lines("2026-11-08.jsonl")
        #expect(lines.count == 2)
        let decoded = try LogEvent.decode(Data(lines[0].utf8))
        #expect(decoded.proc == .app)
        #expect(decoded.v == 1)
        #expect(decoded.event == .captureSaved)
        #expect(decoded.captureID == "c1")
        #expect(decoded.t == t.clock.now)
        #expect(!lines[1].contains("capture_id"))
        #expect(lines[0].contains("\"capture_id\":\"c1\""))
        #expect(lines[0].contains("\"t\":\"2026-11-08T12:00:00.000Z\""))
    }

    @Test func codesAreSanitized() {
        let e = LogEvent(event: .enrichFailed, code: "Hello World https://x")
        #expect(e.code == "unrecognized")
        #expect(LogEvent(event: .enrichFailed, kind: "link preview", trigger: "A", dest: "x/y", phase: "S").kind == "unrecognized")
        #expect(LogEvent(event: .enrichFailed, code: "transient:429").code == "transient:429")
    }

    @Test func concurrentWritersNeverInterleave() async throws {
        let t = try LogHarness(); defer { t.cleanup() }
        let app = t.log(.app, lockTimeout: .seconds(5))
        let share = t.log(.share, lockTimeout: .seconds(5))
        await withTaskGroup(of: Void.self) { group in
            for (log, tag) in [(app, "a"), (share, "s")] {
                group.addTask {
                    for i in 0..<500 { log.append(LogEvent(event: .captureSaved, captureID: "\(tag)-\(i)", trigger: "note")) }
                }
            }
        }
        let lines = try t.lines("2026-11-08.jsonl")
        #expect(lines.count == 1000)
        for line in lines { _ = try LogEvent.decode(Data(line.utf8)) }
    }

    @Test func appendIsDurableBeforeReturn() throws {
        let t = try LogHarness(); defer { t.cleanup() }
        t.log(.share).append(LogEvent(event: .captureSaved, captureID: "c1", trigger: "note"))
        let events = t.log(.app).events(captureID: "c1", from: t.clock.now)
        #expect(events.map(\.event) == [.captureSaved])
        #expect(events.first?.proc == .share)
    }

    @Test func lockTimeoutDropsEvent() throws {
        let t = try LogHarness(); defer { t.cleanup() }
        let log = t.log()
        log.append(LogEvent(event: .appLaunch))
        let fd = open(t.url("2026-11-08.jsonl").path, O_WRONLY | O_APPEND)
        #expect(fd >= 0)
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        defer { flock(fd, LOCK_UN); close(fd) }

        let start = ContinuousClock.now
        log.append(LogEvent(event: .appLaunch))
        #expect(ContinuousClock.now - start < .milliseconds(300))
        #expect(try t.lines("2026-11-08.jsonl").count == 1)
    }

    @Test func segmentCapWritesOneTruncatedMarker() throws {
        let t = try LogHarness(); defer { t.cleanup() }
        let log = t.log(segmentCap: 400)
        for i in 0..<20 { log.append(LogEvent(event: .captureSaved, captureID: "c-\(i)", trigger: "note")) }
        let events = try t.lines("2026-11-08.jsonl").map { try LogEvent.decode(Data($0.utf8)) }
        #expect(events.filter { $0.event == .logTruncated }.count == 1)
        #expect(events.last?.event == .logTruncated)
        #expect(events.count < 20)
    }

    @Test func eventsForCaptureStartAtItsDay() throws {
        let t = try LogHarness(at: "2026-11-06T10:00:00Z"); defer { t.cleanup() }
        let log = t.log()
        log.append(LogEvent(event: .captureSaved, captureID: "A", trigger: "note"))
        t.clock.set(utc("2026-11-08T09:00:00Z"))
        log.append(LogEvent(event: .enrichQueued, captureID: "A", kind: "transcript"))
        log.append(LogEvent(event: .enrichStarted, captureID: "B", kind: "transcript"))
        t.clock.set(utc("2026-11-08T10:00:00Z"))
        log.append(LogEvent(event: .enrichFinished, captureID: "A", kind: "transcript", outcome: .ok))

        let events = log.events(captureID: "A", from: utc("2026-11-07T00:00:00Z"))
        #expect(events.map(\.event) == [.enrichQueued, .enrichFinished])
    }

    @Test func globalEventsNewestFirstWithLimit() throws {
        let t = try LogHarness(); defer { t.cleanup() }
        let log = t.log()
        for i in 0..<5 {
            t.clock.set(utc("2026-11-08T12:00:00Z").addingTimeInterval(Double(i) * 10))
            log.append(LogEvent(event: .syncPass, count: i, phase: "end"))
            log.append(LogEvent(event: .captureSaved, captureID: "c\(i)", trigger: "note"))
        }
        let page = log.globalEvents(limit: 3, before: nil)
        #expect(page.map { $0.count } == [4, 3, 2])
        let next = log.globalEvents(limit: 3, before: page.last?.t)
        #expect(next.map { $0.count } == [1, 0])
    }

    @Test func readerSkipsTornLine() throws {
        let t = try LogHarness(); defer { t.cleanup() }
        let log = t.log()
        log.append(LogEvent(event: .captureSaved, captureID: "c1", trigger: "note"))
        let h = try FileHandle(forWritingTo: t.url("2026-11-08.jsonl"))
        try h.seekToEnd(); try h.write(contentsOf: Data("{\"t\":".utf8)); try h.close()
        #expect(log.events(captureID: "c1", from: t.clock.now).count == 1)
    }

    @Test func pruneKeeps30Days() throws {
        let t = try LogHarness(); defer { t.cleanup() }
        try FileManager.default.createDirectory(at: t.layout.logsDir, withIntermediateDirectories: true)
        for name in ["2026-10-08.jsonl", "2026-10-08.1.jsonl", "2026-10-10.jsonl", "upload-state.json"] {
            try Data("x\n".utf8).write(to: t.url(name))
        }
        t.log().prune()
        let left = try FileManager.default.contentsOfDirectory(atPath: t.layout.logsDir.path).sorted()
        #expect(left == ["2026-10-10.jsonl", "upload-state.json"])
    }

    @Test func clearStartsNextSegment() throws {
        let t = try LogHarness(); defer { t.cleanup() }
        let log = t.log()
        try FileManager.default.createDirectory(at: t.layout.logsDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: t.url("upload-state.json"))
        log.append(LogEvent(event: .appLaunch))
        log.append(LogEvent(event: .appLaunch))
        log.clear()
        #expect(!FileManager.default.fileExists(atPath: t.url("2026-11-08.jsonl").path))
        #expect(try t.lines("2026-11-08.1.jsonl").count == 1)
        #expect(try t.lines("2026-11-08.1.jsonl")[0].contains("log.cleared"))
        log.append(LogEvent(event: .appLaunch))
        #expect(try t.lines("2026-11-08.1.jsonl").count == 2)

        log.clear()
        #expect(log.segmentFiles().map(\.lastPathComponent) == ["2026-11-08.2.jsonl"])
        #expect(FileManager.default.fileExists(atPath: t.url("upload-state.json").path))
    }

    @Test func fileNames() {
        #expect(ActivityLog.fileName(day: utc("2026-11-08T23:59:59Z"), segment: 0) == "2026-11-08.jsonl")
        #expect(ActivityLog.fileName(day: utc("2026-11-08T00:00:00Z"), segment: 1) == "2026-11-08.1.jsonl")
    }
}
