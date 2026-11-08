import Foundation
import Observation
import os
import CaptureCore
import LocalRepository
import SyncEngine

/// The Settings screen's state and actions: the connected destination, sync status, retry, uploading
/// existing captures, the location preference, and local storage use (spec §11 "Settings").
public struct EnrichmentSwitch: Identifiable, Sendable {
    public let kind: FacetKind
    public let title: String
    public var id: String { kind.rawValue }
}

@MainActor @Observable
public final class SettingsModel {
    public private(set) var activeDestination: Destination?
    public private(set) var counts: [SyncBucket: Int] = [:]
    /// Disk space used by the local store (database and capture packages).
    public private(set) var storageBytes: Int64 = 0
    public private(set) var locationEnabled: Bool
    /// Whether stripes show where details came from.
    public private(set) var showsLayerStripes: Bool
    /// Whether Activity and the Log screen are shown.
    public private(set) var developerMode: Bool
    /// True after a failed `refresh()`; cleared by the next successful one. A failed refresh keeps the
    /// previous values.
    public private(set) var loadFailed = false

    /// "Last sync … · N being processed · …"; nil until the first `refresh()`.
    public private(set) var statusSummary: String?

    /// One line for the Sync section.
    public var summary: String { Self.summary(counts: counts) }

    @ObservationIgnored private let store: HippoStore
    @ObservationIgnored private let registry: ProviderRegistry
    @ObservationIgnored private let coordinator: SyncCoordinator
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let isOnline: @Sendable () -> Bool
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let locale: Locale
    @ObservationIgnored private let requestLocationPermission: () async -> Bool
    @ObservationIgnored private let onEnrichmentEnabled: @Sendable (FacetKind) async -> Void
    private nonisolated static let log = Logger(subsystem: "com.jorgeper.hippo", category: "settings")

    public init(store: HippoStore, registry: ProviderRegistry, coordinator: SyncCoordinator, settings: AppSettings,
                requestLocationPermission: @escaping () async -> Bool,
                onEnrichmentEnabled: @escaping @Sendable (FacetKind) async -> Void = { _ in },
                isOnline: @escaping @Sendable () -> Bool = { true },
                now: @escaping @Sendable () -> Date = Date.init, locale: Locale = .current) {
        self.isOnline = isOnline
        self.now = now
        self.locale = locale
        self.onEnrichmentEnabled = onEnrichmentEnabled
        self.store = store
        self.registry = registry
        self.coordinator = coordinator
        self.settings = settings
        self.requestLocationPermission = requestLocationPermission
        locationEnabled = settings.locationEnabled
        showsLayerStripes = settings.showsLayerStripes
        developerMode = settings.developerMode
    }

    public static let enrichmentSwitches: [EnrichmentSwitch] = [
        EnrichmentSwitch(kind: .linkPreview, title: "Link previews"),
        EnrichmentSwitch(kind: .place, title: "Place names"),
        EnrichmentSwitch(kind: .textRecognition, title: "Text in images"),
        EnrichmentSwitch(kind: .transcript, title: "Voice note transcripts"),
        EnrichmentSwitch(kind: .dataDetection, title: "Dates, phone numbers and addresses"),
        EnrichmentSwitch(kind: .sourceAppGuess, title: "App guesses"),
    ]

    public static let enrichmentFooter = "Link previews fetch the page title and picture from the website. Place names are looked up with Apple Maps. Everything else runs on this iPhone."
    public static let layerStripesFooter = "Bronze: what you captured. Silver: added on this iPhone. Gold: added by your server."

    public func setShowsLayerStripes(_ on: Bool) {
        settings.showsLayerStripes = on
        showsLayerStripes = on
        store.log.append(LogEvent(event: .settingsChanged, kind: "layer_stripes", on: on))
    }

    public func setDeveloperMode(_ on: Bool) {
        settings.developerMode = on
        developerMode = on
        store.log.append(LogEvent(event: .settingsChanged, kind: "developer_mode", on: on))
    }

    public func isEnrichmentEnabled(_ kind: FacetKind) -> Bool { settings.isEnrichmentEnabled(kind) }

    /// Stores the switch. Turning a kind on backfills existing captures through `onEnrichmentEnabled`.
    public func setEnrichment(_ kind: FacetKind, on: Bool) async {
        settings.setEnrichmentEnabled(kind, on)
        store.log.append(LogEvent(event: .settingsChanged, kind: kind.rawValue, on: on))
        if on { await onEnrichmentEnabled(kind) }
    }

    nonisolated static func summary(counts: [SyncBucket: Int]) -> String {
        let attention = counts[.needsAttention] ?? 0, waiting = counts[.notSynced] ?? 0
        var parts: [String] = []
        if attention > 0 { parts.append("\(attention) need attention") }
        if waiting > 0 { parts.append("\(waiting) waiting to upload") }
        return parts.isEmpty ? "All captures synced" : parts.joined(separator: " · ")
    }

