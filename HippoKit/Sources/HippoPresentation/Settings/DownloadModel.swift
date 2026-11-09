import Foundation
import Observation
import os
import LocalRepository
import SyncEngine

/// The Download sheet: how far back, what that would bring in, and the run itself.
@MainActor @Observable
public final class DownloadModel {
    public var window = DownloadWindow.default
    /// Also download captures removed from this iPhone with "Delete from iPhone".
    public var includeLocallyDeleted = false
    public private(set) var estimate: DownloadEstimate?
    public private(set) var estimating = false
    /// The window `estimate` was computed for; `run` uses this, not the live `window`.
    public private(set) var estimateWindow: DownloadWindow?
    public private(set) var estimateFailed = false
    /// "Downloading <done> of <total>…" while running.
    public private(set) var progress: (done: Int, total: Int)?
    public private(set) var result: DownloadResult?
    public private(set) var isRunning = false
    public private(set) var destinationName = ""

    @ObservationIgnored private let store: HippoStore
    @ObservationIgnored private let adapterFor: @Sendable (Destination) throws -> any StorageAdapter
    @ObservationIgnored private let isOnline: @Sendable () -> Bool
    @ObservationIgnored private var generation = 0
    private nonisolated static let log = Logger(subsystem: "com.jorgeper.hippo", category: "download")

    public init(store: HippoStore, adapterFor: @escaping @Sendable (Destination) throws -> any StorageAdapter,
                isOnline: @escaping @Sendable () -> Bool = { true }) {
        self.store = store
        self.adapterFor = adapterFor
        self.isOnline = isOnline
    }

    /// 2 weeks, 1 month, 3 months, 6 months, 1 year, everything.
    public static func windowLabel(_ window: DownloadWindow) -> String {
        guard let seconds = window.seconds else { return "everything" }
        switch Int((seconds / 86_400).rounded()) {
        case 14: return "2 weeks"
        case 30: return "1 month"
        case 90: return "3 months"
        case 180: return "6 months"
        case 365: return "1 year"
        default: return "\(Int((seconds / 86_400).rounded())) days"
        }
    }

    /// A failure line when nothing downloaded and a code says why; otherwise the count, plus failures.
    public static func resultText(_ r: DownloadResult, destinationName name: String = "") -> String {
        if r.downloaded == 0, let code = r.code {
            switch code {
            case "cancelled": return "Download stopped"
            case "offline": return "Connect to the internet to download"
            case "needs_authentication", "unavailable", "no_destination": return "Connect \(name) to download"
            default: return "Couldn't download from \(name)"
            }
        }
        var text = "Downloaded \(r.downloaded) \(r.downloaded == 1 ? "capture" : "captures")"
        if r.failed > 0 { text += " · \(r.failed) couldn't be downloaded" }
        return text
    }

    public var estimateText: String? {
        guard let estimate else { return nil }
        let noun = estimate.count == 1 ? "capture" : "captures"
        return "About \(estimate.count) \(noun), \(ByteCountFormatter.string(fromByteCount: estimate.bytes, countStyle: .file))"
    }

    public var skipText: String? {
        guard let n = estimate?.skippedLocallyDeleted, n > 0 else { return nil }
        return "Skipping \(n) you removed from this iPhone"
    }

    public var canRun: Bool { (estimate?.count ?? 0) > 0 && !estimating && isOnline() && !isRunning }
    public var resultText: String? { result.map { Self.resultText($0, destinationName: destinationName) } }

    /// Re-reads what the current window would bring in.
    public func refreshEstimate() async {
        let store = store, adapterFor = adapterFor, window = window, include = includeLocallyDeleted
        generation += 1
        let mine = generation
        estimating = true
        estimateFailed = false
        let loaded: (DownloadEstimate, String)? = await Task.detached {
            do {
                let name = try store.destinations.active()?.displayName ?? ""
                let estimate = try await store.makeDownloader(adapterFor: adapterFor)
                    .estimate(window: window, includeLocallyDeleted: include)
                return (estimate, name)
            } catch {
                Self.log.error("\("estimate_failed", privacy: .public)")
                return nil
            }
        }.value
        // A newer refresh owns the state; an older result never lands after it.
        guard mine == generation else { return }
        estimating = false
        guard let loaded else {
            estimateFailed = true
            estimate = nil
            estimateWindow = nil
            return
        }
        estimate = loaded.0
        estimateWindow = window
        destinationName = loaded.1
    }

    /// Downloads the estimated captures. Cancelling the calling task stops after the capture in progress.
    public func run() async {
        guard !isRunning, let candidates = estimate?.candidates, !candidates.isEmpty else { return }
        isRunning = true
        result = nil
        progress = (0, candidates.count)
        let downloader = store.makeDownloader(adapterFor: adapterFor), window = estimateWindow ?? window
        let task = Task.detached {
            await downloader.run(candidates, window: window, progress: { done, total in
                Task { @MainActor [weak self] in
                    guard let self, self.isRunning else { return }
                    self.progress = (done, total)
                }
            })
        }
        // Detached tasks don't inherit cancellation; pass it on so the sheet can stop a run.
        let outcome = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        isRunning = false
        progress = nil
        if let name = try? store.destinations.active()?.displayName { destinationName = name }
        result = outcome
        NotificationCenter.default.post(name: SyncCoordinator.passFinished, object: nil)
        await refreshEstimate()
    }
}
