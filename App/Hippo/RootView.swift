import SwiftUI

/// The first screen: the timeline, or, if the store could not be opened, an explanation instead.
struct RootView: View {
    let startup: Result<AppEnvironment, StartupError>

    var body: some View {
        switch startup {
        case .success(let environment):
            NavigationStack {
                TimelineView(environment: environment)
            }
        case .failure(let error):
            ContentUnavailableView("Storage unavailable", systemImage: "exclamationmark.triangle",
                                   description: Text(LocalizedStringKey(error.message)))
        }
    }
}
