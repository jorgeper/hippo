import Foundation
import Testing
import CryptoKit
import SyncEngine
@testable import DropboxAdapter

private struct Harness {
    let api = ScriptedTransport()
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("hippo-dbx-\(UUID().uuidString)")
    let adapter: DropboxAdapter

    init(root: String = "", cutoff: Int64 = 8 << 20, chunk: Int64 = 8 << 20) {
        adapter = DropboxAdapter(client: makeClient(api: api), accountID: "dbid:acct", rootPrefix: root,
                                 scratchDirectory: scratch.appendingPathComponent("chunks"),
                                 singleRequestCutoff: cutoff, chunkSize: chunk)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    func file(_ name: String, bytes: Int) throws -> (URL, FileIntegrity) {
        var data = Data(count: bytes)
        for i in 0..<bytes { data[i] = UInt8(truncatingIfNeeded: i &* 13 &+ 5) }
        let url = scratch.appendingPathComponent(name)
        try data.write(to: url)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (url, FileIntegrity(byteCount: Int64(bytes), sha256: sha))
    }

    func on(_ endpoint: String, _ result: Result<DropboxResponse, Error>) {
        api.enqueue(matching: { $0.url.path == "/2/" + endpoint }, result)
    }

    func meta(_ url: URL, path: String = "/captures/x") throws -> [String: Any] {
        ["path_display": path, "size": try Data(contentsOf: url).count,
         "content_hash": try DropboxContentHash.of(url)]
    }

    /// `get_metadata` returns the `Metadata` union, which carries `.tag`; upload responses do not.
    func tagged(_ m: [String: Any]) -> [String: Any] { m.merging([".tag": "file"]) { a, _ in a } }

    func apiError(_ tags: Any, status: Int = 409) -> Result<DropboxResponse, Error> {
        ScriptedTransport.json(["error": tags, "error_summary": "x"], status: status)
    }

    func arg(_ r: DropboxRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data((r.headers["Dropbox-API-Arg"] ?? "").utf8))) as? [String: Any] ?? [:]
    }

    func rpcBody(_ r: DropboxRequest) -> [String: Any] {
        guard case .json(let d) = r.body else { return [:] }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
    }

    func paths(_ suffix: String) -> [DropboxRequest] { api.requests.filter { $0.url.path == "/2/" + suffix } }
}

private var notFound: [String: Any] { [".tag": "path", "path": [".tag": "not_found"]] }
private let noCheckpoint: @Sendable (UploadCheckpoint) async throws -> Void = { _ in }

private final class Saved: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [UploadCheckpoint] = []
    func add(_ c: UploadCheckpoint) { lock.lock(); all.append(c); lock.unlock() }
    var checkpoints: [UploadCheckpoint] { lock.lock(); defer { lock.unlock() }; return all }
    var offsets: [Int64] {
        checkpoints.compactMap { (try? JSONSerialization.jsonObject(with: $0.opaque) as? [String: Any])?["offset"] as? Int64 }
    }
}

@Suite struct DropboxAdapterTests {
    @Test func remotePathUsesRootPrefix() throws {
        #expect(try DropboxPaths.remote("captures/x", root: "") == "/captures/x")
        #expect(try DropboxPaths.remote("captures/x", root: "_hippo-test/r1") == "/_hippo-test/r1/captures/x")
        #expect(DropboxPaths.relative("/_hippo-test/r1/captures/x", root: "_hippo-test/r1") == "captures/x")
        #expect(DropboxPaths.relative("/_HIPPO-test/R1/captures/x", root: "_hippo-test/r1") == "captures/x")
        #expect(DropboxPaths.relative("/captures/x", root: "") == "captures/x")
        #expect(DropboxPaths.relative("/other/captures/x", root: "r1") == nil)
        for bad in ["", "/abs", "a/../b", "a/./b", "a//b", "a\\b", "a\0b", ".."] {
            #expect(throws: StorageError.permanent(code: "invalid_path")) { _ = try DropboxPaths.remote(bad, root: "") }
        }
    }

