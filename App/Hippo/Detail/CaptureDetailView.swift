import SwiftUI
import os
import HippoPresentation

/// One capture's details: preview, comment, shared content, captured and attachment facts, sync state.
struct CaptureDetailView: View {
    let environment: AppEnvironment
    /// Called after the capture is deleted, before this screen pops, so the timeline reloads.
    let onDeleted: () -> Void

    @State private var model: CaptureDetailModel
    @State private var confirmingDelete = false
    @State private var deleteFailed = false
    @State private var retrying = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private static let log = Logger(subsystem: "com.jorgeper.hippo", category: "detail-ui")

    init(environment: AppEnvironment, captureID: String, onDeleted: @escaping () -> Void) {
        self.environment = environment
        self.onDeleted = onDeleted
        _model = State(initialValue: CaptureDetailModel(store: environment.store, captureID: captureID))
    }

    var body: some View {
        content
            .navigationTitle("Capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let detail = model.detail {
                    ToolbarItem(placement: .topBarTrailing) { menu(detail) }
                }
            }
            .task { await model.load() }
            .onReceive(NotificationCenter.default.publisher(for: TimelineModel.enrichmentChanged)) { _ in
                Task { await model.load() }
            }
            // A sync pass may have pulled gold for this capture, or changed its upload state.
            .onReceive(NotificationCenter.default.publisher(for: SyncCoordinator.passFinished)) { _ in
                Task { await model.load() }
            }
            .confirmationDialog(model.deletionPrompt?.title ?? "Delete from iPhone?", isPresented: $confirmingDelete,
                                titleVisibility: .visible, presenting: model.deletionPrompt) { prompt in
                Button(prompt.confirm, role: .destructive) { delete() }
                Button("Cancel", role: .cancel) {}
            } message: { prompt in
                Text(prompt.message)
            }
            .alert("Couldn't delete this capture", isPresented: $deleteFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Nothing was removed. Try again in a moment.")
            }
    }

    @ViewBuilder private var content: some View {
        if let detail = model.detail {
            List {
                if detail.preview != .none {
                    AttachmentPreview(kind: detail.preview)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                if let comment = detail.comment {
                    Section("Your comment") { Text(comment).italic().textSelection(.enabled) }
                }
                EnrichmentSections(detail: detail)
                if let title = detail.sharedTitle {
                    Section("Shared title") { sharedText(title) }
                }
                if let text = detail.sharedText {
                    Section("Shared text") { sharedText(text) }
                }
                if !detail.links.isEmpty {
                    Section("Links") {
                        ForEach(detail.links, id: \.absoluteString) { link in
                            Button { openURL(link) } label: {
                                Text(link.absoluteString).font(.callout).lineLimit(3)
                            }
                        }
                    }
                }
                if !detail.captured.isEmpty {
                    Section {
                        ForEach(detail.captured, id: \.label) { row($0) }
                    }
                }
                if !detail.attachments.isEmpty {
                    Section("Attachments") {
                        ForEach(Array(detail.attachments.enumerated()), id: \.offset) { _, rows in
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(rows, id: \.label) { row($0) }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                if !detail.sync.isEmpty {
                    Section("Sync") { ForEach(Array(detail.sync.enumerated()), id: \.offset) { syncRow($1) } }
                }
            }
            .listStyle(.insetGrouped)
            .contentMargins(.top, detail.preview == .none ? 16 : 0, for: .scrollContent)
        } else if model.loadFailed {
            ContentUnavailableView {
                Label("Couldn't load this capture", systemImage: "exclamationmark.triangle")
            } actions: {
                Button("Retry") { Task { await model.load() } }
            }
        } else {
            ProgressView()
        }
    }

    /// Shared content is quoted in a tinted block so it never reads as the user's own words.
    private func sharedText(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .padding(.leading, 10)
            .overlay(alignment: .leading) {
                Rectangle().fill(.tertiary).frame(width: 3)
            }
    }

    private func row(_ row: DetailRow) -> some View {
        LabeledContent(row.label) {
            Text(row.value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }

    private func syncRow(_ row: SyncRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let name = row.destinationName {
                    Text(name).font(.headline)
                    Spacer()
                }
                Text(row.label.title).font(.subheadline).foregroundStyle(color(row.label))
                if row.destinationName == nil { Spacer() }
            }
            if let message = row.message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            if row.canRetry {
                Button("Retry") { retry() }.buttonStyle(.bordered).disabled(retrying)
            }
        }
        .padding(.vertical, 2)
    }

    private func color(_ label: SyncLabel) -> Color {
        switch label {
        case .onIPhone: .secondary
        case .synced: .green
        case .needsAttention: .orange
        }
    }

    private func menu(_ detail: CaptureDetail) -> some View {
        Menu {
            let items = detail.exportURLs + detail.links
            if !items.isEmpty { ShareLink("Share…", items: items) }
            Button("Delete from iPhone…", role: .destructive) { confirmingDelete = true }
                .disabled(model.deletionPrompt == nil)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("More")
        .accessibilityIdentifier("detail-menu")
    }

    private func retry() {
        guard !retrying else { return }
        retrying = true
        let model = model, coordinator = environment.coordinator
        Task {
            defer { retrying = false }
            await BackgroundActivity.run(name: "detail-retry", onExpire: coordinator.map(SyncScheduling.stopper)) {
                await model.retry()
                _ = await coordinator?.syncNow()
            }
            await model.load()
        }
    }

    private func delete() {
        let model = model
        Task {
            do {
                _ = try await BackgroundActivity.run(name: "detail-delete") { try await model.delete() }
                onDeleted()
                dismiss()
            } catch {
                Self.log.error("\("delete_failed", privacy: .public)")
                deleteFailed = true
            }
        }
    }
}
