import Foundation
import UniformTypeIdentifiers
import CaptureCore
import LocalRepository

/// Everything the details screen shows for one capture. Missing values are omitted, never blank.
public struct CaptureDetail: Equatable, Sendable {
    public var preview: PreviewKind
    public var comment: String?
    public var sharedTitle: String?
    public var sharedText: String?
    public var links: [URL]
    public var captured: [DetailRow]
    public var attachments: [[DetailRow]]
    public var sync: [SyncRow]
    /// Files offered through Share/Export: every attachment's file.
    public var exportURLs: [URL]

    /// `now` is accepted for symmetry with the timeline; nothing here is relative to it, because
    /// ages are measured against the capture time. `calendar.timeZone` is the current zone.
    public static func make(metadata m: CaptureMetadata, packageURL: URL, noteBody: String?, jobs: [UploadJob],
                            destination: (String) -> Destination?, now: Date, locale: Locale,
                            calendar: Calendar) -> CaptureDetail {
        let files: [(Attachment, URL)] = m.attachments.compactMap { a in
            guard (try? PackagePath.validateRelative(a.relativePath)) != nil else { return nil }
            return (a, packageURL.appendingPathComponent(a.relativePath))
        }
        let links = m.urls.compactMap { URL(string: $0.url) }
        let sync = jobs.isEmpty ? [SyncRow.unassigned]
            : jobs.map { SyncRow.make(job: $0, destinationName: destination($0.destinationID)?.displayName) }
        return CaptureDetail(
            preview: preview(metadata: m, files: files, links: links, noteBody: noteBody),
            comment: nonEmpty(m.userNote), sharedTitle: nonEmpty(m.sharedTitle), sharedText: nonEmpty(m.sharedText),
            links: links,
            captured: capturedRows(m, locale: locale, calendar: calendar),
            attachments: m.attachments.enumerated().map { attachmentRows($1, number: $0 + 1, locale: locale) },
            sync: sync,
            exportURLs: files.map(\.1))
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    // MARK: Preview

    private static func preview(metadata m: CaptureMetadata, files: [(Attachment, URL)], links: [URL],
                                noteBody: String?) -> PreviewKind {
        if m.captureMethod == .typedNote, let noteBody, !noteBody.isEmpty { return .text(noteBody) }
        if let (a, url) = files.first {
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

    private static func capturedRows(_ m: CaptureMetadata, locale: Locale, calendar: Calendar) -> [DetailRow] {
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
        case "file_import": "Imported"
        default: nil
        }
        if let how { rows.append(DetailRow(label: "How", value: how)) }
        if let l = m.captureLocation {
            var value = DetailFormat.coordinates(latitude: l.latitude, longitude: l.longitude)
            if l.horizontalAccuracyMeters >= 0, let meters = Int(exactly: l.horizontalAccuracyMeters.rounded()) {
                value += " · ±\(meters) m"
            }
            let age = m.capturedAt.timeIntervalSince(l.observedAt)
            if age >= 60 { value += " · \(DetailFormat.age(age)) before saving" }
            rows.append(DetailRow(label: "Where", value: value))
        }
        return rows
    }

    // MARK: Attachments

    private static func attachmentRows(_ a: Attachment, number: Int, locale: Locale) -> [DetailRow] {
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
