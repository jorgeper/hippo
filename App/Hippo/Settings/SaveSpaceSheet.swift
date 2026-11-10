import SwiftUI
import SyncEngine
import HippoPresentation

/// "Save space" (design §4.4): choose how old and how large, see what it frees, then trim.
struct SaveSpaceSheet: View {
    @State private var model: SpaceSaveModel
    @State private var runTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    private let coordinator: SyncCoordinator?

    init(store: HippoStore, registry: ProviderRegistry, coordinator: SyncCoordinator?) {
        self.coordinator = coordinator
        _model = State(initialValue: SpaceSaveModel(
            store: store, adapterFor: { try registry.adapter(for: $0) }, isOnline: { EnrichmentScheduling.isOnline }))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Older than", selection: $model.options.olderThan) {
                        ForEach(SpaceSaveOptions.ageSteps, id: \.self) { Text(SpaceSaveModel.ageLabel($0)).tag($0) }
                    }
                    Picker("Larger than", selection: $model.options.largerThan) {
                        ForEach(SpaceSaveOptions.sizeSteps, id: \.self) { Text(SpaceSaveModel.sizeLabel($0)).tag($0) }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.estimateText)
                        Text(model.note)
                    }
                }
                .pickerStyle(.menu)
                .disabled(model.isRunning)
                Section {
                    Button("Save space") { start() }
                        .disabled(!model.canRun)
                        .accessibilityIdentifier("save-space-run")
                    if let progress = model.progress {
                        Text("Trimming \(progress.done) of \(progress.total)…").foregroundStyle(.secondary)
                    }
                    if let text = model.resultText { Text(text) }
                } footer: {
                    if let footer = model.offlineFooter { Text(footer) }
                }
            }
            .navigationTitle("Save space")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .task { await model.refreshEstimate() }
        .onChange(of: model.options) { _, _ in Task { await model.refreshEstimate() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { runTask?.cancel() }
        }
        .onDisappear { runTask?.cancel() }
    }

    private func start() {
        guard runTask == nil else { return }
        runTask = TaskBox.runInBackground(name: "save-space", coordinator: coordinator, finished: {
            runTask = nil
            NotificationCenter.default.post(name: SyncCoordinator.passFinished, object: nil)
        }) {
            await model.run()
        }
    }
}
