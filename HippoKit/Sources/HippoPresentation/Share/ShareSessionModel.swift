import Foundation
import Observation
import UniformTypeIdentifiers
import CaptureCore
import ShareIntake
import SyncEngine

/// A draft already on disk: from the camera.
public struct PreparedCapture: Sendable {
    public var draft: CaptureDraft
    public var previewImageURL: URL?
    public var totalBytes: Int64

    public init(draft: CaptureDraft, previewImageURL: URL?, totalBytes: Int64) {
        self.draft = draft; self.previewImageURL = previewImageURL; self.totalBytes = totalBytes
    }
}

/// State machine behind the capture sheet: the Share Extension (gathers the shared items) and the in-app
/// camera. Takes an optional comment and voice comment, and commits one capture.
@MainActor @Observable
public final class ShareSessionModel {
    public enum State: Equatable {
        case preparing(done: Int, total: Int)
        case ready
        case confirmPartial(message: String)
        case saving
        case saved
        case failed(message: String, canSave: Bool)
    }

    static let nothingSavableMessage = "Nothing Hippo can save was shared."
    static let genericFailureMessage = "Hippo couldn't save this. Nothing was saved."

    public private(set) var state: State
    public var comment: String = ""
    public private(set) var summary: String = ""
    public private(set) var previewImageURL: URL?
    /// Set when the intake left items behind. The sheet shows it inline; Save asks before committing the rest.
    public private(set) var partialNotice: String?
    /// SF Symbol for the preview when there is no thumbnail.
    public private(set) var previewSymbol: String = "doc"
    /// Records the voice comment in place (camera). Nil in the extension.
    public let voice: RecordingSession?

    public var destinationLine: String {
        if let destinationName {
            "Saves on this iPhone first. Uploads to \(destinationName) when it can."
        } else {
            "Saves on this iPhone. Uploads once you connect Dropbox in Hippo."
        }
    }

    private let store: HippoStore
    private let intake: IntakeDirectory
    /// Nil for a prepared capture, which carries its location and never re-reads it.
    private let input: ShareInput?
    private let destinationName: String?
    private let location: (Date) -> CaptureLocation?
    private let now: () -> Date
    private let timeZone: TimeZone
    private let captureID: UUID

    private var draft: CaptureDraft?
    private var totalBytes: Int64 = 0
    private var cancelled = false

    /// Share Extension: `prepare()` copies the shared items in.
    public init(store: HippoStore, intake: IntakeDirectory, input: ShareInput,
                destinationName: String?, location: @escaping (Date) -> CaptureLocation?,
                now: @escaping () -> Date = Date.init, timeZone: TimeZone = .current) {
        self.store = store; self.intake = intake; self.input = input
        self.destinationName = destinationName; self.location = location; self.now = now; self.timeZone = timeZone
        captureID = UUID()
        voice = nil
        state = .preparing(done: 0, total: input.providers.count)
    }

    /// Camera. State starts `.ready`; `prepare()` is a no-op.
    public init(store: HippoStore, intake: IntakeDirectory, prepared: PreparedCapture,
                destinationName: String?, voice: RecordingSession?,
                location: @escaping (Date) -> CaptureLocation?, now: @escaping () -> Date = Date.init) {
        self.store = store; self.intake = intake; input = nil
        self.destinationName = destinationName; self.location = location; self.now = now
        timeZone = prepared.draft.timeZone
        captureID = prepared.draft.captureID
        self.voice = voice
        draft = prepared.draft
        totalBytes = prepared.totalBytes
        comment = prepared.draft.userNote ?? ""
        previewImageURL = prepared.previewImageURL
        summary = Self.summary(for: prepared.draft, totalBytes: prepared.totalBytes)
        previewSymbol = Self.symbol(for: prepared.draft)
        state = .ready
    }

    /// Copies the shared items into the intake directory. Call once, when the sheet appears.
    public func prepare() async {
        guard let input, draft == nil, case .preparing = state else { return }
        let result = await ShareIntake(directory: intake).prepare(input, captureID: captureID, startedAt: now(), timeZone: timeZone) { [weak self] done, total in
            Task { @MainActor in
                // Progress can land after the result; it never moves the state backwards.
                guard let self, case .preparing = self.state else { return }
                self.state = .preparing(done: done, total: total)
            }
        }
        // Cancelled while copying: the copies are discarded and the state stays as it was.
        guard !cancelled else { intake.discard(captureID: captureID); return }
        let d = result.draft
        guard !d.attachments.isEmpty || !d.urls.isEmpty || d.sharedText != nil else {
            intake.discard(captureID: captureID)
            state = .failed(message: Self.nothingSavableMessage, canSave: false)
            return
        }
        draft = d
        totalBytes = result.totalBytes
        previewImageURL = result.firstImageURL
        summary = Self.summary(for: d, totalBytes: result.totalBytes)
        let unsupported = result.failures.filter { $0.kind == .unsupported }.count
        let failedLoads = result.failures.filter { $0.kind == .loadFailed }.count
        previewSymbol = Self.symbol(for: d)
        partialNotice = result.failures.isEmpty ? nil : Self.partialMessage(unsupported: unsupported, loadFailed: failedLoads)
        state = .ready
    }

