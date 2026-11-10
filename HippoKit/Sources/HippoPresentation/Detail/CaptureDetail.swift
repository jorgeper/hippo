import Foundation
import UniformTypeIdentifiers
import CaptureCore
import LocalRepository

public struct TitledText: Equatable, Sendable {
    public let title: String
    public let text: String
    public let layer: Layer
    public init(title: String, text: String, layer: Layer = .silver) { self.title = title; self.text = text; self.layer = layer }
}

public enum FoundAction: Equatable, Sendable {
    case call(URL), map(URL), addToCalendar(start: Date, title: String), open(URL)
}

public struct FoundItem: Equatable, Sendable {
    public let kind: String
    public let text: String
    public let action: FoundAction?
    public init(kind: String, text: String, action: FoundAction?) { self.kind = kind; self.text = text; self.action = action }
}

/// One entry in Detail's Comments section: the capture-time comment (`user_note`), a capture-time recording, or a
/// comment added afterwards.
public struct CommentRow: Equatable, Sendable, Identifiable {
    public enum Body: Equatable, Sendable {
        case text(String)
        case audio(URL, durationText: String?)
    }
    /// "user_note", the recording's attachment ID, or the comment ID.
    public var id: String
    public var body: Body
    /// When an after-the-fact comment was added ("Added today, 2:02 PM"); nil for capture-time comments.
    public var caption: String?
    /// An audio row's transcript, once enrichment has one.
    public var transcript: String?
    public var transcriptLayer: Layer?

    public init(id: String, body: Body, caption: String? = nil, transcript: String? = nil, transcriptLayer: Layer? = nil) {
        self.id = id; self.body = body; self.caption = caption
        self.transcript = transcript; self.transcriptLayer = transcriptLayer
    }
}

/// Everything the details screen shows for one capture. Missing values are omitted, never blank.
public struct CaptureDetail: Equatable, Sendable {
    public var preview: PreviewKind
    /// The capture-time comment, capture-time recordings (except a voice recording's own), then later comments.
    public var comments: [CommentRow]
    public var sharedTitle: String?
    public var sharedText: String?
    public var links: [URL]
    public var captured: [DetailRow]
    public var attachments: [[DetailRow]]
    public var sync: [SyncRow]
    /// The destination's verdict on this capture; shown first among the sync-layer rows. Nil when there is nothing to say.
    public var storage: StatusLine?
    /// Files changed in the destination that "Upload again from iPhone" would put back.
    public var changedPaths: [String]
    /// Shown when a changed file was trimmed from this iPhone and is gone from the destination too.
    public var unrestorableNote: String?
    /// Files offered through Share/Export: every attachment's file.
    public var exportURLs: [URL]
    /// Trimmed attachments by attachment ID.
    public var remoteOnly: [String: RemoteOnlyAttachment]
    public var linkCards: [ResolvedLink]
    public var transcripts: [TitledText]
    public var recognizedText: [TitledText]
    public var found: [FoundItem]
    public var summary: String?
    public var tags: [String]
    public var foundLayer: Layer
    public var summaryLayer: Layer
    public var tagsLayer: Layer
    /// Detail's Status section: bronze save line, one line per enrichment step, the server arrival. Sync rows are `sync`.
    public var status: [StatusLine]
    /// Where a result will appear and isn't there yet.
    public var pending: [FacetKind: PendingLine]

