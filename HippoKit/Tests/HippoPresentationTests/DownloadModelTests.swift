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

    func model(online: Bool = true) -> DownloadModel {
        let provider = providerB
        return DownloadModel(store: b.store, adapterFor: { try provider.makeAdapter(for: $0) }, isOnline: { online })
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
        #expect(posts.total == 1)
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
}
