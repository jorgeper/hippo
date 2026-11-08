import Foundation
import CryptoKit
import Testing
import CaptureCore
import LocalRepository
import SyncEngine
import FilesystemAdapter

private func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

private final class Downloads: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func add(_ p: String) { lock.lock(); paths.append(p); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return paths.count }
}

private struct Setup {
    let h: SyncHarness
    let enrichments: EnrichmentStore
    let pkg: CommittedPackage
    let assetBytes = Data("gold-thumbnail".utf8)
    var id: String { pkg.metadata.captureID }
    var assetPath: String { "assets/\(hex(assetBytes)).jpg" }

    init() async throws {
        h = try SyncHarness()
        enrichments = EnrichmentStore(db: h.db, layout: h.layout)
        pkg = try await h.capture()
    }

    func remoteDir(_ layer: String = "server", id: String? = nil, from dir: String? = nil) -> String {
        let base = try! EnrichmentPaths.remoteDirectory(.server, packageDirectory: dir ?? pkg.relativeDirectory)
        let swapped = base.replacingOccurrences(of: "enrichments/server", with: "enrichments/\(layer)")
        guard let id else { return swapped }
        return String(swapped.dropLast(36)) + id
    }

    func doc(text: String = "walrus", captureID: String? = nil, layer: EnrichmentLayer = .server,
             digest: String? = nil, assetRelPath: String? = nil) throws -> EnrichmentDocument {
        let ref: JSONValue = .object(["relative_path": .string(assetRelPath ?? assetPath),
                                      "sha256": .string(hex(assetBytes)),
                                      "byte_count": .number(Double(assetBytes.count))])
        let facet = Facet(version: 1, status: .ok, generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                          provenance: "gold", data: .object(["text": .string(text), "thumb": ref]))
        let real = try #require(try h.index.packageDigest(captureID: id))
        return EnrichmentDocument(schemaVersion: 1, captureID: captureID ?? id, layer: layer,
                                  packageDigest: digest ?? real,
                                  producer: EnrichmentProducer(name: "server", version: "1", build: "1"),
                                  generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                  facets: [FacetKind.summary.rawValue: facet])
    }

    func put(_ data: Data, at path: String) throws {
        let url = h.remote.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    /// Writes the document and its asset under `enrichments/server/…`.
    @discardableResult
    func putGold(_ d: EnrichmentDocument? = nil, dir: String? = nil) throws -> EnrichmentDocument {
        let d = try d ?? doc()
        let dir = dir ?? remoteDir()
        try put(try EnrichmentJSON.encode(d), at: dir + "/enrichment.json")
        try put(assetBytes, at: dir + "/" + assetPath)
        return d
    }

    func puller(_ adapter: (any StorageAdapter)? = nil) -> GoldPuller {
        let a: any StorageAdapter = adapter ?? h.adapter
        let clock = h.clock
        return GoldPuller(layout: h.layout, index: h.index, destinations: h.destinations, enrichments: enrichments,
                          adapterFor: { _ in a }, now: { clock.now })
    }

    var cursor: String? { try? enrichments.goldCursor(destinationID: "dest-fs") }
    var lastCode: String? {
        try? h.db.query("SELECT last_result_code FROM gold_cursors WHERE destination_id = 'dest-fs'").first?
            .string("last_result_code")
    }
    func localDirExists(_ id: String? = nil) -> Bool {
        FileManager.default.fileExists(atPath: h.layout.enrichmentDirectory(.server, captureID: id ?? self.id).path)
    }
    var stagingLeftovers: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: h.layout.stagingDir.path)) ?? []).filter { $0.hasPrefix("gold-") }
    }
    func expectSkipped(_ r: GoldPullResult, code: String? = nil) {
        #expect(r.skipped == 1)
        #expect(r.applied == 0)
        #expect(!localDirExists())
        #expect(cursor != nil)
        #expect(stagingLeftovers.isEmpty)
        if let code { #expect(r.code == code); #expect(lastCode == code) }
    }
}

@Suite struct GoldPullerTests {
    @Test func appliesGoldForKnownCapture() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        let remote = try s.putGold()

        let r = await s.puller().pull()

