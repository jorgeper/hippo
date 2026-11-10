import Foundation
import Observation
import CaptureCore
import ShareIntake
import SyncEngine

/// The microphone recorder, implemented over AVAudioRecorder in the app.
@MainActor public protocol AudioRecording: AnyObject {
    func start(writingTo url: URL) throws
    func stop()
    var currentTime: TimeInterval { get }
}

public enum MicPermission: Sendable { case granted, denied, undetermined }

/// State machine behind the voice recorder screen: a `RecordingSession` plus committing the recording, as a
/// new capture or as an audio comment on an existing one (`target`).
@MainActor @Observable
public final class RecorderModel {
    public enum State: Equatable {
        case idle, denied
        case recording(startedAt: Date)
        case stopped(duration: TimeInterval, interrupted: Bool)
        case saving, saved
        case failed(String)
    }

    public static let saveFailedMessage = "Hippo couldn't save this recording. It's still here. Try again."
    /// A comment save failed for a reason other than those in `CommentErrorCopy`.
    nonisolated public static let commentSaveFailedMessage = "Hippo couldn't save this comment. It's still here. Try again."
    static let startFailedMessage = RecordingSession.startFailedMessage

    public var state: State {
        if isSaving { return .saving }
        if didSave { return .saved }
        if let saveFailure { return .failed(saveFailure) }
        switch session.state {
        case .idle: return .idle
        case .denied: return .denied
        case .recording(let startedAt): return .recording(startedAt: startedAt)
        case .stopped(let duration, let interrupted): return .stopped(duration: duration, interrupted: interrupted)
        case .failed(let message): return .failed(message)
        }
    }

    private let store: HippoStore
    private let session: RecordingSession
    private let location: (Date) -> CaptureLocation?
    public let target: SaveTarget
    private let now: () -> Date

    private var isSaving = false
    private var didSave = false
    private var saveFailure: String?

    public init(store: HippoStore, intake: IntakeDirectory, recorder: AudioRecording,
                permission: @escaping () async -> MicPermission,
                location: @escaping (Date) -> CaptureLocation?,
                now: @escaping () -> Date = Date.init, target: SaveTarget = .newCapture) {
        self.store = store; self.location = location; self.target = target; self.now = now
        session = RecordingSession(intake: intake, recorder: recorder, permission: permission, now: now)
    }

    /// Asks for permission if needed, then starts recording. Ignored unless idle, denied, or failed
    /// with nothing recorded.
    public func start() async {
        guard !isSaving, !didSave, saveFailure == nil else { return }
        await session.start()
    }

    /// True once a recording is on disk awaiting `save()` or `discard()`.
    public var hasPendingRecording: Bool { isSaving || session.pending != nil }

    public func stop() { session.stop() }

    /// A call, Siri or similar took the microphone: keep what was recorded and offer to save it.
    public func interruptionBegan() { session.interruptionBegan() }

    /// Commits the recording: a new voice capture, or an audio comment on `target`'s capture. On failure the
    /// file stays and `save()` can be tried again.
    public func save() async {
        guard !isSaving, !didSave, let taken = session.takePending() else { return }
        isSaving = true
        saveFailure = nil
        do {
            switch target {
            case .newCapture:
                let draft = CaptureDraft(
                    captureID: UUID(), startedAt: taken.startedAt, timeZone: taken.timeZone, method: .voiceRecording,
                    attachments: [AttachmentSource(body: .file(taken.url), originalFilename: nil,
                                                   uti: "com.apple.m4a-audio", mimeType: "audio/mp4",
                                                   representationSource: "recording")],
                    location: location(taken.startedAt))
                _ = try await store.capture(draft)
            case .comment(let captureID):
                _ = try await store.addComment(
                    captureID: captureID,
                    .audio(fileURL: taken.url, uti: "com.apple.m4a-audio", mimeType: "audio/mp4",
                           durationSeconds: taken.duration),
                    now: now(), timeZone: taken.timeZone)
            }
            try? FileManager.default.removeItem(at: taken.url)
            didSave = true
        } catch {
            session.restorePending(taken)
            switch target {
            case .newCapture: saveFailure = Self.saveFailedMessage
            case .comment: saveFailure = CommentErrorCopy.message(for: error, fallback: Self.commentSaveFailedMessage)
            }
        }
        isSaving = false
    }

    /// Throws the recording away (stopping it first if it is still running). Ignored while saving.
    public func discard() {
        if isSaving { return }   // the commit is in flight; it decides the outcome
        session.discard()
        didSave = false
        saveFailure = nil
    }

    /// "0:07", "12:05", "1:02:03".
    nonisolated public static func elapsedText(_ s: TimeInterval) -> String {
        let total = s.isFinite ? max(0, Int(s)) : 0
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        return h > 0 ? "\(h):\(two(m)):\(two(sec))" : "\(m):\(two(sec))"
    }

    nonisolated private static func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
}
