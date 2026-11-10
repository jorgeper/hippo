import SwiftUI
import UIKit
import AVFoundation
import CaptureCore
import LocalRepository
import HippoPresentation

/// The Camera button's full-screen flow: camera permission, the system camera, then the capture sheet
/// for the shot (comment and voice comment). After the save, the file goes to Photos when "Also save to
/// Photos" is on, then sync and enrichment run.
struct CameraCaptureView: View {
    let environment: AppEnvironment
    let location: LocationService

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var phase: Phase = .checking
    @State private var confirmingDiscard = false

    private enum Phase {
        case checking
        case picking
        /// Writing the shot into the intake directory.
        case staging
        case denied
        /// Staging the shot failed; nothing was saved.
        case stageFailed(isVideo: Bool)
        case sheet(Staged)
    }

    /// The staged shot and the voice comment's recorder, for the capture sheet.
    private struct Staged {
        let model: ShareSessionModel
        let session: RecordingSession
        let recorder: SystemAudioRecorder
        let isVideo: Bool
        /// The package's capture ID (lowercased UUID).
        let captureID: String
    }

    var body: some View {
        content
            .onAppear { location.beginSessionFix() }
            .task { await checkPermission() }
            .onChange(of: sheetState) { _, state in
                if state == .saved, case .sheet(let staged) = phase { saved(staged) }
            }
            .onDisappear {
                // Covers anything that closes the cover with a shot not yet saved.
                guard case .sheet(let staged) = phase else { return }
                if staged.model.state != .saved && staged.model.state != .saving { staged.model.cancel() }
                staged.recorder.deactivate()
            }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .checking:
            Color.black.ignoresSafeArea()
        case .picking:
            CameraPicker(onResult: { result in Task { await stage(result) } },
                         onPhotoFailed: { if case .picking = phase { phase = .stageFailed(isVideo: false) } },
                         onCancel: { dismiss() })
                .ignoresSafeArea()
        case .staging:
            ZStack {
                Color.black.ignoresSafeArea()
                ProgressView().tint(.white)
            }
        case .denied:
            Color.black.ignoresSafeArea()
                .alert("Hippo needs camera access to take pictures. Turn it on in Settings.", isPresented: closesOnDismiss) {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    Button("Cancel", role: .cancel) {}
                }
        case .stageFailed(let isVideo):
            Color.black.ignoresSafeArea()
                .alert(isVideo ? "Hippo couldn't save this video." : "Hippo couldn't save this photo.",
                       isPresented: closesOnDismiss) {
                    Button("OK", role: .cancel) {}
                }
        case .sheet(let staged):
            CaptureSheetView(model: staged.model, voice: staged.session,
                             save: { accept in await save(staged.model, acceptPartial: accept) },
                             cancel: { confirmingDiscard = true },
                             finish: { dismiss() })
                .confirmationDialog(staged.isVideo ? "Discard this video?" : "Discard this photo?",
                                    isPresented: $confirmingDiscard, titleVisibility: .visible) {
                    Button("Discard", role: .destructive) { staged.model.cancel(); dismiss() }
                    Button("Keep editing", role: .cancel) {}
                }
        }
    }

    /// An alert that is up until any of its buttons is tapped, which then closes the cover.
    private var closesOnDismiss: Binding<Bool> {
        Binding(get: { true }, set: { if !$0 { dismiss() } })
    }

    private var sheetState: ShareSessionModel.State? {
        if case .sheet(let staged) = phase { staged.model.state } else { nil }
    }

    private func checkPermission() async {
        guard case .checking = phase else { return }
        // The simulator has no camera; the picker would throw.
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { dismiss(); return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            phase = .picking
        case .notDetermined:
            phase = await AVCaptureDevice.requestAccess(for: .video) ? .picking : .denied
        default:
            phase = .denied
        }
    }

    private func stage(_ result: CameraResult) async {
        guard case .picking = phase else { return }
        phase = .staging
        let isVideo = if case .video = result { true } else { false }
        // `captured_at` is the end of the shot.
        let startedAt = Date()
        let captureID = UUID()
        let intake = environment.intake
        let fix = location.location(startedAt: startedAt)
        let prepared: PreparedCapture
        do {
            // Encoding a full-size still takes a moment: keep it off the main actor.
            prepared = try await Task.detached(priority: .userInitiated) {
                try CameraCapture.stage(result, intake: intake, captureID: captureID, startedAt: startedAt,
                                        timeZone: .current, location: fix)
            }.value
        } catch {
            intake.discard(captureID: captureID)
            phase = .stageFailed(isVideo: isVideo)
            return
        }
        let recorder = SystemAudioRecorder()
        let session = RecordingSession(intake: environment.intake, recorder: recorder,
                                       permission: { await SystemAudioRecorder.requestMicPermission() })
        recorder.onInterruption = { [weak session] in session?.interruptionBegan() }
        let model = ShareSessionModel(
            store: environment.store, intake: environment.intake, prepared: prepared,
            destinationName: (try? environment.store.destinations.active())?.displayName, voice: session,
            location: { [location] in location.location(startedAt: $0) })
        phase = .sheet(Staged(model: model, session: session, recorder: recorder, isVideo: isVideo,
                              captureID: captureID.uuidString.lowercased()))
    }

    private func save(_ model: ShareSessionModel, acceptPartial: Bool) async {
        await BackgroundActivity.run(name: "camera-save") { @MainActor in await model.save(acceptPartial: acceptPartial) }
    }

    /// The sheet closes itself a second after "Saved"; the follow-up work runs on its own.
    private func saved(_ staged: Staged) {
        staged.recorder.deactivate()
        let environment = environment
        let captureID = staged.captureID, isVideo = staged.isVideo
        Task {
            if LocationService.settings.cameraSavesToPhotos {
                await Self.saveToPhotos(environment, captureID: captureID, isVideo: isVideo)
            }
            if let coordinator = environment.coordinator {
                await SyncScheduling.runPass(coordinator, name: "camera-sync", trigger: "after_save")
            }
        }
        Task { await EnrichmentScheduling.run(environment, reason: "camera") }
    }

    /// Adds the committed package's camera file (the intake copy is gone by now) to Photos.
    private nonisolated static func saveToPhotos(_ environment: AppEnvironment, captureID: String, isVideo: Bool) async {
        let store = environment.store
        guard let directory = try? store.index.relativeDirectory(captureID: captureID),
              let metadata = try? store.index.metadata(captureID: captureID, layout: store.layout),
              let attachment = metadata.attachments.first(where: { $0.representationSource == "camera" })
        else {
            store.log.append(LogEvent(event: .cameraLibrarySave, captureID: captureID, outcome: .failed, code: "lookup_failed"))
            return
        }
        let url = store.layout.packageURL(relativeDirectory: directory).appendingPathComponent(attachment.relativePath)
        await PhotoLibrarySaver.save(fileURL: url, isVideo: isVideo, captureID: captureID, log: store.log)
    }
}
