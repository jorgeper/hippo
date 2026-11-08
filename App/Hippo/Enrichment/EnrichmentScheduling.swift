import Foundation
import Network
import os
import CaptureCore
import SyncEngine
import HippoPresentation
import Enrichment

/// When silver enrichment runs (design §10), in the app process only: the Share Extension never links
/// this file or the `Enrichment` product. Triggers: launch (after recovery and the first sync), every
/// activation, an in-app save, a Settings switch turned on, and the background task after its sync pass.
///
/// `run` is a coalescing single flight: one pass task at a time, and a call made while it runs asks for
/// one more round and waits for it. Each round runs inside `BackgroundActivity`: it schedules, runs due
/// tasks until a pass runs nothing, then syncs if anything ran, so new silver uploads.
@MainActor
enum EnrichmentScheduling {
    /// Fixed strings only: never IDs, paths, URLs or content.
    private nonisolated static let log = Logger(subsystem: "com.jorgeper.hippo", category: "enrichment")
    /// The kinds the app's enrichers produce (the Settings switches).
    nonisolated static let kinds: [FacetKind] = [.linkPreview, .place, .textRecognition, .transcript,
                                                 .dataDetection, .sourceAppGuess]

    private static var runner: EnrichmentRunner?
    private static var current: Task<Void, Never>?
    private static var rerun = false
    /// False until launch recovery has finished: recovery sweeps enrichment staging, which enrichers
    /// write into, so no pass may overlap it.
    private static var ready = false
    private static var readyWaiters: [CheckedContinuation<Void, Never>] = []
    /// The running task, for `cancel()` from any thread (expiry handlers).
    private nonisolated static let cancelHandle = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    /// Call once launch recovery has finished; runs held back until then go ahead.
    static func markLaunchRecovered() {
        ready = true
        let waiting = readyWaiters
        readyWaiters = []
        for c in waiting { c.resume() }
    }

    /// Runs enrichment now, or joins the run in flight (which then goes round once more). Returns when
    /// the run it joined has finished. `reason` is a fixed string, for logs.
    static func run(_ env: AppEnvironment, reason: String) async {
        guard env.processKind == .app, let coordinator = env.coordinator else { return }
        if !ready { await withCheckedContinuation { readyWaiters.append($0) } }
        log.info("\("enrichment_run", privacy: .public) \(reason, privacy: .public)")
        if let current {
            rerun = true
            await current.value
            return
        }
        let runner = runner(for: env)
        let task = Task { @MainActor in
            repeat {
                rerun = false
                await pass(runner, coordinator)
            } while rerun && !Task.isCancelled
            current = nil
            cancelHandle.withLock { $0 = nil }
        }
        current = task
        cancelHandle.withLock { $0 = task }
        await task.value
    }

    /// Stops the run in flight: the runner finishes no new task, and no follow-up sync starts. Safe from
    /// any thread.
    nonisolated static func cancel() {
        cancelHandle.withLock { $0 }?.cancel()
    }

    private static func pass(_ runner: EnrichmentRunner, _ coordinator: SyncCoordinator) async {
        await BackgroundActivity.run(name: "enrichment", onExpire: { EnrichmentScheduling.cancel() }) {
            do { try await runner.schedule() } catch {
                log.error("\("enrichment_schedule_failed", privacy: .public)")
            }
            var ranAny = false
            while !Task.isCancelled {
                let result = await runner.runPending()
                guard result.ran > 0 else { break }
                ranAny = true
            }
            if ranAny && !Task.isCancelled {
                await SyncScheduling.runPass(coordinator, name: "enrichment-sync")
            }
        }
    }

    // MARK: Runner

    /// Built on first use from the app's store, with all six enrichers.
    private static func runner(for env: AppEnvironment) -> EnrichmentRunner {
        if let runner { return runner }
        let store = env.store
        let staging = store.layout.enrichmentStagingDir
        let network = NetworkStatus.shared
        let settings = LocationService.settings
        let enrichers: [any Enricher] = [
            LinkPreviewEnricher(http: URLSessionHTTPFetcher(), metadata: LinkPresentationFetcher(),
                                tempDirectory: staging),
            PlaceEnricher(lookup: MapKitPlaceLookup()),
            TextRecognitionEnricher(),
            TranscriptEnricher(transcriber: SpeechTranscriberService(),
                               locale: TranscriptLocale.choose(current: .current)),
            DataDetectionEnricher(),
            SourceAppGuessEnricher(),
        ]
        let made = EnrichmentRunner(
            layout: store.layout, index: store.index, tasks: store.enrichmentTasks, store: store.enrichments,
            enrichers: enrichers,
            producer: EnrichmentProducer(name: "hippo-ios", version: env.producer.appVersion,
                                         build: env.producer.build),
            isEnabled: { settings.isEnrichmentEnabled($0) },
            isOnline: { network.isOnline })
        runner = made
        return made
    }

    /// The kinds switched on in Settings.
    nonisolated static func enabledKinds() -> Set<FacetKind> {
        let settings = LocationService.settings
        return Set(kinds.filter { settings.isEnrichmentEnabled($0) })
    }
}

/// Whether the device has a usable network path, from one process-wide `NWPathMonitor`. Optimistic
/// until the first update: a fetch made offline defers itself without spending an attempt.
/// `@unchecked`: the monitor is touched only in `init`; the status is behind a lock.
final class NetworkStatus: @unchecked Sendable {
    static let shared = NetworkStatus()

    private let monitor = NWPathMonitor()
    private let online = OSAllocatedUnfairLock(initialState: true)

    private init() {
        monitor.pathUpdateHandler = { [online] path in
            online.withLock { $0 = path.status == .satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "com.jorgeper.hippo.network-status", qos: .utility))
    }

    var isOnline: Bool { online.withLock { $0 } }
}
