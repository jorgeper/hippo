import Foundation
import Testing
import Synchronization
import LocalRepository
import FilesystemAdapter
import SyncEngine
@testable import HippoPresentation

private final class Counter: Sendable {
    private let value = Mutex(0)
    func bump() { value.withLock { $0 += 1 } }
    var total: Int { value.withLock { $0 } }
}

/// Counts `passFinished` posts with a nil object (the model's own; the coordinator posts itself).
private final class Posts: @unchecked Sendable {
    private let counter = Counter()
    private let token: NSObjectProtocol
    init() {
        let counter = counter
        token = NotificationCenter.default.addObserver(forName: SyncCoordinator.passFinished, object: nil, queue: nil) { note in
            if note.object == nil { counter.bump() }
        }
    }
    deinit { NotificationCenter.default.removeObserver(token) }
    var total: Int { counter.total }
}

/// What a `HookedAdapter` does: fail every download offline, and/or hold the next folder listing.
private final class Hooks: Sendable {
    let failDownloads: Bool
    private let holdNext = Mutex(false)
    private let (startedStream, startedSignal) = AsyncStream<Void>.makeStream()
    private let (releaseStream, releaseSignal) = AsyncStream<Void>.makeStream()

    init(failDownloads: Bool = false) { self.failDownloads = failDownloads }

    func holdNextListing() { holdNext.withLock { $0 = true } }
    func started() async { for await _ in startedStream { return } }
    func release() { releaseSignal.finish() }

    func beforeListing() async {
        guard holdNext.withLock({ let was = $0; $0 = false; return was }) else { return }
        startedSignal.yield()
        for await _ in releaseStream {}
    }
}

private final class HookedAdapter: StorageAdapter {
    private let base: any StorageAdapter
    private let hooks: Hooks
    init(_ base: any StorageAdapter, _ hooks: Hooks) { self.base = base; self.hooks = hooks }

    var capabilities: StorageCapabilities { base.capabilities }
    func replaceFile(localURL: URL, relativePath: String, expected: FileIntegrity) async throws -> UploadReceipt {
        try await base.replaceFile(localURL: localURL, relativePath: relativePath, expected: expected)
    }
    func listChanges(under prefix: String, cursor: String?) async throws -> ChangePage {
        try await base.listChanges(under: prefix, cursor: cursor)
    }
    func downloadFile(relativePath: String, to localURL: URL, maxBytes: Int64,
                      progress: (@Sendable (Int64) -> Void)?) async throws -> RemoteFileInfo {
        if hooks.failDownloads { throw StorageError.offline }
        return try await base.downloadFile(relativePath: relativePath, to: localURL, maxBytes: maxBytes, progress: progress)
    }
    func deleteFolder(relativePath: String) async throws { try await base.deleteFolder(relativePath: relativePath) }
    func latestCursor(under prefix: String) async throws -> String { try await base.latestCursor(under: prefix) }
    func listFolder(relativePath: String, recursive: Bool, cursor: String?) async throws -> ListPage {
        await hooks.beforeListing()
        return try await base.listFolder(relativePath: relativePath, recursive: recursive, cursor: cursor)
    }
    func thumbnail(relativePath: String, maxPixelSize: Int) async throws -> Data? {
        try await base.thumbnail(relativePath: relativePath, maxPixelSize: maxPixelSize)
    }
    func validateDestination() async throws { try await base.validateDestination() }
    func ensureContainer(relativePath: String) async throws { try await base.ensureContainer(relativePath: relativePath) }
    func inspectFile(relativePath: String) async throws -> RemoteFileInfo? {
        try await base.inspectFile(relativePath: relativePath)
    }
    func verify(remote: RemoteFileInfo, localURL: URL, expected: FileIntegrity) async throws -> VerificationEvidence? {
        try await base.verify(remote: remote, localURL: localURL, expected: expected)
    }
    func uploadFile(localURL: URL, relativePath: String, expected: FileIntegrity, checkpoint: UploadCheckpoint?,
                    saveCheckpoint: @Sendable (UploadCheckpoint) async throws -> Void) async throws -> UploadReceipt {
        try await base.uploadFile(localURL: localURL, relativePath: relativePath, expected: expected,
                                  checkpoint: checkpoint, saveCheckpoint: saveCheckpoint)
    }
}

