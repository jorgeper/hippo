import SwiftUI
import HippoPresentation

/// Settings' last section: the Developer mode switch, and when on, the log.
struct DeveloperSection: View {
    let model: SettingsModel
    let logModel: GlobalLogModel
    @State private var on: Bool
    @State private var confirmingClear = false

    init(model: SettingsModel, logModel: GlobalLogModel) {
        self.model = model
        self.logModel = logModel
        _on = State(initialValue: model.developerMode)
    }

    var body: some View {
        Section {
            Toggle("Developer mode", isOn: Binding(get: { on }, set: { value in
                on = value
                model.setDeveloperMode(value)
            }))
            .accessibilityIdentifier("settings-developer-mode")
            if on {
                NavigationLink("Log") { GlobalLogView(model: logModel) }
                Button("Clear log", role: .destructive) { confirmingClear = true }
                    .confirmationDialog("Delete this iPhone's log? Copies already uploaded are kept.",
                                        isPresented: $confirmingClear, titleVisibility: .visible) {
                        Button("Clear log", role: .destructive) { Task { await logModel.clear() } }
                    }
                Text(logModel.uploadLine).foregroundStyle(.secondary)
            }
        } header: {
            Text("Developer")
        }
        .task(id: on) { if on { await logModel.load() } }
    }
}
