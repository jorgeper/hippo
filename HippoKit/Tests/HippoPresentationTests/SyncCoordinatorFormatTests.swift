import Foundation
import Testing
import LocalRepository
import SyncEngine
@testable import HippoPresentation

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@MainActor
private struct Harness {
    let t: TestStore
    let remote: URL
    let provider: FakeStorageProvider
    let suite = "hippo-format-\(UUID().uuidString)"

    init() throws {
        t = try TestStore()
        remote = t.base.appendingPathComponent("Remote", isDirectory: true)
        provider = FakeStorageProvider(root: remote)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        _ = try t.store.destinations.connect(provider.destination)
    }

    func cleanup() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        t.cleanup()
    }

    /// A coordinator whose format uploader asks `formatAdapter` for its adapter (the registry's by default).
    func coordinator(formatAdapter: (@Sendable (Destination) throws -> any StorageAdapter)? = nil) throws -> SyncCoordinator {
        let bundle = try FormatBundle.load(docsDirectory: repoRoot.appendingPathComponent("docs"),
                                           schemaDirectory: repoRoot.appendingPathComponent("schema"))
        let provider = provider
        let uploader = t.store.makeFormatUploader(bundle: bundle, adapterFor: formatAdapter ?? { try provider.makeAdapter(for: $0) })
        return SyncCoordinator(store: t.store, registry: ProviderRegistry([provider]), ownerPrefix: "test",
                               appVersion: "0.1.0", settings: AppSettings(defaults: UserDefaults(suiteName: suite)!),
                               formatUploader: uploader)
    }
}

@MainActor
struct SyncCoordinatorFormatTests {
    @Test func passUploadsTheFormatFilesBeforeTheWorkerRounds() async throws {
        let h = try Harness(); defer { h.cleanup() }
        _ = try await h.t.note("hello", at: Date(timeIntervalSince1970: 1_800_000_000))
        let coordinator = try h.coordinator()
        let result = await coordinator.syncNow()
        #expect(result.synced == 1)
        let ops = h.provider.faults.operations
        let format = try #require(ops.firstIndex(of: "replace format/README.md"))
        let capture = try #require(ops.firstIndex { $0.hasPrefix("upload captures/") })
        #expect(format < capture)
        #expect(ops.last { $0.hasPrefix("replace ") } != nil)
        #expect(FileManager.default.fileExists(atPath: h.remote.appendingPathComponent("README.md").path))
    }

    @Test func aFailedFormatUploadDoesNotStopThePass() async throws {
        let h = try Harness(); defer { h.cleanup() }
        let p = try await h.t.note("hello", at: Date(timeIntervalSince1970: 1_800_000_000))
        let coordinator = try h.coordinator(formatAdapter: { _ in throw StorageError.offline })
        let result = await coordinator.syncNow()
        #expect(result.synced == 1 && result.failed == 0)
        let upload = h.t.store.log.globalEvents(limit: 50, before: nil).filter { $0.event == .formatUploadFailed }
        #expect(upload.count == 1)
        #expect(upload.first?.code == "offline")
        #expect(FileManager.default.fileExists(atPath: h.remote.appendingPathComponent(p.relativeDirectory).path))
    }
}
