import Foundation
import Testing
import CaptureCore
import LocalRepository
@testable import HippoPresentation

private let locale = Locale(identifier: "en_US")
private let la = TimeZone(identifier: "America/Los_Angeles")!
private var calendar: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = la
    c.locale = locale
    return c
}
// 2026-11-07 12:00 in Los Angeles (UTC-8).
private let now = Date(timeIntervalSince1970: 1_794_081_600)
private func iso(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

private func summary(_ id: String = "c1", types: [ContentType], method: CaptureMethod = .shareExtension,
                     attachments: Int, primary: String? = nil, title: String = "Title",
                     comment: String? = nil, offset: Int? = nil) -> CaptureSummary {
    CaptureSummary(id: id, capturedAt: iso("2026-11-07T20:00:00Z"), localDay: "2026-11-07", title: title,
                   noteExcerpt: comment, contentTypes: types, method: method, attachmentCount: attachments,
                   primaryAttachmentPath: primary, relativeDirectory: "2026/11/x", syncBucket: .notSynced,
                   utcOffsetSeconds: offset)
}

private func metadata(urls: [String] = [], attachments: [CaptureCore.Attachment] = []) -> CaptureMetadata {
    CaptureMetadata(schemaVersion: 1, captureID: "c1", capturedAt: now, localDatetime: "", timezoneIdentifier: "UTC",
                    utcOffsetSeconds: 0, captureMethod: .shareExtension, contentTypes: [], userNote: nil,
                    sharedTitle: nil, sharedText: nil, urls: urls.map { CapturedURL(url: $0, source: "shared") },
                    sourceApplication: nil, captureLocation: nil, producer: Producer(appVersion: "1", build: "1", osVersion: "t"),
                    attachments: attachments, metadataObservations: [], extensions: [:])
}

private func attachment(_ n: Int, uti: String = "public.jpeg", duration: Double? = nil) -> CaptureCore.Attachment {
    CaptureCore.Attachment(attachmentID: "a\(n)", relativePath: "attachments/\(n).bin", uti: uti, byteCount: 1, sha256: "x",
               representationSource: "item_provider_file",
               media: duration.map { MediaFacts(durationSeconds: $0) })
}

@Suite struct TimelineTests {
    @Test func syncLabelTitles() {
        #expect(SyncLabel(.notSynced).title == "On iPhone")
        #expect(SyncLabel(.synced).title == "Synced")
        #expect(SyncLabel(.needsAttention).title == "Needs attention")
    }

    @Test func dayHeaderTitles() {
        func t(_ d: String) -> String { DayHeader.title(localDay: d, now: now, calendar: calendar, locale: locale) }
        #expect(t("2026-11-07") == "TODAY · SAT NOV 7")
        #expect(t("2026-11-06") == "YESTERDAY · FRI NOV 6")
        #expect(t("2026-11-05") == "THU NOV 5")
        #expect(t("2025-11-05") == "WED NOV 5, 2025")
    }

    @Test func chipsWriteIntoSheetFiltersAndAreDerived() {
        var state = TimelineFilterState()
        #expect(state.activeChip == .all)
        state = state.select(.links)
        #expect(state.sheet.types == [.url])
        #expect(state.activeChip == .links)
        state = state.select(.notes)
        #expect(state.sheet.types.isEmpty && state.sheet.methods == [.typedNote])
        state = state.select(.links)
        state.sheet.types.insert(.image)
        #expect(state.activeChip == nil)
        state.sheet.date = .today
        state.sheet.hasComment = true
        state.sheet.sync = [.synced]
        state.sheet.sort = .oldestFirst
        #expect(state.sheet.activeCount == 4)
    }

    @Test func datePresetRanges() throws {
        func range(_ p: DatePreset) -> Range<Date>? {
            var s = TimelineFilterState()
            s.sheet.date = p
            return s.makeFilter(now: now, calendar: calendar).dateRange
        }
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        #expect(range(.any) == nil)
        #expect(range(.today) == today..<tomorrow)
        #expect(range(.last7) == calendar.date(byAdding: .day, value: -6, to: today)!..<tomorrow)
        #expect(range(.last30) == calendar.date(byAdding: .day, value: -29, to: today)!..<tomorrow)
        let from = iso("2026-11-02T20:00:00Z"), through = iso("2026-11-04T05:00:00Z")
        #expect(range(.custom(from: from, through: through))
                == calendar.startOfDay(for: from)..<calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: through)!))
    }

    @Test func filterMapsFlagsAndTrimsSearch() {
        var s = TimelineFilterState(search: "  cats  ")
        var f = s.makeFilter(now: now, calendar: calendar)
        #expect(f.searchText == "cats" && f.hasComment == nil && f.hasLocation == nil)
        s.search = "   "; s.sheet.hasLocation = true
        f = s.makeFilter(now: now, calendar: calendar)
        #expect(f.searchText == nil && f.hasLocation == true)
    }

    @Test func rowTimeUsesRecordedOffset() {
        var s = summary(types: [.url], attachments: 0, offset: 32400)
        s.capturedAt = iso("2026-11-07T07:30:00Z")
        let time = TimelineRow.make(s, metadata: nil, enrichment: nil, locale: locale).time
        #expect(time.replacingOccurrences(of: "\u{202F}", with: " ") == "4:30 PM")
    }

    @Test func rowCarriesPackageDirectory() {
        let row = TimelineRow.make(summary(types: [.image], attachments: 1, primary: "attachments/1.jpg"),
                                   metadata: nil, enrichment: nil, locale: locale)
        #expect(row.relativeDirectory == "2026/11/x")
    }

    @Test func voiceRowShowsDuration() {
        let s = summary(types: [.audio], method: .voiceRecording, attachments: 1)
        let m = metadata(attachments: [attachment(1, uti: "public.mpeg-4-audio", duration: 75.4)])
        let row = TimelineRow.make(s, metadata: m, enrichment: nil, locale: locale)
        #expect(row.kind == .voice && row.title == "Voice note · 1:15")
        #expect(TimelineRow.make(s, metadata: nil, enrichment: nil, locale: locale).title == "Voice note")
    }

    @Test func linkRowShowsHost() {
        let s = summary(types: [.url], attachments: 0, title: "A page", comment: "read later")
        let row = TimelineRow.make(s, metadata: metadata(urls: ["https://www.example.com/a"]), enrichment: nil, locale: locale)
        #expect(row.kind == .link && row.title == "A page" && row.subtitle == "example.com")
        #expect(row.comment == "read later" && row.sync == .onIPhone)
    }

    @Test func linkRowUsesPreview() {
        let s = summary(types: [.url], attachments: 0, title: "A page")
        let e = ResolvedEnrichment(links: ["https://www.example.com/a": ResolvedLink(
            url: "https://www.example.com/a", title: "Preview title", siteName: "Example", channel: "Chan",
            thumbnailURL: URL(fileURLWithPath: "/t.jpg"))], places: [:], recognizedText: [:], transcripts: [:],
            detections: [], sourceAppGuess: nil, summary: nil, tags: [], usesServer: false)
        let row = TimelineRow.make(s, metadata: metadata(urls: ["https://www.example.com/a"]), enrichment: e,
                                   locale: locale)
        #expect(row.title == "Preview title" && row.subtitle == "Chan")
        #expect(row.thumbnailURL == URL(fileURLWithPath: "/t.jpg"))
        let plain = TimelineRow.make(s, metadata: metadata(urls: ["https://www.example.com/a"]), enrichment: nil,
                                     locale: locale)
        #expect(plain.title == "A page" && plain.subtitle == "example.com" && plain.thumbnailURL == nil)
    }

    @Test func voiceRowShowsTranscriptLine() {
        let s = summary(types: [.audio], method: .voiceRecording, attachments: 1)
        let m = metadata(attachments: [attachment(1, uti: "public.mpeg-4-audio", duration: 5)])
        let long = String(repeating: "word ", count: 30)
        let e = ResolvedEnrichment(links: [:], places: [:], recognizedText: [:], transcripts: [
            "a1": TranscriptItem(attachmentID: "a1", text: "\n  \nFirst line here\nsecond", locale: "en_US", segments: [])],
            detections: [], sourceAppGuess: nil, summary: nil, tags: [], usesServer: false)
        #expect(TimelineRow.make(s, metadata: m, enrichment: e, locale: locale).subtitle == "First line here")
        let e2 = ResolvedEnrichment(links: [:], places: [:], recognizedText: [:], transcripts: [
            "a1": TranscriptItem(attachmentID: "a1", text: long, locale: "en_US", segments: [])],
            detections: [], sourceAppGuess: nil, summary: nil, tags: [], usesServer: false)
        #expect(TimelineRow.make(s, metadata: m, enrichment: e2, locale: locale).subtitle?.count == 80)
    }

    @Test func multiRowCountsExtra() {
        let s = summary(types: [.image], attachments: 5, primary: "attachments/1.bin")
        let m = metadata(attachments: (1...5).map { attachment($0) })
        let row = TimelineRow.make(s, metadata: m, enrichment: nil, locale: locale)
        #expect(row.kind == .multi && row.thumbnailAttachmentPaths.count == 3 && row.extraCount == 2)
    }

    @Test func singleMediaNoteAndFileRows() {
        let media = TimelineRow.make(summary(types: [.image], attachments: 1, primary: "attachments/1.bin"),
                                     metadata: nil, enrichment: nil, locale: locale)
        #expect(media.kind == .media && media.thumbnailAttachmentPaths == ["attachments/1.bin"])
        #expect(TimelineRow.make(summary(types: [.text], method: .typedNote, attachments: 1), metadata: nil, enrichment: nil,
                                 locale: locale).kind == .note)
        let file = TimelineRow.make(summary(types: [.pdf], attachments: 1, title: "doc.pdf"), metadata: nil, enrichment: nil, locale: locale)
        #expect(file.kind == .file && file.title == "doc.pdf")
    }

    @Test @MainActor func rowProgressFromTasks() async throws {
        let t = try TestStore(); defer { t.cleanup() }
        let due = try await t.note("due", at: iso("2026-11-07T18:00:00Z")).metadata.captureID
        let deferred = try await t.note("deferred", at: iso("2026-11-07T19:00:00Z")).metadata.captureID
        let done = try await t.note("done", at: iso("2026-11-07T20:00:00Z")).metadata.captureID
        let tasks = t.store.enrichmentTasks
        try tasks.set(captureID: due, kind: .dataDetection, version: 1, status: "pending", now: now)
        try tasks.set(captureID: deferred, kind: .place, version: 1, status: "pending", now: now)
        try tasks.recordAttempt(captureID: deferred, kind: .place, status: "pending", errorCode: "throttled",
                                nextAttemptAt: now.addingTimeInterval(600), incrementAttempts: true, now: now)
        try tasks.set(captureID: done, kind: .dataDetection, version: 1, status: "ok", now: now)
        let model = TimelineModel(store: t.store, now: { now }, calendar: calendar, locale: locale)
        await model.reload()
        let rows = Dictionary(uniqueKeysWithValues: model.sections.flatMap(\.rows).map { ($0.id, $0.progress) })
        #expect(rows[due] == .working)
        #expect(rows[deferred] == .waiting)
        #expect(rows[done] == RowProgress.none)
    }

    @Test @MainActor func groupsByRecordedLocalDayNewestFirst() async throws {
        let t = try TestStore(); defer { t.cleanup() }
        try await t.note("first", at: iso("2026-11-06T18:00:00Z"))
        try await t.note("second", at: iso("2026-11-07T18:00:00Z"))
        try await t.note("third", at: iso("2026-11-07T20:00:00Z"))
        let model = TimelineModel(store: t.store, now: { now }, calendar: calendar, locale: locale)
        await model.reload()
        #expect(model.sections.map(\.header) == ["TODAY · SAT NOV 7", "YESTERDAY · FRI NOV 6"])
        #expect(model.sections.map { $0.rows.map(\.title) } == [["third", "second"], ["first"]])
        #expect(!model.isEmpty)
    }

    @Test @MainActor func dayHeaderUsesTheRecordedZoneNotTheViewingZone() async throws {
        let t = try TestStore(); defer { t.cleanup() }
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        // 00:30 on Nov 7 in Tokyo is 07:30 on Nov 6 in Los Angeles, where the calendar is set.
        let captured = iso("2026-11-06T15:30:00Z")
        try await t.note("late night in Tokyo", at: captured, zone: tokyo)
        let model = TimelineModel(store: t.store, now: { now }, calendar: calendar, locale: locale)
        await model.reload()
        #expect(model.sections.map(\.header) == ["TODAY · SAT NOV 7"])
        #expect(model.sections.first?.rows.map(\.title) == ["late night in Tokyo"])
    }

    @Test @MainActor func paginationLoadsAllRowsWithoutDuplicates() async throws {
        let t = try TestStore(); defer { t.cleanup() }
        for i in 0..<120 { try await t.note("n\(i)", at: Date(timeIntervalSince1970: 1_794_000_000 + Double(i * 60))) }
        let model = TimelineModel(store: t.store, pageSize: 50, now: { now }, calendar: calendar, locale: locale)
        await model.reload()
        #expect(model.sections.flatMap(\.rows).count == 50)
        for _ in 0..<5 {
            guard let last = model.sections.last?.rows.last else { break }
            await model.rowAppeared(id: last.id)
        }
        let ids = model.sections.flatMap(\.rows).map(\.id)
        #expect(ids.count == 120 && Set(ids).count == 120)
    }

    @Test @MainActor func searchIsDebounced() async throws {
        let t = try TestStore(); defer { t.cleanup() }
        let model = TimelineModel(store: t.store, now: { now }, calendar: calendar, locale: locale,
                                  debounce: .milliseconds(100))
        model.searchChanged("c")
        model.searchChanged("ca")
        #expect(model.reloadCount == 0)
        await model.settle()
        #expect(model.reloadCount == 1)
        #expect(model.filter.search == "ca")
    }

    @Test @MainActor func metadataIsCachedAndLoaded() async throws {
        let t = try TestStore(); defer { t.cleanup() }
        let pkg = try await t.link("https://www.example.com/a", at: iso("2026-11-07T18:00:00Z"))
        let model = TimelineModel(store: t.store, now: { now }, calendar: calendar, locale: locale)
        let m = await model.metadata(for: pkg.metadata.captureID)
        #expect(m?.urls.first?.url == "https://www.example.com/a")
        #expect(await model.metadata(for: "missing") == nil)
        await model.reload()
        #expect(model.sections.first?.rows.first?.subtitle == "example.com")
    }

    @Test @MainActor func oldestFirstPagingIsAscendingAndUnique() async throws {
        let t = try TestStore(); defer { t.cleanup() }
        for i in 0..<120 { try await t.note("n\(i)", at: Date(timeIntervalSince1970: 1_794_000_000 + Double(i * 60))) }
        let model = TimelineModel(store: t.store, pageSize: 50, now: { now }, calendar: calendar, locale: locale)
        model.filter.sheet.sort = .oldestFirst
        await model.settle()
        for _ in 0..<5 {
            guard let last = model.sections.last?.rows.last else { break }
            await model.rowAppeared(id: last.id)
        }
        let titles = model.sections.flatMap(\.rows).map(\.title)
        #expect(titles == (0..<120).map { "n\($0)" })
    }

    @Test @MainActor func failedReloadClearsRowsAndFlags() async throws {
        let t = try TestStore(); defer { t.cleanup() }
        try await t.note("one", at: iso("2026-11-07T18:00:00Z"))
        let model = TimelineModel(store: t.store, now: { now }, calendar: calendar, locale: locale)
        await model.reload()
        #expect(model.sections.count == 1 && !model.loadFailed)
        try Database(url: t.store.layout.databaseURL).execute("ALTER TABLE captures RENAME TO captures_gone")
        await model.reload()
        #expect(model.loadFailed && model.sections.isEmpty && model.isEmpty)
    }

    @Test @MainActor func reloadKeepsLoadedDepthButFilterChangeResetsIt() async throws {
        let t = try TestStore(); defer { t.cleanup() }
        for i in 0..<70 { try await t.note("n\(i)", at: Date(timeIntervalSince1970: 1_794_000_000 + Double(i * 60))) }
        let model = TimelineModel(store: t.store, pageSize: 20, now: { now }, calendar: calendar, locale: locale)
        await model.reload()
        for _ in 0..<3 {
            guard let last = model.sections.last?.rows.last else { break }
            await model.rowAppeared(id: last.id)
        }
        #expect(model.sections.flatMap(\.rows).count == 70)

        await model.reload()
        #expect(model.sections.flatMap(\.rows).count == 70)

        model.filter.sheet.sort = .oldestFirst
        await model.settle()
        #expect(model.sections.flatMap(\.rows).count == 20)
    }

    @Test @MainActor func loadFailedClearsAfterALaterSuccessfulPage() async throws {
        let t = try TestStore(); defer { t.cleanup() }
        for i in 0..<30 { try await t.note("n\(i)", at: Date(timeIntervalSince1970: 1_794_000_000 + Double(i * 60))) }
        let model = TimelineModel(store: t.store, pageSize: 20, now: { now }, calendar: calendar, locale: locale)
        await model.reload()
        let last = try #require(model.sections.last?.rows.last)
        let other = try Database(url: t.store.layout.databaseURL)
        try other.execute("ALTER TABLE captures RENAME TO captures_gone")
        await model.rowAppeared(id: last.id)
        #expect(model.loadFailed)
        try other.execute("ALTER TABLE captures_gone RENAME TO captures")
        await model.rowAppeared(id: last.id)
        #expect(!model.loadFailed)
        #expect(model.sections.flatMap(\.rows).count == 30)
    }
}

@MainActor
struct TimelineReviewTests {
    @Test func reviewPendingCount() async throws {
        let t = try TestStore()
        defer { t.cleanup() }
        let dest = Destination(id: "dest-x", providerKind: "dropbox", accountIdentifier: "acct", remoteRoot: "/",
                               displayName: "Dropbox", status: .active)
        _ = try t.store.destinations.connect(dest)
        let a = try await t.note("one", at: now)
        let b = try await t.note("two", at: now.addingTimeInterval(60))
        let model = TimelineModel(store: t.store, now: { now }, calendar: calendar, locale: locale)
        await model.reload()
        #expect(model.reviewPending == 0 && model.reviewDestinationName == nil)

        try t.store.remoteState.addReviewItems([a, b].map {
            ReviewItem(captureID: $0.metadata.captureID, destinationID: dest.id, reason: "threshold", createdAt: now)
        })
        await model.reload()
        #expect(model.reviewPending == 2 && model.reviewDestinationName == "Dropbox")

        try t.store.remoteState.clearReview(destinationID: dest.id)
        await model.reload()
        #expect(model.reviewPending == 0)
    }
}
