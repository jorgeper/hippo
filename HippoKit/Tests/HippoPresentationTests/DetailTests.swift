import Foundation
import Testing
import CaptureCore
@testable import LocalRepository
import SyncEngine
@testable import HippoPresentation

private let locale = Locale(identifier: "en_US")
private let la = TimeZone(identifier: "America/Los_Angeles")!
private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
private var calendar: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = la
    c.locale = locale
    return c
}
private let now = Date(timeIntervalSince1970: 1_794_081_600)
private let pkg = URL(fileURLWithPath: "/pkg/captures/2026/11/07/c1")

private func meta(method: CaptureMethod = .shareExtension, localDatetime: String = "2026-11-07T12:00:00-08:00",
                  zone: String = "America/Los_Angeles", offset: Int = -28800, urls: [String] = [],
                  location: CaptureLocation? = nil, capturedAt: Date = Date(timeIntervalSince1970: 1_794_081_600),
                  attachments: [CaptureCore.Attachment] = []) -> CaptureMetadata {
    CaptureMetadata(schemaVersion: 1, captureID: "c1", capturedAt: capturedAt, localDatetime: localDatetime,
                    timezoneIdentifier: zone, utcOffsetSeconds: offset, captureMethod: method, contentTypes: [],
                    userNote: nil, sharedTitle: nil, sharedText: nil,
                    urls: urls.map { CapturedURL(url: $0, source: "shared") }, sourceApplication: nil,
                    captureLocation: location, producer: Producer(appVersion: "1", build: "1", osVersion: "t"),
                    attachments: attachments, metadataObservations: [], extensions: [:])
}

private func att(uti: String = "public.jpeg", name: String? = "a.jpg", mime: String? = "image/jpeg",
                 media: MediaFacts? = nil) -> CaptureCore.Attachment {
    CaptureCore.Attachment(attachmentID: "a1", relativePath: "content/a1.bin", originalFilename: name, uti: uti,
                           mimeType: mime, byteCount: 2_500_000, sha256: "x", representationSource: "item_provider_file",
                           media: media)
}

private func job(_ state: JobState, code: String? = nil, dest: String = "d1") -> UploadJob {
    UploadJob(jobID: "j", captureID: "c1", destinationID: dest, state: state, attemptCount: 0, nextAttemptAt: nil,
              lastErrorCode: code, cancelRequested: false)
}

private let dropbox = Destination(id: "d1", providerKind: "dropbox", accountIdentifier: "a", remoteRoot: "/",
                                  displayName: "Dropbox", status: .active)

/// The system time format puts U+202F before AM/PM; tests compare with a plain space.
private func plain(_ s: String?) -> String? { s?.replacingOccurrences(of: "\u{202F}", with: " ") }

private func make(_ m: CaptureMetadata, body: String? = nil, jobs: [UploadJob] = [],
                  enrichment: ResolvedEnrichment = .empty) -> CaptureDetail {
    CaptureDetail.make(metadata: m, packageURL: pkg, noteBody: body, jobs: jobs, enrichment: enrichment,
                       destination: { $0 == "d1" ? dropbox : nil }, now: now, locale: locale, calendar: calendar)
}

struct SyncCase: Sendable {
    let state: JobState, code: String?, message: String?, label: SyncLabel, retry: Bool
    init(_ state: JobState, _ code: String?, _ message: String?, _ label: SyncLabel, _ retry: Bool) {
        self.state = state; self.code = code; self.message = message; self.label = label; self.retry = retry
    }
}

private func resolved(places: [String: PlaceItem] = [:], detections: [Detection] = [], guess: String? = nil,
                      server: Bool = false, transcripts: [String: TranscriptItem] = [:]) -> ResolvedEnrichment {
    ResolvedEnrichment(links: [:], places: places, recognizedText: [:], transcripts: transcripts,
                       detections: detections, sourceAppGuess: guess, summary: nil, tags: [], usesServer: server)
}

