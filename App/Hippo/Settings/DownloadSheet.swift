import SwiftUI
import SyncEngine
import HippoPresentation

/// "Download from <name>" (design §4.5): choose how far back, see what it brings in, then download.
struct DownloadSheet: View {
    @State private var model: DownloadModel
    @State private var runTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    private let coordinator: SyncCoordinator?

    init(store: HippoStore, registry: ProviderRegistry, coordinator: SyncCoordinator?) {
        self.coordinator = coordinator
        _model = State(initialValue: DownloadModel(
            store: store, adapterFor: { try registry.adapter(for: $0) }, isOnline: { EnrichmentScheduling.isOnline }))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("From the last", selection: $model.window.seconds) {
                        ForEach(DownloadWindow.steps, id: \.self) {
                            Text(DownloadModel.windowLabel(DownloadWindow(seconds: $0))).tag($0)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(model.isRunning)
                    if model.estimating {
                        ProgressView()
                    } else if model.estimateFailed {
                        Text("Couldn't check \(model.destinationName)").foregroundStyle(.secondary)
                    } else if let text = model.estimateText {
                        Text(text)
                    }
                    if let skip = model.skipText {
                        Toggle(isOn: $model.includeLocallyDeleted) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(skip).font(.footnote).foregroundStyle(.secondary)
                                Text("Include them")
                            }
                        }
                        .disabled(model.isRunning)
                    }
                }
                Section {
                    Button("Download") { start() }
                        .disabled(!model.canRun)
                        .accessibilityIdentifier("download-run")
                    if let progress = model.progress {
                        Text("Downloading \(progress.done) of \(progress.total)…").foregroundStyle(.secondary)
                    }
                    if let text = model.resultText { Text(text) }
                }
            }
            .navigationTitle("Download")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .task { await model.refreshEstimate() }
        .onChange(of: model.window) { _, _ in Task { await model.refreshEstimate() } }
        .onChange(of: model.includeLocallyDeleted) { _, _ in Task { await model.refreshEstimate() } }
        .onChange(of: scenePhase) { _, phase in
            // Resumable by design: what was downloaded stays, and the next run picks up the rest.
            if phase == .background { runTask?.cancel() }
        }
        .onDisappear { runTask?.cancel() }
    }

    private func start() {
        guard runTask == nil else { return }
        runTask = TaskBox.runInBackground(name: "download", coordinator: coordinator, finished: {
            runTask = nil
        }) {
            await model.run()
        }
    }
}