    @Test func capabilitiesDescribeDropbox() {
        let c = Harness(cutoff: 1234).adapter.capabilities
        #expect(c.supportsFolders && c.supportsResumableUpload && c.supportsThumbnails)
        #expect(!c.supportsBackgroundTransfers && !c.serverSideSHA256 && c.maxSingleRequestBytes == 1234)
    }

    @Test func validateDestinationChecksAccount() async throws {
        let h = Harness()
        h.on("users/get_current_account", ScriptedTransport.json(["account_id": "dbid:acct", "name": ["display_name": "J"]]))
        try await h.adapter.validateDestination()
        h.on("users/get_current_account", ScriptedTransport.json(["account_id": "dbid:other"]))
        await #expect(throws: StorageError.permanent(code: "account_mismatch")) { try await h.adapter.validateDestination() }
    }

    @Test func ensureContainerTreatsFolderConflictAsSuccess() async throws {
        let h = Harness(root: "r")
        h.on("files/create_folder_v2", h.apiError([".tag": "path", "path": [".tag": "conflict", "conflict": [".tag": "folder"]]]))
        try await h.adapter.ensureContainer(relativePath: "captures/a")
        let body = h.rpcBody(h.paths("files/create_folder_v2")[0])
        #expect(body["path"] as? String == "/r/captures/a" && body["autorename"] as? Bool == false)
    }

