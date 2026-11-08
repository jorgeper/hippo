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
/// tasks until a pass runs nothing (bounded by `maxRoundsPerPass` and a no-progress check), then syncs
/// if anything ran, so new silver uploads.
@MainActor
enum EnrichmentScheduling {
    /// Fixed strings only: never IDs, paths, URLs or content.
    private nonisolated static let log = Logger(subsystem: "com.jorgeper.hippo", category: "enrichment")
    /// The kinds the app's enrichers produce (the Settings switches).
    nonisolated static let kinds: [FacetKind] = [.linkPreview, .place, .textRecognition, .transcript,
                                                 .dataDetection, .sourceAppGuess]

    private static var runner: EnrichmentRunner?
    /// At most this many `runPending` rounds per pass; leftover work waits for the next trigger.
    nonisolated static let maxRoundsPerPass = 20

    private static var current: Task<Void, Never>?
    /// Set when a call joins the run in flight: the `cancels` count at that moment. A rerun is dropped
    /// only by a `cancel()` made after it was asked for.
    private static var rerunRequestedAt: Int?
    /// False until launch recovery has finished: recovery sweeps enrichment staging, which enrichers
    /// write into, so no pass may overlap it.
    private static var ready = false
    private static var readyWaiters: [CheckedContinuation<Void, Never>] = []
    /// The running task, for `cancel()` from any thread (expiry handlers), and how many times `cancel()`
    /// has been called.
    private struct Control {
        var task: Task<Void, Never>?
        var cancels = 0
    }
    private nonisolated static let control = OSAllocatedUnfairLock(initialState: Control())

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
            rerunRequestedAt = control.withLock { $0.cancels }
            await current.value
            return
        }
        let runner = runner(for: env)
        let task = Task { @MainActor in
            repeat {
                rerunRequestedAt = nil
                await pass(runner, coordinator)
            } while rerunRequestedAt != nil && !Task.isCancelled
            current = nil
            let cancels = control.withLock { c -> Int in
                c.task = nil
                return c.cancels
            }
            // Asked for while a cancelled run was unwinding, and not cancelled since: start afresh.
            if let requested = rerunRequestedAt {
                rerunRequestedAt = nil
                if requested == cancels { Task { await run(env, reason: "rerun") } }
            }
        }
        current = task
        control.withLock { $0.task = task }
        await task.value
    }

    /// Stops the run in flight: the runner finishes no new task, and no follow-up sync starts. Reruns
    /// asked for before this call are dropped. Safe from any thread.
    nonisolated static func cancel() {
        let task = control.withLock { c -> Task<Void, Never>? in
            c.cancels += 1
            return c.task
        }
        task?.cancel()
    }

    private static func pass(_ runner: EnrichmentRunner, _ coordinator: SyncCoordinator) async {
        await BackgroundActivity.run(name: "enrichment", onExpire: { EnrichmentScheduling.cancel() }) {
            do { try await runner.schedule() } catch {
                log.error("\("enrichment_schedule_failed", privacy: .public)")
            }
            // Bounded: at most `maxRoundsPerPass` rounds, and it stops after two rounds in a row where
            // every task run failed (for example, results that can't be saved while the disk is full).
            var ranAny = false
            var roundsWithoutProgress = 0
            for _ in 0..<maxRoundsPerPass {
                if Task.isCancelled { break }
                let result = await runner.runPending()
                guard result.ran > 0 else { break }
                ranAny = true
                roundsWithoutProgress = result.failed >= result.ran ? roundsWithoutProgress + 1 : 0
                if roundsWithoutProgress >= 2 {
                    log.error("\("enrichment_no_progress", privacy: .public)")
                    break
                }
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
            LinkPreviewEnricher(http: URLSessionHTTPFetcher(), redirects: URLSessionRedirectResolver(),
                                metadata: LinkPresentationFetcher(),
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
            isOnline: { network.isOnline }, log: store.log)
        runner = made
        return made
    }

    /// The enrichers' versions for the kinds switched on in Settings, for `EnrichmentTaskStore.hasWork`.
    static func enabledVersions(_ env: AppEnvironment) -> [FacetKind: Int] {
        let enabled = enabledKinds()
        return runner(for: env).versions.filter { enabled.contains($0.key) }
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
