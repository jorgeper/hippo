import SwiftUI
import HippoPresentation

/// This iPhone's log, newest first. Developer mode only.
struct GlobalLogView: View {
    let model: GlobalLogModel

    var body: some View {
        List {
            if model.lines.isEmpty {
                Text("Nothing logged yet").foregroundStyle(.secondary)
            } else {
                ForEach(model.lines) { LogLineRow(line: $0) }
                if model.canLoadMore {
                    Button("Load more") { Task { await model.loadMore() } }
                }
            }
        }
        .navigationTitle("Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                CopyLogButton { model.copyText(appVersion: hippoAppVersion()) }
            }
        }
        .task { await model.load() }
    }
}
