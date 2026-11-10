import SwiftUI
import ShareIntake
import LocalRepository

/// The first screen: the timeline, or, if the store could not be opened, an explanation instead. Shares
/// handed off by the extension for a voice comment are presented over it, oldest first.
struct RootView: View {
    let startup: Result<AppEnvironment, StartupError>
    @State private var path = NavigationPath()
    @State private var pendingShare: PendingShareItem?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        switch startup {
        case .success(let environment):
            NavigationStack(path: $path) {
                TimelineView(environment: environment, path: $path)
            }
            .syncScheduling(environment)
            .fullScreenCover(item: $pendingShare) { item in
                PendingShareView(environment: environment, pending: item.pending) {
                    finishPending(item.id, environment)
                }
            }
            .onAppear { checkPending(environment) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { checkPending(environment) }
            }
            .onOpenURL { url in
                if url.scheme == "hippo" { checkPending(environment) }
            }
        case .failure(let error):
            ContentUnavailableView("Storage unavailable", systemImage: "exclamationmark.triangle",
                                   description: Text(LocalizedStringKey(error.message)))
        }
    }

    /// Presents the oldest pending share unless one is already up. Pending shares whose files are gone
    /// were removed by the intake; they are logged here.
    private func checkPending(_ environment: AppEnvironment) {
        guard pendingShare == nil else { return }
        let (captures, dropped) = environment.intake.pendingCaptures()
        if dropped > 0 {
            environment.store.log.append(LogEvent(event: .captureSaveFailed, code: "pending_missing", count: dropped))
        }
        pendingShare = captures.first.map(PendingShareItem.init)
    }

    /// Closes the sheet for `id` and presents the next one. A second call for the same share does nothing.
    private func finishPending(_ id: UUID, _ environment: AppEnvironment) {
        guard pendingShare?.id == id else { return }
        pendingShare = nil
        checkPending(environment)
    }
}

/// A pending share, identified by its capture ID for `.fullScreenCover(item:)`.
private struct PendingShareItem: Identifiable {
    let pending: PendingCapture
    var id: UUID { pending.draft.captureID }
}
