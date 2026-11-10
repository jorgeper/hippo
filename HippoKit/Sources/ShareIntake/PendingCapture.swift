import Foundation
import CaptureCore

/// A capture gathered by the Share Extension, waiting for the app to add a voice comment and commit it.
public struct PendingCapture: Sendable {
    public var draft: CaptureDraft          // userNote = the typed comment so far; location already set
    public var previewImageURL: URL?
    public var totalBytes: Int64
    public var savedAt: Date
    public init(draft: CaptureDraft, previewImageURL: URL?, totalBytes: Int64, savedAt: Date) {
        self.draft = draft; self.previewImageURL = previewImageURL
        self.totalBytes = totalBytes; self.savedAt = savedAt
    }
}

/// On-disk shape of `intake/<capture-id>/pending.json`. File bodies are stored by last path component.
private struct PendingFile: Codable {
    struct Attachment: Codable {
        var file: String?
        var data: Data?
        var originalFilename: String?
        var uti: String
        var mimeType: String?
        var representationSource: String
        enum CodingKeys: String, CodingKey {
            case file, data, uti
            case originalFilename = "original_filename"
            case mimeType = "mime_type"
            case representationSource = "representation_source"
        }
    }

    var schemaVersion = 1
    var captureID: UUID
    var startedAt: Date
    var timeZone: String
    var method: CaptureMethod
    var userNote: String?
    var sharedTitle: String?
    var sharedText: String?
    var urls: [CapturedURL]
    var attachments: [Attachment]
    var location: CaptureLocation?
    var observations: [MetadataObservation]
    var previewImage: String?
    var totalBytes: Int64
    var savedAt: Date

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case captureID = "capture_id"
        case startedAt = "started_at"
        case timeZone = "time_zone"
        case method
        case userNote = "user_note"
        case sharedTitle = "shared_title"
        case sharedText = "shared_text"
        case urls, attachments, location, observations
        case previewImage = "preview_image"
        case totalBytes = "total_bytes"
        case savedAt = "saved_at"
    }
}

extension IntakeDirectory {
    static let pendingFileName = "pending.json"

    private func pendingURL(captureID: UUID) -> URL {
        directory(for: captureID).appendingPathComponent(Self.pendingFileName, isDirectory: false)
    }

    /// Writes `intake/<capture-id>/pending.json`. File bodies must already live inside that directory.
    public func savePending(_ pending: PendingCapture) throws {
        let draft = pending.draft
        try FileManager.default.createDirectory(at: directory(for: draft.captureID), withIntermediateDirectories: true)
        let dir = directory(for: draft.captureID).standardizedFileURL.resolvingSymlinksInPath()

        func relativeName(_ url: URL) throws -> String {
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            guard resolved.deletingLastPathComponent() == dir else { throw CocoaError(.fileWriteInvalidFileName) }
            return resolved.lastPathComponent
        }

        let attachments = try draft.attachments.map { source -> PendingFile.Attachment in
            var file: String?
            var data: Data?
            switch source.body {
            case .file(let url): file = try relativeName(url)
            case .data(let bytes): data = bytes
            }
            return .init(file: file, data: data, originalFilename: source.originalFilename, uti: source.uti,
                         mimeType: source.mimeType, representationSource: source.representationSource)
        }
        let file = PendingFile(
            captureID: draft.captureID, startedAt: draft.startedAt, timeZone: draft.timeZone.identifier,
            method: draft.method, userNote: draft.userNote, sharedTitle: draft.sharedTitle,
            sharedText: draft.sharedText, urls: draft.urls, attachments: attachments, location: draft.location,
            observations: draft.observations, previewImage: try pending.previewImageURL.map(relativeName),
            totalBytes: pending.totalBytes, savedAt: pending.savedAt)
        try HippoJSON.encode(file).write(to: pendingURL(captureID: draft.captureID), options: .atomic)
    }

    /// Oldest first. A pending capture whose files are missing is removed and reported in `dropped`.
    public func pendingCaptures() -> (captures: [PendingCapture], dropped: Int) {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var captures: [PendingCapture] = []
        var dropped = 0
        for entry in entries {
            let jsonURL = entry.appendingPathComponent(Self.pendingFileName)
            guard fm.fileExists(atPath: jsonURL.path) else { continue }
            switch Self.load(jsonURL, in: entry) {
            case .loaded(let pending):
                captures.append(pending)
            case .keep:
                continue
            case .discard:
                try? fm.removeItem(at: entry)
                dropped += 1
            }
        }
        captures.sort {
            $0.savedAt != $1.savedAt ? $0.savedAt < $1.savedAt
                : $0.draft.captureID.uuidString < $1.draft.captureID.uuidString
        }
        return (captures, dropped)
    }

    /// True when `intake/<capture-id>/pending.json` exists.
    public func isPending(captureID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: pendingURL(captureID: captureID).path)
    }

    private enum LoadOutcome {
        case loaded(PendingCapture)
        /// Unreadable for now, or written by a newer version: leave it on disk.
        case keep
        /// Confirmed corrupt or missing a file: remove it.
        case discard
    }

    private static func load(_ jsonURL: URL, in dir: URL) -> LoadOutcome {
        let fm = FileManager.default
        guard let bytes = try? Data(contentsOf: jsonURL) else { return .keep }
        let file: PendingFile
        do {
            file = try HippoJSON.decode(PendingFile.self, from: bytes)
        } catch FormatError.unsupportedSchemaVersion {
            return .keep
        } catch {
            return .discard
        }
        guard let zone = TimeZone(identifier: file.timeZone) else { return .discard }
        var attachments: [AttachmentSource] = []
        for item in file.attachments {
            let body: AttachmentSource.Body
            if let name = item.file {
                let url = dir.appendingPathComponent(name, isDirectory: false)
                guard fm.fileExists(atPath: url.path) else { return .discard }
                body = .file(url)
            } else if let data = item.data {
                body = .data(data)
            } else { return .discard }
            attachments.append(AttachmentSource(body: body, originalFilename: item.originalFilename, uti: item.uti,
                                                mimeType: item.mimeType, representationSource: item.representationSource))
        }
        var preview: URL?
        if let name = file.previewImage {
            let url = dir.appendingPathComponent(name, isDirectory: false)
            guard fm.fileExists(atPath: url.path) else { return .discard }
            preview = url
        }
        let draft = CaptureDraft(captureID: file.captureID, startedAt: file.startedAt, timeZone: zone, method: file.method,
                                 userNote: file.userNote, sharedTitle: file.sharedTitle, sharedText: file.sharedText,
                                 urls: file.urls, attachments: attachments, location: file.location,
                                 observations: file.observations)
        return .loaded(PendingCapture(draft: draft, previewImageURL: preview, totalBytes: file.totalBytes, savedAt: file.savedAt))
    }
}
