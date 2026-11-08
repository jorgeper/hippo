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
    public private(set) var lastUpload: String?

    public init(store: HippoStore, pageSize: Int = 500) {
        self.store = store
        self.pageSize = pageSize
        refreshLastUpload()
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
        refreshLastUpload()
    }

    public func clear() async {
        let store = store
        await Task.detached { store.log.clear() }.value
        await load()
    }

    public func copyText(appVersion: String) -> String {
        (["Hippo log · app \(appVersion)"] + lines.map { "\($0.time)  \($0.text)" }).joined(separator: "\n")
    }

    private func refreshLastUpload() {
        guard let r = LogUploader.lastResult(layout: store.layout) else { lastUpload = nil; return }
        if let code = r.code { lastUpload = "Last log upload failed: \(code)"; return }
        let f = DateFormatter()
        f.locale = Locale.current; f.timeZone = TimeZone.current; f.dateFormat = "HH:mm"
        lastUpload = "Last log upload \(f.string(from: r.at))"
    }
}
