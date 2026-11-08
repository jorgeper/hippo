import Foundation
import CaptureCore
import LocalRepository

public enum DatePreset: Equatable, Sendable {
    case any, today, last7, last30
    case custom(from: Date, through: Date)
}

/// Everything in the Filters sheet.
public struct SheetFilters: Equatable, Sendable {
    public var sort: LocalRepository.SortOrder = .newestFirst
    public var date: DatePreset = .any
    public var types: Set<ContentType> = []
    public var methods: Set<CaptureMethod> = []
    public var hasComment = false
    public var hasLocation = false
    public var sync: Set<SyncBucket> = []

    public init() {}

    /// Non-default fields, not counting `sort`.
    public var activeCount: Int {
        [date != .any, !types.isEmpty, !methods.isEmpty, hasComment, hasLocation, !sync.isEmpty]
            .filter { $0 }.count
    }
}

public enum QuickChip: CaseIterable, Sendable {
    case all, links, images, notes, audio

    var types: Set<ContentType> {
        switch self {
        case .links: [.url]
        case .images: [.image]
        case .audio: [.audio]
        case .all, .notes: []
        }
    }

    var methods: Set<CaptureMethod> { self == .notes ? [.typedNote] : [] }
}

public struct TimelineFilterState: Equatable, Sendable {
    public var sheet: SheetFilters
    public var search: String

    public init(sheet: SheetFilters = SheetFilters(), search: String = "") {
        self.sheet = sheet
        self.search = search
    }

    /// A chip replaces the sheet's types and methods.
    public func select(_ chip: QuickChip) -> TimelineFilterState {
        var copy = self
        copy.sheet.types = chip.types
        copy.sheet.methods = chip.methods
        return copy
    }

    public var activeChip: QuickChip? {
        QuickChip.allCases.first { $0.types == sheet.types && $0.methods == sheet.methods }
    }

    public func makeFilter(now: Date, calendar: Calendar) -> CaptureFilter {
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int, from d: Date) -> Date {
            calendar.date(byAdding: .day, value: offset, to: d) ?? d
        }
        let range: Range<Date>?
        switch sheet.date {
        case .any: range = nil
        case .today: range = today..<day(1, from: today)
        case .last7: range = day(-6, from: today)..<day(1, from: today)
        case .last30: range = day(-29, from: today)..<day(1, from: today)
        case let .custom(from, through):
            let start = calendar.startOfDay(for: from)
            range = start..<max(start, day(1, from: calendar.startOfDay(for: through)))
        }
        let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return CaptureFilter(dateRange: range, contentTypes: sheet.types, methods: sheet.methods,
                             hasComment: sheet.hasComment ? true : nil, hasLocation: sheet.hasLocation ? true : nil,
                             syncBuckets: sheet.sync, searchText: text.isEmpty ? nil : text, sort: sheet.sort)
    }
}
