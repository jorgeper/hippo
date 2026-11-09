import Foundation
import CaptureCore

/// Which process wrote an event. Background tasks run in the app process.
public enum LogProcess: String, Codable, Sendable { case app, share }

public enum LogOutcome: String, Codable, Sendable {
    case ok, empty
    case notApplicable = "not_applicable"
    case deferred, retrying, failed, skipped, cancelled
}

/// The closed set of event names. Documented in `docs/log-format.md`.
public enum LogEventName: String, Codable, Sendable, CaseIterable {
    case captureSaved = "capture.saved"
    case captureDeleted = "capture.deleted"
    case captureSaveFailed = "capture.save_failed"
    case enrichQueued = "enrich.queued"
    case enrichStarted = "enrich.started"
    case enrichFinished = "enrich.finished"
    case enrichDeferred = "enrich.deferred"
    case enrichRetrying = "enrich.retrying"
    case enrichFailed = "enrich.failed"
    case enrichScheduled = "enrich.scheduled"
    case enrichPass = "enrich.pass"
    case silverUploaded = "silver.uploaded"
    case silverUploadFailed = "silver.upload_failed"
    case packageUploaded = "package.uploaded"
    case packageUploadFailed = "package.upload_failed"
    case goldApplied = "gold.applied"
    case goldRemoved = "gold.removed"
    case goldSkipped = "gold.skipped"
    case goldPull = "gold.pull"
    case remoteDelete = "remote.delete"
    case remoteChanged = "remote.changed"
    case remoteReview = "remote.review"
    case syncPass = "sync.pass"
    case bgTask = "bg.task"
    case appLaunch = "app.launch"
    case settingsChanged = "settings.changed"
    case logTruncated = "log.truncated"
    case logCleared = "log.cleared"
}

/// One log line. Content-free by construction: every free-form field passes `Diagnostics.safeCode` in
/// `init`, and no field can be changed afterwards (only `ActivityLog` stamps `t`, `v` and `proc`).
public struct LogEvent: Codable, Equatable, Sendable {
    public internal(set) var t: Date
    public internal(set) var v: Int
    public internal(set) var proc: LogProcess
    public private(set) var event: LogEventName
    public private(set) var captureID: String?
    public private(set) var kind: String?
    public private(set) var outcome: LogOutcome?
    public private(set) var code: String?
    public private(set) var attempt: Int?
    public private(set) var count: Int?
    public private(set) var ms: Int?
    public private(set) var trigger: String?
    public private(set) var dest: String?
    public private(set) var on: Bool?
    /// `start`, `end` or `expired`, for `sync.pass`, `enrich.pass` and `bg.task`.
    public private(set) var phase: String?
    public private(set) var retryAt: Date?

    /// `t`, `v` and `proc` are stamped by the `ActivityLog` that writes the event.
    public init(event: LogEventName, captureID: String? = nil, kind: String? = nil, outcome: LogOutcome? = nil,
                code: String? = nil, attempt: Int? = nil, count: Int? = nil, ms: Int? = nil,
                trigger: String? = nil, dest: String? = nil, on: Bool? = nil, phase: String? = nil,
                retryAt: Date? = nil) {
        t = Date(timeIntervalSince1970: 0)
        v = 1
        proc = .app
        self.event = event
        self.captureID = captureID
        self.kind = kind.map(Diagnostics.safeCode)
        self.outcome = outcome
        self.code = code.map(Diagnostics.safeCode)
        self.attempt = attempt
        self.count = count
        self.ms = ms
        self.trigger = trigger.map(Diagnostics.safeCode)
        self.dest = dest.map(Diagnostics.safeCode)
        self.on = on
        self.phase = phase.map(Diagnostics.safeCode)
        self.retryAt = retryAt
    }

    enum CodingKeys: String, CodingKey {
        case t, v, proc, event
        case captureID = "capture_id"
        case kind, outcome, code, attempt, count, ms, trigger, dest, on, phase
        case retryAt = "retry_at"
    }

    /// One compact JSON object, sorted keys, nil fields omitted, RFC 3339 UTC millisecond dates.
    func encodeLine() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(HippoJSON.timestamp(date))
        }
        return try encoder.encode(self)
    }

    /// Parses one line. Throws on anything that is not a complete event.
    public static func decode(_ data: Data) throws -> LogEvent {
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let plain = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let d = try? fractional.parse(s) { return d }
            if let d = try? plain.parse(s) { return d }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "Invalid RFC 3339 date"))
        }
        return try decoder.decode(LogEvent.self, from: data)
    }
}
