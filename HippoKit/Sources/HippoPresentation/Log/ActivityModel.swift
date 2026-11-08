import Foundation
import Observation
import SyncEngine

/// The per-capture activity log behind Detail's Activity screen. Reads the log only for display.
@MainActor @Observable
public final class ActivityModel {
    private let store: HippoStore
    private let captureID: String
    private let capturedAt: Date
    public private(set) var lines: [LogLine] = []
    /// Runs after a load's read and before it applies. Set only by tests, to finish loads out of order.
    @ObservationIgnored var beforeApply: (@Sendable () async -> Void)?
    /// Counts `load()` calls, so a read that finishes after a newer one started is dropped.
    @ObservationIgnored private var generation = 0

    public init(store: HippoStore, captureID: String, capturedAt: Date) {
        self.store = store
        self.captureID = captureID
        self.capturedAt = capturedAt
    }

    /// Logs older than 30 days are deleted, so an old capture's history may be incomplete.
    public var mayBePruned: Bool { capturedAt < Date().addingTimeInterval(-30 * 86_400) }

    /// Overlapping calls may finish out of order: only the most recently started one applies its result.
    public func load() async {
        generation += 1
        let mine = generation
        let store = store, id = captureID, from = capturedAt
        let events = await Task.detached { store.log.events(captureID: id, from: from) }.value
        if let beforeApply { await beforeApply() }
        guard mine == generation else { return }
        let now = Date(), zone = TimeZone.current, locale = Locale.current
        lines = events.enumerated().map { LogLine.make($1, id: $0, now: now, zone: zone, locale: locale) }
    }

    public func copyText(appVersion: String) -> String {
        (["Hippo activity · capture \(captureID) · app \(appVersion)"] + lines.map { "\($0.time)  \($0.text)" })
            .joined(separator: "\n")
    }
}
