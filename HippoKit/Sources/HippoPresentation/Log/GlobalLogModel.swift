import Foundation
import Observation
import SyncEngine

/// The global log behind Settings > Developer > Log, newest first, paged.
@MainActor @Observable
public final class GlobalLogModel {
    private let store: HippoStore
    private let pageSize: Int
    public private(set) var lines: [LogLine] = []
    public private(set) var canLoadMore = false
    /// Developer section's quiet line (spec §8.1): where logs go and how the last upload went.
    public private(set) var uploadLine = ""
    private let now: @Sendable () -> Date
    private let locale: Locale
    private let zone: TimeZone

    public init(store: HippoStore, pageSize: Int = 500, now: @escaping @Sendable () -> Date = Date.init,
                locale: Locale = .current, zone: TimeZone = .current) {
        self.store = store
        self.pageSize = pageSize
        self.now = now
        self.locale = locale
        self.zone = zone
        refreshUploadLine()
    }

    public func load() async {
        lines = []
        canLoadMore = false
        await loadMore()
    }

    /// Re-reads one page deeper from the newest event. Paging by timestamp would drop events that share one.
    public func loadMore() async {
        let store = store, limit = lines.count + pageSize
        let events = await Task.detached { store.log.globalEvents(limit: limit, before: nil) }.value
        let now = Date(), zone = TimeZone.current, locale = Locale.current
        lines = events.enumerated().map { LogLine.make($1, id: $0, now: now, zone: zone, locale: locale) }
        canLoadMore = events.count == limit
        refreshUploadLine()
    }

    public func clear() async {
        let store = store
        await Task.detached { store.log.clear() }.value
        await load()
    }

    public func copyText(appVersion: String) -> String {
        (["Hippo log · app \(appVersion)"] + lines.map { "\($0.time)  \($0.text)" }).joined(separator: "\n")
    }

    private func refreshUploadLine() {
        guard let destination = try? store.destinations.active() else {
            uploadLine = "Logs aren't uploaded: no storage connected"
            return
        }
        let head = "Logs upload to \(destination.displayName)"
        guard let r = LogUploader.lastResult(layout: store.layout) else { uploadLine = "\(head) · not uploaded yet"; return }
        let when = Self.dayAndTime(r.at, now: now(), locale: locale, zone: zone)
        if let code = r.code {
            uploadLine = "\(head) · last upload failed \(when) (\(code))"
        } else {
            uploadLine = "\(head) · last upload \(when)"
        }
    }

    /// "today 14:02", "yesterday 09:15", else "Nov 1 14:02".
    static func dayAndTime(_ date: Date, now: Date, locale: Locale, zone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let time = DateFormatter()
        time.locale = locale; time.timeZone = zone; time.dateFormat = "HH:mm"
        let clock = time.string(from: date)
        if cal.isDate(date, inSameDayAs: now) { return "today \(clock)" }
        if let yesterday = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: yesterday) {
            return "yesterday \(clock)"
        }
        let day = DateFormatter()
        day.locale = locale; day.timeZone = zone; day.calendar = cal
        day.setLocalizedDateFormatFromTemplate("MMMd")
        return "\(day.string(from: date)) \(clock)"
    }
}
