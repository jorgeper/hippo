import AVFoundation
import HippoPresentation

/// `AudioRecording` over AVAudioRecorder, with the play-and-record session and interruption handling.
@MainActor
final class SystemAudioRecorder: AudioRecording {
    private var recorder: AVAudioRecorder?
    nonisolated(unsafe) private var observer: NSObjectProtocol?
    /// Set by the owner; called on the main actor when an interruption begins.
    var onInterruption: (() -> Void)?

    /// `AVAudioSession.InterruptionType.began`; the enum is deprecated in iOS 27 but the notification is not.
    nonisolated private static let interruptionBegan: UInt = 1

    var currentTime: TimeInterval { recorder?.currentTime ?? 0 }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    static func micPermission() -> MicPermission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        default: .undetermined
        }
    }

    static func requestMicPermission() async -> MicPermission {
        if micPermission() == .undetermined {
            _ = await AVAudioApplication.requestRecordPermission()
        }
        return micPermission()
    }

    func start(writingTo url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default)
        try session.setActive(true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            guard r.record() else { throw CocoaError(.fileWriteUnknown) }
            recorder = r
        } catch {
            deactivate()
            throw error
        }
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw == Self.interruptionBegan else { return }
            MainActor.assumeIsolated { self?.onInterruption?() }
        }
    }

    func stop() {
        recorder?.stop()
        recorder = nil
        removeObserver()
        deactivate()
    }

    /// Lets other apps' audio resume. Also called after discard or save via `stop()`.
    func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func removeObserver() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}
