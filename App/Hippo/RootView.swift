import SwiftUI
import ShareIntake
import LocalRepository

/// The first screen: the timeline, or, if the store could not be opened, an explanation instead. Shares
/// handed off by the extension for a voice comment are presented over it, oldest first.
struct RootView: View {
    /// Posted when a sheet or cover over the timeline closes, so a pending share held back by it is shown.
    static let presentationClosed = Notification.Name("HippoPresentationClosed")

    let startup: Result<AppEnvironment, StartupError>
    @State private var path = NavigationPath()
    @State private var pendingShare: PendingShareItem?
    /// The pending share whose cover is on screen. A share set while another presentation was up never
    /// appears, and `checkPending` presents it again.
    @State private var appearedPendingID: UUID?
    @State private var pendingSetAt = Date.distantPast
    /// Shares put off with "Later": not presented again until the next activation.
    @State private var putOff: Set<UUID> = []
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        switch startup {
        case .success(let environment):
            NavigationStack(path: $path) {
                TimelineView(environment: environment, path: $path)
            }
            .syncScheduling(environment)
            .fullScreenCover(item: $pendingShare) { item in
                PendingShareView(environment: environment, pending: item.pending,
                                 done: { finishPending(item.id, environment) },
                                 later: { putOffPending(item.id, environment) })
                    .onAppear { appearedPendingID = item.id }
                    .onDisappear { if appearedPendingID == item.id { appearedPendingID = nil } }
            }
            .onAppear { checkPending(environment) }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                putOff = []
                checkPending(environment)
            }
            .onOpenURL { url in
                guard url.scheme == "hippo" else { return }
                putOff = []
                checkPending(environment)
            }
            .onReceive(NotificationCenter.default.publisher(for: Self.presentationClosed)) { _ in
                checkPending(environment)
            }
        case .failure(let error):
            ContentUnavailableView("Storage unavailable", systemImage: "exclamationmark.triangle",
                                   description: Text(LocalizedStringKey(error.message)))
        }
    }

    /// Presents the oldest pending share unless one is on screen. Pending shares whose files are gone were
    /// removed by the intake, as were those already saved (the app was killed before the intake was
    /// cleared); both are logged here.
    private func checkPending(_ environment: AppEnvironment) {
        if let current = pendingShare {
            // On screen, or set a moment ago and still being presented: leave it.
            if appearedPendingID == current.id || Date().timeIntervalSince(pendingSetAt) < 1 { return }
            // Set while another sheet was up, so it never appeared: present it again on the next update.
            pendingShare = nil
            Task { @MainActor in checkPending(environment) }
            return
        }
        let index = environment.store.index
        let (captures, dropped, committed) = environment.intake.pendingCaptures(isCommitted: { id in
            (try? index.relativeDirectory(captureID: id.uuidString.lowercased())) != nil
        })
        if dropped > 0 {
            environment.store.log.append(LogEvent(event: .captureSaveFailed, code: "pending_missing", count: dropped))
        }
        if committed > 0 {
            environment.store.log.append(LogEvent(event: .captureSaveFailed, code: "pending_already_committed",
                                                  count: committed))
        }
        guard let next = captures.first(where: { !putOff.contains($0.draft.captureID) }) else { return }
        pendingShare = PendingShareItem(pending: next)
        pendingSetAt = Date()
    }

    /// Closes the sheet for `id` and presents the next one. A second call for the same share does nothing.
    private func finishPending(_ id: UUID, _ environment: AppEnvironment) {
        guard pendingShare?.id == id else { return }
        pendingShare = nil
        checkPending(environment)
    }

    /// Closes the sheet for `id` and keeps its pending draft for the next activation.
    private func putOffPending(_ id: UUID, _ environment: AppEnvironment) {
        putOff.insert(id)
        finishPending(id, environment)
    }
}

/// A pending share, identified by its capture ID for `.fullScreenCover(item:)`.
private struct PendingShareItem: Identifiable {
    let pending: PendingCapture
    var id: UUID { pending.draft.captureID }
}