    /// `now` is accepted for symmetry with the timeline; nothing here is relative to it, because
    /// ages are measured against the capture time. `calendar.timeZone` is the current zone. `accountName` gives the
    /// account holder's name by destination ID, for a trimmed file whose account isn't the connected one.
    public static func make(metadata m: CaptureMetadata, packageURL: URL, noteBody: String?, jobs: [UploadJob],
                            enrichment: ResolvedEnrichment, tasks: [EnrichmentTask] = [],
                            changed: RemoteChangedRecord? = nil, trimmedPaths: Set<String> = [],
                            destinationName: String? = nil,
                            trimmed: [TrimmedAttachment] = [], thumbnailURL: (String) -> URL? = { _ in nil },
                            activeDestination: Destination? = nil,
                            accountName: (String) -> String? = { _ in nil },
                            isEnabled: (FacetKind) -> Bool = { _ in true }, isOnline: Bool = true,
                            goldArrivedAt: Date? = nil, comments: [CaptureComment] = [],
                            destination: (String) -> Destination?, now: Date,
                            locale: Locale, calendar: Calendar) -> CaptureDetail {
        let files: [(Attachment, URL)] = m.attachments.compactMap { a in
            guard (try? PackagePath.validateRelative(a.relativePath)) != nil else { return nil }
            return (a, packageURL.appendingPathComponent(a.relativePath))
        }
        let remoteOnly = Dictionary(uniqueKeysWithValues: trimmed.compactMap { t -> (String, RemoteOnlyAttachment)? in
            guard let a = m.attachments.first(where: { $0.attachmentID == t.attachmentID }) else { return nil }
            let owner = destination(t.destinationID)
            let name = owner?.displayName
            let state: RemoteOnlyAttachment.State
            if t.state == .mismatch {
                state = .mismatch(message: RemoteOnlyAttachment.mismatchText(destinationName: name))
            } else if let name, activeDestination?.id == t.destinationID {
                state = .available(destinationName: name)
            } else {
                state = .unavailable(message: RemoteOnlyAttachment.unavailableText(destinationName: name,
                                                                                accountName: accountName(t.destinationID)))
            }
            return (t.attachmentID, RemoteOnlyAttachment(attachmentID: t.attachmentID, relativePath: t.relativePath,
                                                         byteCount: t.byteCount, thumbnailURL: thumbnailURL(t.attachmentID),
                                                         symbol: symbol(for: a.uti), state: state))
        })
        let urls = LinkIdentity.deduplicated(m.urls)
        let links = urls.compactMap { URL(string: $0.url) }
        let sync = jobs.isEmpty ? [SyncRow.unassigned]
            : jobs.map { SyncRow.make(job: $0, destinationName: destination($0.destinationID)?.displayName) }
        let steps = EnrichmentProgress.steps(tasks, isEnabled: isEnabled, isOnline: isOnline, now: now)
        let savedZone = TimeZone(identifier: m.timezoneIdentifier) ?? TimeZone(secondsFromGMT: m.utcOffsetSeconds) ?? .gmt
        let recordings = recordingComments(m, files: files)
        return CaptureDetail(
            preview: preview(metadata: m, files: files, links: links, noteBody: noteBody, remoteOnly: remoteOnly),
            comments: commentRows(m, recordings: recordings, comments: comments, packageURL: packageURL,
                                  enrichment: enrichment, now: now, locale: locale, calendar: calendar),
            sharedTitle: nonEmpty(m.sharedTitle), sharedText: nonEmpty(m.sharedText),
            links: links,
            captured: capturedRows(m, enrichment: enrichment, locale: locale, calendar: calendar),
            attachments: m.attachments.enumerated().map {
                attachmentRows($1, number: $0 + 1, place: enrichment.places[$1.attachmentID],
                               placeFromServer: enrichment.fromServer.places.contains($1.attachmentID), locale: locale,
                               remoteOnly: remoteOnly[$1.attachmentID])
            },
            sync: sync,
            storage: storageLine(jobs: jobs, changed: changed, hasTrimmed: !trimmedPaths.isEmpty, name: destinationName),
            changedPaths: changed?.paths ?? [],
            unrestorableNote: destinationName.flatMap { name in
                (changed?.paths ?? []).contains(where: trimmedPaths.contains)
                    ? RemoteOnlyAttachment.goneText(destinationName: name)
                    : nil
            },
            exportURLs: files.filter { remoteOnly[$0.0.attachmentID] == nil }.map(\.1),
            remoteOnly: remoteOnly,
            linkCards: urls.compactMap { enrichment.links[$0.url] },
            transcripts: titled(m, enrichment.transcripts.mapValues(\.text), gold: enrichment.fromServer.transcripts,
                                excluding: Set(recordings.map(\.0.attachmentID))),
            recognizedText: titled(m, enrichment.recognizedText, gold: enrichment.fromServer.recognizedText),
            found: enrichment.detections.map { foundItem($0, metadata: m, noteBody: noteBody) },
            summary: nonEmpty(enrichment.summary), tags: enrichment.tags,
            foundLayer: enrichment.fromServer.detections ? .gold : .silver,
            summaryLayer: enrichment.fromServer.summary ? .gold : .silver,
            tagsLayer: enrichment.fromServer.tags ? .gold : .silver,
            status: StatusLine.lines(saved: m.capturedAt, steps: steps, goldKinds: goldKinds(enrichment),
                                     goldArrivedAt: goldArrivedAt, locale: locale, zone: savedZone),
            pending: steps.reduce(into: [:]) { out, step in
                if let line = EnrichmentProgress.pendingLine(step.key, step.value) { out[step.key] = line }
            })
    }

