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

/// State machine behind the voice recorder screen.
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
    static let startFailedMessage = "Hippo couldn't start recording. Try again."

    public private(set) var state: State = .idle

    private let store: HippoStore
    private let intake: IntakeDirectory
    private let recorder: AudioRecording
    private let permission: () async -> MicPermission
    private let location: (Date) -> CaptureLocation?
    private let now: () -> Date

    /// The recording on disk that `save()`/`discard()` act on.
    private var pending: Pending?
    private struct Pending {
        var id: UUID
        var url: URL
        var startedAt: Date
        var timeZone: TimeZone
        var duration: TimeInterval
        var interrupted: Bool
    }
    private var current: (id: UUID, url: URL, startedAt: Date, timeZone: TimeZone)?

    public init(store: HippoStore, intake: IntakeDirectory, recorder: AudioRecording,
                permission: @escaping () async -> MicPermission,
                location: @escaping (Date) -> CaptureLocation?,
                now: @escaping () -> Date = Date.init) {
        self.store = store; self.intake = intake; self.recorder = recorder
        self.permission = permission; self.location = location; self.now = now
    }

    /// Asks for permission if needed, then starts recording. Ignored unless idle, denied, or failed
    /// with nothing recorded.
    public func start() async {
        switch state {
        case .idle, .denied: break
        case .failed where pending == nil: break
        default: return
        }
        // `.undetermined` after the request is treated as `.denied`.
        guard await permission() == .granted else { state = .denied; return }
        // Another call may have started while the permission prompt was up.
        switch state {
        case .idle, .denied, .failed: break
        default: return
        }
        let id = UUID()
        let url = intake.recordingURL(id: id)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try recorder.start(writingTo: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            state = .failed(Self.startFailedMessage)
            return
        }
        let startedAt = now()
        current = (id, url, startedAt, .current)
        state = .recording(startedAt: startedAt)
    }

    /// True once a recording is on disk awaiting `save()` or `discard()`.
    public var hasPendingRecording: Bool { pending != nil }

    public func stop() { finish(interrupted: false) }

    /// A call, Siri or similar took the microphone: keep what was recorded and offer to save it.
    public func interruptionBegan() { finish(interrupted: true) }

    private func finish(interrupted: Bool) {
        guard case .recording = state, let current else { return }
        // Read before stop(), which can reset it. After a system stop the recorder may report 0, so fall
        // back to the wall-clock time since the start.
        var duration = max(0, recorder.currentTime)
        if duration == 0 { duration = max(0, now().timeIntervalSince(current.startedAt)) }
        recorder.stop()
        self.current = nil
        pending = Pending(id: current.id, url: current.url, startedAt: current.startedAt,
                          timeZone: current.timeZone,
                          duration: duration, interrupted: interrupted)
        state = .stopped(duration: duration, interrupted: interrupted)
    }

    /// Commits the recording. On failure the file stays and `save()` can be tried again.
    public func save() async {
        guard let p = pending else { return }
        switch state {
        case .stopped, .failed: break
        default: return
        }
        state = .saving
        let draft = CaptureDraft(
            captureID: p.id, startedAt: p.startedAt, timeZone: p.timeZone, method: .voiceRecording,
            attachments: [AttachmentSource(body: .file(p.url), originalFilename: nil,
                                           uti: "com.apple.m4a-audio", mimeType: "audio/mp4",
                                           representationSource: "recording")],
            location: location(p.startedAt))
        do {
            _ = try await store.capture(draft)
            try? FileManager.default.removeItem(at: p.url)
            pending = nil
            state = .saved
        } catch {
            state = .failed(Self.saveFailedMessage)
        }
    }

    /// Throws the recording away (stopping it first if it is still running). Ignored while saving.
    public func discard() {
        if case .saving = state { return }   // the commit is in flight; it decides the outcome
        if case .recording = state { recorder.stop() }
        if let url = current?.url ?? pending?.url { try? FileManager.default.removeItem(at: url) }
        current = nil
        pending = nil
        state = .idle
    }

    /// "0:07", "12:05", "1:02:03".
    nonisolated public static func elapsedText(_ s: TimeInterval) -> String {
        let total = s.isFinite ? max(0, Int(s)) : 0
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        return h > 0 ? "\(h):\(two(m)):\(two(sec))" : "\(m):\(two(sec))"
    }

    nonisolated private static func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
}
