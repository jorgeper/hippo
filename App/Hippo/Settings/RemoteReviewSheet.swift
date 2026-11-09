import SwiftUI
import SyncEngine
import HippoPresentation

/// What to do with captures that look different in the destination (design §4.6).
struct RemoteReviewSheet: View {
    @State private var model: RemoteReviewModel
    @State private var busy = false
    @Environment(\.dismiss) private var dismiss
    private let coordinator: SyncCoordinator?

    init(store: HippoStore, coordinator: SyncCoordinator?) {
        self.coordinator = coordinator
        _model = State(initialValue: RemoteReviewModel(store: store, sync: {
            _ = await coordinator?.syncNow(trigger: "manual")
        }))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(model.summaryLine)
                    if model.trimmedCount > 0 { Text(model.trimmedLine).foregroundStyle(.secondary) }
                } header: {
                    Text(model.title).textCase(nil).font(.headline).foregroundStyle(.primary)
                } footer: {
                    Text(model.footer)
                }
                Section {
                    Button(RemoteReviewModel.removeTitle, role: .destructive) { run("review-remove") { await model.removeFromPhone() } }
                    Button(model.keepTitle) { run("review-keep") { await model.keepAndUploadAgain() } }
                    Button(RemoteReviewModel.laterTitle) {
                        model.decideLater()
                        dismiss()
                    }
                }
                .disabled(busy || !model.isPending)
            }
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .task { await model.load() }
        .alert("Something went wrong", isPresented: $model.resolveFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Hippo couldn't finish that. Your captures are safe on this iPhone.")
        }
    }

    private func run(_ name: String, _ action: @escaping @MainActor () async -> Void) {
        guard !busy else { return }
        busy = true
        let coordinator = coordinator
        Task {
            await BackgroundActivity.run(name: name, onExpire: coordinator.map(SyncScheduling.stopper)) { await action() }
            busy = false
            NotificationCenter.default.post(name: SyncCoordinator.passFinished, object: nil)
            if !model.resolveFailed { dismiss() }
        }
    }
}
