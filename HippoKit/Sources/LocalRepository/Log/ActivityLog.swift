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

    private func segmentURL(day: String, segment: Int) -> URL {
        layout.logsDir.appendingPathComponent(segment == 0 ? "\(day).jsonl" : "\(day).\(segment).jsonl")
    }

    /// Today's segment: the cached one if it still exists, else the highest on disk, else segment 0 to be
    /// created (`create`).
    private func target(day: String) -> (url: URL, create: Bool) {
        let cached = cache.withLock { $0.day == day ? $0.url : nil }
        if let cached, FileManager.default.fileExists(atPath: cached.path) { return (cached, false) }
        try? FileManager.default.createDirectory(at: layout.logsDir, withIntermediateDirectories: true)
        if let highest = orderedSegments().last(where: { $0.day == day }) {
            cache.withLock { $0 = Cache(day: day, url: highest.url) }
            return (highest.url, false)
        }
        let url = segmentURL(day: day, segment: 0)
        cache.withLock { $0 = Cache(day: day, url: url) }
        return (url, true)
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

    private enum Opened { case locked(Int32), gone, failed }

    /// Opens `url` and takes the lock. An existing segment is opened without `O_CREAT`, so a segment that a
    /// `clear()` deleted is never re-created. `.gone` means look again: the file is missing, was unlinked
    /// while we waited, or (when creating segment 0) another segment of the day has appeared.
    private func openLocked(_ url: URL, create: Bool, timeout: Duration) -> Opened {
        let fd = open(url.path, O_WRONLY | O_APPEND | (create ? O_CREAT : 0), 0o644)
        guard fd >= 0 else { return errno == ENOENT ? .gone : .failed }
        guard lock(fd, timeout: timeout) else { close(fd); return .failed }
        var st = stat()
        guard fstat(fd, &st) == 0 else { flock(fd, LOCK_UN); close(fd); return .failed }
        var gone = st.st_nlink == 0
        if create, !gone, let parsed = Self.parse(fileName: url.lastPathComponent),
           orderedSegments().contains(where: { $0.day == parsed.day && $0.segment != parsed.segment }) {
            // A clear created a later segment meanwhile: our empty file must not come back as segment 0.
            if st.st_size == 0 { try? FileManager.default.removeItem(at: url) }
            gone = true
        }
        if gone { flock(fd, LOCK_UN); close(fd); return .gone }
        return .locked(fd)
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
            let (url, create) = target(day: day)
            let fd: Int32
            switch openLocked(url, create: create, timeout: remaining) {
            case .locked(let f): fd = f
            case .gone:
                cache.withLock { $0 = Cache(day: nil, url: nil) }
                continue
            case .failed:
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

    /// Records `log.cleared` in the next segment of today, then deletes every older log file (not
    /// `upload-state.json`), so a remote copy of today's file is never overwritten by a near-empty one and
    /// a day always has a segment for appenders to find. Today's current segment stays locked meanwhile,
    /// so waiting appenders see it unlinked and move to the new segment.
    public func clear() {
        let date = now()
        let day = Self.dayString(date)
        let current = orderedSegments().last { $0.day == day }
        let next = (current?.segment ?? -1) + 1
        try? FileManager.default.createDirectory(at: layout.logsDir, withIntermediateDirectories: true)
        var held: Int32?
        if let current, case .locked(let fd) = openLocked(current.url, create: false, timeout: lockTimeout) { held = fd }
        defer { if let held { flock(held, LOCK_UN); close(held) } }

        var marker = LogEvent(event: .logCleared)
        marker.t = date; marker.proc = process
        let url = segmentURL(day: day, segment: next)
        guard var line = try? marker.encodeLine() else { return }
        line.append(0x0A)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { Self.osLog.error("\("write_failed", privacy: .public)"); return }
        defer { close(fd) }
        if !Self.writeAll(fd, line) { Self.osLog.error("\("write_failed", privacy: .public)") }
        cache.withLock { $0 = Cache(day: day, url: url) }
        for s in orderedSegments() where s.url.lastPathComponent != url.lastPathComponent { try? FileManager.default.removeItem(at: s.url) }
    }
}