    @Test func inspectMapsMissingFilesAndFolders() async throws {
        let h = Harness()
        h.on("files/get_metadata", h.apiError(notFound))
        #expect(try await h.adapter.inspectFile(relativePath: "a/b") == nil)
        h.on("files/get_metadata", ScriptedTransport.json([".tag": "folder", "path_display": "/a/b"]))
        await #expect(throws: StorageError.permanent(code: "path_is_directory")) { _ = try await h.adapter.inspectFile(relativePath: "a/b") }
        h.on("files/get_metadata", ScriptedTransport.json([".tag": "file", "size": 5, "content_hash": "abc"]))
        let info = try #require(try await h.adapter.inspectFile(relativePath: "a/b"))
        #expect(info == RemoteFileInfo(relativePath: "a/b", byteCount: 5,
                                       providerHash: ProviderHash(algorithm: "dropbox_content_hash", value: "abc")))
    }

    @Test func smallUploadIsSingleRequestWithAddMode() async throws {
        let h = Harness()
        let (url, integrity) = try h.file("a.bin", bytes: 1000)
        h.on("files/get_metadata", h.apiError(notFound))
        h.on("files/upload", ScriptedTransport.json(try h.meta(url)))
        let receipt = try await h.adapter.uploadFile(localURL: url, relativePath: "captures/x", expected: integrity,
                                                     checkpoint: nil, saveCheckpoint: noCheckpoint)
        #expect(receipt.evidence.kind == "dropbox_content_hash")
        #expect(receipt.evidence.value == (try DropboxContentHash.of(url)))
        #expect(receipt.byteCount == 1000 && receipt.relativePath == "captures/x")
        let uploads = h.paths("files/upload")
        #expect(uploads.count == 1)
        let a = h.arg(uploads[0])
        #expect((a["mode"] as? [String: Any])?[".tag"] as? String == "add")
        #expect(a["autorename"] as? Bool == false && a["strict_conflict"] as? Bool == true && a["mute"] as? Bool == true)
        #expect(a["path"] as? String == "/captures/x")
    }

    @Test func existingMatchingFileIsAReceiptWithoutUploading() async throws {
        let h = Harness()
        let (url, integrity) = try h.file("a.bin", bytes: 300)
        h.on("files/get_metadata", ScriptedTransport.json(h.tagged(try h.meta(url))))
        _ = try await h.adapter.uploadFile(localURL: url, relativePath: "captures/x", expected: integrity,
                                           checkpoint: nil, saveCheckpoint: noCheckpoint)
        #expect(h.paths("files/upload").isEmpty)
    }

    @Test func conflictWithMatchingHashIsSuccess() async throws {
        let h = Harness()
        let (url, integrity) = try h.file("a.bin", bytes: 500)
        h.on("files/get_metadata", h.apiError(notFound))
        h.on("files/upload", h.apiError([".tag": "path", "reason": [".tag": "conflict", "conflict": [".tag": "file"]], "upload_session_id": "SECRET-SESSION"]))
        h.on("files/get_metadata", ScriptedTransport.json(h.tagged(try h.meta(url))))
        let receipt = try await h.adapter.uploadFile(localURL: url, relativePath: "captures/x", expected: integrity,
                                                     checkpoint: nil, saveCheckpoint: noCheckpoint)
        #expect(receipt.byteCount == 500)
    }

    @Test func conflictWithDifferentHashThrowsConflict() async throws {
        let h = Harness()
        let (url, integrity) = try h.file("a.bin", bytes: 500)
        let (other, _) = try h.file("b.bin", bytes: 500)
        try Data(repeating: 1, count: 500).write(to: other)
        h.on("files/get_metadata", h.apiError(notFound))
        h.on("files/upload", h.apiError([".tag": "path", "reason": [".tag": "conflict", "conflict": [".tag": "file"]], "upload_session_id": "SECRET-SESSION"]))
        h.on("files/get_metadata", ScriptedTransport.json(h.tagged(try h.meta(other))))
        do {
            _ = try await h.adapter.uploadFile(localURL: url, relativePath: "captures/x", expected: integrity,
                                               checkpoint: nil, saveCheckpoint: noCheckpoint)
            Issue.record("expected conflict")
        } catch let StorageError.conflict(existing) {
            #expect(existing.byteCount == 500)
        }
    }

    @Test func largeUploadUsesSessionsAndCheckpoints() async throws {
        let h = Harness(cutoff: 1024, chunk: 1024)
        let (url, integrity) = try h.file("big.bin", bytes: 2560)
        h.on("files/get_metadata", h.apiError(notFound))
        h.on("files/upload_session/start", ScriptedTransport.json(["session_id": "S1"]))
        h.on("files/upload_session/append_v2", .success(DropboxResponse(status: 200)))
        h.on("files/upload_session/append_v2", .success(DropboxResponse(status: 200)))
        h.on("files/upload_session/append_v2", .success(DropboxResponse(status: 200)))
        h.on("files/upload_session/finish", ScriptedTransport.json(try h.meta(url)))
        let saved = Saved()
        let receipt = try await h.adapter.uploadFile(localURL: url, relativePath: "captures/x", expected: integrity,
                                                     checkpoint: nil, saveCheckpoint: { saved.add($0) })
        #expect(receipt.byteCount == 2560)
        let appends = h.paths("files/upload_session/append_v2")
        let offsets = appends.map { ((h.arg($0)["cursor"] as? [String: Any])?["offset"] as? Int) ?? -1 }
        #expect(offsets == [0, 1024, 2048])
        #expect(appends.allSatisfy { h.arg($0)["close"] as? Bool == false })
        let finish = h.arg(h.paths("files/upload_session/finish")[0])
        #expect((finish["cursor"] as? [String: Any])?["offset"] as? Int == 2560)
        #expect((finish["cursor"] as? [String: Any])?["session_id"] as? String == "S1")
        let commit = try #require(finish["commit"] as? [String: Any])
        #expect((commit["mode"] as? [String: Any])?[".tag"] as? String == "add")
        #expect(commit["strict_conflict"] as? Bool == true && commit["autorename"] as? Bool == false)
        #expect(saved.offsets == [1024, 2048, 2560])
        let start = h.paths("files/upload_session/start")[0]
        #expect(h.arg(start)["close"] as? Bool == false)
        // Chunk slices are removed after each request.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: h.scratch.appendingPathComponent("chunks").path)) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test func incorrectOffsetAdoptsCorrectOffset() async throws {
        let h = Harness(cutoff: 1024, chunk: 1024)
        let (url, integrity) = try h.file("big.bin", bytes: 3072)
        let cp = UploadCheckpoint(opaque: Data(#"{"session_id":"S1","offset":1024}"#.utf8))
        h.on("files/get_metadata", h.apiError(notFound))
        h.on("files/upload_session/append_v2", h.apiError([".tag": "incorrect_offset", "correct_offset": 2048]))
        h.on("files/upload_session/append_v2", .success(DropboxResponse(status: 200)))
        h.on("files/upload_session/finish", ScriptedTransport.json(try h.meta(url)))
        let saved = Saved()
        _ = try await h.adapter.uploadFile(localURL: url, relativePath: "captures/x", expected: integrity,
                                           checkpoint: cp, saveCheckpoint: { saved.add($0) })
        let appends = h.paths("files/upload_session/append_v2")
        let offsets = appends.map { ((h.arg($0)["cursor"] as? [String: Any])?["offset"] as? Int) ?? -1 }
        #expect(offsets == [1024, 2048])
        #expect(saved.offsets == [2048, 3072])
        #expect(h.paths("files/upload_session/start").isEmpty)
    }

    @Test func lostSessionExpiresTheCheckpoint() async throws {
        let h = Harness(cutoff: 1024, chunk: 1024)
        let (url, integrity) = try h.file("big.bin", bytes: 3072)
        let cp = UploadCheckpoint(opaque: Data(#"{"session_id":"S1","offset":1024}"#.utf8))
        h.on("files/get_metadata", h.apiError(notFound))
        h.on("files/upload_session/append_v2", h.apiError([".tag": "not_found"]))
        await #expect(throws: StorageError.checkpointExpired) {
            _ = try await h.adapter.uploadFile(localURL: url, relativePath: "captures/x", expected: integrity,
                                               checkpoint: cp, saveCheckpoint: noCheckpoint)
        }
        let garbage = UploadCheckpoint(opaque: Data("junk".utf8))
        h.on("files/get_metadata", h.apiError(notFound))
        await #expect(throws: StorageError.checkpointExpired) {
            _ = try await h.adapter.uploadFile(localURL: url, relativePath: "captures/x", expected: integrity,
                                               checkpoint: garbage, saveCheckpoint: noCheckpoint)
        }
    }

    @Test func saveCheckpointErrorsPropagateUnchanged() async throws {
        struct Signal: Error, Equatable {}
        let h = Harness(cutoff: 1024, chunk: 1024)
        let (url, integrity) = try h.file("big.bin", bytes: 2048)
        h.on("files/get_metadata", h.apiError(notFound))
        h.on("files/upload_session/start", ScriptedTransport.json(["session_id": "S1"]))
        h.on("files/upload_session/append_v2", .success(DropboxResponse(status: 200)))
        do {
            _ = try await h.adapter.uploadFile(localURL: url, relativePath: "captures/x", expected: integrity,
                                               checkpoint: nil, saveCheckpoint: { _ in throw URLError(.timedOut) })
            Issue.record("expected a throw")
        } catch let e as URLError { #expect(e.code == .timedOut) }
    }

    @Test func replaceUsesOverwriteAndVerifiesTheHash() async throws {
        let h = Harness()
        let (url, integrity) = try h.file("r.bin", bytes: 300)
        h.on("files/upload", ScriptedTransport.json(try h.meta(url, path: "/enrichments/e.json")))
        let receipt = try await h.adapter.replaceFile(localURL: url, relativePath: "enrichments/e.json", expected: integrity)
        #expect(receipt.evidence.kind == "dropbox_content_hash")
        #expect((h.arg(h.paths("files/upload")[0])["mode"] as? [String: Any])?[".tag"] as? String == "overwrite")

        var wrong = try h.meta(url)
        wrong["content_hash"] = "deadbeef"
        h.on("files/upload", ScriptedTransport.json(wrong))
        await #expect(throws: StorageError.permanent(code: "integrity_mismatch")) {
            _ = try await h.adapter.replaceFile(localURL: url, relativePath: "logs/a.jsonl", expected: integrity)
        }
        await #expect(throws: StorageError.permanent(code: "replace_not_allowed")) {
            _ = try await h.adapter.replaceFile(localURL: url, relativePath: "captures/a/x", expected: integrity)
        }
    }

    @Test func deleteFolderNotFoundIsSuccess() async throws {
        let h = Harness(root: "r")
        h.on("files/delete_v2", h.apiError([".tag": "path_lookup", "path_lookup": [".tag": "not_found"]]))
        try await h.adapter.deleteFolder(relativePath: "captures/2026/11/07/abc")
        #expect(h.rpcBody(h.paths("files/delete_v2")[0])["path"] as? String == "/r/captures/2026/11/07/abc")
    }

    @Test func deleteFolderRefusesOutOfScopePaths() async throws {
        let h = Harness()
        for p in ["logs/abc", "captures", "enrichments", "other/x"] {
            await #expect(throws: StorageError.permanent(code: "delete_not_allowed")) { try await h.adapter.deleteFolder(relativePath: p) }
        }
        await #expect(throws: StorageError.permanent(code: "invalid_path")) { try await h.adapter.deleteFolder(relativePath: "captures/../x") }
        #expect(h.api.requests.isEmpty)
    }

    @Test func listChangesMapsDeletedFolderAndDropsFolders() async throws {
        let h = Harness(root: "r")
        h.on("files/list_folder", ScriptedTransport.json([
            "entries": [
                [".tag": "folder", "path_display": "/r/captures/2026"],
                [".tag": "file", "path_display": "/r/captures/2026/a", "size": 4, "content_hash": "h1"],
                [".tag": "file", "path_display": "/r/captures/2026/.tmp", "size": 4, "content_hash": "h2"],
                [".tag": "deleted", "path_display": "/r/captures/2025/gone"],
            ], "cursor": "C1", "has_more": true]))
        let page = try await h.adapter.listChanges(under: "captures/", cursor: nil)
        #expect(page.changes == [
            .upserted(RemoteFileInfo(relativePath: "captures/2026/a", byteCount: 4,
                                     providerHash: ProviderHash(algorithm: "dropbox_content_hash", value: "h1"))),
            .deleted(relativePath: "captures/2025/gone"),
        ])
        #expect(page.cursor == "C1" && page.hasMore)
        let body = h.rpcBody(h.paths("files/list_folder")[0])
        #expect(body["path"] as? String == "/r/captures" && body["recursive"] as? Bool == true)
        #expect(body["include_deleted"] as? Bool == false && body["limit"] as? Int == 2000)

        h.on("files/list_folder/continue", h.apiError([".tag": "reset"]))
        await #expect(throws: StorageError.cursorReset) { _ = try await h.adapter.listChanges(under: "captures/", cursor: "C1") }
    }

    @Test func listChangesCreatesAMissingFolderAndRetriesOnce() async throws {
        let h = Harness()
        h.on("files/list_folder", h.apiError(notFound))
        h.on("files/create_folder_v2", ScriptedTransport.json(["metadata": [".tag": "folder"]]))
        h.on("files/list_folder", ScriptedTransport.json(["entries": [], "cursor": "C", "has_more": false]))
        let page = try await h.adapter.listChanges(under: "captures/", cursor: nil)
        #expect(page.changes.isEmpty && page.cursor == "C")
    }

    @Test func latestCursorCreatesAMissingFolder() async throws {
        let h = Harness()
        h.on("files/list_folder/get_latest_cursor", h.apiError(notFound))
        h.on("files/create_folder_v2", ScriptedTransport.json(["metadata": [".tag": "folder"]]))
        h.on("files/list_folder/get_latest_cursor", ScriptedTransport.json(["cursor": "LC"]))
        #expect(try await h.adapter.latestCursor(under: "captures/") == "LC")
        #expect(h.rpcBody(h.paths("files/list_folder/get_latest_cursor")[0])["path"] as? String == "/captures")
    }

    @Test func listFolderUsesEmptyStringForTheRootAndReturnsEntries() async throws {
        let h = Harness()
        h.on("files/list_folder", ScriptedTransport.json([
            "entries": [[".tag": "folder", "path_display": "/captures"],
                        [".tag": "file", "path_display": "/a.bin", "size": 3, "content_hash": "h"]],
            "cursor": "C", "has_more": false]))
        let page = try await h.adapter.listFolder(relativePath: "", recursive: false, cursor: nil)
        #expect(h.rpcBody(h.paths("files/list_folder")[0])["path"] as? String == "")
        #expect(page.entries.map(\.relativePath) == ["captures", "a.bin"])
        #expect(page.entries.map(\.isFolder) == [true, false])
        #expect(page.cursor == nil && !page.hasMore)
        h.on("files/list_folder", h.apiError(notFound))
        let none = try await h.adapter.listFolder(relativePath: "captures/2099", recursive: true, cursor: nil)
        #expect(none.entries.isEmpty && !none.hasMore)
    }

    @Test func thumbnailUnsupportedIsNil() async throws {
        let h = Harness()
        h.on("files/get_thumbnail_v2", h.apiError([".tag": "path", "path": [".tag": "unsupported_extension"]]))
        #expect(try await h.adapter.thumbnail(relativePath: "a/x.bin", maxPixelSize: 64) == nil)
        h.api.enqueue(matching: { $0.url.path.hasSuffix("get_thumbnail_v2") },
                      .success(DropboxResponse(status: 200, body: Data([0xFF, 0xD8, 1]))))
        let jpeg = try await h.adapter.thumbnail(relativePath: "a/x.png", maxPixelSize: 900)
        #expect(jpeg == Data([0xFF, 0xD8, 1]))
        let arg = h.arg(h.paths("files/get_thumbnail_v2")[1])
        #expect((arg["size"] as? [String: Any])?[".tag"] as? String == "w1024h768")
        #expect((arg["resource"] as? [String: Any])?[".tag"] as? String == "path")
        #expect((h.arg(h.paths("files/get_thumbnail_v2")[0])["size"] as? [String: Any])?[".tag"] as? String == "w640h480")
    }

    @Test func downloadTooLargeWritesNothing() async throws {
        let h = Harness()
        h.on("files/get_metadata", ScriptedTransport.json([".tag": "file", "size": 5000, "content_hash": "h"]))
        let dest = h.scratch.appendingPathComponent("out.bin")
        await #expect(throws: StorageError.permanent(code: "too_large")) {
            _ = try await h.adapter.downloadFile(relativePath: "a/x", to: dest, maxBytes: 10)
        }
        #expect(!FileManager.default.fileExists(atPath: dest.path))
        #expect(h.paths("files/download").isEmpty)
    }

    @Test func downloadMissingAndSuccess() async throws {
        let h = Harness()
        let dest = h.scratch.appendingPathComponent("out.bin")
        h.on("files/get_metadata", h.apiError(notFound))
        await #expect(throws: StorageError.permanent(code: "not_found")) {
            _ = try await h.adapter.downloadFile(relativePath: "a/x", to: dest, maxBytes: 100)
        }
        h.on("files/get_metadata", ScriptedTransport.json([".tag": "file", "size": 3, "content_hash": "h"]))
        h.api.enqueue(matching: { $0.url.path == "/2/files/download" },
                      .success(DropboxResponse(status: 200, headers: ["dropbox-api-result": #"{"size":3,"content_hash":"fromheader"}"#], body: Data([1, 2, 3]))))
        let info = try await h.adapter.downloadFile(relativePath: "a/x", to: dest, maxBytes: 100)
        #expect(info.byteCount == 3 && info.providerHash?.value == "fromheader")
        #expect(try Data(contentsOf: dest) == Data([1, 2, 3]))
        let siblings = try FileManager.default.contentsOfDirectory(atPath: h.scratch.path).filter { $0.contains(".part-") }
        #expect(siblings.isEmpty)
    }

    @Test func offlineAndRateLimitSurfaceAsStorageErrors() async throws {
        let h = Harness()
        h.on("files/get_metadata", .failure(URLError(.notConnectedToInternet)))
        await #expect(throws: StorageError.offline) { _ = try await h.adapter.inspectFile(relativePath: "a/x") }
        h.on("files/get_metadata", .success(DropboxResponse(status: 429, headers: ["retry-after": "7"],
                                                            body: Data(#"{"error":{".tag":"too_many_requests"}}"#.utf8))))
        await #expect(throws: StorageError.rateLimited(retryAfter: 7)) { _ = try await h.adapter.inspectFile(relativePath: "a/x") }
    }
}
