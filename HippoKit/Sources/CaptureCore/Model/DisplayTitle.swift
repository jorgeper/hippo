import Foundation

/// Deterministic title for a capture, used by the index and the capture list.
public enum DisplayTitle {
    private static let noteLineLimit = 80

    public static func make(_ m: CaptureMetadata, noteBody: String?) -> String {
        if let title = nonBlank(m.sharedTitle) {
            return title
        }
        if let line = noteBody.flatMap(firstNonEmptyLine) {
            return String(line.prefix(noteLineLimit))
        }
        if let first = m.urls.first {
            return hostAndPath(first.url)
        }
        if let name = nonBlank(m.attachments.first?.originalFilename) {
            return name
        }
        if m.captureMethod == .voiceRecording {
            guard let seconds = m.attachments.first?.media?.durationSeconds, seconds.isFinite, seconds >= 0 else {
                return "Voice note"
            }
            let total = Int(seconds.rounded())
            let ss = total % 60
            return "Voice note · \(total / 60):\(ss < 10 ? "0" : "")\(ss)"
        }
        return typeWord(m.contentTypes.first)
    }

    private static func nonBlank(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    private static func firstNonEmptyLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    /// `https://example.com/item/42?q=1` → `example.com/item/42`. A bare `/` path is dropped.
    private static func hostAndPath(_ raw: String) -> String {
        guard let components = URLComponents(string: raw), let host = components.host, !host.isEmpty else {
            return raw
        }
        let path = components.path == "/" ? "" : components.path
        return host + path
    }

    private static func typeWord(_ type: ContentType?) -> String {
        switch type {
        case .image?: "Image"
        case .video?: "Video"
        case .audio?: "Audio"
        case .pdf?: "PDF"
        case .text?, nil: "Note"
        case .url?: "Link"
        default: "File"
        }
    }
}
