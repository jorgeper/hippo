import Foundation
import Testing
import CryptoKit
import CaptureCore
@testable import LocalRepository

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func uuid(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))! }

/// The index harness plus an enrichment store on the same database and root.
private struct EnrichmentHarness {
    let h: IndexHarness
    let store: EnrichmentStore
    let scratch: URL

    init() throws {
        h = try IndexHarness()
        store = EnrichmentStore(db: h.db, layout: h.layout)
        scratch = h.root.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    func cleanup() { h.cleanup() }

    /// A file outside the store holding `bytes`, and the asset reference that describes it.
    func newAsset(_ bytes: String, ext: String = "jpg") throws -> (ref: AssetRef, url: URL) {
        let data = Data(bytes.utf8)
        let sha = sha256Hex(data)
        let url = scratch.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        return (AssetRef(relativePath: "assets/\(sha).\(ext)", byteCount: Int64(data.count), sha256: sha,
                         mimeType: "image/jpeg"), url)
    }

    func document(_ pkg: CommittedPackage, _ layer: EnrichmentLayer, facets: [FacetKind: any Encodable]) throws
        -> EnrichmentDocument {
        let digest = try #require(try h.index.packageDigest(captureID: pkg.metadata.captureID))
        var out: [String: Facet] = [:]
        for (kind, payload) in facets {
            let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(payload))
            out[kind.rawValue] = Facet(version: 1, status: .ok, generatedAt: HippoJSON.wholeMilliseconds(t0),
                                       provenance: "test", data: json)
        }
        return EnrichmentDocument(schemaVersion: 1, captureID: pkg.metadata.captureID, layer: layer,
                                  packageDigest: digest,
                                  producer: EnrichmentProducer(name: "test", version: "1", build: "1"),
                                  generatedAt: HippoJSON.wholeMilliseconds(t0), facets: out)
    }

    func linkDoc(_ pkg: CommittedPackage, title: String, thumbnail: AssetRef?) throws -> EnrichmentDocument {
        try document(pkg, .device, facets: [
            .linkPreview: LinkPreviewData(items: [LinkPreviewItem(url: "https://example.com", title: title,
                                                                  thumbnail: thumbnail)])])
    }

    func search(_ q: String) throws -> [String] {
        try h.index.page(CaptureFilter(searchText: q), after: nil, limit: 50).map(\.id)
    }

    func deviceRevision(_ captureID: String) throws -> String? {
        try h.db.query("SELECT device_revision FROM captures WHERE capture_id = ?", [.text(captureID)]).first?
            .string("device_revision")
    }

    func addDestination(_ id: String) throws {
        try h.db.execute("INSERT INTO destinations VALUES (?, 'filesystem', 'a', '/', 'n', 'active', 1)", [.text(id)])
    }

    func addJob(_ captureID: String, _ destinationID: String, state: String) throws {
        try h.db.execute("""
            INSERT INTO jobs(job_id, capture_id, destination_id, state, updated_at_ms) VALUES (?, ?, ?, ?, 1)
            """, [.text(UUID().uuidString), .text(captureID), .text(destinationID), .text(state)])
    }
}

@Suite struct EnrichmentStoreTests {
    @Test func layoutPaths() {
        let layout = StoreLayout(root: URL(fileURLWithPath: "/r"))
        #expect(layout.enrichmentsDir.path == "/r/enrichments")
        #expect(layout.enrichmentDirectory(.server, captureID: "abc").path == "/r/enrichments/server/abc")
        #expect(layout.enrichmentStagingDir.path == "/r/staging/enrichments")
    }

