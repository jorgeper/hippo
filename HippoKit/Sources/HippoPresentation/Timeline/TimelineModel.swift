import Foundation
import Observation
import os
import CaptureCore
import LocalRepository
import SyncEngine

@MainActor @Observable
public final class TimelineModel {
    private struct Item: Sendable {
        var summary: CaptureSummary
        var row: TimelineRow
    }

    private struct Page: Sendable {
        var items: [Item]
        var reachedEnd: Bool
    }

    public private(set) var sections: [(header: String, rows: [TimelineRow])] = []
    public private(set) var isEmpty = false
    /// True after a failed reload or page; cleared by the next successful reload.
    public private(set) var loadFailed = false

    public var filter = TimelineFilterState() {
        didSet {
            guard !suppressFilterReload, filter != oldValue else { return }
            debounceTask?.cancel()
            reloadTask?.cancel()
            reloadTask = Task { await reload() }
        }
    }

    /// Counts completed `reload()` calls; tests use it to see debouncing.
    private(set) var reloadCount = 0

    @ObservationIgnored private let store: HippoStore
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let locale: Locale
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var items: [Item] = []
    @ObservationIgnored private var reachedEnd = false
    @ObservationIgnored private var isLoadingMore = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var suppressFilterReload = false
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var metadataCache: [String: CaptureMetadata] = [:]
    @ObservationIgnored private var metadataOrder: [String] = []
    private static let log = Logger(subsystem: "com.jorgeper.hippo", category: "timeline")
    @ObservationIgnored private var activeFilter = CaptureFilter()
    private static let metadataCacheLimit = 200
    private static let prefetchDistance = 10

    public init(store: HippoStore, pageSize: Int = 50, now: @escaping @Sendable () -> Date = Date.init,
                calendar: Calendar = .current, locale: Locale = .current, debounce: Duration = .milliseconds(250)) {
        self.store = store
        self.pageSize = pageSize
        self.now = now
        self.calendar = calendar
        self.locale = locale
        self.debounce = debounce
    }

    /// Waits for a pending search debounce and for the reload started by changing `filter`. Tests use it.
    func settle() async {
        while let pending = debounceTask {
            await pending.value
            if debounceTask == pending { break }
        }
        await reloadTask?.value
    }

    /// Reloads the first page with the current filter.
    public func reload() async {
        generation += 1
        let mine = generation
        isLoadingMore = false
        let captured = currentFilter()
        let page: Page?
        do {
            page = try await Self.loadPage(store: store, filter: captured, after: nil, limit: pageSize, locale: locale)
        } catch {
            Self.log.error("\("reload_failed", privacy: .public)")
            page = nil
        }
        guard mine == generation else { return }
        reloadCount += 1
        guard let page else {
            // Never leave the previous filter's rows on screen.
            items = []
            reachedEnd = true
            loadFailed = true
            publish()
            return
        }
        loadFailed = false
        activeFilter = captured
        items = page.items
        reachedEnd = page.reachedEnd
        publish()
    }

    /// Loads the next page when `id` is among the last 10 rows.
    public func rowAppeared(id: String) async {
        guard !reachedEnd, !isLoadingMore,
              let position = items.firstIndex(where: { $0.row.id == id }),
              position >= items.count - Self.prefetchDistance,
              let last = items.last?.summary
        else { return }
        isLoadingMore = true
        let mine = generation
        let cursor = PageCursor(capturedAt: last.capturedAt, captureID: last.id)
        let page: Page?
        do {
            page = try await Self.loadPage(store: store, filter: activeFilter, after: cursor, limit: pageSize,
                                           locale: locale)
        } catch {
            Self.log.error("\("page_failed", privacy: .public)")
            page = nil
        }
        guard mine == generation else { return }
        isLoadingMore = false
        guard let page else {
            loadFailed = true
            return
        }
        let known = Set(items.map(\.row.id))
        items += page.items.filter { !known.contains($0.row.id) }
        reachedEnd = page.reachedEnd
        publish()
    }

    /// Updates the search text now and reloads once typing pauses for the debounce interval.
    public func searchChanged(_ text: String) {
        suppressFilterReload = true
        filter.search = text
        suppressFilterReload = false
        debounceTask?.cancel()
        let delay = debounce
        debounceTask = Task {
            do { try await Task.sleep(for: delay) } catch { return }
            await reload()
        }
    }

    /// Full metadata for a row's capture, cached (at most 200 entries).
    public func metadata(for id: String) async -> CaptureMetadata? {
        if let cached = metadataCache[id] { return cached }
        let store = store
        let loaded = await Task.detached { try? store.index.metadata(captureID: id, layout: store.layout) }.value
        guard let loaded else { return nil }
        if metadataCache[id] != nil { return loaded }
        metadataCache[id] = loaded
        metadataOrder.append(id)
        if metadataOrder.count > Self.metadataCacheLimit {
            metadataCache[metadataOrder.removeFirst()] = nil
        }
        return loaded
    }

    private func currentFilter() -> CaptureFilter { filter.makeFilter(now: now(), calendar: calendar) }

    private func publish() {
        isEmpty = items.isEmpty
        let current = now()
        var result: [(header: String, rows: [TimelineRow])] = []
        var lastDay: String?
        for item in items {
            if item.summary.localDay == lastDay {
                result[result.count - 1].rows.append(item.row)
            } else {
                lastDay = item.summary.localDay
                let header = DayHeader.title(localDay: item.summary.localDay, now: current, calendar: calendar,
                                             locale: locale)
                result.append((header, [item.row]))
            }
        }
        sections = result
    }

    /// Index reads are synchronous SQLite calls, so they run off the main actor.
    private static func loadPage(store: HippoStore, filter: CaptureFilter, after: PageCursor?, limit: Int,
                                 locale: Locale) async throws -> Page {
        try await Task.detached {
            let summaries = try store.index.page(filter, after: after, limit: limit)
            let items = summaries.map { s -> Item in
                let needsMetadata = s.attachmentCount >= 2 || s.method == .voiceRecording
                    || s.contentTypes.contains(.audio) || (s.attachmentCount == 0 && s.contentTypes.contains(.url))
                let metadata = needsMetadata ? (try? store.index.metadata(captureID: s.id, layout: store.layout)) ?? nil : nil
                return Item(summary: s, row: TimelineRow.make(s, metadata: metadata, locale: locale))
            }
            return Page(items: items, reachedEnd: summaries.count < limit)
        }.value
    }
}
