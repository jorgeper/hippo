import SwiftUI
import ShareIntake
import HippoPresentation

/// A share handed off by the extension to record a voice comment: the capture sheet with the recording
/// started at once. There is no discard; "Save without comment" saves it without the recording.
struct PendingShareView: View {
    let environment: AppEnvironment
    let pending: PendingCapture
    /// Closes this sheet and presents the next pending share, if any. Safe to call more than once.
    let done: () -> Void

    @State private var model: ShareSessionModel
    @State private var session: RecordingSession
    @State private var recorder: SystemAudioRecorder

    init(environment: AppEnvironment, pending: PendingCapture, done: @escaping () -> Void) {
        self.environment = environment
        self.pending = pending
        self.done = done
        let recorder = SystemAudioRecorder()
        let session = RecordingSession(intake: environment.intake, recorder: recorder,
                                       permission: { await SystemAudioRecorder.requestMicPermission() })
        recorder.onInterruption = { [weak session] in session?.interruptionBegan() }
        // The pending draft already carries its location; the model never asks.
        let model = ShareSessionModel(
            store: environment.store, intake: environment.intake, prepared: PreparedCapture(pending),
            isPendingShare: true, destinationName: (try? environment.store.destinations.active())?.displayName,
            voice: session, location: { _ in nil })
        _model = State(initialValue: model)
        _session = State(initialValue: session)
        _recorder = State(initialValue: recorder)
    }

    var body: some View {
        CaptureSheetView(model: model, voice: .record(session),
                         save: { accept in await save(acceptPartial: accept) },
                         cancel: {},
                         finish: done)
            .overlay(alignment: .topLeading) {
                // A commit that can't be retried leaves the sheet with no enabled button: offer Discard.
                if case .failed(_, canSave: false) = model.state {
                    Button("Discard", role: .destructive) {
                        session.discard()
                        environment.intake.discard(captureID: pending.draft.captureID)
                        done()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                    .background(Color(.systemBackground))
                }
            }
            .interactiveDismissDisabled()
            // The design starts the voice comment at once for a handed-off share.
            .task { await session.start() }
            .onDisappear {
                // Covers anything that closes the sheet with a recording unsaved; the pending draft stays.
                if model.state != .saved { session.discard() }
                recorder.deactivate()
            }
            .onChange(of: model.state) { _, state in
                guard state == .saved else { return }
                recorder.deactivate()
                if let coordinator = environment.coordinator {
                    Task { await SyncScheduling.runPass(coordinator, name: "pending-sync", trigger: "after_save") }
                }
                let environment = environment
                Task { await EnrichmentScheduling.run(environment, reason: "pending_share") }
                done()
            }
    }

    private func save(acceptPartial: Bool) async {
        let model = model
        await BackgroundActivity.run(name: "pending-share-save") { @MainActor in await model.save(acceptPartial: acceptPartial) }
    }
}