/// Two phones sharing one destination folder: A uploads two captures; this phone (B) uploaded one of its own
/// and then removed it, so the folder holds three and B holds none.
@MainActor
private struct Harness {
    let a: TestStore
    let b: TestStore
    let remote: URL
    let providerB: FakeStorageProvider
    let suites: [String]
    let removedID: String
    let aIDs: [String]

    init(fromA: Int = 2) async throws {
        a = try TestStore()
        b = try TestStore()
        remote = a.base.appendingPathComponent("Remote", isDirectory: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        let providerA = FakeStorageProvider(root: remote)
        providerB = FakeStorageProvider(root: remote)
        suites = ["hippo-dl-a-\(UUID().uuidString)", "hippo-dl-b-\(UUID().uuidString)"]
        func coordinator(_ t: TestStore, _ p: FakeStorageProvider, _ suite: String) -> SyncCoordinator {
            SyncCoordinator(store: t.store, registry: ProviderRegistry([p]), ownerPrefix: "test", appVersion: "0.1.0",
                            settings: AppSettings(defaults: UserDefaults(suiteName: suite)!))
        }
        _ = try a.store.destinations.connect(providerA.destination)
        _ = try b.store.destinations.connect(providerB.destination)
        let now = Date()
        var ids: [String] = []
        for n in 1...fromA {
            let p = try await a.note("capture \(n) from A", at: now.addingTimeInterval(-Double(n) * 86_400))
            ids.append(p.metadata.captureID)
        }
        aIDs = ids
        let mine = try await b.note("mine", at: now.addingTimeInterval(-3 * 86_400))
        removedID = mine.metadata.captureID
        _ = await coordinator(a, providerA, suites[0]).syncNow()
        _ = await coordinator(b, providerB, suites[1]).syncNow()
        _ = try await b.store.delete(captureID: removedID)
    }

    func cleanup() {
        suites.forEach { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) }
        a.cleanup()
        b.cleanup()
    }

    func model(online: Bool = true, hooks: Hooks? = nil) -> DownloadModel {
        let provider = providerB
        return DownloadModel(store: b.store, adapterFor: {
            let base = try provider.makeAdapter(for: $0)
            return hooks.map { HookedAdapter(base, $0) } ?? base
        }, isOnline: { online })
    }
}

private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

