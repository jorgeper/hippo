import SwiftUI
import HippoPresentation
import Enrichment
import SyncEngine

/// One capture's log lines, oldest first. Developer mode only.
struct ActivityView: View {
    let captureID: String
    @State private var model: ActivityModel
    @State private var taskReload: Task<Void, Never>?

    init(environment: AppEnvironment, captureID: String, capturedAt: Date) {
        self.captureID = captureID
        _model = State(initialValue: ActivityModel(store: environment.store, captureID: captureID, capturedAt: capturedAt))
    }

    var body: some View {
        List {
            Section {
                if model.lines.isEmpty {
                    Text("Nothing logged yet").foregroundStyle(.secondary)
                } else {
                    ForEach(model.lines) { LogLineRow(line: $0) }
                }
            } footer: {
                if model.mayBePruned { Text("Earlier events may have been removed (Hippo keeps 30 days).") }
            }
        }
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                CopyLogButton { model.copyText(appVersion: hippoAppVersion()) }
            }
        }
        .task { await model.load() }
        // Reload only for this capture's tasks, at most once per 500 ms (a backfill finishes many a second).
        .onReceive(NotificationCenter.default.publisher(for: EnrichmentRunner.taskFinished)) { note in
            guard note.userInfo?[EnrichmentRunner.captureIDKey] as? String == captureID,
                  taskReload == nil else { return }
            taskReload = Task {
                try? await Task.sleep(for: .milliseconds(500))
                if Task.isCancelled { return }
                taskReload = nil
                await model.load()
            }
        }
        .onDisappear { taskReload?.cancel(); taskReload = nil }
        .onReceive(NotificationCenter.default.publisher(for: SyncCoordinator.passFinished)) { _ in
            Task { await model.load() }
        }
    }
}
