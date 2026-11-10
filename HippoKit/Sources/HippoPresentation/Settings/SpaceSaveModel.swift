import Foundation
import Observation
import os
import LocalRepository
import SyncEngine

/// The Save space sheet: how old and how large, what that would free, and the run itself.
@MainActor @Observable
public final class SpaceSaveModel {
    public var options = SpaceSaveOptions.default
    public private(set) var estimate: SpaceSaveEstimate?
    /// "Trimming <done> of <total>…" while running.
    public private(set) var progress: (done: Int, total: Int)?
    public private(set) var result: SpaceSaveResult?
    public private(set) var isRunning = false
    public private(set) var destinationName = ""

    @ObservationIgnored private let store: HippoStore
    @ObservationIgnored private let adapterFor: @Sendable (Destination) throws -> any StorageAdapter
    @ObservationIgnored private let isOnline: @Sendable () -> Bool
    private nonisolated static let log = Logger(subsystem: "com.jorgeper.hippo", category: "space")

    public init(store: HippoStore, adapterFor: @escaping @Sendable (Destination) throws -> any StorageAdapter,
                isOnline: @escaping @Sendable () -> Bool = { true }) {
        self.store = store
        self.adapterFor = adapterFor
        self.isOnline = isOnline
    }

    public static func ageLabel(_ seconds: TimeInterval) -> String {
        switch Int((seconds / 86_400).rounded()) {
        case 7: "1 week"
        case 30: "1 month"
        case 90: "3 months"
        case 365: "1 year"
        default: "\(Int((seconds / 86_400).rounded())) days"
        }
    }

    public static func sizeLabel(_ bytes: Int64) -> String { "\(bytes / 1_000_000) MB" }

    public static func resultText(_ r: SpaceSaveResult) -> String {
        var text = "Freed \(ByteCountFormatter.string(fromByteCount: r.bytes, countStyle: .file)) from \(r.trimmed) files"
        if r.skipped > 0 { text += " · \(r.skipped) skipped" }
        return text
    }

    public var estimateText: String {
        guard let estimate else { return "" }
        guard estimate.files > 0 else {
            return "Nothing older than \(Self.ageLabel(options.olderThan)) and larger than \(Self.sizeLabel(options.largerThan)) is in \(destinationName) yet"
        }
        let noun = estimate.captures == 1 ? "capture" : "captures"
        return "Frees about \(ByteCountFormatter.string(fromByteCount: estimate.bytes, countStyle: .file)) from \(estimate.captures) \(noun)"
    }

    public var note: String { "These files will then be only in \(destinationName)." }
    public var canRun: Bool { (estimate?.files ?? 0) > 0 && isOnline() && !isRunning }
    public var offlineFooter: String? { isOnline() ? nil : "Connect to the internet to save space." }
    public var resultText: String? { result.map(Self.resultText) }

    /// Re-reads what the current options would free.
    public func refreshEstimate() async {
        let store = store, adapterFor = adapterFor, options = options
        let loaded: (SpaceSaveEstimate, String)? = await Task.detached {
            do {
                let name = try store.destinations.active()?.displayName ?? ""
                return (try store.makeSpaceSaver(adapterFor: adapterFor).estimate(options), name)
            } catch {
                Self.log.error("\("estimate_failed", privacy: .public)")
                return nil
            }
        }.value
        guard let loaded, options == self.options else { return }
        estimate = loaded.0
        destinationName = loaded.1
    }

    /// Trims what the options select. Cancelling the calling task stops after the file in progress.
    public func run() async {
        guard !isRunning else { return }
        isRunning = true
        result = nil
        progress = (0, 0)
        let saver = store.makeSpaceSaver(adapterFor: adapterFor), options = options
        let task = Task.detached {
            await saver.run(options, progress: { done, total in
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
        result = outcome
        await refreshEstimate()
    }
}
