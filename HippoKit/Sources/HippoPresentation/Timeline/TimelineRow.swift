import Foundation
import UniformTypeIdentifiers
import CaptureCore
import LocalRepository

public struct TimelineRow: Identifiable, Equatable, Sendable {
    public enum RowKind: Sendable, Equatable { case media, multi, link, note, voice, file }

    public var id: String
    public var time: String
    public var title: String
    public var subtitle: String?
    public var comment: String?
    public var kind: RowKind
    public var sync: SyncLabel
    /// The capture package's directory relative to the store, for resolving `thumbnailAttachmentPaths`.
    public var relativeDirectory: String
    /// Package-relative paths.
    public var thumbnailAttachmentPaths: [String]
    public var extraCount: Int
    /// A file URL for a link's preview picture, when one has been fetched.
    public var thumbnailURL: URL?
    /// Enrichment activity: a spinner while working, a clock while only waiting.
    public var progress: RowProgress = .none

    /// `metadata` nil means the summary alone is used.
    public static func make(_ s: CaptureSummary, metadata: CaptureMetadata?, enrichment: ResolvedEnrichment?,
                                locale: Locale) -> TimelineRow {
        var row = TimelineRow(id: s.id, time: timeText(s, locale: locale), title: s.title, subtitle: nil,
                              comment: s.noteExcerpt, kind: .file, sync: SyncLabel(s.syncBucket),
                              relativeDirectory: s.relativeDirectory,
                              thumbnailAttachmentPaths: [], extraCount: 0, thumbnailURL: nil)
        let hasVisual = s.contentTypes.contains(.image) || s.contentTypes.contains(.video)
        // Audio outside a recording is a voice comment: the row shows what it comments on (design §4.6).
        // Without metadata, a capture with audio is taken to have one audio attachment.
        let audioCount = metadata.map { $0.attachments.filter(isAudio).count }
            ?? (s.contentTypes.contains(.audio) ? 1 : 0)
        let count = s.method == .voiceRecording ? s.attachmentCount : max(0, s.attachmentCount - audioCount)
        if s.method != .voiceRecording && count >= 2 {
            let visual = metadata?.attachments.filter(isVisual).map(\.relativePath)
                ?? s.primaryAttachmentPath.map { [$0] } ?? []
            let shown = Array(visual.prefix(3))
            row.kind = .multi
            row.thumbnailAttachmentPaths = shown
            row.extraCount = max(0, count - shown.count)
        } else if s.method == .voiceRecording {
            row.kind = .voice
            let seconds = metadata?.attachments.first?.media?.durationSeconds
            if let seconds, seconds.isFinite, seconds >= 0 {
                let total = Int(seconds)
                row.title = "Voice note · \(total / 60):" + (total % 60 < 10 ? "0" : "") + "\(total % 60)"
            } else {
                row.title = "Voice note"
            }
            if let line = transcriptLine(metadata: metadata, enrichment: enrichment) { row.subtitle = line }
        } else if count == 1 && hasVisual {
            row.kind = .media
            row.thumbnailAttachmentPaths = s.primaryAttachmentPath.map { [$0] } ?? []
        } else if count == 0 && s.contentTypes.contains(.url) {
            row.kind = .link
            let first = metadata?.urls.first?.url
            let link = first.flatMap { enrichment?.links[$0] }
            if let title = nonEmpty(link?.title) { row.title = title }
            row.subtitle = nonEmpty(link?.channel) ?? nonEmpty(link?.siteName) ?? first.flatMap { host(of: $0) }
            row.thumbnailURL = link?.thumbnailURL
        } else if s.method == .typedNote {
            row.kind = .note
        }
        return row
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    /// The first non-empty line of the first audio attachment's transcript, at most 80 characters.
    private static func transcriptLine(metadata: CaptureMetadata?, enrichment: ResolvedEnrichment?) -> String? {
        guard let metadata, let enrichment,
              let audio = metadata.attachments.first(where: isAudio),
              let text = enrichment.transcripts[audio.attachmentID]?.text else { return nil }
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return line.map { String($0.prefix(80)) }
    }

    private static func isAudio(_ a: Attachment) -> Bool {
        if let type = UTType(a.uti) { return type.conforms(to: .audio) }
        return a.mimeType?.hasPrefix("audio/") ?? false
    }

    private static func timeText(_ s: CaptureSummary, locale: Locale) -> String {
        let zone = s.utcOffsetSeconds.flatMap { TimeZone(secondsFromGMT: $0) } ?? .current
        return s.capturedAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: zone))
    }

    private static func host(of raw: String) -> String? {
        guard let host = URLComponents(string: raw)?.host, !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func isVisual(_ a: Attachment) -> Bool {
        if let type = UTType(a.uti) { return type.conforms(to: .image) || type.conforms(to: .movie) }
        return a.mimeType.map { $0.hasPrefix("image/") || $0.hasPrefix("video/") } ?? false
    }
}
