import SwiftUI
import CaptureCore
import HippoPresentation

struct NoteEditorView: View {
    let environment: AppEnvironment
    let location: LocationService
    var target: SaveTarget = .newCapture

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var startedAt = Date()
    @State private var confirmingDiscard = false
    @State private var saving = false
    @State private var saveFailed = false
    @State private var saveFailedMessage = Self.noteSaveFailedMessage
    @FocusState private var focused: Bool

    private static let noteSaveFailedMessage = "Hippo couldn't save this note. It's still here. Try again."

    private var isComment: Bool {
        if case .comment = target { true } else { false }
    }

    private var isBlank: Bool { text.allSatisfy { $0.isWhitespace } }
    private var canSave: Bool { !isBlank && !saving }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .focused($focused)
                .padding(.horizontal, 12)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(isComment ? "Write a comment" : "Write a note")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 17)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .navigationTitle(isComment ? "Add a comment" : "Note")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            if isBlank { dismiss() } else { confirmingDiscard = true }
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { saving = true; Task { await save() } }.disabled(!canSave)
                            .accessibilityIdentifier("note-save")
                    }
                }
                .confirmationDialog(isComment ? "Discard comment?" : "Discard note?", isPresented: $confirmingDiscard,
                                    titleVisibility: .visible) {
                    Button("Discard", role: .destructive) { dismiss() }
                    Button("Keep editing", role: .cancel) {}
                }
                .alert(saveFailedMessage, isPresented: $saveFailed) {
                    Button("OK", role: .cancel) {}
                }
        }
        .interactiveDismissDisabled(!isBlank)
        .onAppear {
            startedAt = Date()
            focused = true
            if !isComment { location.beginSessionFix() }
        }
    }

    private func save() async {
        if case .comment(let captureID) = target {
            await saveComment(captureID: captureID)
            return
        }
        let started = startedAt
        guard let draft = NoteComposer.draft(
            text: text, captureID: UUID(), startedAt: started, timeZone: .current,
            location: location.location(startedAt: started)) else { saving = false; return }
        let store = environment.store
        do {
            _ = try await BackgroundActivity.run(name: "note-save") { try await store.capture(draft) }
        } catch {
            saving = false
            saveFailed = true
            return
        }
        dismiss()
        if let coordinator = environment.coordinator {
            Task { await SyncScheduling.runPass(coordinator, name: "note-sync", trigger: "after_save") }
        }
        let environment = environment
        Task { await EnrichmentScheduling.run(environment, reason: "note") }
    }

    private func saveComment(captureID: String) async {
        guard let draft = NoteComposer.comment(text: text) else { saving = false; return }
        let store = environment.store
        do {
            _ = try await BackgroundActivity.run(name: "comment-save") {
                try await store.addComment(captureID: captureID, draft)
            }
        } catch {
            saving = false
            saveFailedMessage = CommentErrorCopy.message(for: error, fallback: RecorderModel.commentSaveFailedMessage)
            saveFailed = true
            return
        }
        dismiss()
        if let coordinator = environment.coordinator {
            Task { await SyncScheduling.runPass(coordinator, name: "comment-sync", trigger: "after_save") }
        }
        let environment = environment
        Task { await EnrichmentScheduling.run(environment, reason: "comment") }
    }
}
