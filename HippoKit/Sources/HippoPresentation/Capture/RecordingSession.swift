import Foundation
import Observation
import ShareIntake

/// The recording state machine: records into `IntakeDirectory.recordingURL(id:)` and leaves the file
/// on disk for the caller to commit (`takePending()`) or throw away (`discard()`).
@MainActor @Observable
public final class RecordingSession {
    public enum State: Equatable {
        case idle, denied
        case recording(startedAt: Date)
        case stopped(duration: TimeInterval, interrupted: Bool)
        case failed(String)
    }

    public static let startFailedMessage = "Hippo couldn't start recording. Try again."

    public private(set) var state: State = .idle

    private let intake: IntakeDirectory
    private let recorder: AudioRecording
    private let permission: () async -> MicPermission
    private let now: () -> Date

    private var current: (url: URL, startedAt: Date, timeZone: TimeZone)?
    private var held: (url: URL, startedAt: Date, timeZone: TimeZone, duration: TimeInterval)?

    /// The recording on disk after stop/interruption, until `discard()` or `takePending()`.
    public var pending: (url: URL, duration: TimeInterval)? {
        held.map { ($0.url, $0.duration) }
    }

    public init(intake: IntakeDirectory, recorder: AudioRecording,
                permission: @escaping () async -> MicPermission, now: @escaping () -> Date = Date.init) {
        self.intake = intake; self.recorder = recorder
        self.permission = permission; self.now = now
    }

    /// Asks for permission if needed, then starts recording. Ignored unless idle, denied, or failed
    /// with nothing recorded.
    public func start() async {
        switch state {
        case .idle, .denied: break
        case .failed where held == nil: break
        default: return
        }
        // `.undetermined` after the request is treated as `.denied`.
        guard await permission() == .granted else { state = .denied; return }
        // Another call may have started while the permission prompt was up.
        switch state {
        case .idle, .denied, .failed: break
        default: return
        }
        let url = intake.recordingURL(id: UUID())
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try recorder.start(writingTo: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            state = .failed(Self.startFailedMessage)
            return
        }
        let startedAt = now()
        current = (url, startedAt, .current)
        state = .recording(startedAt: startedAt)
    }

    public func stop() { finish(interrupted: false) }

    /// A call, Siri or similar took the microphone: keep what was recorded.
    public func interruptionBegan() { finish(interrupted: true) }

    private func finish(interrupted: Bool) {
        guard case .recording = state, let current else { return }
        // Read before stop(), which can reset it. After a system stop the recorder may report 0, so fall
        // back to the wall-clock time since the start.
        var duration = max(0, recorder.currentTime)
        if duration == 0 { duration = max(0, now().timeIntervalSince(current.startedAt)) }
        recorder.stop()
        self.current = nil
        held = (current.url, current.startedAt, current.timeZone, duration)
        state = .stopped(duration: duration, interrupted: interrupted)
    }

    /// Stops if recording, deletes the file, and returns to idle.
    public func discard() {
        if case .recording = state { recorder.stop() }
        if let url = current?.url ?? held?.url { try? FileManager.default.removeItem(at: url) }
        current = nil
        held = nil
        state = .idle
    }

    /// Hands the file to the caller (who commits it) and returns to idle without deleting it.
    public func takePending() -> (url: URL, duration: TimeInterval, startedAt: Date, timeZone: TimeZone)? {
        guard let h = held else { return nil }
        held = nil
        state = .idle
        return (h.url, h.duration, h.startedAt, h.timeZone)
    }

    /// Puts a taken recording back (a commit failed).
    public func restorePending(_ taken: (url: URL, duration: TimeInterval, startedAt: Date, timeZone: TimeZone)) {
        held = (taken.url, taken.startedAt, taken.timeZone, taken.duration)
        state = .stopped(duration: taken.duration, interrupted: false)
    }
}