    @Test func writeThenReadDocument() async throws {
        let t = try EnrichmentHarness(); defer { t.cleanup() }
        let pkg = try await t.h.add(note: "Plain")
        let id = pkg.metadata.captureID
        let asset = try t.newAsset("thumbnail bytes")
        let doc = try t.linkDoc(pkg, title: "Preview", thumbnail: asset.ref)

        #expect(try t.store.document(.device, captureID: id) == nil)
        try t.store.write(doc, newAssets: [asset.ref.relativePath: asset.url])

        #expect(try t.store.document(.device, captureID: id) == doc)
        #expect(try t.store.document(.server, captureID: id) == nil)
        let stored = t.store.assetURL(.device, captureID: id, asset: asset.ref)
        #expect(stored == t.h.layout.enrichmentDirectory(.device, captureID: id).appendingPathComponent(asset.ref.relativePath))
        #expect(try Data(contentsOf: stored) == Data("thumbnail bytes".utf8))
        // The caller's file is left where it was.
        #expect(FileManager.default.fileExists(atPath: asset.url.path))
        let json = try Data(contentsOf: t.h.layout.enrichmentDirectory(.device, captureID: id)
            .appendingPathComponent(EnrichmentPaths.documentName))
        #expect(try t.deviceRevision(id) == sha256Hex(json))
    }

    @Test func unreadableDocumentThrows() async throws {
        let t = try EnrichmentHarness(); defer { t.cleanup() }
        let pkg = try await t.h.add(note: "Plain")
        let dir = t.h.layout.enrichmentDirectory(.server, captureID: pkg.metadata.captureID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: dir.appendingPathComponent(EnrichmentPaths.documentName))
        #expect(throws: (any Error).self) { _ = try t.store.document(.server, captureID: pkg.metadata.captureID) }
    }

