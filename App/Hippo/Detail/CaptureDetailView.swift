import SwiftUI
import os
import CaptureCore
import HippoPresentation
import Enrichment

/// One capture's details: preview, comment, shared content, captured and attachment facts, sync state.
struct CaptureDetailView: View {
    let environment: AppEnvironment
    /// Called after the capture is deleted, before this screen pops, so the timeline reloads.
    let onDeleted: () -> Void

    @State private var model: CaptureDetailModel
    @State private var confirmingDelete = false
    @State private var deleteFailed = false
    @State private var retrying = false
    @State private var showsStripes = LocationService.settings.showsLayerStripes
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private static let log = Logger(subsystem: "com.jorgeper.hippo", category: "detail-ui")

    init(environment: AppEnvironment, captureID: String, onDeleted: @escaping () -> Void) {
        self.environment = environment
        self.onDeleted = onDeleted
        _model = State(initialValue: CaptureDetailModel(
            store: environment.store, captureID: captureID,
            isEnabled: { LocationService.settings.isEnrichmentEnabled($0) },
            isOnline: { EnrichmentScheduling.isOnline }))
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
            .onReceive(NotificationCenter.default.publisher(for: EnrichmentRunner.taskFinished)) { _ in
                Task { await model.load() }
            }
            // The stripes switch lives in Settings; pick up a change on return.
            .onAppear { showsStripes = LocationService.settings.showsLayerStripes }
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
                        .layerStripe(.bronze, shown: showsStripes)
                }
                if let comment = detail.comment {
                    Section("Your comment") {
                        Text(comment).italic().textSelection(.enabled).layerStripe(.bronze, shown: showsStripes)
                    }
                }
                EnrichmentSections(detail: detail, showsStripes: showsStripes)
                if let title = detail.sharedTitle {
                    Section("Shared title") { sharedText(title).layerStripe(.bronze, shown: showsStripes) }
                }
                if let text = detail.sharedText {
                    Section("Shared text") { sharedText(text).layerStripe(.bronze, shown: showsStripes) }
                }
                if !detail.links.isEmpty {
                    Section("Links") {
                        ForEach(detail.links, id: \.absoluteString) { link in
                            Button { openURL(link) } label: {
                                Text(link.absoluteString).font(.callout).lineLimit(3)
                            }
                            .layerStripe(.bronze, shown: showsStripes)
                        }
                    }
                }
                if !detail.captured.isEmpty {
                    Section {
                        ForEach(detail.captured, id: \.label) { item in
                            row(item)
                            if item.label == "Where", let line = detail.pending[.place] {
                                PendingLineView(line: line).layerStripe(.silver, shown: showsStripes)
                            }
                        }
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
                StatusSection(detail: detail, showsStripes: showsStripes, retrying: retrying, onRetry: retry)
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
        .layerStripe(row.layer, shown: showsStripes)
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