@Suite struct DetailTests {
    @Test func detailWhereUsesPlace() {
        let loc = CaptureLocation(latitude: 47.6, longitude: -122.3, horizontalAccuracyMeters: 10, observedAt: now, provenance: "t")
        let place = PlaceItem(target: "capture", subLocality: "Capitol Hill", locality: "Seattle")
        let d = make(meta(location: loc), enrichment: resolved(places: ["capture": place]))
        let labels = d.captured.map(\.label)
        #expect(labels == ["When", "How", "Where", "Coordinates"])
        #expect(d.captured[2].value == "Capitol Hill, Seattle")
        #expect(d.captured[3].value.contains("47.6"))
        #expect(make(meta(location: loc)).captured.map(\.label) == ["When", "How", "Where"])
    }

    @Test func detailPhotoTakenIn() {
        let facts = MediaFacts(embeddedCreatedAt: EmbeddedTimestamp(value: "2026-11-07T10:00:00-08:00", hasUTCOffset: true))
        let place = PlaceItem(target: "a1", locality: "Lisbon", country: "Portugal")
        let d = make(meta(attachments: [att(media: facts)]), enrichment: resolved(places: ["a1": place]))
        #expect(d.attachments[0].last == DetailRow(label: "Taken in", value: "Lisbon, Portugal", layer: .silver))
    }

    @Test func detailSourceGuessRow() {
        let d = make(meta(), enrichment: resolved(guess: "Safari"))
        #expect(d.captured.map(\.label) == ["When", "How", "Source"])
        #expect(d.captured[2].value == "Probably from Safari")
    }

    @Test func detailFoundActions() {
        let dets = [
            Detection(type: "phone", text: "(415) 555-0100", value: "+1 (415) 555-0100", source: "note"),
            Detection(type: "address", text: "1 Main St", source: "note"),
            Detection(type: "date", text: "tomorrow", value: "2026-11-08T09:00:00-08:00", source: "note"),
            Detection(type: "date", text: "noon", value: "2026-11-08T12:00:00", source: "note"),
            Detection(type: "link", text: "a.test", value: "https://a.test/", source: "note")]
        let d = make(meta(urls: []), body: "hello", enrichment: resolved(detections: dets))
        #expect(d.found.count == 5)
        #expect(d.found[0].action == .call(URL(string: "tel:+14155550100")!))
        #expect(d.found[1].action == .map(URL(string: "maps://?q=1%20Main%20St")!))
        guard case .addToCalendar(let start, let title)? = d.found[2].action else { Issue.record("no date"); return }
        #expect(start == DetailFormat.parseRFC3339("2026-11-08T09:00:00-08:00")!.date)
        #expect(!title.isEmpty)
        // No offset: wall clock in the capture zone (Los Angeles, UTC-8 in November).
        guard case .addToCalendar(let wall, _)? = d.found[3].action else { Issue.record("no wall date"); return }
        #expect(wall == DetailFormat.parseRFC3339("2026-11-08T12:00:00-08:00")!.date)
        #expect(d.found[4].action == .open(URL(string: "https://a.test/")!))
    }

