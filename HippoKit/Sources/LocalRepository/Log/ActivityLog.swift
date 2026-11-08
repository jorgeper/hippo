import Foundation
import CaptureCore
import os

/// The content-free event log (design §7): JSON Lines, one file per UTC day, in `logs/` beside the
/// store. The app and the share extension both append, each line in a single `write` under an advisory
/// `flock`, so lines never interleave. Nothing here throws: a failed or timed-out write drops the event.
public final class ActivityLog: Sendable {
    /// Fixed category strings only.
    private static let osLog = Logger(subsystem: "com.jorgeper.hippo", category: "log")

    private struct Cache { var day: String?; var url: URL? }

    private let layout: StoreLayout
    private let process: LogProcess
    private let now: @Sendable () -> Date
    private let lockTimeout: Duration
    private let segmentCap: Int
    private let cache = OSAllocatedUnfairLock(initialState: Cache())

    public init(layout: StoreLayout, process: LogProcess, now: @escaping @Sendable () -> Date = Date.init,
                lockTimeout: Duration = .milliseconds(100), segmentCap: Int = 2_097_152) {
        self.layout = layout
        self.process = process
        self.now = now
        self.lockTimeout = lockTimeout
        self.segmentCap = segmentCap
    }

    // MARK: Names

    /// `2026-11-08.jsonl` for segment 0, `2026-11-08.1.jsonl` for segment 1.
    public static func fileName(day: Date, segment: Int) -> String {
        segment == 0 ? "\(dayString(day)).jsonl" : "\(dayString(day)).\(segment).jsonl"
    }

