import Foundation
import Testing
import Synchronization
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
                  enrichment: ResolvedEnrichment = .empty, changed: RemoteChangedRecord? = nil,
                  trimmedPaths: Set<String> = [], destinationName: String? = nil) -> CaptureDetail {
    CaptureDetail.make(metadata: m, packageURL: pkg, noteBody: body, jobs: jobs, enrichment: enrichment,
                       changed: changed, trimmedPaths: trimmedPaths, destinationName: destinationName,
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

    // M2: gold Source, "Taken in" and Text in image items carry the gold layer; silver ones stay silver.
    @Test func goldLayersForSourceTakenInAndTextInImage() {
        let a2 = CaptureCore.Attachment(attachmentID: "a2", relativePath: "content/a2.bin", originalFilename: "b.jpg",
                                        uti: "public.jpeg", mimeType: "image/jpeg", byteCount: 1, sha256: "x",
                                        representationSource: "r", media: nil)
        var e = resolved(places: ["a1": PlaceItem(target: "a1", locality: "Seattle"),
                                  "a2": PlaceItem(target: "a2", locality: "Tacoma")], guess: "Safari")
        e.recognizedText = ["a1": "gold text", "a2": "silver text"]
        e.fromServer = ServerOrigin(places: ["a1"], recognizedText: ["a1"], sourceApp: true)
        let d = make(meta(attachments: [att(), a2]), enrichment: e)
        #expect(d.captured.first { $0.label == "Source" }?.layer == .gold)
        #expect(d.attachments.map { $0.first { $0.label == "Taken in" }?.layer } == [.gold, .silver])
        #expect(d.recognizedText.map(\.layer) == [.gold, .silver])
    }

    // M2: a mixed place (silver locality, gold nearby) resolved from real documents: one gold Where row.
    @Test func mixedPlaceWhereRowIsGold() throws {
        let loc = CaptureLocation(latitude: 47.6, longitude: -122.3, horizontalAccuracyMeters: 10, observedAt: now, provenance: "t")
        let e = ResolvedEnrichment.make(
            device: try enrichmentDoc(.device, facets: [.place: (.ok, PlaceData(items: [
                PlaceItem(target: "capture", locality: "Seattle")]))]),
            server: try enrichmentDoc(.server, facets: [.place: (.ok, PlaceData(items: [
                PlaceItem(target: "capture", nearby: NearbyPlace(name: "Pike Place Market", distanceMeters: 40))]))]),
            assetURL: { _, a in URL(fileURLWithPath: "/assets/\(a.relativePath)") })
        let rows = make(meta(location: loc), enrichment: e).captured
        let place = try #require(rows.first { $0.label == "Where" })
        #expect(place.value == "Seattle · near Pike Place Market")
        #expect(place.layer == .gold)
        #expect(rows.first { $0.label == "Coordinates" }?.layer == .bronze)
    }

    // M2: with a location but no place, Where shows the coordinates as captured (bronze), with no Coordinates row.
    @Test func whereWithoutPlaceIsBronzeCoordinates() {
        let loc = CaptureLocation(latitude: 47.6, longitude: -122.3, horizontalAccuracyMeters: 10, observedAt: now, provenance: "t")
        let rows = make(meta(location: loc), enrichment: .empty).captured
        #expect(rows.first { $0.label == "Where" }?.layer == .bronze)
        #expect(rows.first { $0.label == "Where" }?.value.hasPrefix("47.6000, -122.3000") == true)
        #expect(!rows.contains { $0.label == "Coordinates" })
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

    private func record(_ paths: [String]) -> RemoteChangedRecord {
        RemoteChangedRecord(captureID: "c1", destinationID: "d1", paths: paths, detectedAt: now)
    }

    @Test func storageLinePrecedence() {
        func storage(_ jobs: [UploadJob], changed: RemoteChangedRecord? = nil, trimmed: Set<String> = [],
                     name: String? = "Dropbox") -> StatusLine? {
            make(meta(), jobs: jobs, changed: changed, trimmedPaths: trimmed, destinationName: name).storage
        }
        let sync = Layer.sync
        #expect(storage([job(.uploading)], changed: record(["a"]), trimmed: ["b"])
                == StatusLine(layer: sync, text: "Changed in Dropbox", state: .failed))
        #expect(storage([job(.uploading)], trimmed: ["b"]) == StatusLine(layer: sync, text: "Uploading…", state: .working))
        #expect(storage([job(.synced), job(.retryableFailure, code: "offline", dest: "d2")], trimmed: ["b"])
                == StatusLine(layer: sync, text: "Waiting for a connection", state: .waiting))
        #expect(storage([job(.retryableFailure, code: "rate_limited")]) == nil)
        #expect(storage([job(.synced)], trimmed: ["b"])
                == StatusLine(layer: sync, text: "Large files in Dropbox only", state: .done))
        #expect(storage([job(.synced)]) == StatusLine(layer: sync, text: "In Dropbox · verified", state: .done))
        #expect(storage([job(.pending)]) == nil)
        #expect(storage([]) == nil)
        #expect(storage([job(.synced)], name: nil) == nil)
        #expect(make(meta(), jobs: [job(.synced)]).storage == nil)
    }

    @Test func changedShowsUploadAgainAndUnrestorableNote() {
        let plain = make(meta(), jobs: [job(.synced)], destinationName: "Dropbox")
        #expect(plain.changedPaths.isEmpty && plain.unrestorableNote == nil)

        let changed = make(meta(), jobs: [job(.synced)], changed: record(["content/a1.bin", "metadata.json"]),
                           trimmedPaths: ["content/other.bin"], destinationName: "Dropbox")
        #expect(changed.changedPaths == ["content/a1.bin", "metadata.json"])
        #expect(changed.unrestorableNote == nil)

        let gone = make(meta(), jobs: [job(.synced)], changed: record(["content/a1.bin"]),
                        trimmedPaths: ["content/a1.bin"], destinationName: "Dropbox")
        #expect(gone.unrestorableNote
                == "This file was only in Dropbox and is gone there. Restore it from Dropbox's deleted files on dropbox.com.")
    }

    @Test func trimmedAttachmentRowsAndPreview() {
        // Another Dropbox account: its destination is named after the provider; the account name is kept apart.
        let other = Destination(id: "d2", providerKind: "dropbox", accountIdentifier: "x", remoteRoot: "/",
                                displayName: "Dropbox", status: .active)
        func detail(_ state: TrimState, dest: String = "d1", active: Destination? = dropbox,
                    thumb: URL? = nil, account: @escaping (String) -> String? = { _ in nil }) -> CaptureDetail {
            let t = TrimmedAttachment(captureID: "c1", attachmentID: "a1", relativePath: "content/a1.bin",
                                      byteCount: 2_500_000, sha256: "x", destinationID: dest, state: state, trimmedAt: now)
            return CaptureDetail.make(metadata: meta(attachments: [att()]), packageURL: pkg, noteBody: nil,
                                      jobs: [job(.synced, dest: dest)], enrichment: .empty,
                                      trimmed: [t], thumbnailURL: { _ in thumb }, activeDestination: active,
                                      accountName: account,
                                      destination: { ["d1": dropbox, "d2": other][$0] }, now: now,
                                      locale: locale, calendar: calendar)
        }
        let thumb = URL(fileURLWithPath: "/t/a1.jpg")
        let available = detail(.trimmed, thumb: thumb)
        let expected = RemoteOnlyAttachment(attachmentID: "a1", relativePath: "content/a1.bin", byteCount: 2_500_000,
                                            thumbnailURL: thumb, symbol: "photo", state: .available(destinationName: "Dropbox"))
        #expect(available.preview == .remoteOnly(expected))
        #expect(available.remoteOnly["a1"] == expected)
        #expect(available.attachments[0].contains(DetailRow(label: "Storage", value: "In Dropbox · Download (2.5 MB)")))
        #expect(available.exportURLs.isEmpty)

        let elsewhere = detail(.trimmed, dest: "d2", active: dropbox)
        let message = "Connect Dropbox to download"
        #expect(elsewhere.remoteOnly["a1"]?.state == .unavailable(message: message))
        #expect(elsewhere.attachments[0].contains(DetailRow(label: "Storage", value: message)))
        #expect(detail(.trimmed, dest: "d2", active: nil).remoteOnly["a1"]?.state == .unavailable(message: message))

        // The account name is looked up by the trimmed file's destination ID.
        let named = detail(.trimmed, dest: "d2", active: dropbox, account: { $0 == "d2" ? "Sample Holder" : nil })
        #expect(named.remoteOnly["a1"]?.state
                == .unavailable(message: "Connect Dropbox (account Sample Holder) to download"))
        #expect(RemoteOnlyAttachment.unavailableText(destinationName: nil, accountName: nil)
                == "Connect your storage to download")

        let mismatch = detail(.mismatch)
        let changed = "Changed in Dropbox: this file no longer matches"
        #expect(mismatch.remoteOnly["a1"]?.state == .mismatch(message: changed))
        #expect(mismatch.attachments[0].contains(DetailRow(label: "Storage", value: changed)))

        let plainDetail = make(meta(attachments: [att()]))
        #expect(plainDetail.remoteOnly.isEmpty)
        #expect(plainDetail.exportURLs.count == 1)
    }

    @Test func trimmedSymbolsFollowType() {
        func symbol(_ uti: String) -> String? {
            let t = TrimmedAttachment(captureID: "c1", attachmentID: "a1", relativePath: "content/a1.bin", byteCount: 1,
                                      sha256: "x", destinationID: "d1", state: .trimmed, trimmedAt: now)
            return CaptureDetail.make(metadata: meta(attachments: [att(uti: uti)]), packageURL: pkg, noteBody: nil,
                                      jobs: [], enrichment: .empty, trimmed: [t], activeDestination: dropbox,
                                      destination: { _ in dropbox }, now: now, locale: locale,
                                      calendar: calendar).remoteOnly["a1"]?.symbol
        }
        #expect(symbol("public.jpeg") == "photo")
        #expect(symbol("public.mpeg-4") == "video")
        #expect(symbol("com.apple.quicktime-movie") == "video")
        #expect(symbol("com.adobe.pdf") == "doc")
    }

    @Test func restoreErrorsSetMessageAndDownloadReloads() async throws {
        let t = try TestStore()
        defer { t.cleanup() }
        _ = try t.store.destinations.connect(Destination(id: "dest-x", providerKind: "dropbox", accountIdentifier: "acct",
                                                         remoteRoot: "/", displayName: "Dropbox", status: .active))
        let p = try await t.note("will be trimmed", at: now)
        let id = p.metadata.captureID
        let a = try #require(p.metadata.attachments.first)
        try t.store.trims.record(TrimmedAttachment(captureID: id, attachmentID: a.attachmentID, relativePath: a.relativePath,
                                                   byteCount: a.byteCount, sha256: a.sha256, destinationID: "dest-x",
                                                   state: .trimmed, trimmedAt: now))
        try FileManager.default.removeItem(at: t.store.layout.packageURL(relativeDirectory: p.relativeDirectory)
            .appendingPathComponent(a.relativePath))
        let model = await CaptureDetailModel(store: t.store, captureID: id, calendar: calendar, locale: locale,
                                             adapterFor: { _ in throw StorageError.offline })
        await model.load()
        #expect(await model.detail?.remoteOnly[a.attachmentID]?.state == .available(destinationName: "Dropbox"))
        await model.restore(attachmentID: a.attachmentID)
        #expect(await model.restoreMessages[a.attachmentID] == "Connect to the internet to download")
        #expect(await model.restoreProgress[a.attachmentID] == nil)
    }

    @Test func modelNamesTheAccountOfAnUnavailableOrSignedOutFile() async throws {
        let t = try TestStore()
        defer { t.cleanup() }
        func dest(_ id: String) -> Destination {
            Destination(id: id, providerKind: "dropbox", accountIdentifier: id, remoteRoot: "/", displayName: "Dropbox",
                        status: .active)
        }
        _ = try t.store.destinations.connect(dest("dest-a"))
        let p = try await t.note("will be trimmed", at: now)
        let id = p.metadata.captureID
        let a = try #require(p.metadata.attachments.first)
        try t.store.trims.record(TrimmedAttachment(captureID: id, attachmentID: a.attachmentID, relativePath: a.relativePath,
                                                   byteCount: a.byteCount, sha256: a.sha256, destinationID: "dest-a",
                                                   state: .trimmed, trimmedAt: now))
        try FileManager.default.removeItem(at: t.store.layout.packageURL(relativeDirectory: p.relativeDirectory)
            .appendingPathComponent(a.relativePath))
        let names: [String: String] = ["dest-a": "Alpha Person", "dest-b": "Beta Person"]
        let model = await CaptureDetailModel(store: t.store, captureID: id, calendar: calendar, locale: locale,
                                             adapterFor: { _ in throw StorageError.needsAuthentication },
                                             accountName: { names[$0.id] })
        // Signed out of the file's account while it is still the active one.
        await model.load()
        #expect(await model.detail?.remoteOnly[a.attachmentID]?.state == .available(destinationName: "Dropbox"))
        await model.restore(attachmentID: a.attachmentID)
        #expect(await model.restoreMessages[a.attachmentID] == "Connect Dropbox (account Alpha Person) to download")

        // Another account is active: the file's own account is named.
        _ = try t.store.destinations.connect(dest("dest-b"))
        await model.load()
        #expect(await model.detail?.remoteOnly[a.attachmentID]?.state
                == .unavailable(message: "Connect Dropbox (account Alpha Person) to download"))
    }

    @Test func storageLineNamesTheBoundDestinationNotTheActiveOne() async throws {
        let t = try TestStore()
        defer { t.cleanup() }
        func dest(_ id: String, _ name: String, _ status: DestinationStatus) -> Destination {
            Destination(id: id, providerKind: "dropbox", accountIdentifier: id, remoteRoot: "/", displayName: name, status: status)
        }
        _ = try t.store.destinations.connect(dest("dest-a", "Alpha", .active))
        let p = try await t.note("bound to A", at: now)
        let id = p.metadata.captureID
        while let j = try t.store.jobs.claimNext(owner: "o", now: Date(), lease: 60) {
            try t.store.jobs.markSynced(jobID: j.jobID, owner: "o")
        }
        _ = try t.store.destinations.connect(dest("dest-b", "Beta", .active))
        #expect(try t.store.destinations.active()?.displayName == "Beta")

        let model = await CaptureDetailModel(store: t.store, captureID: id, calendar: calendar, locale: locale)
        await model.load()
        #expect(await model.detail?.storage?.text == "In Alpha · verified")
    }

    @Test func promptsAndStorageLineNameTheActiveDestinationWhenItHasAJob() async throws {
        let t = try TestStore()
        defer { t.cleanup() }
        func dest(_ id: String, _ name: String) -> Destination {
            Destination(id: id, providerKind: "dropbox", accountIdentifier: id, remoteRoot: "/", displayName: name,
                        status: .active)
        }
        _ = try t.store.destinations.connect(dest("dest-a", "Alpha"))
        let p = try await t.note("bound to both", at: now)
        let id = p.metadata.captureID
        func syncAll() throws {
            while let j = try t.store.jobs.claimNext(owner: "o", now: Date(), lease: 60) {
                try t.store.jobs.markSynced(jobID: j.jobID, owner: "o")
            }
        }
        try syncAll()
        _ = try t.store.destinations.connect(dest("dest-b", "Beta"))
        _ = try t.store.destinations.backfill(destinationID: "dest-b")
        try syncAll()
        #expect(try t.store.jobs.jobs(captureID: id).count == 2)

        let model = await CaptureDetailModel(store: t.store, captureID: id, calendar: calendar, locale: locale)
        await model.load()
        #expect(await model.everywherePrompt == DeletionPrompt.everywhere(destinationName: "Beta"))
        #expect(await model.detail?.storage?.text == "In Beta · verified")
        #expect(await model.deletionPrompt?.message == "This removes the capture from this iPhone. The copy in Beta stays.")
    }

    @Test func uploadAgainRequeuesAndSyncs() async throws {
        let t = try TestStore()
        defer { t.cleanup() }
        _ = try t.store.destinations.connect(Destination(id: "dest-x", providerKind: "dropbox", accountIdentifier: "acct",
                                                         remoteRoot: "/", displayName: "Dropbox", status: .active))
        let p = try await t.note("changed remotely", at: now)
        let id = p.metadata.captureID
        try t.store.remoteState.markChanged(captureID: id, destinationID: "dest-x", paths: ["metadata.json"], now: now)
        let calls = Mutex(0)
        let model = await CaptureDetailModel(store: t.store, captureID: id, calendar: calendar, locale: locale,
                                             sync: { calls.withLock { $0 += 1 } })
        await model.load()
        #expect(await model.detail?.changedPaths == ["metadata.json"])
        #expect(await model.detail?.storage?.text == "Changed in Dropbox")

        await model.uploadAgain()

        #expect(calls.withLock { $0 } == 1)
        #expect(try t.store.remoteState.changed(captureID: id) == nil)
        #expect(await model.detail?.changedPaths.isEmpty == true)
        #expect(await model.detail?.storage == nil)
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

    @Test func everywherePromptCopy() async throws {
        let p = DeletionPrompt.everywhere(destinationName: "Dropbox")
        #expect(p.title == "Delete everywhere?" && p.confirm == "Delete everywhere")
        #expect(p.message == "Delete from this iPhone and from Dropbox? Dropbox keeps deleted files for a while, so you can restore them on dropbox.com.")

        let t = try TestStore()
        defer { t.cleanup() }
        let unbound = try await t.note("no job", at: now)
        let model = await CaptureDetailModel(store: t.store, captureID: unbound.metadata.captureID)
        await model.load()
        #expect(await model.everywherePrompt == nil)

        _ = try t.store.destinations.connect(Destination(id: "dest-x", providerKind: "dropbox", accountIdentifier: "acct",
                                                         remoteRoot: "/", displayName: "Dropbox", status: .active))
        let bound = try await t.note("with job", at: now)
        let boundModel = await CaptureDetailModel(store: t.store, captureID: bound.metadata.captureID)
        await boundModel.load()
        #expect(await boundModel.everywherePrompt == DeletionPrompt.everywhere(destinationName: "Dropbox"))
        _ = try await boundModel.deleteEverywhere()
        #expect(await boundModel.everywherePrompt == nil)
        #expect(try t.store.remoteState.hasTombstone(captureID: bound.metadata.captureID))
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

    // I1: a load that finishes after a newer one must not overwrite it (e.g. "Looking for dates…" coming
    // back after detection has finished).
    @MainActor @Test func supersededLoadIsDropped() async throws {
        let t = try TestStore()
        defer { t.cleanup() }
        let p = try await t.note("lunch tomorrow", at: now)
        let id = p.metadata.captureID
        try t.store.enrichmentTasks.set(captureID: id, kind: .dataDetection, version: 3, status: "pending", now: now)
        let model = CaptureDetailModel(store: t.store, captureID: id, now: { now }, calendar: calendar, locale: locale)
        let gate = FirstCallGate()
        model.beforeApply = { await gate.arrive() }

        // The first load reads the pending task, then is held before it applies.
        let first = Task { await model.load() }
        await gate.firstArrived()
        try t.store.enrichmentTasks.recordAttempt(captureID: id, kind: .dataDetection, status: "empty",
                                                  errorCode: nil, nextAttemptAt: nil, incrementAttempts: true, now: now)
        await model.load()
        let newer = try #require(model.detail)
        #expect(newer.status.contains { $0.text == "Dates, phone numbers and addresses: nothing found" })

        await gate.release()
        await first.value
        #expect(model.detail == newer)
        #expect(model.loadFailed == false)
    }

    // I1: a superseded load that failed must not flag a failure over a newer successful one.
    @MainActor @Test func supersededFailedLoadDoesNotSetFlag() async throws {
        let t = try TestStore()
        defer { t.cleanup() }
        let p = try await t.note("hi", at: now)
        let id = p.metadata.captureID
        let model = CaptureDetailModel(store: t.store, captureID: id, now: { now }, calendar: calendar, locale: locale)
        let gate = FirstCallGate()
        model.beforeApply = { await gate.arrive() }
        let metadataURL = t.store.layout.packageURL(
            relativeDirectory: try #require(try t.store.index.relativeDirectory(captureID: id)))
            .appendingPathComponent("metadata.json")
        let saved = try Data(contentsOf: metadataURL)
        try FileManager.default.removeItem(at: metadataURL)

        let first = Task { await model.load() }
        await gate.firstArrived()
        try saved.write(to: metadataURL)
        await model.load()
        #expect(model.detail != nil)
        await gate.release()
        await first.value
        #expect(model.loadFailed == false)
        #expect(model.detail != nil)
    }
}
