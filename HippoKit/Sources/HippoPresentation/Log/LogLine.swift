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
        let clock = format(t, "HH:mm:ss", zone: zone, locale: Locale(identifier: "en_US_POSIX"))
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

    private static func settingName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        switch raw {
        case "location": return "Save location"
        case "layer_stripes": return "Show where details came from"
        case "developer_mode": return "Developer mode"
        default:
            let k = FacetKind(rawValue: raw)
            let name = EnrichmentProgress.kindName(k)
            return name
        }
    }

    private static func text(_ e: LogEvent, zone: TimeZone, locale: Locale) -> String {
        let kind = e.kind.map { EnrichmentProgress.kindName(FacetKind(rawValue: $0)) }
        func join(_ parts: [String?]) -> String { parts.compactMap { $0 }.joined(separator: " · ") }
        let fallback = join([e.event.rawValue, e.outcome?.rawValue, e.code])
        switch e.event {
        case .captureSaved:
            switch e.proc {
            case .share: return "Saved from the share sheet"
            case .app: return "Saved"
            }
        case .captureDeleted: return "Deleted from this iPhone"
        case .captureSaveFailed: return join(["Save failed", e.code])
        case .commentAdded: return join(["Comment added", e.kind == "audio" ? "audio" : nil])
        case .commentSaveFailed: return join(["Couldn't save comment", e.code])
        case .enrichQueued: return join([kind, "queued"])
        case .enrichStarted: return join([kind, "started", e.attempt.flatMap { $0 > 1 ? "attempt \($0)" : nil }])
        case .enrichFinished:
            switch e.outcome {
            case .ok?: return join([kind, e.count.map { "found \($0)" } ?? "done", e.ms.map(duration)])
            case .empty?: return join([kind, "nothing found", e.ms.map(duration)])
            case .failed?: return join([kind, "failed", e.code, e.ms.map(duration)])
            case .skipped?, .cancelled?, .notApplicable?, .deferred?, .retrying?:
                return join([kind, e.outcome?.rawValue.replacingOccurrences(of: "_", with: " "), e.code, e.ms.map(duration)])
            case nil: return join([kind, "finished", e.ms.map(duration)])
            }
        case .enrichDeferred:
            let retry = e.retryAt.map { "retry " + format($0, "HH:mm", zone: zone, locale: Locale(identifier: "en_US_POSIX")) }
            return join([kind, e.code.map { "waiting: \($0)" } ?? "waiting", retry])
        case .enrichRetrying: return join([kind, "failed, will retry", e.code, e.attempt.map { "attempt \($0)" }])
        case .enrichFailed: return join([kind, "failed", e.code])
        case .enrichScheduled:
            guard let kind else { return fallback }
            return e.count.map { "\(kind) queued for \($0) \($0 == 1 ? "capture" : "captures")" } ?? "\(kind) queued"
        case .enrichPass:
            switch e.phase {
            case "start": return "Enrichment pass started"
            case "end": return join(["Enrichment pass finished", e.count.map { "\($0) run" }, e.code.map { "(\($0))" }])
            default: return fallback
            }
        case .silverUploaded, .packageUploaded:
            if let d = destination(e.dest) { return "Uploaded to \(d)" }
            return "Uploaded"
        case .silverUploadFailed, .packageUploadFailed:
            let d = destination(e.dest).map { "Upload to \($0) failed" } ?? "Upload failed"
            return join([d, e.code])
        case .remoteDelete:
            let d = destination(e.dest) ?? "storage"
            switch e.outcome {
            case nil: return "Delete queued for \(d)"
            case .ok?: return "Deleted in \(d)"
            default: return join(["Delete in \(d) failed", e.code])
            }
        case .remoteChanged:
            if e.code == "unverified" { return "Not removed: upload not verified" }
            return "Changed in \(destination(e.dest) ?? "storage")"
        case .remoteReview:
            let d = destination(e.dest) ?? "storage"
            let head = d.prefix(1).uppercased() + d.dropFirst() + " looks different"
            return join([head, e.count.map { "\($0) \($0 == 1 ? "capture" : "captures") to review" }])
        case .trimRun:
            let n = e.count ?? 0
            let size = ByteCountFormatter.string(fromByteCount: e.bytes ?? 0, countStyle: .file)
            return join(["Saved space", "\(n) \(n == 1 ? "file" : "files")", size])
        case .attachmentRestored:
            let d = destination(e.dest).map { " from \($0)" } ?? ""
            if e.outcome == .failed { return join(["Download failed", e.code]) }
            return "Downloaded a file" + d
        case .cameraLibrarySave:
            if e.outcome == .failed { return join(["Couldn't save to Photos", e.code]) }
            return "Saved to Photos"
        case .downloadRun:
            let n = e.count ?? 0
            let d = destination(e.dest).map { " from \($0)" } ?? ""
            return join(["Downloaded \(n) \(n == 1 ? "capture" : "captures")" + d, e.code])
        case .downloadCapture:
            switch e.outcome {
            case .ok?, nil: return "Downloaded" + (destination(e.dest).map { " from \($0)" } ?? "")
            case .skipped?: return join(["Skipped", e.code])
            default: return join(["Couldn't download", e.code])
            }
        case .authConnected: return "Connected " + (destination(e.dest) ?? "storage")
        case .authDisconnected: return "Disconnected " + (destination(e.dest) ?? "storage")
        case .authRefreshFailed:
            guard let d = destination(e.dest) else { return "Sign-in expired" }
            return d.prefix(1).uppercased() + d.dropFirst() + " sign-in expired"
        case .goldApplied: return "Server results applied"
        case .goldRemoved: return "Server results removed"
        case .goldSkipped: return join(["Server results skipped", e.code])
        case .goldPull:
            return join(["Server results checked", e.count.map { "\($0) applied" }, e.on == true ? "sync position reset" : nil,
                         e.code])
        case .syncPass:
            let trigger = e.trigger.map { " (\($0))" } ?? ""
            switch e.phase {
            case "start": return "Sync started" + trigger
            case "end": return join(["Sync finished" + trigger, e.count.map { "\($0) uploaded" }, e.code])
            default: return fallback
            }
        case .bgTask:
            switch e.phase {
            case "start": return "Background task started"
            case "expired": return "Background task expired"
            case "end": return "Background task finished"
            default: return fallback
            }
        case .appLaunch: return join(["App launched", e.code])
        case .settingsChanged:
            guard let name = settingName(e.kind), let on = e.on else { return fallback }
            return "\(name) turned \(on ? "on" : "off")"
        case .logCleared: return "Log cleared"
        case .logTruncated: return "Log truncated (daily size limit)"
        }
    }
}
