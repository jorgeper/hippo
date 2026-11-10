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
    /// The capture ID of the pending share whose cover is on screen. A share set while another
    /// presentation was up never appears, and `checkPending` presents it again.
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
                let captureID = item.pending.draft.captureID
                PendingShareView(environment: environment, pending: item.pending,
                                 done: { finishPending(captureID, environment) },
                                 later: { putOffPending(captureID, environment) })
                    .onAppear { appearedPendingID = captureID }
                    .onDisappear { if appearedPendingID == captureID { appearedPendingID = nil } }
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
        // On screen, or set a moment ago and still being presented: leave it. Otherwise it was set while
        // another sheet was up and never appeared; the fresh item below has a new identity, so SwiftUI
        // presents it again.
        if let current = pendingShare,
           appearedPendingID == current.pending.draft.captureID || Date().timeIntervalSince(pendingSetAt) < 1 {
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
        let next = captures.first(where: { !putOff.contains($0.draft.captureID) })
        pendingShare = next.map(PendingShareItem.init)
        if next != nil { pendingSetAt = Date() }
    }

    /// Closes the sheet for capture `id` and presents the next one. A second call for the same share does
    /// nothing.
    private func finishPending(_ id: UUID, _ environment: AppEnvironment) {
        guard pendingShare?.pending.draft.captureID == id else { return }
        pendingShare = nil
        checkPending(environment)
    }

    /// Closes the sheet for capture `id` and keeps its pending draft for the next activation.
    private func putOffPending(_ id: UUID, _ environment: AppEnvironment) {
        putOff.insert(id)
        finishPending(id, environment)
    }
}

/// One attempt to present a pending share. Each attempt has its own identity, so setting a new item for
/// the same share makes `.fullScreenCover(item:)` present again; match shares on the capture ID.
private struct PendingShareItem: Identifiable {
    let pending: PendingCapture
    let attempt = UUID()
    var id: UUID { attempt }
}
