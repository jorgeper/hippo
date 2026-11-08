import AVFoundation
import HippoPresentation

/// `AudioRecording` over AVAudioRecorder, with the play-and-record session and interruption handling.
@MainActor
final class SystemAudioRecorder: NSObject, AudioRecording, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    nonisolated(unsafe) private var observer: NSObjectProtocol?
    /// Called on the main actor when the system takes the session or the recorder fails mid-recording.
    var onInterruption: (() -> Void)?

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
            r.delegate = self
            guard r.record() else { throw CocoaError(.fileWriteUnknown) }
            recorder = r
        } catch {
            deactivate()
            throw error
        }
        // Our own `deactivate()` posts this too, with source `.app`; only the system's counts.
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.didBecomeInactiveNotification, object: nil, queue: .main) { [weak self] note in
            guard let context = note.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext,
                  context.source == .system else { return }
            MainActor.assumeIsolated { self?.onInterruption?() }
        }
    }

    func stop() {
        removeObserver()   // before deactivating, so our own deactivation is never seen as an interruption
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
        deactivate()
    }

    /// Lets other apps' audio resume.
    func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func removeObserver() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    // MARK: AVAudioRecorderDelegate

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard !flag else { return }
        Task { @MainActor [weak self] in self?.onInterruption?() }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in self?.onInterruption?() }
    }
}