    /// Commits the capture, with the voice comment (stopped first if still recording) as the last
    /// attachment. Without `acceptPartial`, items the intake couldn't take ask for confirmation first.
    public func save(acceptPartial: Bool = false) async {
        guard !cancelled, draft != nil else { return }
        switch state {
        case .ready, .confirmPartial, .failed(_, canSave: true): break
        default: return
        }
        if let voice, case .recording = voice.state { voice.stop() }
        if let partialNotice, !acceptPartial {
            state = .confirmPartial(message: partialNotice)
            return
        }
        guard var draft = finishedDraft() else { return }
        state = .saving
        let recording = voice?.takePending()
        if let recording {
            draft.attachments.append(AttachmentSource(body: .file(recording.url), uti: "com.apple.m4a-audio",
                                                      mimeType: "audio/mp4", representationSource: "recording"))
        }
        do {
            _ = try await store.capture(draft, partialPolicy: acceptPartial ? .acceptPartial : .rejectPartial)
            intake.discard(captureID: captureID)
            if let recording { try? FileManager.default.removeItem(at: recording.url) }
            state = .saved
        } catch {
            // The recording stays on disk so Save can be tried again.
            if let recording { voice?.restorePending(recording) }
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        switch error {
        case let error as CaptureError:
            if case .attachmentsFailed = error {
                state = .confirmPartial(message: Self.message(for: error))
            } else {
                state = .failed(message: Self.message(for: error), canSave: false)
            }
        default:
            // Only `CaptureError` comes out of the store; a retry wouldn't change anything.
            state = .failed(message: Self.genericFailureMessage, canSave: false)
        }
    }

    /// The draft with the trimmed comment and, for shared items, the location fix for its start time.
    private func finishedDraft() -> CaptureDraft? {
        guard var draft else { return nil }
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.userNote = trimmed.isEmpty ? nil : trimmed
        if input != nil { draft.location = location(draft.startedAt) }
        return draft
    }

    /// The user declined the "save the rest" question: back to editing, nothing saved.
    public func declinePartial() {
        guard case .confirmPartial = state else { return }
        state = .ready
    }

    /// Removes the intake files, now or when a running `prepare()` returns, and any voice comment. The
    /// sheet closes afterwards.
    public func cancel() {
        cancelled = true
        voice?.discard()
        intake.discard(captureID: captureID)
    }

    // MARK: - Copy

    static func message(for error: CaptureError) -> String {
        switch error {
        case .insufficientSpace: "Not enough space on this iPhone. Nothing was saved."
        case .attachmentsFailed(let failures): "\(items(failures.count)) couldn't be saved."
        case .emptyCapture: nothingSavableMessage
        case .io: genericFailureMessage
        }
    }

    static func partialMessage(unsupported a: Int, loadFailed b: Int) -> String {
        switch (a > 0, b > 0) {
        case (true, true): "\(items(a)) can't be saved and \(b) couldn't be copied."
        case (true, false): "Hippo can't save \(a) of these items."
        default: "\(items(b)) couldn't be copied."
        }
    }

    /// "1 item", "2 items".
    private static func items(_ n: Int) -> String { n == 1 ? "1 item" : "\(n) items" }

    static func symbol(for draft: CaptureDraft) -> String {
        if let first = draft.attachments.first {
            let type = UTType(first.uti)
            if type?.conforms(to: .movie) == true { return "video" }
            if type?.conforms(to: .image) == true { return "photo" }
            return type?.conforms(to: .plainText) == true && draft.attachments.count == 1 ? "text.alignment" : "doc"
        }
        return draft.urls.isEmpty ? "text.alignment" : "link"
    }

    static func summary(for draft: CaptureDraft, totalBytes: Int64) -> String {
        let size = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        let attachments = draft.attachments
        if attachments.count > 1 { return "\(attachments.count) items · \(size)" }
        if let only = attachments.first {
            let type = UTType(only.uti)
            let name = only.originalFilename.flatMap { $0.isEmpty ? nil : $0 }
                ?? (type?.conforms(to: .image) == true ? "1 photo"
                    : type?.conforms(to: .movie) == true ? "1 video" : "1 file")
            return "\(name) · \(size)"
        }
        if let first = draft.urls.first {
            return URL(string: first.url)?.host(percentEncoded: false) ?? first.url
        }
        return "Text"
    }
}
