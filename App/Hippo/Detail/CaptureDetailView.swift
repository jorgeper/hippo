import SwiftUI
import os
import CaptureCore
import LocalRepository
import SyncEngine
import HippoPresentation
import Enrichment

/// One capture's details: preview, comments, shared content, captured and attachment facts, sync state.
struct CaptureDetailView: View {
    let environment: AppEnvironment
    let captureID: String
    /// Called after the capture is deleted, before this screen pops, so the timeline reloads.
    let onDeleted: () -> Void

    @State private var model: CaptureDetailModel
    @State private var confirmingDelete = false
    @State private var confirmingDeleteEverywhere = false
    @State private var deleteFailed = false
    @State private var retrying = false
    @State private var uploadingAgain = false
    @State private var developerMode = LocationService.settings.developerMode
    @State private var showsStripes = LocationService.settings.showsLayerStripes
    @State private var taskReload: Task<Void, Never>?
    @State private var compose: Compose?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private static let log = Logger(subsystem: "com.jorgeper.hippo", category: "detail-ui")

    /// The comment sheets: a typed comment or a recorded one.
    private enum Compose: String, Identifiable {
        case note, record
        var id: String { rawValue }
    }

    init(environment: AppEnvironment, captureID: String, onDeleted: @escaping () -> Void) {
        self.environment = environment
        self.captureID = captureID
        self.onDeleted = onDeleted
        let adapterFor: (@Sendable (Destination) throws -> any StorageAdapter)? = environment.registry.map { registry in
            { @Sendable destination in try registry.adapter(for: destination) }
        }
        let registry = environment.registry
        _model = State(initialValue: CaptureDetailModel(
            store: environment.store, captureID: captureID,
            isEnabled: { LocationService.settings.isEnrichmentEnabled($0) },
            isOnline: { EnrichmentScheduling.isOnline },
            sync: { [coordinator = environment.coordinator] in _ = await coordinator?.syncNow(trigger: "manual") },
            adapterFor: adapterFor,
            accountName: { destination in await registry?.provider(kind: destination.providerKind)?.accountName(destination) }))
    }

