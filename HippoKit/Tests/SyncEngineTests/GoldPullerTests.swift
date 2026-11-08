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

    func puller(_ adapter: (any StorageAdapter)? = nil, softChangeLimit: Int = 200) -> GoldPuller {
        let a: any StorageAdapter = adapter ?? h.adapter
        let clock = h.clock
        return GoldPuller(layout: h.layout, index: h.index, destinations: h.destinations, enrichments: enrichments,
                          adapterFor: { _ in a }, softChangeLimit: softChangeLimit, now: { clock.now }, log: h.log)
    }

    /// A server document referencing `count` distinct assets, each declared at `declaredBytes` (the real
    /// bytes when nil); writes the document and, when `writeAssets`, the asset files.
    @discardableResult
    func putManyAssetGold(count: Int, declaredBytes: Int64? = nil, writeAssets: Bool = true) throws -> EnrichmentDocument {
        var refs: [JSONValue] = []
        for i in 0..<count {
            let bytes = Data("asset-\(i)".utf8)
            let path = "assets/\(hex(bytes)).jpg"
            refs.append(.object(["relative_path": .string(path), "sha256": .string(hex(bytes)),
                                 "byte_count": .number(Double(declaredBytes ?? Int64(bytes.count)))]))
            if writeAssets { try put(bytes, at: remoteDir() + "/" + path) }
        }
        let facet = Facet(version: 1, status: .ok, generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                          provenance: "gold", data: .object(["text": .string("walrus"), "thumbs": .array(refs)]))
        let d = EnrichmentDocument(schemaVersion: 1, captureID: id, layer: .server,
                                   packageDigest: try #require(try h.index.packageDigest(captureID: id)),
                                   producer: EnrichmentProducer(name: "server", version: "1", build: "1"),
                                   generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                   facets: [FacetKind.summary.rawValue: facet])
        try put(try EnrichmentJSON.encode(d), at: remoteDir() + "/enrichment.json")
        return d
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

    @Test func logsAppliedRemovedSkippedAndPull() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        try s.putGold()
        _ = await s.puller().pull()
        try FileManager.default.removeItem(at: s.h.remote.appendingPathComponent(s.remoteDir() + "/enrichment.json"))
        _ = await s.puller().pull()
        try s.put(Data(count: 1_048_577), at: s.remoteDir() + "/enrichment.json")
        _ = await s.puller().pull()

        let mine = s.h.log.events(captureID: s.id, from: Date(timeIntervalSince1970: 0))
        #expect(mine.map(\.event) == [.goldApplied, .goldRemoved, .goldSkipped])
        #expect(mine[2].code == "gold_too_large")
        let pulls = s.h.log.globalEvents(limit: 10, before: nil).filter { $0.event == .goldPull }
        #expect(pulls.map(\.code) == ["gold_too_large", "ok", "ok"])
        #expect(pulls.map(\.count) == [0, 0, 1])
        #expect(pulls.allSatisfy { $0.on == false })
    }

    @Test func goldPullLogsCursorReset() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        try s.putGold()
        try s.enrichments.saveGoldCursor(destinationID: "dest-fs", cursor: "garbage", now: s.h.clock.now)
        _ = await s.puller().pull()
        let pull = try #require(s.h.log.globalEvents(limit: 10, before: nil).first { $0.event == .goldPull })
        #expect(pull.on == true)
        #expect(pull.count == 1)
    }

    @Test func goldWithMaxAssetsApplies() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        try s.putManyAssetGold(count: 32)
        let r = await s.puller().pull()
        #expect(r.applied == 1)
        #expect(r.code == nil)
    }

    @Test func goldWithTooManyAssetsSkippedBeforeAnyDownload() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        try s.putManyAssetGold(count: 33)
        let downloads = Downloads()
        let adapter = HookedAdapter(inner: s.h.adapter, beforeDownload: { if $0.contains("/assets/") { downloads.add($0) } })
        s.expectSkipped(await s.puller(adapter).pull(), code: "gold_too_large")
        #expect(downloads.count == 0)
    }

    @Test func goldOverTotalAssetBytesSkippedBeforeAnyDownload() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        // Each asset is within the 5 MiB per-asset cap; together they declare 55 MiB.
        try s.putManyAssetGold(count: 11, declaredBytes: 5_242_880, writeAssets: false)
        let downloads = Downloads()
        let adapter = HookedAdapter(inner: s.h.adapter, beforeDownload: { if $0.contains("/assets/") { downloads.add($0) } })
        s.expectSkipped(await s.puller(adapter).pull(), code: "gold_too_large")
        #expect(downloads.count == 0)
    }

    @Test func goldAtTotalAssetBytesCapIsNotTooLarge() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        // Exactly 50 MiB declared passes the size check (and then fails verification, as the bytes differ).
        try s.putManyAssetGold(count: 10, declaredBytes: 5_242_880)
        s.expectSkipped(await s.puller().pull(), code: "gold_asset_invalid")
    }

    @Test func assetDownloadsCountTowardTheSoftChangeLimit() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        try s.putManyAssetGold(count: 5)
        let lists = Downloads()
        let adapter = MorePagesAdapter(inner: s.h.adapter, lists: lists)

        // Six listed changes (the document and its five assets) plus five downloads reach a limit of 7:
        // no further page is listed. The changes alone would not.
        let r = await s.puller(adapter, softChangeLimit: 7).pull()
        #expect(r.applied == 1)
        #expect(lists.count == 1)

        // Below the limit (two changes plus one download, limit 4), the next page is listed.
        let s2 = try await Setup(); defer { s2.h.cleanup() }
        try s2.putGold()
        let lists2 = Downloads()
        _ = await s2.puller(MorePagesAdapter(inner: s2.h.adapter, lists: lists2), softChangeLimit: 4).pull()
        #expect(lists2.count == 2)
    }

    @Test func launchRecoveryDuringAPullKeepsItsStaging() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        try s.putGold()
        let reconciler = Reconciler(layout: s.h.layout, index: s.h.index, jobs: s.h.jobs, destinations: s.h.destinations)
        let swept = Downloads()
        // Recovery runs mid-download, as it can at launch alongside the first foreground sync.
        let adapter = HookedAdapter(inner: s.h.adapter, beforeDownload: { _ in
            if let report = try? reconciler.run(), report.removedStaging > 0 { swept.add("swept") }
        })

        let r = await s.puller(adapter).pull()

        #expect(swept.count == 0)
        #expect(r.applied == 1)
        #expect(r.code == nil)
        #expect(s.stagingLeftovers.isEmpty)   // neither the directory nor its lock file
    }

    @Test func abandonedGoldStagingIsStillSwept() async throws {
        let s = try await Setup(); defer { s.h.cleanup() }
        let leftover = s.h.layout.stagingDir.appendingPathComponent("gold-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        let reconciler = Reconciler(layout: s.h.layout, index: s.h.index, jobs: s.h.jobs, destinations: s.h.destinations)
        #expect(try reconciler.run().removedStaging == 1)
        #expect(s.stagingLeftovers.isEmpty)
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

/// Says the first page has more after it, so the puller decides whether to list again.
private struct MorePagesAdapter: StorageAdapter {
    let inner: FilesystemAdapter
    let lists: Downloads

    var capabilities: StorageCapabilities { inner.capabilities }
    func listChanges(under prefix: String, cursor: String?) async throws -> ChangePage {
        lists.add(prefix)
        let page = try await inner.listChanges(under: prefix, cursor: cursor)
        return ChangePage(changes: page.changes, cursor: page.cursor, hasMore: cursor == nil)
    }
    func replaceFile(localURL: URL, relativePath: String, expected: FileIntegrity) async throws -> UploadReceipt {
        try await inner.replaceFile(localURL: localURL, relativePath: relativePath, expected: expected)
    }
    func downloadFile(relativePath: String, to localURL: URL, maxBytes: Int64) async throws -> RemoteFileInfo {
        try await inner.downloadFile(relativePath: relativePath, to: localURL, maxBytes: maxBytes)
    }
    func validateDestination() async throws { try await inner.validateDestination() }
    func ensureContainer(relativePath: String) async throws { try await inner.ensureContainer(relativePath: relativePath) }
    func inspectFile(relativePath: String) async throws -> RemoteFileInfo? { try await inner.inspectFile(relativePath: relativePath) }
    func verify(remote: RemoteFileInfo, localURL: URL, expected: FileIntegrity) async throws -> VerificationEvidence? {
        try await inner.verify(remote: remote, localURL: localURL, expected: expected)
    }
    func uploadFile(localURL: URL, relativePath: String, expected: FileIntegrity, checkpoint: UploadCheckpoint?,
                    saveCheckpoint: @Sendable (UploadCheckpoint) async throws -> Void) async throws -> UploadReceipt {
        try await inner.uploadFile(localURL: localURL, relativePath: relativePath, expected: expected,
                                   checkpoint: checkpoint, saveCheckpoint: saveCheckpoint)
    }
}
