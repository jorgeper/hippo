import SwiftUI
import CaptureCore
import HippoPresentation

struct NoteEditorView: View {
    let environment: AppEnvironment
    let location: LocationService

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var startedAt = Date()
    @State private var confirmingDiscard = false
    @State private var saving = false
    @State private var saveFailed = false
    @FocusState private var focused: Bool

    private var canSave: Bool { !text.allSatisfy(\.isWhitespace) && !saving }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .focused($focused)
                .padding(.horizontal, 12)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Write a note")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 17)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }
                .navigationTitle("Note")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            if text.isEmpty { dismiss() } else { confirmingDiscard = true }
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { Task { await save() } }.disabled(!canSave)
                    }
                }
                .confirmationDialog("Discard note?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                    Button("Discard", role: .destructive) { dismiss() }
                    Button("Keep editing", role: .cancel) {}
                }
                .alert("Hippo couldn't save this note. It's still here. Try again.", isPresented: $saveFailed) {
                    Button("OK", role: .cancel) {}
                }
        }
        .interactiveDismissDisabled(!text.isEmpty)
        .onAppear {
            startedAt = Date()
            focused = true
            location.beginSessionFix()
        }
    }

    private func save() async {
        let started = startedAt
        guard let draft = NoteComposer.draft(
            text: text, captureID: UUID(), startedAt: started, timeZone: .current,
            location: location.location(startedAt: started)) else { return }
        saving = true
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
            Task { _ = await BackgroundActivity.run(name: "note-sync") { await coordinator.syncNow() } }
        }
    }
}
