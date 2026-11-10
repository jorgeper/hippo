import SwiftUI
import UIKit
import HippoPresentation

/// The capture sheet's voice comment block: the 56 pt record `CaptureButton` with a caption.
/// States: idle, recording, stopped (or interrupted), denied and failed.
struct VoiceCommentControl: View {
    let session: RecordingSession
    let disabled: Bool
    @State private var confirmingReplace = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            CaptureButton(kind: .record(recording: isRecording), identifier: "voice-comment-button") {
                switch session.state {
                case .recording: session.stop()
                case .stopped: confirmingReplace = true
                default: Task { await session.start() }
                }
            }
            status
            Spacer(minLength: 0)
            if case .stopped = session.state {
                Button(role: .destructive) { session.discard() } label: {
                    Label("Discard", systemImage: "trash").labelStyle(.iconOnly)
                }
            }
        }
        .confirmationDialog("Replace the recording?", isPresented: $confirmingReplace, titleVisibility: .visible) {
            Button("Replace", role: .destructive) {
                session.discard()
                Task { await session.start() }
            }
            Button("Keep", role: .cancel) {}
        }
        .disabled(disabled)
    }

    private var isRecording: Bool {
        if case .recording = session.state { true } else { false }
    }

    @ViewBuilder private var status: some View {
        switch session.state {
        case .idle:
            Text("Record a comment").foregroundStyle(.secondary)
        case .recording(let startedAt):
            SwiftUI.TimelineView(.periodic(from: startedAt, by: 0.5)) { context in
                HStack(spacing: 8) {
                    Text("Recording…")
                    Text(RecorderModel.elapsedText(context.date.timeIntervalSince(startedAt))).monospacedDigit()
                }
            }
        case .stopped(let duration, let interrupted):
            VStack(alignment: .leading, spacing: 4) {
                Text("Voice comment · \(RecorderModel.elapsedText(duration))").monospacedDigit()
                if interrupted {
                    Text("Recording stopped by an interruption. Save what was recorded?")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        case .denied:
            VStack(alignment: .leading, spacing: 4) {
                Text("Hippo needs the microphone to record a comment.")
                #if !HIPPO_SHARE_EXTENSION
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                #endif
            }
        case .failed(let message):
            Text(message).foregroundStyle(.red)
        }
    }
}
