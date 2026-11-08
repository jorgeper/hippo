import Foundation
import CaptureCore
import LocalRepository

/// One readable line of the activity log. Built only from what an event carries, which is no content.
public struct LogLine: Equatable, Sendable, Identifiable {
    public var id: Int
    /// Local `HH:mm:ss`, with `MMM d` in front when the event is not from today.
    public var time: String
    public var layer: Layer
    public var text: String

    public static func make(_ e: LogEvent, id: Int, now: Date, zone: TimeZone, locale: Locale) -> LogLine {
        LogLine(id: id, time: timeString(e.t, now: now, zone: zone, locale: locale), layer: layer(e.event),
                text: text(e, zone: zone, locale: locale))
    }

    // MARK: Time

    private static func format(_ date: Date, _ pattern: String, zone: TimeZone, locale: Locale) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = zone
        f.dateFormat = pattern
        return f.string(from: date)
    }

    static func timeString(_ t: Date, now: Date, zone: TimeZone, locale: Locale) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let clock = format(t, "HH:mm:ss", zone: zone, locale: locale)
        if cal.isDate(t, inSameDayAs: now) { return clock }
        return "\(format(t, "MMM d", zone: zone, locale: locale)) \(clock)"
    }

    // MARK: Layer

    static func layer(_ name: LogEventName) -> Layer {
        switch name {
        case .enrichQueued, .enrichStarted, .enrichFinished, .enrichDeferred, .enrichRetrying, .enrichFailed,
             .enrichScheduled, .enrichPass:
            .silver
        case .goldApplied, .goldRemoved, .goldSkipped, .goldPull: .gold
        case .packageUploaded, .packageUploadFailed, .silverUploaded, .silverUploadFailed, .syncPass, .bgTask: .sync
        default: .bronze
        }
    }

    // MARK: Text

    private static func destination(_ dest: String?) -> String? {
        switch dest {
        case "dropbox": "Dropbox"
        case "filesystem": "the Developer folder"
        default: nil
        }
    }

    private static func duration(_ ms: Int) -> String {
        ms < 1000 ? "\(ms) ms" : String(format: "%.1f s", Double(ms) / 1000)
    }

    private static func text(_ e: LogEvent, zone: TimeZone, locale: Locale) -> String {
        let kind = e.kind.map { EnrichmentProgress.kindName(FacetKind(rawValue: $0)) }
        func join(_ parts: [String?]) -> String { parts.compactMap { $0 }.joined(separator: " · ") }
        switch e.event {
        case .captureSaved:
            switch e.proc {
            case .share: return "Saved from the share sheet"
            case .app: return "Saved"
            }
        case .captureDeleted: return "Deleted from this iPhone"
        case .captureSaveFailed: return join(["Save failed", e.code])
        case .enrichQueued: return join([kind, "queued"])
        case .enrichStarted: return join([kind, "started", e.attempt.flatMap { $0 > 1 ? "attempt \($0)" : nil }])
        case .enrichFinished:
            switch e.outcome {
            case .ok?: return join([kind, e.count.map { "found \($0)" } ?? "done", e.ms.map(duration)])
            case .empty?: return join([kind, "nothing found", e.ms.map(duration)])
            default: break
            }
        case .enrichDeferred:
            let retry = e.retryAt.map { "retry " + format($0, "HH:mm", zone: zone, locale: locale) }
            return join([kind, e.code.map { "waiting: \($0)" } ?? "waiting", retry])
        case .enrichRetrying: return join([kind, "failed, will retry", e.code, e.attempt.map { "attempt \($0)" }])
        case .enrichFailed: return join([kind, "failed", e.code])
        case .silverUploaded, .packageUploaded:
            if let d = destination(e.dest) { return "Uploaded to \(d)" }
        case .silverUploadFailed, .packageUploadFailed:
            if let d = destination(e.dest) { return join(["Upload to \(d) failed", e.code]) }
        case .syncPass:
            let trigger = e.trigger.map { " (\($0))" } ?? ""
            switch e.phase {
            case "start": return "Sync started" + trigger
            case "end":
                return join(["Sync finished" + trigger, e.count.map { "\($0) uploaded" }, e.code])
            default: break
            }
        case .appLaunch: return join(["App launched", e.code])
        case .settingsChanged:
            if let on = e.on { return join([e.kind, on ? "turned on" : "turned off"]) }
        case .logCleared: return "Log cleared"
        case .logTruncated: return "Log full, later events dropped"
        default: break
        }
        return join([e.event.rawValue, e.outcome?.rawValue, e.code])
    }
}
