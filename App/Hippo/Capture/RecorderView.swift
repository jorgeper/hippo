import SwiftUI
import UIKit
import HippoPresentation

struct RecorderView: View {
    let environment: AppEnvironment
    let location: LocationService

    @Environment(\.dismiss) private var dismiss
    @State private var model: RecorderModel
    @State private var recorder: SystemAudioRecorder
    @State private var confirmingDiscard = false

    init(environment: AppEnvironment, location: LocationService) {
        self.environment = environment
        self.location = location
        let recorder = SystemAudioRecorder()
        let model = RecorderModel(
            store: environment.store, intake: environment.intake, recorder: recorder,
            permission: { await SystemAudioRecorder.requestMicPermission() },
            location: { [location] in location.location(startedAt: $0) })
        recorder.onInterruption = { [weak model] in model?.interruptionBegan() }
        _model = State(initialValue: model)
        _recorder = State(initialValue: recorder)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                status
                Spacer()
                controls
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .navigationTitle("Record")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        // Recording, stopped and failed-with-a-file all hold audio the user would lose.
                        if isRecording || model.hasPendingRecording { confirmingDiscard = true } else { model.discard(); dismiss() }
                    }
                    .disabled(model.state == .saving)
                }
            }
        }
        .interactiveDismissDisabled(isBusy)
        .confirmationDialog("Discard recording?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { model.discard(); dismiss() }
            Button("Keep recording", role: .cancel) {}
        }
        .onAppear {
            location.beginSessionFix()
        }
        .onDisappear {
            // Covers Cancel, swipe-away and anything else that leaves a recording unfinished.
            if model.state != .saved { model.discard() }
            recorder.deactivate()
        }
        .onChange(of: model.state) { _, state in
            if state == .saved {
                recorder.deactivate()
                dismiss()
                if let coordinator = environment.coordinator {
                    Task { await SyncScheduling.runPass(coordinator, name: "record-sync") }
                }
            }
        }
    }

    private var isRecording: Bool {
        if case .recording = model.state { true } else { false }
    }

    private var isBusy: Bool {
        switch model.state {
        case .recording, .stopped, .saving, .failed: true
        default: false
        }
    }

    @ViewBuilder private var status: some View {
        switch model.state {
        case .idle:
            Text(RecorderModel.elapsedText(0)).timeText()
        case .recording(let startedAt):
            SwiftUI.TimelineView(.periodic(from: startedAt, by: 0.5)) { context in
                Text(RecorderModel.elapsedText(context.date.timeIntervalSince(startedAt))).timeText()
            }
        case .stopped(let duration, let interrupted):
            VStack(spacing: 8) {
                Text(RecorderModel.elapsedText(duration)).timeText()
                if interrupted {
                    Text("Recording stopped by an interruption. Save what was recorded?")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
            }
        case .saving, .saved:
            ProgressView("Saving")
        case .denied:
            VStack(spacing: 12) {
                Text("Hippo needs the microphone to record voice notes.")
                    .multilineTextAlignment(.center)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(.bordered)
            }
        case .failed(let message):
            Text(message).multilineTextAlignment(.center).foregroundStyle(.red)
        }
    }

    @ViewBuilder private var controls: some View {
        switch model.state {
        case .idle, .denied:
            recordButton(recording: false)
        case .recording:
            recordButton(recording: true)
        case .stopped, .failed:
            if model.hasPendingRecording {
                HStack(spacing: 16) {
                    Button("Discard", role: .destructive) { model.discard(); dismiss() }
                        .buttonStyle(.bordered)
                    Button("Save") { Task { await save() } }
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
            } else {
                recordButton(recording: false)
            }
        case .saving, .saved:
            EmptyView()
        }
    }

    private func save() async {
        await BackgroundActivity.run(name: "recording-save") { @MainActor in await model.save() }
    }

    private func recordButton(recording: Bool) -> some View {
        Button {
            if recording { model.stop() } else { Task { await model.start() } }
        } label: {
            ZStack {
                Circle().strokeBorder(.secondary, lineWidth: 4).frame(width: 88, height: 88)
                if recording {
                    RoundedRectangle(cornerRadius: 8).fill(.red).frame(width: 36, height: 36)
                } else {
                    Circle().fill(.red).frame(width: 72, height: 72)
                }
            }
        }
        .accessibilityLabel(recording ? "Stop" : "Record")
    }
}

private extension Text {
    func timeText() -> some View {
        font(.system(.largeTitle, design: .rounded, weight: .light)).monospacedDigit()
    }
}