    @Test func writeReusesExistingAssets() async throws {
        let t = try EnrichmentHarness(); defer { t.cleanup() }
        let pkg = try await t.h.add(note: "Plain")
        let id = pkg.metadata.captureID
        let kept = try t.newAsset("kept")
        let dropped = try t.newAsset("dropped", ext: "png")
        var first = try t.linkDoc(pkg, title: "One", thumbnail: kept.ref)
        first.facets["extra"] = Facet(version: 1, status: .ok, generatedAt: HippoJSON.wholeMilliseconds(t0),
                                      provenance: "test",
                                      data: .object(["image": .object([
                                          "relative_path": .string(dropped.ref.relativePath),
                                          "sha256": .string(dropped.ref.sha256),
                                          "byte_count": .number(Double(dropped.ref.byteCount))])]))
        try t.store.write(first, newAssets: [kept.ref.relativePath: kept.url, dropped.ref.relativePath: dropped.url])

        let second = try t.linkDoc(pkg, title: "Two", thumbnail: kept.ref)
        try t.store.write(second, newAssets: [:])
        #expect(try t.store.document(.device, captureID: id) == second)
        #expect(try Data(contentsOf: t.store.assetURL(.device, captureID: id, asset: kept.ref)) == Data("kept".utf8))
        // Unreferenced old assets are dropped.
        #expect(!FileManager.default.fileExists(atPath: t.store.assetURL(.device, captureID: id, asset: dropped.ref).path))

        // An asset that is neither new nor already present.
        let unknown = AssetRef(relativePath: "assets/\(String(repeating: "e", count: 64)).jpg", byteCount: 3,
                               sha256: String(repeating: "e", count: 64))
        #expect(throws: EnrichmentStoreError.missingAsset) {
            try t.store.write(try t.linkDoc(pkg, title: "Three", thumbnail: unknown), newAssets: [:])
        }
        // An existing file whose bytes no longer match.
        try Data("tampered".utf8).write(to: t.store.assetURL(.device, captureID: id, asset: kept.ref))
        #expect(throws: EnrichmentStoreError.missingAsset) {
            try t.store.write(try t.linkDoc(pkg, title: "Four", thumbnail: kept.ref), newAssets: [:])
        }
        // A failed write leaves the previous document in place.
        #expect(try t.store.document(.device, captureID: id) == second)
    }

    @Test func writeForUnindexedCaptureThrows() async throws {
        let t = try EnrichmentHarness(); defer { t.cleanup() }
        let pkg = try await t.h.add(note: "Plain")
        let doc = try t.linkDoc(pkg, title: "Preview", thumbnail: nil)
        try t.h.index.remove(captureID: pkg.metadata.captureID)
        #expect(throws: EnrichmentStoreError.notIndexed) { try t.store.write(doc, newAssets: [:]) }
        #expect(!FileManager.default.fileExists(
            atPath: t.h.layout.enrichmentDirectory(.device, captureID: pkg.metadata.captureID).path))
    }

    @Test func enrichmentTextIsSearchable() async throws {
        let t = try EnrichmentHarness(); defer { t.cleanup() }
        let pkg = try await t.h.add(note: "Wombat")
        _ = try await t.h.add(note: "Other")
        let id = pkg.metadata.captureID
        try t.store.write(try t.document(pkg, .server, facets: [.summary: SummaryData(text: "quokka sighting")]),
                          newAssets: [:])
        #expect(try t.search("quokka") == [id])
        #expect(try t.search("quokka wombat") == [id])
        #expect(try t.search("quokka other").isEmpty)
        // A server write does not set the device revision.
        #expect(try t.deviceRevision(id) == nil)
    }

    @Test func removeLayerClearsSearch() async throws {
        let t = try EnrichmentHarness(); defer { t.cleanup() }
        let pkg = try await t.h.add(note: "Wombat")
        let id = pkg.metadata.captureID
        try t.store.write(try t.document(pkg, .server, facets: [.summary: SummaryData(text: "quokka sighting")]),
                          newAssets: [:])
        try t.store.write(try t.document(pkg, .device, facets: [
            .textRecognition: TextRecognitionData(items: [RecognizedText(attachmentID: "a", text: "platypus",
                                                                          languages: ["en"])])]), newAssets: [:])
        #expect(try t.search("quokka") == [id])
        #expect(try t.search("platypus") == [id])

        try t.store.removeLayer(.server, captureID: id)
        #expect(try t.search("quokka").isEmpty)
        #expect(try t.search("platypus") == [id])
        #expect(try t.store.document(.server, captureID: id) == nil)
        #expect(try t.deviceRevision(id) != nil)

        try t.store.removeLayer(.device, captureID: id)
        #expect(try t.search("platypus").isEmpty)
        #expect(try t.deviceRevision(id) == nil)
        #expect(!FileManager.default.fileExists(atPath: t.h.layout.enrichmentDirectory(.device, captureID: id).path))
        // Removing an absent layer is fine.
        try t.store.removeLayer(.device, captureID: id)
    }

    @Test func writeIsAtomicAndSweepsStaging() async throws {
        let t = try EnrichmentHarness(); defer { t.cleanup() }
        let fm = FileManager.default
        let pkg = try await t.h.add(note: "Plain")
        let id = pkg.metadata.captureID
        let doc = try t.linkDoc(pkg, title: "Preview", thumbnail: nil)
        try t.store.write(doc, newAssets: [:])
        // A successful write leaves nothing in staging.
        #expect(try fm.contentsOfDirectory(atPath: t.h.layout.enrichmentStagingDir.path).isEmpty)

        let leftover = t.h.layout.enrichmentStagingDir.appendingPathComponent("x", isDirectory: true)
        try fm.createDirectory(at: leftover, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: leftover.appendingPathComponent(EnrichmentPaths.documentName))
        let orphan = t.h.layout.enrichmentDirectory(.server, captureID: UUID().uuidString.lowercased())
        try fm.createDirectory(at: orphan, withIntermediateDirectories: true)

        #expect(try t.store.sweep() == 2)
        #expect(!fm.fileExists(atPath: leftover.path))
        #expect(!fm.fileExists(atPath: orphan.path))
        #expect(try t.store.document(.device, captureID: id) == doc)
        #expect(try t.store.sweep() == 0)
    }

    @Test func sweepCanKeepOrphans() throws {
        let t = try EnrichmentHarness(); defer { t.cleanup() }
        let fm = FileManager.default
        let leftover = t.h.layout.enrichmentStagingDir.appendingPathComponent("x", isDirectory: true)
        try fm.createDirectory(at: leftover, withIntermediateDirectories: true)
        let orphan = t.h.layout.enrichmentDirectory(.server, captureID: UUID().uuidString.lowercased())
        try fm.createDirectory(at: orphan, withIntermediateDirectories: true)

        #expect(try t.store.sweep(removingOrphans: false) == 1)
        #expect(!fm.fileExists(atPath: leftover.path))
        #expect(fm.fileExists(atPath: orphan.path))
        #expect(try t.store.sweep() == 1)
        #expect(!fm.fileExists(atPath: orphan.path))
    }

    @Test func removeAllRemovesBothLayers() async throws {
        let t = try EnrichmentHarness(); defer { t.cleanup() }
        let pkg = try await t.h.add(note: "Plain")
        let id = pkg.metadata.captureID
        try t.store.write(try t.linkDoc(pkg, title: "Preview", thumbnail: nil), newAssets: [:])
        try t.store.write(try t.document(pkg, .server, facets: [.tags: TagsData(values: ["x"])]), newAssets: [:])
        try t.store.removeAll(captureID: id)
        #expect(!FileManager.default.fileExists(atPath: t.h.layout.enrichmentDirectory(.device, captureID: id).path))
        #expect(!FileManager.default.fileExists(atPath: t.h.layout.enrichmentDirectory(.server, captureID: id).path))
        try t.store.removeAll(captureID: id)
    }

    @Test func uploadCandidatesRules() async throws {
        let t = try EnrichmentHarness(); defer { t.cleanup() }
        try t.addDestination("d")
        try t.addDestination("other")
        var pkgs: [CommittedPackage] = []
        for n in 1...7 {
            pkgs.append(try await t.h.add(id: uuid(n), at: t0.addingTimeInterval(Double(n)), note: "c\(n)"))
        }
        func id(_ n: Int) -> String { pkgs[n - 1].metadata.captureID }
        func write(_ n: Int, _ title: String) throws -> String {
            try t.store.write(try t.linkDoc(pkgs[n - 1], title: title, thumbnail: nil), newAssets: [:])
            return try #require(try t.deviceRevision(id(n)))
        }
        func candidates(_ now: Date = t0) throws -> [String] {
            try t.store.uploadCandidates(destinationID: "d", now: now, limit: 50).map(\.captureID)
        }

        // 1: has silver but no synced job for "d" (pending there, synced elsewhere) → excluded.
        _ = try write(1, "one")
        try t.addJob(id(1), "d", state: "pending")
        try t.addJob(id(1), "other", state: "synced")
        // 2: synced + new revision → included.
        let rev2 = try write(2, "two")
        try t.addJob(id(2), "d", state: "synced")
        // 3: uploaded at the same revision → excluded.
        let rev3 = try write(3, "three")
        try t.addJob(id(3), "d", state: "synced")
        try t.store.markUploaded(captureID: id(3), destinationID: "d", revision: rev3, now: t0)
        // 4: blocked on the same revision → excluded.
        let rev4 = try write(4, "four")
        try t.addJob(id(4), "d", state: "synced")
        try t.store.markUploadFailed(captureID: id(4), destinationID: "d", revision: rev4, code: "bad",
                                     blocked: true, nextAttemptAt: nil, now: t0)
        // 5: blocked, then a new revision → included.
        let rev5old = try write(5, "five")
        try t.addJob(id(5), "d", state: "synced")
        try t.store.markUploadFailed(captureID: id(5), destinationID: "d", revision: rev5old, code: "bad",
                                     blocked: true, nextAttemptAt: nil, now: t0)
        let rev5 = try write(5, "five again")
        #expect(rev5 != rev5old)
        // 6: retry scheduled in the future → excluded until then.
        let rev6 = try write(6, "six")
        try t.addJob(id(6), "d", state: "synced")
        try t.store.markUploadFailed(captureID: id(6), destinationID: "d", revision: rev6, code: "net",
                                     blocked: false, nextAttemptAt: t0.addingTimeInterval(60), now: t0)
        // 7: synced but no silver → excluded.
        try t.addJob(id(7), "d", state: "synced")

        #expect(try candidates() == [id(5), id(2)])
        let rows = try t.store.uploadCandidates(destinationID: "d", now: t0, limit: 50)
        #expect(rows.map(\.revision) == [rev5, rev2])
        #expect(rows.map(\.relativeDirectory) == [pkgs[4].relativeDirectory, pkgs[1].relativeDirectory])
        #expect(try candidates(t0.addingTimeInterval(60)) == [id(6), id(5), id(2)])
        #expect(try t.store.uploadCandidates(destinationID: "d", now: t0, limit: 1).map(\.captureID) == [id(5)])
        #expect(try t.store.uploadCandidates(destinationID: "other", now: t0, limit: 50).map(\.captureID) == [id(1)])

        // 3 changes again → included; uploading it clears the row's failure state.
        let rev3b = try write(3, "three again")
        #expect(try candidates().contains(id(3)))
        try t.store.markUploaded(captureID: id(3), destinationID: "d", revision: rev3b, now: t0)
        #expect(try !candidates().contains(id(3)))
        try t.store.markUploaded(captureID: id(4), destinationID: "d", revision: rev4, now: t0)
        let row = try t.h.db.query("SELECT * FROM enrichment_uploads WHERE capture_id = ?", [.text(id(4))])[0]
        #expect(row.int("blocked") == 0)
        #expect(row.int("attempt_count") == 0)
        #expect(row.string("last_error_code") == nil)
        #expect(row.string("attempted_revision") == rev4)
    }

    @Test func goldCursorRoundTrip() throws {
        let t = try EnrichmentHarness(); defer { t.cleanup() }
        try t.addDestination("d")
        #expect(try t.store.goldCursor(destinationID: "d") == nil)
        try t.store.saveGoldCursor(destinationID: "d", cursor: "c1", now: t0)
        #expect(try t.store.goldCursor(destinationID: "d") == "c1")
        try t.store.recordGoldResult(destinationID: "d", code: "ok", now: t0)
        #expect(try t.store.goldCursor(destinationID: "d") == "c1")
        try t.store.saveGoldCursor(destinationID: "d", cursor: nil, now: t0)
        #expect(try t.store.goldCursor(destinationID: "d") == nil)
        let row = try t.h.db.query("SELECT * FROM gold_cursors WHERE destination_id = 'd'")[0]
        #expect(row.string("last_result_code") == "ok")
    }

    @Test func searchTextOrderAndLayers() throws {
        func doc(_ layer: EnrichmentLayer, _ facets: [FacetKind: (any Encodable, FacetStatus)]) throws -> EnrichmentDocument {
            var out: [String: Facet] = [:]
            for (kind, (payload, status)) in facets {
                let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(payload))
                out[kind.rawValue] = Facet(version: 1, status: status, generatedAt: t0, provenance: "t", data: json)
            }
            return EnrichmentDocument(schemaVersion: 1, captureID: "x", layer: layer, packageDigest: "d",
                                      producer: EnrichmentProducer(name: "t", version: "1", build: "1"),
                                      generatedAt: t0, facets: out)
        }
        let device = try doc(.device, [
            .linkPreview: (LinkPreviewData(items: [LinkPreviewItem(url: "https://u", title: "T", siteName: "S",
                                                                   channel: "C", summary: "D")]), .ok),
            .place: (PlaceData(items: [PlaceItem(target: "capture", subLocality: "Sub", locality: "Loc", region: "Reg",
                                                 country: "Cty", nearby: NearbyPlace(name: "Near", distanceMeters: 5))]), .ok),
            .textRecognition: (TextRecognitionData(items: [RecognizedText(attachmentID: "a", text: "OCR", languages: [])]), .ok),
            .transcript: (TranscriptData(items: [TranscriptItem(attachmentID: "b", text: "Said", locale: "en_US",
                                                                segments: [])]), .failed),
        ])
        let server = try doc(.server, [
            .summary: (SummaryData(text: "Sum"), .ok),
            .tags: (TagsData(values: ["t1", "t2"]), .ok),
        ])
        #expect(EnrichmentSearchText.make(device: device, server: server)
                == ["T", "S", "C", "D", "Sub", "Loc", "Reg", "Cty", "Near", "OCR", "Sum", "t1", "t2"].joined(separator: "\n"))
        #expect(EnrichmentSearchText.make(device: nil, server: nil) == "")
    }
}
