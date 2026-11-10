import Foundation
import Testing
import Synchronization
import CaptureCore
import FilesystemAdapter
import LocalRepository
import SyncEngine
@testable import HippoPresentation

private let old = Date(timeIntervalSince1970: 1_700_000_000)

private final class Ticks: Sendable {
    private let values = Mutex<[[Int]]>([])
    func add(_ done: Int, _ total: Int) { values.withLock { $0.append([done, total]) } }
    var all: [[Int]] { values.withLock { $0 } }
}

@MainActor
private struct Harness {
    let t: TestStore
    let remote: URL
    let provider: FakeStorageProvider
    let coordinator: SyncCoordinator
    let suite: String

    init() throws {
        t = try TestStore()
        remote = t.base.appendingPathComponent("Remote", isDirectory: true)
        provider = FakeStorageProvider(root: remote)
        suite = "hippo-space-\(UUID().uuidString)"
        coordinator = SyncCoordinator(store: t.store, registry: ProviderRegistry([provider]), ownerPrefix: "test",
                                      appVersion: "0.1.0",
                                      settings: AppSettings(defaults: UserDefaults(suiteName: suite)!))
    }

    func cleanup() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        t.cleanup()
    }

    func connect() throws {
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        _ = try t.store.destinations.connect(provider.destination)
    }

    func model(online: Bool = true) -> SpaceSaveModel {
        let provider = provider
        return SpaceSaveModel(store: t.store, adapterFor: { try provider.makeAdapter(for: $0) }, isOnline: { online })
    }
}

@MainActor
struct SpaceSaveTests {
    @Test func labels() {
        #expect(SpaceSaveOptions.ageSteps.map(SpaceSaveModel.ageLabel) == ["1 week", "1 month", "3 months", "1 year"])
        #expect(SpaceSaveOptions.sizeSteps.map(SpaceSaveModel.sizeLabel) == ["1 MB", "10 MB", "50 MB", "100 MB"])
    }

    @Test func estimateTextAndCanRun() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.connect()
        let m = h.model()
        await m.refreshEstimate()
        #expect(m.estimate == SpaceSaveEstimate(captures: 0, files: 0, bytes: 0))
        #expect(m.estimateText == "Nothing older than 1 month and larger than 10 MB is in Developer folder yet")
        #expect(!m.canRun)
        m.options = SpaceSaveOptions(olderThan: SpaceSaveOptions.ageSteps[0], largerThan: SpaceSaveOptions.sizeSteps[3])
        await m.refreshEstimate()
        #expect(m.estimateText == "Nothing older than 1 week and larger than 100 MB is in Developer folder yet")

        _ = try await h.t.note("hello there", at: old)
        _ = await h.coordinator.syncNow()
        m.options = SpaceSaveOptions(olderThan: SpaceSaveOptions.ageSteps[0], largerThan: 1)
        await m.refreshEstimate()
        #expect(m.estimate?.files == 1)
        #expect(m.estimateText == "Frees about \(ByteCountFormatter.string(fromByteCount: m.estimate!.bytes, countStyle: .file)) from 1 capture")
        #expect(m.canRun)
        #expect(m.offlineFooter == nil)

        let offline = h.model(online: false)
        offline.options = m.options
        await offline.refreshEstimate()
        #expect(!offline.canRun)
        #expect(offline.offlineFooter == "Connect to the internet to save space.")
    }

    @Test func runReportsProgressAndResult() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.connect()
        let p = try await h.t.note("hello there", at: old)
        _ = await h.coordinator.syncNow()
        let m = h.model()
        m.options = SpaceSaveOptions(olderThan: SpaceSaveOptions.ageSteps[0], largerThan: 1)
        await m.refreshEstimate()
        let bytes = try #require(m.estimate?.bytes)

        await m.run()

        #expect(m.result == SpaceSaveResult(trimmed: 1, bytes: bytes, skipped: 0, code: nil))
        #expect(m.resultText == "Freed \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) from 1 files")
        #expect(m.progress == nil)
        #expect(!m.isRunning)
        #expect(m.estimate?.files == 0)
        #expect(try h.t.store.trims.trimmed(captureID: p.metadata.captureID).count == 1)
    }

    @Test func resultTextMentionsSkipped() {
        let text = SpaceSaveModel.resultText(SpaceSaveResult(trimmed: 2, bytes: 3_000_000, skipped: 1, code: "x"))
        #expect(text.hasSuffix("from 2 files · 1 skipped"))
    }
}