@MainActor
struct DownloadModelTests {
    @Test func labels() {
        #expect(DownloadWindow.steps.map { DownloadModel.windowLabel(DownloadWindow(seconds: $0)) }
                == ["2 weeks", "1 month", "3 months", "6 months", "1 year", "everything"])
    }

    @Test func estimateAndSkipText() async throws {
        let h = try await Harness()
        defer { h.cleanup() }
        let m = h.model()
        #expect(m.window == .default)
        #expect(!m.includeLocallyDeleted)
        await m.refreshEstimate()
        let e = try #require(m.estimate)
        #expect(e.count == 2)
        #expect(m.estimateText == "About 2 captures, \(bytes(e.bytes))")
        #expect(m.skipText == "Skipping 1 you removed from this iPhone")
        #expect(m.canRun)
        #expect(!m.estimating)
        #expect(!m.estimateFailed)
    }

    @Test func includeThemChangesEstimate() async throws {
        let h = try await Harness()
        defer { h.cleanup() }
        let m = h.model()
        await m.refreshEstimate()
        let before = try #require(m.estimate)
        m.includeLocallyDeleted = true
        await m.refreshEstimate()
        let after = try #require(m.estimate)
        #expect(after.count == before.count + 1)
        #expect(m.estimateText == "About \(after.count) captures, \(bytes(after.bytes))")
        #expect(m.skipText == "Skipping 1 you removed from this iPhone")
    }

    @Test func singularEstimateText() async throws {
        let h = try await Harness(fromA: 1)
        defer { h.cleanup() }
        let m = h.model()
        await m.refreshEstimate()
        let e = try #require(m.estimate)
        #expect(e.count == 1)
        #expect(m.estimateText == "About 1 capture, \(bytes(e.bytes))")
    }

    @Test func runReportsProgressAndResultText() async throws {
        let h = try await Harness()
        defer { h.cleanup() }
        let posts = Posts()
        let m = h.model()
        await m.refreshEstimate()
        await m.run()
        #expect(m.result == DownloadResult(downloaded: 2, skipped: 0, failed: 0, code: nil))
        #expect(m.resultText == "Downloaded 2 captures")
        #expect(m.progress == nil)
        #expect(try h.b.store.index.count() == 2)
        for id in h.aIDs { #expect(try h.b.store.index.relativeDirectory(captureID: id) != nil) }
        #expect(posts.total >= 1)  // other tests post the same name in parallel
        #expect(m.estimate?.count == 0)
        #expect(!m.canRun)
    }

    @Test func resultTextFormats() {
        #expect(DownloadModel.resultText(DownloadResult(downloaded: 1, skipped: 0, failed: 0, code: nil)) == "Downloaded 1 capture")
        #expect(DownloadModel.resultText(DownloadResult(downloaded: 2, skipped: 0, failed: 1, code: "x"))
                == "Downloaded 2 captures · 1 couldn't be downloaded")
    }

    @Test func offlineDisablesRun() async throws {
        let h = try await Harness()
        defer { h.cleanup() }
        let m = h.model(online: false)
        await m.refreshEstimate()
        #expect(m.estimate?.count == 2)
        #expect(!m.canRun)
    }

    @Test func failureLines() {
        func text(_ code: String) -> String {
            DownloadModel.resultText(DownloadResult(downloaded: 0, skipped: 0, failed: 0, code: code), destinationName: "Dropbox")
        }
        #expect(text("cancelled") == "Download stopped")
        #expect(text("offline") == "Connect to the internet to download")
        for code in ["needs_authentication", "unavailable", "no_destination"] { #expect(text(code) == "Connect Dropbox to download") }
        #expect(text("invalid_package") == "Couldn't download from Dropbox")
        #expect(DownloadModel.resultText(DownloadResult(downloaded: 1, skipped: 0, failed: 1, code: "offline"), destinationName: "Dropbox")
                == "Downloaded 1 capture · 1 couldn't be downloaded")
    }

    @Test func offlineFailureShowsConnectLine() async throws {
        let h = try await Harness()
        defer { h.cleanup() }
        let m = h.model(hooks: Hooks(failDownloads: true))
        await m.refreshEstimate()
        await m.run()
        #expect(m.result?.downloaded == 0)
        #expect(m.result?.code == "offline")
        #expect(m.resultText == "Connect to the internet to download")
        #expect(try h.b.store.index.count() == 0)
    }

    @Test func cancelledRunShowsStopped() async throws {
        let h = try await Harness()
        defer { h.cleanup() }
        let m = h.model()
        await m.refreshEstimate()
        let task = Task { await m.run() }
        task.cancel()
        await task.value
        #expect(m.result?.downloaded == 0)
        #expect(m.resultText == "Download stopped")
    }

    @Test func staleEstimateIsDroppedAndBlocksRun() async throws {
        let h = try await Harness()
        defer { h.cleanup() }
        let hooks = Hooks()
        let m = h.model(hooks: hooks)
        await m.refreshEstimate()
        #expect(m.canRun)
        #expect(m.estimateWindow == .default)

        hooks.holdNextListing()
        let first = Task { await m.refreshEstimate() }
        await hooks.started()
        #expect(m.estimating)
        #expect(!m.canRun)

        let twoWeeks = DownloadWindow(seconds: 14 * 86_400)
        m.window = twoWeeks
        await m.refreshEstimate()
        #expect(m.estimateWindow == twoWeeks)
        #expect(!m.estimating)

        hooks.release()
        await first.value
        #expect(m.estimateWindow == twoWeeks)
        #expect(!m.estimating)
    }
}
