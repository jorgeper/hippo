import Foundation
import Observation
import UniformTypeIdentifiers
import CaptureCore
import ShareIntake
import SyncEngine

/// State machine behind the Share Extension sheet: gathers the shared items, takes an optional comment
/// and commits one capture.
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

    public var destinationLine: String {
        if let destinationName {
            "Saves on this iPhone first. Uploads to \(destinationName) when it can."
        } else {
            "Saves on this iPhone. Uploads once you connect Dropbox in Hippo."
        }
    }

    private let store: HippoStore
    private let intake: IntakeDirectory
    private let input: ShareInput
    private let destinationName: String?
    private let location: (Date) -> CaptureLocation?
    private let now: () -> Date
    private let timeZone: TimeZone
    private let captureID = UUID()

    private var draft: CaptureDraft?
    private var cancelled = false

    public init(store: HippoStore, intake: IntakeDirectory, input: ShareInput,
                destinationName: String?, location: @escaping (Date) -> CaptureLocation?,
                now: @escaping () -> Date = Date.init, timeZone: TimeZone = .current) {
        self.store = store; self.intake = intake; self.input = input
        self.destinationName = destinationName; self.location = location; self.now = now; self.timeZone = timeZone
        state = .preparing(done: 0, total: input.providers.count)
    }

    /// Copies the shared items into the intake directory. Call once, when the sheet appears.
    public func prepare() async {
        guard draft == nil, case .preparing = state else { return }
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
        previewImageURL = result.firstImageURL
        summary = Self.summary(for: d, totalBytes: result.totalBytes)
        let unsupported = result.failures.filter { $0.kind == .unsupported }.count
        let failedLoads = result.failures.filter { $0.kind == .loadFailed }.count
        previewSymbol = Self.symbol(for: d)
        partialNotice = result.failures.isEmpty ? nil : Self.partialMessage(unsupported: unsupported, loadFailed: failedLoads)
        state = .ready
    }

    /// Commits the capture. Without `acceptPartial`, items the intake couldn't take ask for confirmation first.
    public func save(acceptPartial: Bool = false) async {
        guard !cancelled, var draft else { return }
        switch state {
        case .ready, .confirmPartial, .failed(_, canSave: true): break
        default: return
        }
        if let partialNotice, !acceptPartial {
            state = .confirmPartial(message: partialNotice)
            return
        }
        state = .saving
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.userNote = trimmed.isEmpty ? nil : trimmed
        draft.location = location(draft.startedAt)
        do {
            _ = try await store.capture(draft, partialPolicy: acceptPartial ? .acceptPartial : .rejectPartial)
            intake.discard(captureID: captureID)
            state = .saved
        } catch let error as CaptureError {
            if case .attachmentsFailed = error {
                state = .confirmPartial(message: Self.message(for: error))
            } else {
                state = .failed(message: Self.message(for: error), canSave: false)
            }
        } catch {
            // Only `CaptureError` comes out of the store; a retry wouldn't change anything.
            state = .failed(message: Self.genericFailureMessage, canSave: false)
        }
    }

    /// The user declined the "save the rest" question: back to editing, nothing saved.
    public func declinePartial() {
        guard case .confirmPartial = state else { return }
        state = .ready
    }

    /// Removes the intake files, now or when a running `prepare()` returns. The sheet closes afterwards.
    public func cancel() {
        cancelled = true
        intake.discard(captureID: captureID)
    }

    // MARK: - Copy

    static func message(for error: CaptureError) -> String {
        switch error {
        case .insufficientSpace: "Not enough space on this iPhone. Nothing was saved."
        case .attachmentsFailed(let failures): "\(failures.count) items couldn't be saved."
        case .emptyCapture: nothingSavableMessage
        case .io: genericFailureMessage
        }
    }

    static func partialMessage(unsupported a: Int, loadFailed b: Int) -> String {
        switch (a > 0, b > 0) {
        case (true, true): "\(a) items can't be saved and \(b) couldn't be copied."
        case (true, false): "Hippo can't save \(a) of these items."
        default: "\(b) items couldn't be copied."
        }
    }

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
