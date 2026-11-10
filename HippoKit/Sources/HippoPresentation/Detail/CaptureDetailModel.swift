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
    /// Download progress (0...1) by attachment ID, present only while that attachment is downloading.
    public private(set) var restoreProgress: [String: Double] = [:]
    /// Why the last download of each attachment didn't finish; cleared when its next one starts.
    public private(set) var restoreMessages: [String: String] = [:]

    @ObservationIgnored private let store: HippoStore
    @ObservationIgnored private let captureID: String
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let locale: Locale
    @ObservationIgnored private let isEnabled: @Sendable (FacetKind) -> Bool
    @ObservationIgnored private let isOnline: @Sendable () -> Bool
    @ObservationIgnored private let sync: @Sendable () async -> Void
    @ObservationIgnored private let accountName: @Sendable (Destination) async -> String?
    /// The account holder's name of each trimmed attachment's destination, by attachment ID; set by `load()`.
    @ObservationIgnored private var restoreAccountNames: [String: String] = [:]
    @ObservationIgnored private let adapterFor: (@Sendable (Destination) throws -> any StorageAdapter)?
    private nonisolated static let log = Logger(subsystem: "com.jorgeper.hippo", category: "detail")
    /// Runs after a load's read and before it applies. Set only by tests, to finish loads out of order.
    @ObservationIgnored var beforeApply: (@Sendable () async -> Void)?
    /// Counts `load()` calls, so a read that finishes after a newer one started is dropped.
    @ObservationIgnored private var generation = 0

    public init(store: HippoStore, captureID: String, now: @escaping @Sendable () -> Date = Date.init,
                calendar: Calendar = .current, locale: Locale = .current,
                isEnabled: @escaping @Sendable (FacetKind) -> Bool = { _ in true },
                isOnline: @escaping @Sendable () -> Bool = { true },
                sync: @escaping @Sendable () async -> Void = {},
                adapterFor: (@Sendable (Destination) throws -> any StorageAdapter)? = nil,
                accountName: @escaping @Sendable (Destination) async -> String? = { _ in nil }) {
        self.accountName = accountName
        self.adapterFor = adapterFor
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
        /// By attachment ID.
        var accountNames: [String: String]
    }

    /// Reads the capture's metadata, note body and upload jobs. Leaves `detail` nil if it can't be read.
    /// Overlapping calls may finish out of order: only the most recently started one applies its result.
    public func load() async {
        generation += 1
        let mine = generation
        let store = store, id = captureID, now = now(), calendar = calendar, locale = locale
        let isEnabled = isEnabled, isOnline = isOnline, accountName = accountName
        let loaded: Loaded? = await Task.detached {
            do {
                guard let metadata = try store.index.metadata(captureID: id, layout: store.layout),
                      let dir = try store.index.relativeDirectory(captureID: id) else { return nil }
                let url = store.layout.packageURL(relativeDirectory: dir)
                let package = CommittedPackage(metadata: metadata,
                                               marker: CompletionMarker(schemaVersion: 1, captureID: id, files: []),
                                               relativeDirectory: dir, directoryURL: url)
                let jobs = try store.jobs.jobs(captureID: id)
                let trimmed = (try? store.trims.trimmed(captureID: id)) ?? []
                let names = Dictionary(uniqueKeysWithValues: Set(jobs.map(\.destinationID) + trimmed.map(\.destinationID)).map {
                    ($0, try? store.destinations.destination(id: $0))
                })
                let active = (try? store.destinations.active()) ?? nil
                var accountNames: [String: String] = [:]
                for case let d? in names.values { accountNames[d.id] = await accountName(d) }
                let enrichment = ResolvedEnrichment.load(store: store, captureID: id)
                let tasks = try store.enrichmentTasks.tasks(captureIDs: [id])
                let goldArrivedAt = (try? store.enrichments.document(.server, captureID: id))?.generatedAt
                let changed = (try? store.remoteState.changed(captureID: id)) ?? nil
                let trimmedPaths = (try? store.trims.trimmedPaths(captureID: id)) ?? []
                // The destination `deleteEverywhere` binds to: the active one when this capture has a job for it,
                // else the lowest job destination ID -- never an active one the capture has no job for.
                let boundID = HippoStore.boundDestinationID(jobs: jobs, activeID: active?.id)
                let boundName = boundID.flatMap { names[$0] ?? nil }?.displayName
                // The destination the storage line speaks for: the changed record's, else the bound one.
                let storageID = changed?.destinationID ?? boundID
                let storageName = storageID.flatMap { names[$0] ?? nil }?.displayName
                let detail = CaptureDetail.make(metadata: metadata, packageURL: url, noteBody: package.noteBody(),
                                                jobs: jobs, enrichment: enrichment, tasks: tasks,
                                                changed: changed, trimmedPaths: trimmedPaths,
                                                destinationName: storageName, trimmed: trimmed,
                                                thumbnailURL: { aid in
                                                    let url = store.layout.thumbnailURL(attachmentID: aid)
                                                    return FileManager.default.fileExists(atPath: url.path) ? url : nil
                                                },
                                                activeDestination: active, accountName: { accountNames[$0] }, isEnabled: isEnabled,
                                                isOnline: isOnline(), goldArrivedAt: goldArrivedAt,
                                                comments: PackageComments.load(directory: url).comments,
                                                destination: { names[$0] ?? nil }, now: now,
                                                locale: locale, calendar: calendar)
                let prompt = DeletionPrompt.make(jobs: jobs, destinationName: boundName)
                let everywhere = boundName.map { DeletionPrompt.everywhere(destinationName: $0) }
                return Loaded(detail: detail, prompt: prompt, everywherePrompt: everywhere, capturedAt: metadata.capturedAt,
                              accountNames: trimmed.reduce(into: [:]) { $0[$1.attachmentID] = accountNames[$1.destinationID] })
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
        restoreAccountNames = loaded.accountNames
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

    /// Downloads a trimmed attachment back into the package, then reloads. Ignored while the same
    /// attachment is already downloading.
    public func restore(attachmentID: String) async {
        guard restoreProgress[attachmentID] == nil, let adapterFor else { return }
        restoreProgress[attachmentID] = 0
        var name: String?
        if case .available(let n)? = detail?.remoteOnly[attachmentID]?.state { name = n }
        restoreMessages[attachmentID] = nil
        let store = store, id = captureID
        let result: Result<Void, RestoreError> = await Task.detached {
            do {
                try await store.makeRestorer(adapterFor: adapterFor).restore(
                    captureID: id, attachmentID: attachmentID,
                    progress: { done, total in
                        guard total > 0 else { return }
                        let fraction = min(1, max(0, Double(done) / Double(total)))
                        Task { @MainActor [weak self] in
                            guard let self, self.restoreProgress[attachmentID] != nil else { return }
                            self.restoreProgress[attachmentID] = fraction
                        }
                    })
                return .success(())
            } catch let error as RestoreError {
                return .failure(error)
            } catch {
                return .failure(.failed(code: "restore_failed"))
            }
        }.value
        restoreProgress[attachmentID] = nil
        if case .failure(let error) = result {
            Self.log.error("\("restore_failed", privacy: .public)")
            restoreMessages[attachmentID] = switch error {
            case .offline: "Connect to the internet to download"
            case .notConnected(let destinationName):
                if case .unavailable(let message)? = detail?.remoteOnly[attachmentID]?.state { message }
                else {
                    RemoteOnlyAttachment.unavailableText(destinationName: destinationName,
                                                         accountName: restoreAccountNames[attachmentID])
                }
            case .mismatch: RemoteOnlyAttachment.mismatchText(destinationName: name)
            case .notFound: RemoteOnlyAttachment.goneText(destinationName: name)
            case .failed: "Couldn't download this file"
            }
        }
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
