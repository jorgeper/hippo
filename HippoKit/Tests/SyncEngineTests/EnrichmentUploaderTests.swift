import Foundation
import CryptoKit
import Testing
import CaptureCore
import LocalRepository
import SyncEngine
import FilesystemAdapter

private func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<SyncPassResult, Never>?
    func set(_ t: Task<SyncPassResult, Never>) { lock.lock(); task = t; lock.unlock() }
    func cancel() { lock.lock(); let t = task; lock.unlock(); t?.cancel() }
}

private struct Setup {
    let h: SyncHarness
    let enrichments: EnrichmentStore
    let pkg: CommittedPackage
    let assetBytes = Data("thumbnail-bytes".utf8)
    var assetPath: String { "assets/\(hex(assetBytes)).jpg" }
    var remoteDir: String { try! EnrichmentPaths.remoteDirectory(.device, packageDirectory: pkg.relativeDirectory) }

    init(syncPackage: Bool = true) async throws {
        h = try SyncHarness()
        enrichments = EnrichmentStore(db: h.db, layout: h.layout)
        pkg = try await h.capture()
        if syncPackage { _ = await h.worker().runOnce() }
        try writeDoc(text: "first")
    }

    /// Writes a device document that references one asset.
    func writeDoc(text: String) throws {
        let tmp = h.root.appendingPathComponent("asset-\(UUID().uuidString)")
        try assetBytes.write(to: tmp)
        let ref: JSONValue = .object(["relative_path": .string(assetPath), "sha256": .string(hex(assetBytes)),
                                      "byte_count": .number(Double(assetBytes.count))])
        let facet = Facet(version: 1, status: .ok, generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                          provenance: "test", data: .object(["text": .string(text), "thumb": ref]))
        let digest = try #require(try h.index.packageDigest(captureID: pkg.metadata.captureID))
        let doc = EnrichmentDocument(schemaVersion: 1, captureID: pkg.metadata.captureID, layer: .device,
                                     packageDigest: digest, producer: EnrichmentProducer(name: "t", version: "1", build: "1"),
                                     generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                     facets: [FacetKind.summary.rawValue: facet])
        try enrichments.write(doc, newAssets: [assetPath: tmp])
    }

    func uploader(_ adapter: (any StorageAdapter)? = nil) -> EnrichmentUploader {
        let a: any StorageAdapter = adapter ?? h.adapter
        let clock = h.clock
        return EnrichmentUploader(layout: h.layout, destinations: h.destinations, enrichments: enrichments,
                                  adapterFor: { _ in a }, now: { clock.now }, random: { 1 })
    }

    var localJSON: Data {
        try! Data(contentsOf: h.layout.enrichmentDirectory(.device, captureID: pkg.metadata.captureID)
            .appendingPathComponent("enrichment.json"))
    }
    var remoteJSONURL: URL { h.remote.appendingPathComponent(remoteDir + "/enrichment.json") }
    var candidates: [String] {
        (try? enrichments.uploadCandidates(destinationID: "dest-fs", now: h.clock.now, limit: 10).map(\.captureID)) ?? []
    }
    var writes: [String] { h.faults.operations.filter { $0.hasPrefix("upload ") || $0.hasPrefix("replace ") } }
}

@Suite struct EnrichmentUploaderTests {
    @Test func uploadsOnlyAfterPackageSynced() async throws {
        let s = try await Setup(syncPackage: false); defer { s.h.cleanup() }

        let before = await s.uploader().runOnce()
        #expect(before.synced == 0)
        #expect(!FileManager.default.fileExists(atPath: s.h.remote.appendingPathComponent("enrichments").path))

        _ = await s.h.worker().runOnce()
        let after = await s.uploader().runOnce()
        #expect(after == SyncPassResult(synced: 1, failed: 0, idle: false))
        #expect(try Data(contentsOf: s.remoteJSONURL) == s.localJSON)
        #expect(try Data(contentsOf: s.h.remote.appendingPathComponent(s.remoteDir + "/" + s.assetPath)) == s.assetBytes)
        #expect(s.candidates.isEmpty)
    }

