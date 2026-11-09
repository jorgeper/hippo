import Foundation
import Observation
import os
import CaptureCore
import LocalRepository
import SyncEngine

@MainActor @Observable
public final class CaptureDetailModel {
    public private(set) var detail: CaptureDetail?
    /// True after a failed load; cleared by the next successful one. A failed load keeps the previous `detail`.
    public private(set) var loadFailed = false
    /// The confirmation to show before `delete()`; refreshed by `load()`.
    public private(set) var deletionPrompt: DeletionPrompt?
    /// The confirmation to show before `deleteEverywhere()`; nil unless the capture has an upload job.
    public private(set) var everywherePrompt: DeletionPrompt?
    /// When the capture was taken; set by `load()`.
    public private(set) var capturedAt: Date?

    @ObservationIgnored private let store: HippoStore
    @ObservationIgnored private let captureID: String
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let locale: Locale
    @ObservationIgnored private let isEnabled: @Sendable (FacetKind) -> Bool
    @ObservationIgnored private let isOnline: @Sendable () -> Bool
    @ObservationIgnored private let sync: @Sendable () async -> Void
    private nonisolated static let log = Logger(subsystem: "com.jorgeper.hippo", category: "detail")
    /// Runs after a load's read and before it applies. Set only by tests, to finish loads out of order.
    @ObservationIgnored var beforeApply: (@Sendable () async -> Void)?
    /// Counts `load()` calls, so a read that finishes after a newer one started is dropped.
    @ObservationIgnored private var generation = 0

    public init(store: HippoStore, captureID: String, now: @escaping @Sendable () -> Date = Date.init,
                calendar: Calendar = .current, locale: Locale = .current,
                isEnabled: @escaping @Sendable (FacetKind) -> Bool = { _ in true },
                isOnline: @escaping @Sendable () -> Bool = { true },
                sync: @escaping @Sendable () async -> Void = {}) {
        self.sync = sync
        self.isEnabled = isEnabled
        self.isOnline = isOnline
        self.store = store
        self.captureID = captureID
        self.now = now
        self.calendar = calendar
        self.locale = locale
    }

    private struct Loaded: Sendable {
        var detail: CaptureDetail
        var prompt: DeletionPrompt
        var everywherePrompt: DeletionPrompt?
        var capturedAt: Date
    }

    /// Reads the capture's metadata, note body and upload jobs. Leaves `detail` nil if it can't be read.
    /// Overlapping calls may finish out of order: only the most recently started one applies its result.
    public func load() async {
        generation += 1
        let mine = generation
        let store = store, id = captureID, now = now(), calendar = calendar, locale = locale
        let isEnabled = isEnabled, isOnline = isOnline
        let loaded: Loaded? = await Task.detached {
            do {
                guard let metadata = try store.index.metadata(captureID: id, layout: store.layout),
                      let dir = try store.index.relativeDirectory(captureID: id) else { return nil }
                let url = store.layout.packageURL(relativeDirectory: dir)
                let package = CommittedPackage(metadata: metadata,
                                               marker: CompletionMarker(schemaVersion: 1, captureID: id, files: []),
                                               relativeDirectory: dir, directoryURL: url)
                let jobs = try store.jobs.jobs(captureID: id)
                let names = Dictionary(uniqueKeysWithValues: try Set(jobs.map(\.destinationID)).map {
                    ($0, try store.destinations.destination(id: $0))
                })
                let enrichment = ResolvedEnrichment.load(store: store, captureID: id)
                let tasks = try store.enrichmentTasks.tasks(captureIDs: [id])
                let goldArrivedAt = (try? store.enrichments.document(.server, captureID: id))?.generatedAt
                let changed = try store.remoteState.changed(captureID: id)
                let trimmedPaths = try store.trims.trimmedPaths(captureID: id)
                // The destination the storage line speaks for: the active one, else the first job's.
                let storageName = try store.destinations.active()?.displayName ?? jobs.first.flatMap { names[$0.destinationID] ?? nil }?.displayName
                let detail = CaptureDetail.make(metadata: metadata, packageURL: url, noteBody: package.noteBody(),
                                                jobs: jobs, enrichment: enrichment, tasks: tasks,
                                                changed: changed, trimmedPaths: trimmedPaths,
                                                destinationName: storageName, isEnabled: isEnabled,
                                                isOnline: isOnline(), goldArrivedAt: goldArrivedAt, destination: { names[$0] ?? nil }, now: now,
                                                locale: locale, calendar: calendar)
                let prompt = DeletionPrompt.make(jobs: jobs, destinationName: jobs.first.flatMap { names[$0.destinationID] ?? nil }?.displayName)
                // The destination `deleteEverywhere` binds to: the job with the lowest destination ID.
                let boundName = jobs.map(\.destinationID).min().flatMap { names[$0] ?? nil }?.displayName
                let everywhere = boundName.map { DeletionPrompt.everywhere(destinationName: $0) }
                return Loaded(detail: detail, prompt: prompt, everywherePrompt: everywhere, capturedAt: metadata.capturedAt)
            } catch {
                Self.log.error("\("load_failed", privacy: .public)")
                return nil
            }
        }.value
        if let beforeApply { await beforeApply() }
        guard mine == generation else { return }
        guard let loaded else { loadFailed = true; return }
        loadFailed = false
        detail = loaded.detail
        deletionPrompt = loaded.prompt
        everywherePrompt = loaded.everywherePrompt
        capturedAt = loaded.capturedAt
    }

    /// Makes this capture's blocked and retry-waiting uploads claimable now, then reloads.
    public func retry() async {
        let store = store, id = captureID
        do {
            _ = try await Task.detached { try store.retry(captureID: id) }.value
        } catch {
            Self.log.error("\("retry_failed", privacy: .public)")
        }
        await load()
    }

    /// Puts back what changed in the destination from this iPhone's copy, syncs, then reloads.
    public func uploadAgain() async {
        let store = store, id = captureID
        do {
            _ = try await Task.detached { try store.uploadAgain(captureID: id) }.value
        } catch {
            Self.log.error("\("upload_again_failed", privacy: .public)")
        }
        await sync()
        await load()
    }

    /// Deletes the capture from this iPhone.
    public func delete() async throws -> HippoStore.DeletionResult {
        let result = try await store.delete(captureID: captureID)
        generation += 1  // a load still in flight must not bring the deleted capture back
        detail = nil
        deletionPrompt = nil
        everywherePrompt = nil
        return result
    }

    /// Deletes the capture from this iPhone and queues its deletion in the destination.
    public func deleteEverywhere() async throws -> HippoStore.DeletionResult {
        let result = try await store.deleteEverywhere(captureID: captureID)
        generation += 1
        detail = nil
        deletionPrompt = nil
        everywherePrompt = nil
        return result
    }
}
