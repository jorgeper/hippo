import SwiftUI

/// What connecting will do, shown before Dropbox sign-in (design §4.1). The "only that folder" line is
/// where a future full-Dropbox choice would go.
struct DropboxConnectSheet: View {
    let providerName: String
    /// Called before the sheet dismisses itself.
    let onConnect: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Hippo will create a folder called Apps/Hippo in your Dropbox.")
                    Text("Hippo can see only that folder.")
                }
                Section {
                    Button("Connect") {
                        onConnect()
                        dismiss()
                    }
                    .accessibilityIdentifier("dropbox-connect")
                }
            }
            .navigationTitle("Connect \(providerName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