    private static func storageLine(jobs: [UploadJob], changed: RemoteChangedRecord?, hasTrimmed: Bool,
                                    name: String?) -> StatusLine? {
        guard let name, !jobs.isEmpty else { return nil }
        let line: (String, StatusState)?
        if changed != nil { line = ("Changed in \(name)", .failed) }
        else if jobs.contains(where: { $0.state == .uploading }) { line = ("Uploading…", .working) }
        else if jobs.contains(where: { $0.state == .retryableFailure && $0.lastErrorCode == "offline" }) {
            line = ("Waiting for a connection", .waiting)
        } else if hasTrimmed { line = ("Large files in \(name) only", .done) }
        else if jobs.allSatisfy({ $0.state == .synced }) { line = ("In \(name) · verified", .done) }
        else { line = nil }
        return line.map { StatusLine(layer: .sync, text: $0.0, state: $0.1) }
    }

    /// Kinds whose shown result came from the server.
    private static func goldKinds(_ e: ResolvedEnrichment) -> Set<FacetKind> {
        var kinds: Set<FacetKind> = []
        if e.links.values.contains(where: \.fromServer) { kinds.insert(.linkPreview) }
        if !e.fromServer.places.isEmpty { kinds.insert(.place) }
        if !e.fromServer.transcripts.isEmpty { kinds.insert(.transcript) }
        if !e.fromServer.recognizedText.isEmpty { kinds.insert(.textRecognition) }
        if e.fromServer.detections { kinds.insert(.dataDetection) }
        if e.fromServer.sourceApp { kinds.insert(.sourceAppGuess) }
        return kinds
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    // MARK: Comments

    /// Recording attachments shown as comment rows: every one, except in a voice recording, where the recording is
    /// the capture itself.
    private static func recordingComments(_ m: CaptureMetadata, files: [(Attachment, URL)]) -> [(Attachment, URL)] {
        guard m.captureMethod != .voiceRecording else { return [] }
        return files.filter { $0.0.representationSource == "recording" }
    }

    private static func commentRows(_ m: CaptureMetadata, recordings: [(Attachment, URL)], comments: [CaptureComment],
                                    packageURL: URL, enrichment: ResolvedEnrichment, now: Date, locale: Locale,
                                    calendar: Calendar) -> [CommentRow] {
        func transcript(_ id: String) -> (String?, Layer?) {
            guard let text = nonEmpty(enrichment.transcripts[id]?.text) else { return (nil, nil) }
            return (text, enrichment.fromServer.transcripts.contains(id) ? .gold : .silver)
        }
        var rows: [CommentRow] = []
        if let note = nonEmpty(m.userNote) { rows.append(CommentRow(id: "user_note", body: .text(note))) }
        for (a, url) in recordings {
            let (text, layer) = transcript(a.attachmentID)
            rows.append(CommentRow(id: a.attachmentID,
                                   body: .audio(url, durationText: a.media?.durationSeconds.flatMap(DetailFormat.duration)),
                                   transcript: text, transcriptLayer: layer))
        }
        for c in comments {
            let caption = addedCaption(c.addedAt, now: now, locale: locale, calendar: calendar)
            if let body = nonEmpty(c.text) {
                rows.append(CommentRow(id: c.commentID, body: .text(body), caption: caption))
            } else if let audio = c.audio, isCommentAudioPath(audio.relativePath, commentID: c.commentID) {
                let (text, layer) = transcript(c.commentID)
                rows.append(CommentRow(id: c.commentID,
                                       body: .audio(packageURL.appendingPathComponent(audio.relativePath),
                                                    durationText: audio.media?.durationSeconds.flatMap(DetailFormat.duration)),
                                       caption: caption, transcript: text, transcriptLayer: layer))
            }
        }
        return rows
    }

    /// `comments/<comment-id>.<ext>`, nothing that can leave the package (`PackageComments.load` checks the same).
    private static func isCommentAudioPath(_ path: String, commentID: String) -> Bool {
        let prefix = "\(PackageComments.directoryName)/\(commentID)."
        guard path.hasPrefix(prefix) else { return false }
        let ext = path.dropFirst(prefix.count)
        return !ext.isEmpty && !ext.contains("/") && !ext.contains(".")
    }

    /// "Added today, 2:02 PM" when `addedAt` falls on `now`'s day in `calendar`; else "Added Nov 3, 9:15 AM"
    /// (day and month in `locale`'s order).
    static func addedCaption(_ addedAt: Date, now: Date, locale: Locale, calendar: Calendar) -> String {
        let time = addedAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale,
                                                      calendar: calendar, timeZone: calendar.timeZone))
        if calendar.isDate(addedAt, inSameDayAs: now) { return "Added today, " + time }
        let day = addedAt.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .day().month(.abbreviated))
        return "Added " + day + ", " + time
    }

    // MARK: Enrichment

    private static func titled(_ m: CaptureMetadata, _ texts: [String: String],
                               gold: Set<String>, excluding: Set<String> = []) -> [TitledText] {
        m.attachments.enumerated().compactMap { i, a in
            guard !excluding.contains(a.attachmentID), let text = nonEmpty(texts[a.attachmentID]) else { return nil }
            return TitledText(title: "Attachment \(i + 1)", text: text, layer: gold.contains(a.attachmentID) ? .gold : .silver)
        }
    }

    private static func foundItem(_ d: Detection, metadata m: CaptureMetadata, noteBody: String?) -> FoundItem {
        var action: FoundAction?
        switch d.type {
        case "phone":
            let raw = (d.value ?? d.text).trimmingCharacters(in: .whitespaces)
            let digits = raw.filter { $0.isASCII && $0.isNumber }
            let number = (raw.hasPrefix("+") ? "+" : "") + digits
            if !digits.isEmpty { action = URL(string: "tel:\(number)").map(FoundAction.call) }
        case "address":
            if let q = d.text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#?"))),
               let url = URL(string: "maps://?q=\(q)") { action = .map(url) }
        case "date":
            if let start = date(from: d.value, zoneID: m.timezoneIdentifier, fallbackOffset: m.utcOffsetSeconds) {
                action = .addToCalendar(start: start, title: DisplayTitle.make(m, noteBody: noteBody))
            }
        case "link":
            // Gold is untrusted: only web links become actions.
            if let url = URL(string: d.value ?? d.text), let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty { action = .open(url) }
        default: break
        }
        return FoundItem(kind: d.type, text: d.text, action: action)
    }

    /// A value with an offset is exact; one without is wall-clock in the capture's zone.
    private static func date(from value: String?, zoneID: String, fallbackOffset: Int) -> Date? {
        guard let value else { return nil }
        if let parsed = DetailFormat.parseRFC3339(value) { return parsed.date }
        guard let zone = TimeZone(identifier: zoneID) ?? TimeZone(secondsFromGMT: fallbackOffset),
              let wall = DetailFormat.parseWallClock(value) else { return nil }
        // `parseWallClock` reads in GMT; shift to the same wall-clock reading in the capture zone.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .gmt
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: wall)
        cal.timeZone = zone
        return cal.date(from: c)
    }

    // MARK: Preview

    private static func preview(metadata m: CaptureMetadata, files: [(Attachment, URL)], links: [URL],
                                noteBody: String?, remoteOnly: [String: RemoteOnlyAttachment]) -> PreviewKind {
        if m.captureMethod == .typedNote, let noteBody, !noteBody.isEmpty { return .text(noteBody) }
        if let (a, url) = files.first {
            if let remote = remoteOnly[a.attachmentID] { return .remoteOnly(remote) }
            let name = nonEmpty(a.originalFilename)
            if a.mimeType?.lowercased() == "text/html" { return .file(url, previewable: false, name: name) }
            guard let type = UTType(a.uti) else { return .file(url, previewable: true, name: name) }
            if type.conforms(to: .html) || a.mimeType?.lowercased() == "text/html" { return .file(url, previewable: false, name: name) }
            if type.conforms(to: .image) { return .image(url) }
            if type.conforms(to: .movie) || type.conforms(to: .video) { return .video(url) }
            if type.conforms(to: .audio) { return .audio(url) }
            if type.conforms(to: .pdf) { return .pdf(url) }
            return .file(url, previewable: true, name: name)
        }
        if let link = links.first { return .link(link) }
        return .none
    }

    // MARK: Captured

    private static func capturedRows(_ m: CaptureMetadata, enrichment: ResolvedEnrichment, locale: Locale, calendar: Calendar) -> [DetailRow] {
        var rows: [DetailRow] = []
        let parsed = DetailFormat.parseRFC3339(m.localDatetime)
        let instant = parsed?.date ?? m.capturedAt
        let zone = TimeZone(identifier: m.timezoneIdentifier)
            ?? TimeZone(secondsFromGMT: parsed?.offset ?? m.utcOffsetSeconds) ?? .gmt
        var when = DetailFormat.dateTime(instant, zone: zone, locale: locale)
        if zone.secondsFromGMT(for: instant) != calendar.timeZone.secondsFromGMT(for: instant),
           let abbreviation = zone.abbreviation(for: instant) {
            when += " \(abbreviation)"
        }
        rows.append(DetailRow(label: "When", value: when))
        let how: String? = switch m.captureMethod.rawValue {
        case "share_extension": "Shared"
        case "typed_note": "Typed note"
        case "voice_recording": "Recorded"
        case "camera": "Camera"
        case "file_import": "Imported"
        default: nil
        }
        if let how { rows.append(DetailRow(label: "How", value: how)) }
        if let app = nonEmpty(enrichment.sourceAppGuess) {
            rows.append(DetailRow(label: "Source", value: "Probably from \(app)",
                                layer: enrichment.fromServer.sourceApp ? .gold : .silver))
        }
        if let l = m.captureLocation {
            var value = DetailFormat.coordinates(latitude: l.latitude, longitude: l.longitude)
            if l.horizontalAccuracyMeters >= 0, let meters = Int(exactly: l.horizontalAccuracyMeters.rounded()) {
                value += " · ±\(meters) m"
            }
            let age = m.capturedAt.timeIntervalSince(l.observedAt)
            if age >= 60 { value += " · \(DetailFormat.age(age)) before saving" }
            if let line = enrichment.places["capture"].flatMap(PlaceText.line) {
                rows.append(DetailRow(label: "Where", value: line,
                                      layer: enrichment.fromServer.places.contains("capture") ? .gold : .silver))
                rows.append(DetailRow(label: "Coordinates", value: value))
            } else {
                rows.append(DetailRow(label: "Where", value: value))
            }
        }
        return rows
    }

    // MARK: Attachments

    private static func symbol(for uti: String) -> String {
        guard let type = UTType(uti) else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return "video" }
        return "doc"
    }

    private static func attachmentRows(_ a: Attachment, number: Int, place: PlaceItem?, placeFromServer: Bool,
                                       locale: Locale, remoteOnly: RemoteOnlyAttachment?) -> [DetailRow] {
        var rows: [DetailRow] = []
        rows.append(DetailRow(label: "Name", value: nonEmpty(a.originalFilename) ?? "Attachment \(number)"))
        rows.append(DetailRow(label: "Type", value: nonEmpty(a.mimeType) ?? a.uti))
        rows.append(DetailRow(label: "Size", value: ByteCountFormatter.string(fromByteCount: a.byteCount, countStyle: .file)))
        if let w = a.media?.widthPixels, let h = a.media?.heightPixels {
            rows.append(DetailRow(label: "Dimensions", value: "\(w) × \(h)"))
        }
        if let d = a.media?.durationSeconds.flatMap(DetailFormat.duration) {
            rows.append(DetailRow(label: "Duration", value: d))
        }
        if let taken = a.media?.embeddedCreatedAt, let value = takenText(taken, locale: locale) {
            rows.append(DetailRow(label: "Taken", value: value))
        }
        if let l = a.media?.embeddedLocation {
            rows.append(DetailRow(label: "Photo location",
                                  value: DetailFormat.coordinates(latitude: l.latitude, longitude: l.longitude)))
        }
        if let place, let area = PlaceText.area(place) { rows.append(DetailRow(label: "Taken in", value: area, layer: placeFromServer ? .gold : .silver)) }
        if let remoteOnly { rows.append(DetailRow(label: "Storage", value: remoteOnly.storageText)) }
        return rows
    }

    private static func takenText(_ t: EmbeddedTimestamp, locale: Locale) -> String? {
        if t.hasUTCOffset, let parsed = DetailFormat.parseRFC3339(t.value),
           let zone = TimeZone(secondsFromGMT: parsed.offset) {
            return DetailFormat.dateTime(parsed.date, zone: zone, locale: locale)
        }
        guard nonEmpty(t.value) != nil else { return nil }
        // Wall-clock only: show it as recorded, never converted.
        let shown = DetailFormat.parseWallClock(t.value)
            .map { DetailFormat.dateTime($0, zone: .gmt, locale: locale) } ?? t.value
        return t.hasUTCOffset ? shown : shown + " (time zone unknown)"
    }
}