    @Test func assetsBeforeDocument() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        _ = await s.uploader().runOnce()
        let ops = s.writes.filter { $0.contains("enrichments/") }
        #expect(ops == ["upload \(s.remoteDir)/\(s.assetPath)", "replace \(s.remoteDir)/enrichment.json"])
    }

    @Test func newRevisionReplacesRemote() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        _ = await s.uploader().runOnce()
        let first = try Data(contentsOf: s.remoteJSONURL)
        try s.writeDoc(text: "second")
        #expect(s.candidates == [s.pkg.metadata.captureID])

        let result = await s.uploader().runOnce()

        #expect(result.synced == 1)
        let remote = try Data(contentsOf: s.remoteJSONURL)
        #expect(remote == s.localJSON)
        #expect(remote != first)
    }

    @Test func unchangedRevisionNotReuploaded() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        _ = await s.uploader().runOnce()
        let before = s.h.faults.operations.count

        let result = await s.uploader().runOnce()

        #expect(result.synced == 0)
        #expect(s.h.faults.operations.count == before)
    }

    @Test func failureBacksOff() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        let path = "\(s.remoteDir)/\(s.assetPath)"
        s.h.faults.failBeforeWrite(path, .transient(code: "server_500"))

        let result = await s.uploader().runOnce()

        #expect(result == SyncPassResult(synced: 0, failed: 1, idle: false))
        #expect(s.candidates.isEmpty)
        let row = try #require(try s.h.db.query("SELECT * FROM enrichment_uploads").first)
        #expect(row.string("last_error_code") == "transient:server_500")
        #expect(row.int("blocked") == 0)
        #expect(row.int("next_attempt_at_ms") == Int64((t0.timeIntervalSince1970 + 30) * 1000))
        // Not retried before it is due; retried (and succeeds) after.
        #expect(await s.uploader().runOnce().idle)
        s.h.clock.set(t0.addingTimeInterval(30))
        #expect(await s.uploader().runOnce().synced == 1)
    }

    @Test func permanentFailureBlocksRevision() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        s.h.faults.failBeforeWrite("\(s.remoteDir)/\(s.assetPath)", .permanent(code: "forbidden"))
        #expect(await s.uploader().runOnce().failed == 1)
        let row = try #require(try s.h.db.query("SELECT * FROM enrichment_uploads").first)
        #expect(row.int("blocked") == 1)
        #expect(row.string("last_error_code") == "permanent:forbidden")
        s.h.clock.set(t0.addingTimeInterval(1_000_000))
        #expect(s.candidates.isEmpty)
        // A new revision is tried again.
        try s.writeDoc(text: "second")
        #expect(await s.uploader().runOnce().synced == 1)
    }

    @Test func needsAuthenticationStopsWithoutRecording() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        s.h.faults.failBeforeWrite("\(s.remoteDir)/\(s.assetPath)", .needsAuthentication)

        let result = await s.uploader().runOnce()

        #expect(result.failed == 0)
        #expect(try s.h.db.query("SELECT * FROM enrichment_uploads").isEmpty)
        #expect(s.candidates == [s.pkg.metadata.captureID])
    }

    @Test func conflictingRemoteAssetBlocks() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        let url = s.h.remote.appendingPathComponent("\(s.remoteDir)/\(s.assetPath)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("different".utf8).write(to: url)

        #expect(await s.uploader().runOnce().failed == 1)

        let row = try #require(try s.h.db.query("SELECT * FROM enrichment_uploads").first)
        #expect(row.string("last_error_code") == "remote_conflict")
        #expect(row.int("blocked") == 1)
        #expect(!FileManager.default.fileExists(atPath: s.remoteJSONURL.path))
    }

    @Test func existingMatchingAssetIsNotReuploaded() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        let url = s.h.remote.appendingPathComponent("\(s.remoteDir)/\(s.assetPath)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try s.assetBytes.write(to: url)

        #expect(await s.uploader().runOnce().synced == 1)
        #expect(!s.writes.contains("upload \(s.remoteDir)/\(s.assetPath)"))
    }

    @Test func cancelBeforeDocumentLeavesRevisionPending() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        let box = TaskBox()
        let adapter = HookedAdapter(inner: s.h.adapter, afterUpload: { _ in box.cancel() })
        let uploader = s.uploader(adapter)
        let task = Task { await uploader.runOnce() }
        box.set(task)

        let result = await task.value

        #expect(result == SyncPassResult(synced: 0, failed: 0, idle: false))
        #expect(FileManager.default.fileExists(atPath: s.h.remote.appendingPathComponent("\(s.remoteDir)/\(s.assetPath)").path))
        #expect(!FileManager.default.fileExists(atPath: s.remoteJSONURL.path))
        #expect(s.candidates == [s.pkg.metadata.captureID])
        #expect(try s.h.db.query("SELECT * FROM enrichment_uploads").isEmpty)
    }

    @Test func revisionChangedMidUploadIsSkipped() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        let adapter = HookedAdapter(inner: s.h.adapter, afterUpload: { _ in try? s.writeDoc(text: "changed") })

        let result = await s.uploader(adapter).runOnce()

        #expect(result.failed == 0 && result.synced == 0)
        #expect(!FileManager.default.fileExists(atPath: s.remoteJSONURL.path))
        #expect(try s.h.db.query("SELECT * FROM enrichment_uploads").isEmpty)
        #expect(s.candidates == [s.pkg.metadata.captureID])
    }

    @Test func inactiveDestinationSkipped() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        _ = try s.h.destinations.connect(Destination(id: "dest-other", providerKind: "filesystem",
                                                     accountIdentifier: "other", remoteRoot: "/",
                                                     displayName: "Other", status: .active))

        let result = await s.uploader().runOnce()

        // The original destination is no longer active, so its synced job is not uploaded to.
        #expect(result.synced == 0)
        #expect(!FileManager.default.fileExists(atPath: s.h.remote.appendingPathComponent("enrichments").path))
    }

    @Test func noActiveDestinationDoesNothing() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        try s.h.db.execute("UPDATE destinations SET status = 'disabled'")
        #expect(await s.uploader().runOnce() == SyncPassResult(synced: 0, failed: 0, idle: true))
    }
}
