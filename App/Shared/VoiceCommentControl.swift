import SwiftUI
import UIKit
import HippoPresentation

/// The capture sheet's voice comment block: a 56 pt version of the recorder's Record button with a
/// caption. In `.handoff` mode a tap hands the draft to the app; in `.record` mode it records in place.
struct VoiceCommentControl: View {
    let voice: CaptureSheetView.Voice
    let disabled: Bool

    var body: some View {
        Group {
            switch voice {
            case .handoff(let handOff):
                HStack(spacing: 12) {
                    MicButton(recording: false, action: handOff)
                    Text("Record a comment").foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            case .record(let session):
                RecordingBlock(session: session)
            }
        }
        .disabled(disabled)
    }
}

/// The in-place states: idle, recording, stopped (or interrupted), denied and failed.
private struct RecordingBlock: View {
    let session: RecordingSession
    @State private var confirmingReplace = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            MicButton(recording: isRecording) {
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

/// The recorder's Record button at 56 pt: a red disc in a secondary ring, a red square while recording.
private struct MicButton: View {
    let recording: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(.secondary, lineWidth: 3).frame(width: 56, height: 56)
                if recording {
                    RoundedRectangle(cornerRadius: 5).fill(.red).frame(width: 23, height: 23)
                } else {
                    Circle().fill(.red).frame(width: 46, height: 46)
                }
            }
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(recording ? "Stop" : "Record a comment")
        .accessibilityIdentifier("voice-comment-button")
    }
}