        #expect(r.applied == 1)
        #expect(r.code == nil)
        #expect(s.lastCode == "ok")
        #expect(try s.enrichments.document(.server, captureID: s.id) == remote)
        let ref = AssetRef(relativePath: s.assetPath, byteCount: Int64(s.assetBytes.count), sha256: hex(s.assetBytes))
        #expect(FileManager.default.fileExists(atPath: s.enrichments.assetURL(.server, captureID: s.id, asset: ref).path))
        #expect(try s.h.index.page(CaptureFilter(searchText: "walrus"), after: nil, limit: 10).map(\.id) == [s.id])
        #expect(s.stagingLeftovers.isEmpty)
    }

    @Test func goldForUnknownCaptureIgnored() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        let other = UUID().uuidString.lowercased()
        let d = try s.doc(captureID: other)
        try s.put(try EnrichmentJSON.encode(d), at: s.remoteDir(id: other) + "/enrichment.json")

        let r = await s.puller().pull()

        #expect(r.ignored == 1)
        #expect(r.applied == 0)
        #expect(!s.localDirExists(other))
    }

    @Test func deletedRemoteRemovesLocal() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        try s.putGold()
        _ = await s.puller().pull()
        #expect(s.localDirExists())
        try FileManager.default.removeItem(at: s.h.remote.appendingPathComponent(s.remoteDir() + "/enrichment.json"))

        let r = await s.puller().pull()

        #expect(r.removed == 1)
        #expect(!s.localDirExists())
        #expect(try s.h.index.page(CaptureFilter(searchText: "walrus"), after: nil, limit: 10).isEmpty)
    }

    @Test func incrementalOnlyChanges() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        try s.putGold()
        _ = await s.puller().pull()

        let r = await s.puller().pull()

        #expect(r == GoldPullResult(applied: 0, removed: 0, ignored: 0, skipped: 0, code: nil))
    }

    @Test func cursorResetRelists() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        try s.putGold()
        try s.enrichments.saveGoldCursor(destinationID: "dest-fs", cursor: "garbage", now: s.h.clock.now)

        let r = await s.puller().pull()

        #expect(r.applied == 1)
        #expect(s.cursor != nil)
        #expect(s.cursor != "garbage")
    }

    @Test func goldUnsafeAssetPathSkipped() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        try s.putGold(try s.doc(assetRelPath: "assets/../../escape.jpg"))
        s.expectSkipped(await s.puller().pull(), code: "gold_invalid")
    }

    @Test func goldOverCapSkipped() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        try s.put(Data(count: 1_048_577), at: s.remoteDir() + "/enrichment.json")
        s.expectSkipped(await s.puller().pull(), code: "gold_too_large")
    }

    @Test func goldWrongCaptureSkipped() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        try s.putGold(try s.doc(captureID: UUID().uuidString.lowercased()))
        s.expectSkipped(await s.puller().pull(), code: "gold_mismatch")
    }

    @Test func goldBadVersionSkipped() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        let bytes = try EnrichmentJSON.encode(try s.doc())
        var obj = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        obj["schema_version"] = 2
        try s.put(try JSONSerialization.data(withJSONObject: obj), at: s.remoteDir() + "/enrichment.json")
        s.expectSkipped(await s.puller().pull(), code: "gold_unsupported_version")
    }

    @Test func goldAssetShaMismatchSkipped() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        try s.putGold()
        try s.put(Data("tampered-bytes".utf8), at: s.remoteDir() + "/" + s.assetPath)
        s.expectSkipped(await s.puller().pull(), code: "gold_asset_invalid")
    }

    @Test func goldMissingAssetSkipped() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        try s.putGold()
        try FileManager.default.removeItem(at: s.h.remote.appendingPathComponent(s.remoteDir() + "/" + s.assetPath))
        s.expectSkipped(await s.puller().pull(), code: "gold_asset_invalid")
    }

    @Test func digestMismatchStillApplies() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        try s.putGold(try s.doc(digest: String(repeating: "a", count: 64)))

        let r = await s.puller().pull()

        #expect(r.applied == 1)
        #expect(r.code == "gold_digest_mismatch")
        #expect(s.localDirExists())
    }

    @Test func existingLocalAssetIsReused() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        try s.putGold()
        _ = await s.puller().pull()
        try s.putGold(try s.doc(text: "narwhal"))
        let downloads = Downloads()
        let asset = s.assetPath
        let adapter = HookedAdapter(inner: s.h.adapter, beforeDownload: { if $0.hasSuffix(asset) { downloads.add($0) } })

        let r = await s.puller(adapter).pull()

        #expect(r.applied == 1)
        #expect(downloads.count == 0)
    }

    @Test func deviceLayerNeverPulled() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        try s.putGold(try s.doc(layer: .device), dir: s.remoteDir("device"))

        let r = await s.puller().pull()

        #expect(r.applied == 0)
        #expect(!s.localDirExists())
        #expect(try s.enrichments.document(.device, captureID: s.id) == nil)
    }

    @Test func noActiveDestinationDoesNothing() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        try s.putGold()
        try s.h.db.execute("UPDATE destinations SET status = 'paused'")
        let r = await s.puller().pull()
        #expect(r == GoldPullResult(applied: 0, removed: 0, ignored: 0, skipped: 0, code: nil))
        #expect(!s.localDirExists())
    }

    @Test func adapterErrorEndsPullWithCode() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        try s.putGold()
        let adapter = HookedAdapter(inner: s.h.adapter, beforeDownload: { _ in throw StorageError.transient(code: "server_500") })

        let r = await s.puller(adapter).pull()

        #expect(r.code == "transient:server_500")
        #expect(s.cursor == nil)
        #expect(s.lastCode == "transient:server_500")
        #expect(!s.localDirExists())
        #expect(s.stagingLeftovers.isEmpty)
    }

    @Test func deviceLayerDocumentAtServerPathSkipped() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        try s.putGold(try s.doc(layer: .device))

        let r = await s.puller().pull()

        s.expectSkipped(r, code: "gold_mismatch")
        #expect(try s.enrichments.document(.device, captureID: s.id) == nil)
        let rev = try s.h.db.query("SELECT device_revision FROM captures WHERE capture_id = ?", [.text(s.id)]).first
        #expect(rev?.string("device_revision") == nil)
    }

    @Test func docBeforeItsAssetIsAppliedOnceAssetArrives() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        try s.put(try EnrichmentJSON.encode(try s.doc()), at: s.remoteDir() + "/enrichment.json")
        s.expectSkipped(await s.puller().pull(), code: "gold_asset_invalid")

        try s.put(s.assetBytes, at: s.remoteDir() + "/" + s.assetPath)
        let r = await s.puller().pull()

        #expect(r.applied == 1)
        #expect(r.skipped == 0)
        #expect(s.localDirExists())
    }

    @Test func assetBeforeItsDocIsIgnoredThenDocApplies() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        try s.put(s.assetBytes, at: s.remoteDir() + "/" + s.assetPath)
        let first = await s.puller().pull()
        #expect(first == GoldPullResult(applied: 0, removed: 0, ignored: 1, skipped: 0, code: nil))
        #expect(s.lastCode == "ok")

        try s.put(try EnrichmentJSON.encode(try s.doc()), at: s.remoteDir() + "/enrichment.json")
        let r = await s.puller().pull()

        #expect(r.applied == 1)
        #expect(s.localDirExists())
    }

    @Test func docAndAssetInOnePageApplyOnce() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        try s.putGold()
        let downloads = Downloads()
        let adapter = HookedAdapter(inner: s.h.adapter, beforeDownload: {
            if $0.hasSuffix("enrichment.json") { downloads.add($0) }
        })

        let r = await s.puller(adapter).pull()

        #expect(r.applied == 1)
        #expect(r.skipped == 0)
        #expect(downloads.count == 1)
    }

    @Test func wrongDatePartitionIgnored() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        let stray = "enrichments/server/1999/01/01/\(s.id)"
        #expect(stray != s.remoteDir())
        try s.putGold(dir: stray)

        let r = await s.puller().pull()

        #expect(r.applied == 0)
        #expect(r.ignored == 2)
        #expect(!s.localDirExists())
    }

    @Test func deleteAtStrayPartitionKeepsLocalGold() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        try s.putGold()
        _ = await s.puller().pull()
        let stray = "enrichments/server/1999/01/01/\(s.id)"
        try s.put(Data("{}".utf8), at: stray + "/enrichment.json")
        _ = await s.puller().pull()
        try FileManager.default.removeItem(at: s.h.remote.appendingPathComponent(stray + "/enrichment.json"))

        let r = await s.puller().pull()

        #expect(r.removed == 0)
        #expect(r.ignored >= 1)
        #expect(s.localDirExists())
    }

    @Test func downloadedDocumentOverCapSkipped() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        // Listed small, but the file that arrives is larger than the cap.
        let path = s.remoteDir() + "/enrichment.json"
        try s.put(Data(count: 10), at: path)
        let url = s.h.remote.appendingPathComponent(path)
        let adapter = HookedAdapter(inner: s.h.adapter, beforeDownload: { _ in
            try? Data(count: 1_048_577).write(to: url)
        })
        let r = await s.puller(adapter).pull()
        #expect(r.skipped == 1)
        #expect(!s.localDirExists())
    }
}
