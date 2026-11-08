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

    @ObservationIgnored private let store: HippoStore
    @ObservationIgnored private let captureID: String
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let locale: Locale
    @ObservationIgnored private let isEnabled: @Sendable (FacetKind) -> Bool
    @ObservationIgnored private let isOnline: @Sendable () -> Bool
    private nonisolated static let log = Logger(subsystem: "com.jorgeper.hippo", category: "detail")

    public init(store: HippoStore, captureID: String, now: @escaping @Sendable () -> Date = Date.init,
                calendar: Calendar = .current, locale: Locale = .current,
                isEnabled: @escaping @Sendable (FacetKind) -> Bool = { _ in true },
                isOnline: @escaping @Sendable () -> Bool = { true }) {
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
    }

    /// Reads the capture's metadata, note body and upload jobs. Leaves `detail` nil if it can't be read.
    public func load() async {
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
                let detail = CaptureDetail.make(metadata: metadata, packageURL: url, noteBody: package.noteBody(),
                                                jobs: jobs, enrichment: enrichment, tasks: tasks, isEnabled: isEnabled,
                                                isOnline: isOnline(), goldArrivedAt: goldArrivedAt, destination: { names[$0] ?? nil }, now: now,
                                                locale: locale, calendar: calendar)
                let prompt = DeletionPrompt.make(jobs: jobs, destinationName: jobs.first.flatMap { names[$0.destinationID] ?? nil }?.displayName)
                return Loaded(detail: detail, prompt: prompt)
            } catch {
                Self.log.error("\("load_failed", privacy: .public)")
                return nil
            }
        }.value
        guard let loaded else { loadFailed = true; return }
        loadFailed = false
        detail = loaded.detail
        deletionPrompt = loaded.prompt
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

    /// Deletes the capture from this iPhone.
    public func delete() async throws -> HippoStore.DeletionResult {
        let result = try await store.delete(captureID: captureID)
        detail = nil
        deletionPrompt = nil
        return result
    }
}
