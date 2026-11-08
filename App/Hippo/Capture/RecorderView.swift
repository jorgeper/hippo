import SwiftUI
import UIKit
import HippoPresentation

struct RecorderView: View {
    let environment: AppEnvironment
    let location: LocationService

    @Environment(\.dismiss) private var dismiss
    @State private var model: RecorderModel
    private let recorder: SystemAudioRecorder

    init(environment: AppEnvironment, location: LocationService) {
        self.environment = environment
        self.location = location
        let recorder = SystemAudioRecorder()
        self.recorder = recorder
        let model = RecorderModel(
            store: environment.store, intake: environment.intake, recorder: recorder,
            permission: { await SystemAudioRecorder.requestMicPermission() },
            location: { [location] in location.location(startedAt: $0) })
        recorder.onInterruption = { [weak model] in model?.interruptionBegan() }
        _model = State(initialValue: model)
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
                    Button("Cancel") { model.discard(); dismiss() }.disabled(model.state == .saving)
                }
            }
        }
        .interactiveDismissDisabled(isBusy)
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
                    Task { _ = await BackgroundActivity.run(name: "record-sync") { await coordinator.syncNow() } }
                }
            }
        }
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
            if hasPendingRecording {
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

    /// A failed start has nothing recorded; a failed save keeps the file and offers Save again.
    private var hasPendingRecording: Bool {
        if case .failed(let m) = model.state { return m == RecorderModel.saveFailedMessage }
        return true
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
        font(.system(size: 56, weight: .light, design: .rounded)).monospacedDigit()
    }
}
