import SwiftUI
import HippoPresentation
import Enrichment

/// One capture's log lines, oldest first. Developer mode only.
struct ActivityView: View {
    @State private var model: ActivityModel

    init(environment: AppEnvironment, captureID: String, capturedAt: Date) {
        _model = State(initialValue: ActivityModel(store: environment.store, captureID: captureID, capturedAt: capturedAt))
    }

    var body: some View {
        List {
            if model.lines.isEmpty {
                Text("Nothing logged yet").foregroundStyle(.secondary)
            } else {
                Section {
                    ForEach(model.lines) { LogLineRow(line: $0) }
                } footer: {
                    if model.mayBePruned { Text("Earlier events may have been removed (Hippo keeps 30 days).") }
                }
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
        .onReceive(NotificationCenter.default.publisher(for: EnrichmentRunner.taskFinished)) { _ in
            Task { await model.load() }
        }
    }
}