    @Test func foundLinkOpensOnlyWebURLs() {
        func action(_ value: String?, text: String = "x") -> FoundAction? {
            make(meta(), enrichment: resolved(detections: [Detection(type: "link", text: text, value: value, source: "n")]))
                .found[0].action
        }
        #expect(action("javascript:alert(1)") == nil)
        #expect(action("file:///etc/passwd") == nil)
        #expect(action("myapp://x") == nil)
        #expect(action(nil, text: "a.test") == nil)
        #expect(action("https://") == nil)
        #expect(action("https://example.com") == .open(URL(string: "https://example.com")!))
        #expect(make(meta(), enrichment: resolved(detections: [Detection(type: "link", text: "javascript:alert(1)", source: "n")]))
            .found[0].text == "javascript:alert(1)")
    }

    @Test func foundPhonePlusOnlyLeading() {
        func url(_ v: String) -> FoundAction? {
            make(meta(), enrichment: resolved(detections: [Detection(type: "phone", text: v, value: v, source: "n")])).found[0].action
        }
        #expect(url("+1 415 555+0100") == .call(URL(string: "tel:+14155550100")!))
        #expect(url("415+555") == .call(URL(string: "tel:415555")!))
    }

    // Captures saved before the share sheet merged Instagram's `?l=1` copy still show one link and one card.
    @Test func trackingVariantsShowOneLinkAndOneCard() {
        let a = "https://www.instagram.com/reel/X/", b = "https://www.instagram.com/reel/X/?l=1"
        var e = ResolvedEnrichment.empty
        e.links = [a: ResolvedLink(url: a, title: "Reel"), b: ResolvedLink(url: b, title: "Reel")]
        let d = make(meta(urls: [a, b]), enrichment: e)
        #expect(d.links.map(\.absoluteString) == [a])
        #expect(d.linkCards.map(\.url) == [a])
    }

    @Test func layersPerRow() {
        let loc = CaptureLocation(latitude: 47.6, longitude: -122.3, horizontalAccuracyMeters: 10, observedAt: now, provenance: "t")
        var e = resolved(places: ["capture": PlaceItem(target: "capture", locality: "Seattle")], guess: "Safari")
        e.fromServer.places = ["capture"]
        let d = make(meta(urls: ["https://example.com/x"], location: loc), enrichment: e)
        let layers = Dictionary(uniqueKeysWithValues: d.captured.map { ($0.label, $0.layer) })
        #expect(layers == ["When": .bronze, "How": .bronze, "Coordinates": .bronze, "Source": .silver, "Where": .gold])

        let t = { (id: String, s: String) in TranscriptItem(attachmentID: id, text: s, locale: "en_US", segments: []) }
        var e2 = resolved(transcripts: ["a1": t("a1", "x"), "a2": t("a2", "y")])
        e2.fromServer.transcripts = ["a1"]
        let a2 = CaptureCore.Attachment(attachmentID: "a2", relativePath: "content/a2.bin", originalFilename: "b", uti: "public.mpeg-4-audio",
                                        mimeType: nil, byteCount: 1, sha256: "x", representationSource: "r", media: nil)
        let d2 = make(meta(attachments: [att(), a2]), enrichment: e2)
        #expect(d2.transcripts.map(\.layer) == [.gold, .silver])
        #expect(d2.foundLayer == .silver && d2.summaryLayer == .silver && d2.tagsLayer == .silver)

        var e3 = ResolvedEnrichment.empty
        e3.fromServer = ServerOrigin(detections: true, summary: true, tags: true)
        let d3 = make(meta(), enrichment: e3)
        #expect(d3.foundLayer == .gold && d3.summaryLayer == .gold && d3.tagsLayer == .gold)
    }

    @Test func detailTranscriptsTitled() {
        let t = TranscriptItem(attachmentID: "a1", text: "hi there", locale: "en_US", segments: [])
        let d = make(meta(attachments: [att(uti: "public.mpeg-4-audio")]), enrichment: resolved(transcripts: ["a1": t]))
        #expect(d.transcripts == [TitledText(title: "Attachment 1", text: "hi there")])
    }

    @Test func omitsMissingValues() {
        let d = make(meta(urls: ["https://example.com/x"]))
        #expect(d.captured.map(\.label) == ["When", "How"])
        #expect(d.attachments.isEmpty)
        let all = d.captured + d.attachments.flatMap { $0 }
        #expect(all.allSatisfy { !$0.value.isEmpty && !$0.value.contains("Unknown") })
        #expect(d.preview == .link(URL(string: "https://example.com/x")!))
        #expect(d.links.count == 1 && d.comment == nil)
        let bare = make(meta(attachments: [att(name: nil, mime: nil)]))
        #expect(bare.attachments[0].map(\.label) == ["Name", "Type", "Size"])
        #expect(bare.attachments[0][0].value == "Attachment 1")
        #expect(bare.attachments[0][1].value == "public.jpeg")
    }

    @Test func whenAndHowRows() {
        let same = make(meta()).captured
        #expect(plain(same[0].value) == "November 7, 2026 at 12:00 PM")
        #expect(same[1] == DetailRow(label: "How", value: "Shared"))
        let away = make(meta(localDatetime: "2026-11-08T05:00:00+09:00", zone: "Asia/Tokyo", offset: 32400)).captured
        #expect(plain(away[0].value) == "November 8, 2026 at 5:00 AM GMT+9")
        let how = ["typed_note": "Typed note", "voice_recording": "Recorded", "file_import": "Imported"]
        for (raw, text) in how {
            #expect(make(meta(method: CaptureMethod(rawValue: raw))).captured[1].value == text)
        }
        #expect(make(meta(method: CaptureMethod(rawValue: "other"))).captured.map(\.label) == ["When"])
    }

    @Test func whereRowFormatsAccuracyAndAge() {
        func whereRow(_ ago: TimeInterval, acc: Double = 12.4) -> String? {
            let l = CaptureLocation(latitude: 37.7749, longitude: -122.4194, horizontalAccuracyMeters: acc,
                                    observedAt: now.addingTimeInterval(-ago), provenance: "device")
            return make(meta(location: l)).captured.first { $0.label == "Where" }?.value
        }
        #expect(whereRow(0) == "37.7749, -122.4194 · ±12 m")
        #expect(whereRow(59) == "37.7749, -122.4194 · ±12 m")
        #expect(whereRow(60) == "37.7749, -122.4194 · ±12 m · 1 min before saving")
        #expect(whereRow(199) == "37.7749, -122.4194 · ±12 m · 3 min before saving")
        #expect(whereRow(7300) == "37.7749, -122.4194 · ±12 m · 2 h before saving")
        #expect(whereRow(0, acc: -1) == "37.7749, -122.4194")
    }

    @Test func embeddedTimeWithoutOffsetSaysZoneUnknown() {
        func taken(_ value: String, offset: Bool) -> String? {
            let media = MediaFacts(embeddedCreatedAt: EmbeddedTimestamp(value: value, hasUTCOffset: offset))
            return plain(make(meta(attachments: [att(media: media)])).attachments[0].first { $0.label == "Taken" }?.value)
        }
        #expect(taken("2026:11:06 09:30:00", offset: false) == "November 6, 2026 at 9:30 AM (time zone unknown)")
        #expect(taken("2026-11-06T09:30:00", offset: false) == "November 6, 2026 at 9:30 AM (time zone unknown)")
        #expect(taken("2026-11-06T09:30:00+09:00", offset: true) == "November 6, 2026 at 9:30 AM")
    }

    @Test func attachmentRowsShowFacts() {
        let media = MediaFacts(widthPixels: 1170, heightPixels: 2532, durationSeconds: 65.9,
                               embeddedLocation: EmbeddedLocation(latitude: 1.5, longitude: -2.25))
        let rows = make(meta(attachments: [att(media: media)])).attachments[0]
        #expect(rows.first { $0.label == "Name" }?.value == "a.jpg")
        #expect(rows.first { $0.label == "Type" }?.value == "image/jpeg")
        #expect(rows.first { $0.label == "Size" }?.value == ByteCountFormatter.string(fromByteCount: 2_500_000, countStyle: .file))
        #expect(rows.first { $0.label == "Dimensions" }?.value == "1170 × 2532")
        #expect(rows.first { $0.label == "Duration" }?.value == "1:05")
        #expect(rows.first { $0.label == "Photo location" }?.value == "1.5000, -2.2500")
    }

    @Test(arguments: [
        SyncCase(.pending, nil, "Waiting to upload", .onIPhone, false),
        SyncCase(.uploading, nil, "Uploading…", .onIPhone, false),
        SyncCase(.synced, nil, nil, .synced, false),
        SyncCase(.retryableFailure, nil, "Couldn't upload yet. Hippo will retry automatically.", .onIPhone, true),
        SyncCase(.retryableFailure, "network", "Couldn't upload yet. Hippo will retry automatically.", .onIPhone, true),
        SyncCase(.needsAuthentication, nil, "Sign in again in Settings to resume uploads.", .needsAttention, false),
        SyncCase(.paused, nil, "Uploads are paused because this account is signed out.", .needsAttention, false),
        SyncCase(.blocked, "quota_exceeded", "Your storage is full. Free up space, then tap Retry.", .needsAttention, true),
        SyncCase(.blocked, "remote_conflict",
         "A different file already exists in your storage at this capture's path. Hippo won't overwrite it.", .needsAttention, true),
        SyncCase(.blocked, "local_package_invalid", "This capture's files on iPhone are damaged or missing.", .needsAttention, true),
        SyncCase(.blocked, "provider_unavailable", "This storage provider isn't available in this version of Hippo.", .needsAttention, true),
        SyncCase(.blocked, "permanent:provider_unavailable", "This storage provider isn't available in this version of Hippo.", .needsAttention, true),
        SyncCase(.blocked, "permanent:quota_exceeded", "Your storage is full. Free up space, then tap Retry.", .needsAttention, true),
        SyncCase(.blocked, "permanent:something_else", "Upload stopped. Tap Retry to try again.", .needsAttention, true),
        SyncCase(.blocked, "something_else", "Upload stopped. Tap Retry to try again.", .needsAttention, true),
        SyncCase(.blocked, nil, "Upload stopped. Tap Retry to try again.", .needsAttention, true),
    ])
    func syncMessagesByCode(c: SyncCase) {
        let rows = make(meta(), jobs: [job(c.state, code: c.code)]).sync
        #expect(rows == [SyncRow(destinationName: "Dropbox", label: c.label, message: c.message, canRetry: c.retry)])
    }

    @Test func unassignedCaptureShowsConnectHint() {
        #expect(make(meta()).sync == [SyncRow(destinationName: nil, label: .onIPhone,
                                              message: "Not uploaded yet. Connect storage in Settings.", canRetry: false)])
    }

    @Test func deletePromptWhenSynced() {
        let p = DeletionPrompt.make(jobs: [job(.synced)], destinationName: "Dropbox")
        #expect(p.title == "Delete from iPhone?" && p.confirm == "Delete")
        #expect(p.message == "This removes the capture from this iPhone. The copy in Dropbox stays.")
    }

    @Test func deletePromptWarnsWhenUnsynced() {
        let unsynced = "This capture hasn't finished uploading. Deleting it removes the only copy."
        #expect(DeletionPrompt.make(jobs: [], destinationName: nil).message == unsynced)
        #expect(DeletionPrompt.make(jobs: [job(.synced), job(.pending)], destinationName: "Dropbox").message == unsynced)
    }

    @Test func deletePromptForActiveUpload() {
        let p = DeletionPrompt.make(jobs: [job(.uploading)], destinationName: "Dropbox")
        #expect(p.message == "This capture hasn't finished uploading. Deleting it removes the only copy. The upload in progress will be stopped.")
    }

    @Test func htmlIsNotPreviewable() {
        let url = pkg.appendingPathComponent("content/a1.bin")
        #expect(make(meta(attachments: [att(uti: "public.html")])).preview == .file(url, previewable: false, name: "a.jpg"))
        #expect(make(meta(attachments: [att(uti: "com.example.unknown")])).preview
                == .file(url, previewable: true, name: "a.jpg"))
        #expect(make(meta(attachments: [att(uti: "com.example.unknown", name: nil)])).preview
                == .file(url, previewable: true, name: nil))
    }

    @Test func previewKindsByType() {
        let url = pkg.appendingPathComponent("content/a1.bin")
        #expect(make(meta(attachments: [att()])).preview == .image(url))
        #expect(make(meta(attachments: [att(uti: "public.mpeg-4")])).preview == .video(url))
        #expect(make(meta(attachments: [att(uti: "com.apple.m4a-audio")])).preview == .audio(url))
        #expect(make(meta(attachments: [att(uti: "com.adobe.pdf")])).preview == .pdf(url))
        #expect(make(meta()).preview == .none)
        #expect(make(meta(attachments: [att()])).exportURLs == [url])
    }

    @Test func noteBodyIsTextPreview() {
        let d = make(meta(method: .typedNote, attachments: [att(uti: "public.plain-text")]), body: "hello")
        #expect(d.preview == .text("hello"))
    }

    @Test func detailModelLoadsAndDeletes() async throws {
        let t = try TestStore()
        defer { t.cleanup() }
        let p = try await t.note("buy milk", at: now)
        let model = await CaptureDetailModel(store: t.store, captureID: p.metadata.captureID, calendar: calendar, locale: locale)
        await model.load()
        let detail = try #require(await model.detail)
        #expect(detail.preview == .text("buy milk"))
        #expect(detail.sync.first?.label == .onIPhone)
        #expect(await model.deletionPrompt?.message.hasPrefix("This capture hasn't finished uploading") == true)
    }

    @Test func detailModelDeleteRemovesCapture() async throws {
        let t = try TestStore()
        defer { t.cleanup() }
        let p = try await t.link("https://example.com", at: now)
        let model = await CaptureDetailModel(store: t.store, captureID: p.metadata.captureID)
        await model.load()
        #expect(try t.store.index.count() == 1)
        let result = try await model.delete()
        #expect(result == HippoStore.DeletionResult(wasSynced: false, hadActiveUpload: false))
        #expect(try t.store.index.count() == 0)
        #expect(await model.detail == nil)
    }

    @Test func hugeOrNonFiniteValuesOmitRows() {
        for seconds in [1e300, Double.infinity, -.infinity, .nan] {
            let rows = make(meta(attachments: [att(media: MediaFacts(durationSeconds: seconds))])).attachments[0]
            #expect(!rows.contains { $0.label == "Duration" })
        }
        let l = CaptureLocation(latitude: 1, longitude: 2, horizontalAccuracyMeters: 1e300, observedAt: now, provenance: "d")
        #expect(make(meta(location: l)).captured.first { $0.label == "Where" }?.value == "1.0000, 2.0000")
    }

    @Test func htmlMimeTypeIsNotPreviewable() {
        let url = pkg.appendingPathComponent("content/a1.bin")
        #expect(make(meta(attachments: [att(uti: "com.example.unknown", mime: "text/html")])).preview
                == .file(url, previewable: false, name: "a.jpg"))
    }

    @Test func failedLoadKeepsDetailAndSetsFlag() async throws {
        let t = try TestStore()
        defer { t.cleanup() }
        let p = try await t.link("https://example.com", at: now)
        let model = await CaptureDetailModel(store: t.store, captureID: p.metadata.captureID)
        await model.load()
        #expect(await model.loadFailed == false)
        let loaded = await model.detail
        #expect(loaded != nil)
        try FileManager.default.removeItem(at: t.store.layout.packageURL(
            relativeDirectory: try #require(try t.store.index.relativeDirectory(captureID: p.metadata.captureID)))
            .appendingPathComponent("metadata.json"))
        await model.load()
        #expect(await model.loadFailed == true)
        #expect(await model.detail == loaded)
    }

    @Test func retryMakesBlockedJobClaimable() async throws {
        let t = try TestStore()
        defer { t.cleanup() }
        _ = try t.store.destinations.connect(dropbox)
        let p = try await t.link("https://example.com", at: now)
        let id = p.metadata.captureID
        let claimed = try #require(try t.store.jobs.claimNext(owner: "test", now: Date(), lease: 60))
        try t.store.jobs.markFailed(jobID: claimed.jobID, owner: "test", state: .blocked, errorCode: "quota_exceeded",
                                    nextAttemptAt: nil)
        let model = await CaptureDetailModel(store: t.store, captureID: id)
        await model.load()
        #expect(await model.detail?.sync.first?.canRetry == true)
        await model.retry()
        #expect(try t.store.jobs.jobs(captureID: id).first?.state == .pending)
        #expect(await model.detail?.sync.first?.message == "Waiting to upload")
    }
}
