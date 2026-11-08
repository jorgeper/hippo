import SwiftUI

/// The first screen. A placeholder "Captures" screen until the timeline is built; if the store could
/// not be opened, an explanation instead of the app.
struct RootView: View {
    let startup: Result<AppEnvironment, StartupError>

    var body: some View {
        switch startup {
        case .success:
            NavigationStack {
                ContentUnavailableView("Captures", systemImage: "tray",
                                       description: Text("The timeline is coming soon."))
                    .navigationTitle("Captures")
            }
        case .failure(let error):
            ContentUnavailableView("Storage unavailable", systemImage: "exclamationmark.triangle",
                                   description: Text(LocalizedStringKey(error.message)))
        }
    }
}
