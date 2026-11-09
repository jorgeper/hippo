import Foundation
import Testing
import CryptoKit
import SyncEngine
import DropboxAdapter

private struct DeletePath: Encodable { var path: String }

/// Runs against a real Dropbox app folder when `.env` holds credentials; skipped otherwise.
@Suite(.serialized) struct DropboxAdapterContractTests {
    private struct Rig {
        let client: DropboxClient
        let adapter: DropboxAdapter
        let rootPath: String
        let scratch: URL

        func cleanup() async {
            do { _ = try await client.rpc("files/delete_v2", DeletePath(path: rootPath)) }
            catch { Issue.record("live test cleanup failed to delete the run root: \(error)") }
            try? FileManager.default.removeItem(at: scratch)
        }
    }

    private static func makeRig() async throws -> Rig {
        let key = try #require(DropboxTestCredentials.appKey)
        let refresh = try #require(DropboxTestCredentials.refreshToken)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("hippo-dbx-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let store = MemoryTokenStore(DropboxTokens(accessToken: "", expiresAt: .distantPast, refreshToken: refresh, accountID: ""))
        let transport = URLSessionTransport()
        let auth = DropboxAuth(appKey: key, tokens: store, lockURL: scratch.appendingPathComponent("refresh.lock"),
                               transport: transport)
        let client = DropboxClient(auth: auth, transport: transport)
        let account = try JSONSerialization.jsonObject(with: try await client.rpc("users/get_current_account")) as? [String: Any]
        let accountID = try #require(account?["account_id"] as? String)
        let root = "_hippo-test/\(UUID().uuidString.lowercased())"
        let adapter = DropboxAdapter(client: client, accountID: accountID, rootPrefix: root,
                                     scratchDirectory: scratch.appendingPathComponent("chunks"),
                                     singleRequestCutoff: 1 << 20, chunkSize: 1 << 20)
        return Rig(client: client, adapter: adapter, rootPath: "/" + root, scratch: scratch)
    }

    @Test(.enabled(if: DropboxTestCredentials.available))
    func dropboxAdapterPassesContract() async throws {
        let rig = try await Self.makeRig()
        do {
            try await runAdapterContract(makeAdapter: { rig.adapter }, scratch: rig.scratch.appendingPathComponent("contract"))
            try await roundTrip(rig)
        } catch {
            await rig.cleanup()
            throw error
        }
        await rig.cleanup()
    }

    private func roundTrip(_ rig: Rig) async throws {
        let data = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 1) })
        let source = rig.scratch.appendingPathComponent("rt.bin")
        try data.write(to: source)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let path = "captures/2026/11/07/rt/content/rt.bin"
        _ = try await rig.adapter.uploadFile(localURL: source, relativePath: path,
                                             expected: FileIntegrity(byteCount: Int64(data.count), sha256: sha),
                                             checkpoint: nil, saveCheckpoint: { _ in })
        let dest = rig.scratch.appendingPathComponent("rt-down.bin")
        _ = try await rig.adapter.downloadFile(relativePath: path, to: dest, maxBytes: 4 << 20)
        let back = try Data(contentsOf: dest)
        #expect(SHA256.hash(data: back).map { String(format: "%02x", $0) }.joined() == sha)
    }

    @Test(.enabled(if: DropboxTestCredentials.available))
    func listChangesReportsDeletedFolder() async throws {
        let rig = try await Self.makeRig()
        do {
            let folder = "captures/2026/11/07/abc"
            let file = rig.scratch.appendingPathComponent("d.bin")
            let data = Data(repeating: 9, count: 100)
            try data.write(to: file)
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            _ = try await rig.adapter.uploadFile(localURL: file, relativePath: "\(folder)/content/d.bin",
                                                 expected: FileIntegrity(byteCount: 100, sha256: sha),
                                                 checkpoint: nil, saveCheckpoint: { _ in })
            let cursor = try await rig.adapter.latestCursor(under: "captures/")
            try await rig.adapter.deleteFolder(relativePath: folder)
            var next = cursor
            var deleted: [String] = []
            var more = true
            while more {
                let page = try await rig.adapter.listChanges(under: "captures/", cursor: next)
                deleted += page.changes.compactMap { if case .deleted(let p) = $0 { p } else { nil } }
                next = page.cursor
                more = page.hasMore
            }
            #expect(deleted.contains { $0 == folder || $0.hasPrefix(folder + "/") })
        } catch {
            await rig.cleanup()
            throw error
        }
        await rig.cleanup()
    }
}