    var body: some View {
        content
            .safeAreaInset(edge: .bottom) {
                if model.detail != nil { commentBar }
            }
            .sheet(item: $compose, onDismiss: {
                Task { await model.load() }
                NotificationCenter.default.post(name: TimelineModel.enrichmentChanged, object: nil)
            }) { compose in
                switch compose {
                case .note:
                    NoteEditorView(environment: environment, location: LocationService.shared,
                                   target: .comment(captureID: captureID))
                case .record:
                    RecorderView(environment: environment, location: LocationService.shared,
                                 target: .comment(captureID: captureID))
                        .presentationDetents([.medium])
                }
            }
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
            // A backfill finishes many tasks a second across all captures: reload only for this capture's
            // tasks, at most once per 500 ms.
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
            // The stripes switch lives in Settings; pick up a change on return.
            .onAppear {
                showsStripes = LocationService.settings.showsLayerStripes
                developerMode = LocationService.settings.developerMode
            }
            .confirmationDialog(model.deletionPrompt?.title ?? "Delete from iPhone?", isPresented: $confirmingDelete,
                                titleVisibility: .visible, presenting: model.deletionPrompt) { prompt in
                Button(prompt.confirm, role: .destructive) { delete() }
                Button("Cancel", role: .cancel) {}
            } message: { prompt in
                Text(prompt.message)
            }
            .confirmationDialog(model.everywherePrompt?.title ?? "Delete everywhere?",
                                isPresented: $confirmingDeleteEverywhere, titleVisibility: .visible,
                                presenting: model.everywherePrompt) { prompt in
                Button(prompt.confirm, role: .destructive) { delete(everywhere: true) }
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

    /// Trimmed attachments the large preview and the comment rows aren't already showing.
    private func otherRemoteOnly(_ detail: CaptureDetail) -> [RemoteOnlyAttachment] {
        var shown = Set(detail.comments.compactMap { $0.remoteOnly?.attachmentID })
        if case .remoteOnly(let first) = detail.preview { shown.insert(first.attachmentID) }
        return detail.remoteOnly.values.filter { !shown.contains($0.attachmentID) }
            .sorted { $0.relativePath < $1.relativePath }
    }

    /// Note and Record for a comment on this capture: the timeline's bar, without the camera.
    private var commentBar: some View {
        HStack {
            Spacer()
            CaptureButton(kind: .note) { compose = .note }
            Spacer()
            CaptureButton(kind: .record(recording: false)) { compose = .record }
            Spacer()
        }
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// One comment: its text or player, when it was added, then its transcript as a row of its own so it
    /// carries its own layer stripe.
    @ViewBuilder private func commentRows(_ comment: CommentRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let remoteOnly = comment.remoteOnly {
                RemoteOnlyAttachmentView(attachment: remoteOnly, model: model, large: false)
            } else {
                switch comment.body {
                case .text(let text):
                    Text(text).italic().textSelection(.enabled)
                case .audio(let url, let durationText):
                    AudioPlayerRow(url: url, durationText: durationText)
                }
            }
            if let caption = comment.caption {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
        .layerStripe(.bronze, shown: showsStripes)
        if let transcript = comment.transcript {
            Text(transcript)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .listRowSeparator(.hidden, edges: .top)
                .layerStripe(comment.transcriptLayer ?? .silver, shown: showsStripes)
        }
    }

    @ViewBuilder private var content: some View {
        if let detail = model.detail {
            List {
                if detail.preview != .none {
                    AttachmentPreview(kind: detail.preview, model: model)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                ForEach(otherRemoteOnly(detail), id: \.attachmentID) { attachment in
                    RemoteOnlyAttachmentView(attachment: attachment, model: model, large: false)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                if !detail.comments.isEmpty {
                    Section("Comments") {
                        ForEach(detail.comments) { commentRows($0) }
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
                if !detail.context.isEmpty {
                    Section("Context") {
                        ForEach(Array(detail.context.enumerated()), id: \.offset) { _, item in row(item) }
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
                StatusSection(detail: detail, showsStripes: showsStripes, retrying: retrying, onRetry: retry,
                              uploadingAgain: uploadingAgain, onUploadAgain: uploadAgain)
                if developerMode, let capturedAt = model.capturedAt {
                    Section {
                        NavigationLink("Activity") {
                            ActivityView(environment: environment, captureID: captureID, capturedAt: capturedAt)
                        }
                        .accessibilityIdentifier("detail-activity")
                    }
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
        .layerStripe(row.layer, shown: showsStripes)
    }

    private func menu(_ detail: CaptureDetail) -> some View {
        Menu {
            let items = detail.exportURLs + detail.links
            if !items.isEmpty { ShareLink("Share…", items: items) }
            Button("Delete from iPhone…", role: .destructive) { confirmingDelete = true }
                .disabled(model.deletionPrompt == nil)
            if model.everywherePrompt != nil {
                Button("Delete everywhere…", role: .destructive) { confirmingDeleteEverywhere = true }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("More")
        .accessibilityIdentifier("detail-menu")
    }

    private func uploadAgain() {
        guard !uploadingAgain else { return }
        uploadingAgain = true
        let model = model, coordinator = environment.coordinator
        Task {
            defer { uploadingAgain = false }
            await BackgroundActivity.run(name: "detail-upload-again", onExpire: coordinator.map(SyncScheduling.stopper)) {
                await model.uploadAgain()
            }
        }
    }

    private func retry() {
        guard !retrying else { return }
        retrying = true
        let model = model, coordinator = environment.coordinator
        Task {
            defer { retrying = false }
            await BackgroundActivity.run(name: "detail-retry", onExpire: coordinator.map(SyncScheduling.stopper)) {
                await model.retry()
                _ = await coordinator?.syncNow(trigger: "manual")
            }
            await model.load()
        }
    }

    private func delete(everywhere: Bool = false) {
        let model = model
        Task {
            do {
                _ = try await BackgroundActivity.run(name: "detail-delete") {
                    everywhere ? try await model.deleteEverywhere() : try await model.delete()
                }
                onDeleted()
                dismiss()
            } catch {
                Self.log.error("\("delete_failed", privacy: .public)")
                deleteFailed = true
            }
        }
    }
}