    private struct Snapshot: Sendable {
        var destination: Destination?
        var counts: [SyncBucket: Int]
        var bytes: Int64
        var unfinished: [EnrichmentTask]
    }

    /// Re-reads the destination, sync counts, storage use and location preference.
    public func refresh() async {
        let store = store
        locationEnabled = settings.locationEnabled
        let snapshot: Snapshot? = await Task.detached {
            do {
                return Snapshot(destination: try store.destinations.active(), counts: try store.index.counts(),
                                bytes: StorageUsage.bytes(under: store.layout.root),
                                unfinished: (try? store.enrichmentTasks.unfinished()) ?? [])
            } catch {
                Self.log.error("\("refresh_failed", privacy: .public)")
                return nil
            }
        }.value
        guard let snapshot else { loadFailed = true; return }
        loadFailed = false
        activeDestination = snapshot.destination
        counts = snapshot.counts
        storageBytes = snapshot.bytes
        statusSummary = buildStatusSummary(unfinished: snapshot.unfinished)
    }

    private func buildStatusSummary(unfinished: [EnrichmentTask]) -> String {
        let current = now()
        let settings = settings
        var working = 0, offline = 0, retry = 0, failed = 0
        for (_, tasks) in Dictionary(grouping: unfinished, by: \.captureID) {
            let steps = EnrichmentProgress.steps(tasks, isEnabled: { settings.isEnrichmentEnabled($0) },
                                                 isOnline: isOnline(), now: current)
            switch EnrichmentProgress.row(steps) {
            case .working: working += 1
            case .waiting:
                let isOffline = steps.contains { key, state in
                    if state == .waiting(code: "offline") { return true }
                    if case .waitingForInput(let input) = state { return steps[input] == .waiting(code: "offline") }
                    return false
                }
                if isOffline { offline += 1 } else { retry += 1 }
            case .none: break
            }
            if steps.values.contains(where: { if case .failed = $0 { true } else { false } }) { failed += 1 }
        }
        var head = "Last sync never"
        if let last = settings.lastSync {
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = locale
            formatter.dateTimeStyle = .named
            formatter.unitsStyle = .full
            head = "Last sync \(formatter.localizedString(for: last.at, relativeTo: current))"
            if last.failed { head += " didn't finish" }
        }
        var parts = [head]
        if working > 0 { parts.append("\(working) being processed") }
        if offline > 0 { parts.append("\(offline) waiting for a connection") }
        if retry > 0 { parts.append("\(retry) waiting to retry") }
        if failed > 0 { parts.append("\(failed) couldn't be processed") }
        return parts.joined(separator: " · ")
    }

    /// Signs in with `p`, makes it the active destination (binding every capture that has no upload
    /// yet), then syncs.
    public func connect(_ p: any StorageProvider) async throws {
        let destination = try await p.connect()
        let store = store
        _ = try await Task.detached { try store.destinations.connect(destination) }.value
        await refresh()
        await syncThenRefresh()
    }

    /// Signs out of the active destination and pauses its uploads. Captures stay on this iPhone.
    public func signOut() async throws {
        let store = store
        guard let active = try await Task.detached(operation: { try store.destinations.active() }).value else {
            await refresh()
            return
        }
        await registry.provider(kind: active.providerKind)?.signOut(active)
        try await Task.detached { try store.destinations.signOut(destinationID: active.id) }.value
        await refresh()
    }

    /// Makes every blocked or retry-waiting upload for the active destination claimable now, then syncs.
    public func retryAll() async throws {
        let store = store
        _ = try await Task.detached { try store.retryAll() }.value
        await syncThenRefresh()
    }

    /// "Upload existing captures": gives every capture without a job for the active destination one,
    /// then syncs. Returns the number of captures added; 0 when nothing is connected.
    @discardableResult
    public func uploadExisting() async throws -> Int {
        let store = store
        let added = try await Task.detached { () throws -> Int in
            guard let active = try store.destinations.active() else { return 0 }
            return try store.destinations.backfill(destinationID: active.id)
        }.value
        await syncThenRefresh()
        return added
    }

    /// Turning location on asks for permission first and stays off if it is not granted.
    public func setLocationEnabled(_ on: Bool) async {
        let enabled = on ? await requestLocationPermission() : false
        settings.locationEnabled = enabled
        locationEnabled = enabled
        store.log.append(LogEvent(event: .settingsChanged, kind: "location", on: enabled))
    }

    private func syncThenRefresh() async {
        _ = await coordinator.syncNow()
        await refresh()
    }
}