    static func dayString(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// `(day, segment)` of a `YYYY-MM-DD[.N].jsonl` file name; nil for anything else.
    static func parse(fileName: String) -> (day: String, segment: Int)? {
        guard fileName.hasSuffix(".jsonl") else { return nil }
        let parts = fileName.dropLast(".jsonl".count).split(separator: ".", omittingEmptySubsequences: false)
        guard let day = parts.first, day.count == 10 else { return nil }
        switch parts.count {
        case 1: return (String(day), 0)
        case 2: return Int(parts[1]).map { (String(day), $0) }
        default: return nil
        }
    }

    // MARK: Files

    /// Every `*.jsonl` in the log folder, sorted by name.
    public func segmentFiles() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: layout.logsDir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Segment files in reading order: by day, then segment number.
    private func orderedSegments() -> [(day: String, segment: Int, url: URL)] {
        segmentFiles().compactMap { url in
            Self.parse(fileName: url.lastPathComponent).map { ($0.day, $0.segment, url) }
        }.sorted { ($0.day, $0.segment) < ($1.day, $1.segment) }
    }

    private func currentSegment(day: String) -> URL {
        let highest = orderedSegments().last { $0.day == day }
        if let highest { return highest.url }
        return layout.logsDir.appendingPathComponent("\(day).jsonl")
    }

    private func segmentURL(day: String, segment: Int) -> URL {
        layout.logsDir.appendingPathComponent(segment == 0 ? "\(day).jsonl" : "\(day).\(segment).jsonl")
    }

    /// The cached segment for `day` if it still exists, else the highest on disk.
    private func target(day: String) -> URL {
        let cached = cache.withLock { $0.day == day ? $0.url : nil }
        if let cached, FileManager.default.fileExists(atPath: cached.path) { return cached }
        try? FileManager.default.createDirectory(at: layout.logsDir, withIntermediateDirectories: true)
        let url = currentSegment(day: day)
        cache.withLock { $0 = Cache(day: day, url: url) }
        return url
    }

    /// Takes `LOCK_EX` on `fd`, retrying every 5 ms for at most `timeout`.
    private func lock(_ fd: Int32, timeout: Duration) -> Bool {
        let deadline = ContinuousClock.now + timeout
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return true }
            guard errno == EWOULDBLOCK || errno == EINTR, ContinuousClock.now < deadline else { return false }
            usleep(5_000)
        }
    }

    /// Opens `url`, takes the lock, and checks the file is still the one at that path (a `clear()` may
    /// have unlinked it while we waited). Returns the locked descriptor, or nil on failure or timeout.
    private func openLocked(_ url: URL, timeout: Duration) -> Int32? {
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return nil }
        guard lock(fd, timeout: timeout) else { close(fd); return nil }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_nlink > 0 else { flock(fd, LOCK_UN); close(fd); return nil }
        return fd
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buf in
            var offset = 0
            while offset < buf.count {
                let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n < 0 { if errno == EINTR { continue }; return false }
                offset += n
            }
            return true
        }
    }

    // MARK: Writing

    /// Appends one line. Never throws; on a lock timeout or write error the event is dropped.
    public func append(_ e: LogEvent) {
        var event = e
        let date = now()
        event.t = date
        event.v = 1
        event.proc = process
        guard let line = try? event.encodeLine() else { return }
        let day = Self.dayString(date)

        let deadline = ContinuousClock.now + lockTimeout
        for _ in 0..<4 {
            let remaining = max(.zero, deadline - ContinuousClock.now)
            let url = target(day: day)
            guard let fd = openLocked(url, timeout: remaining) else {
                // An unlinked file means a clear won the race: look again. Anything else drops the event.
                if !FileManager.default.fileExists(atPath: url.path), ContinuousClock.now < deadline {
                    cache.withLock { $0 = Cache(day: nil, url: nil) }
                    continue
                }
                Self.osLog.error("\("append_dropped", privacy: .public)")
                return
            }
            defer { flock(fd, LOCK_UN); close(fd) }

            var st = stat()
            guard fstat(fd, &st) == 0 else { return }
            var payload = Data()
            if st.st_size > 0, !Self.endsWithNewline(url: url, size: st.st_size) { payload.append(0x0A) }
            if Int(st.st_size) >= segmentCap {
                guard !Self.lastLineIsTruncationMarker(url: url, size: st.st_size) else { return }
                var marker = LogEvent(event: .logTruncated)
                marker.t = date; marker.proc = process
                guard let markerLine = try? marker.encodeLine() else { return }
                payload.append(markerLine); payload.append(0x0A)
                if !Self.writeAll(fd, payload) { Self.osLog.error("\("write_failed", privacy: .public)") }
                return
            }
            payload.append(line); payload.append(0x0A)
            if !Self.writeAll(fd, payload) { Self.osLog.error("\("write_failed", privacy: .public)") }
            return
        }
        Self.osLog.error("\("append_dropped", privacy: .public)")
    }

    private static func tail(url: URL, size: off_t, bytes: Int) -> Data? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let start = max(0, Int(size) - bytes)
        guard (try? h.seek(toOffset: UInt64(start))) != nil else { return nil }
        return try? h.readToEnd()
    }

    private static func endsWithNewline(url: URL, size: off_t) -> Bool {
        tail(url: url, size: size, bytes: 1)?.last == 0x0A
    }

    private static func lastLineIsTruncationMarker(url: URL, size: off_t) -> Bool {
        guard let data = tail(url: url, size: size, bytes: 512) else { return false }
        let last = data.split(separator: 0x0A).last.flatMap { String(decoding: $0, as: UTF8.self) } ?? ""
        return last.contains("\"log.truncated\"")
    }

    // MARK: Reading

    private func readEvents(_ url: URL) -> [LogEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? LogEvent.decode(Data($0)) }
    }

    /// Events for `captureID`, oldest first, from every segment of each day from `day`'s UTC day onward.
    public func events(captureID: String, from day: Date) -> [LogEvent] {
        let first = Self.dayString(day)
        return orderedSegments().filter { $0.day >= first }
            .flatMap { readEvents($0.url) }
            .filter { $0.captureID == captureID }
    }

    /// Events with no capture ID, newest first, strictly older than `before` when given.
    public func globalEvents(limit: Int, before: Date?) -> [LogEvent] {
        var out: [LogEvent] = []
        for segment in orderedSegments().reversed() {
            for e in readEvents(segment.url).reversed() where e.captureID == nil && (before.map { e.t < $0 } ?? true) {
                out.append(e)
                if out.count >= limit { return out }
            }
        }
        return out
    }

    // MARK: Retention

    /// Deletes day files older than `keepingDays` days (by the date in the file name).
    public func prune(keepingDays: Int = 30) {
        let cutoff = Self.dayString(now().addingTimeInterval(-Double(keepingDays) * 86_400))
        for s in orderedSegments() where s.day < cutoff { try? FileManager.default.removeItem(at: s.url) }
    }

    /// Deletes every log file (not `upload-state.json`) and records `log.cleared` in the next segment of
    /// today, so a remote copy of today's file is never overwritten by a near-empty one.
    public func clear() {
        let date = now()
        let day = Self.dayString(date)
        let current = orderedSegments().last { $0.day == day }
        let next = (current?.segment ?? -1) + 1
        try? FileManager.default.createDirectory(at: layout.logsDir, withIntermediateDirectories: true)
        // Hold today's current segment while deleting, so no append lands in a file about to go away.
        let fd = current.flatMap { openLocked($0.url, timeout: .seconds(1)) }
        defer { if let fd { flock(fd, LOCK_UN); close(fd) } }
        for s in orderedSegments() { try? FileManager.default.removeItem(at: s.url) }

        var marker = LogEvent(event: .logCleared)
        marker.t = date; marker.proc = process
        let url = segmentURL(day: day, segment: next)
        cache.withLock { $0 = Cache(day: day, url: url) }
        guard var line = try? marker.encodeLine() else { return }
        line.append(0x0A)
        if let out = openLocked(url, timeout: lockTimeout) {
            if !Self.writeAll(out, line) { Self.osLog.error("\("write_failed", privacy: .public)") }
            flock(out, LOCK_UN); close(out)
        }
    }
}
