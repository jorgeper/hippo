import Foundation
import SyncEngine

public struct DropboxAdapter: StorageAdapter {
    private static let hashKind = "dropbox_content_hash"

    private let client: DropboxClient
    private let accountID: String
    private let root: String
    private let scratch: URL
    private let cutoff: Int64
    private let chunkSize: Int64

    public init(client: DropboxClient, accountID: String, rootPrefix: String, scratchDirectory: URL,
                singleRequestCutoff: Int64 = 8 << 20, chunkSize: Int64 = 8 << 20) {
        self.client = client
        self.accountID = accountID
        self.root = rootPrefix
        self.scratch = scratchDirectory
        self.cutoff = singleRequestCutoff
        self.chunkSize = chunkSize
    }

    public var capabilities: StorageCapabilities {
        StorageCapabilities(supportsFolders: true, supportsResumableUpload: true,
                            supportsBackgroundTransfers: client.usesBackgroundUploads, serverSideSHA256: false,
                            maxSingleRequestBytes: cutoff, supportsThumbnails: true)
    }

    // MARK: Wire types

    private struct Tag: Encodable {
        var tag: String
        enum CodingKeys: String, CodingKey { case tag = ".tag" }
    }
    private struct PathArg: Encodable { var path: String }
    private struct CreateFolderArg: Encodable { var path: String; var autorename = false }
    private struct MetadataArg: Encodable { var path: String; var include_deleted = false }
    private struct Commit: Encodable {
        var path: String
        var mode: Tag
        var autorename = false
        var mute = true
        var strict_conflict = true
    }
    private struct UploadArg: Encodable {
        var path: String
        var mode: Tag
        var autorename = false
        var mute = true
        var strict_conflict = true
    }
    private struct StartArg: Encodable { var close = false }
    private struct SessionCursor: Encodable { var session_id: String; var offset: Int64 }
    private struct AppendArg: Encodable { var cursor: SessionCursor; var close = false }
    private struct FinishArg: Encodable { var cursor: SessionCursor; var commit: Commit }
    private struct ListArg: Encodable {
        var path: String
        var recursive: Bool
        var include_deleted = false
        var limit = 2000
    }
    private struct CursorArg: Encodable { var cursor: String }
    private struct LatestCursorArg: Encodable { var path: String; var recursive: Bool }
    private struct ThumbnailArg: Encodable {
        struct Resource: Encodable {
            var path: String
            enum CodingKeys: String, CodingKey { case tag = ".tag", path }
            func encode(to encoder: any Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode("path", forKey: .tag)
                try c.encode(path, forKey: .path)
            }
        }
        var resource: Resource
        var format = Tag(tag: "jpeg")
        var size: Tag
        var mode = Tag(tag: "fitone_bestfit")
    }

    private struct Meta: Decodable {
        /// Only the `Metadata` union (get_metadata, list_folder entries) carries it; upload responses do not.
        var tag: String?
        var path_display: String?
        var size: Int64?
        var content_hash: String?
        enum CodingKeys: String, CodingKey { case tag = ".tag", path_display, size, content_hash }
    }
    private struct CreateFolderResult: Decodable { var metadata: Meta }
    private struct SessionStart: Decodable { var session_id: String }
    private struct Account: Decodable { var account_id: String }
    private struct ListResult: Decodable {
        var entries: [Meta]
        var cursor: String
        var has_more: Bool
    }
    private struct CursorResult: Decodable { var cursor: String }
    private struct Checkpoint: Codable { var session_id: String; var offset: Int64 }

    /// Carries an error thrown by `saveCheckpoint` past the error translation, unchanged.
    private struct CallerError: Error { let error: any Error }

    // MARK: Helpers

    private func run<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() }
        catch let e as CallerError { throw e.error }
        catch { throw DropboxClient.storageError(for: error) }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw StorageError.transient(code: "bad_response") }
    }

    private func remote(_ rel: String) throws -> String { try DropboxPaths.remote(rel, root: root) }

    /// The Dropbox path of a folder; the empty relative path is the app-folder root, which is `""`, never `"/"`.
    private func folder(_ rel: String) throws -> String {
        if rel.isEmpty { return root.isEmpty ? "" : "/" + root }
        return try remote(rel)
    }

    private func trimmed(_ prefix: String) -> String { prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix }

    private func isNotFound(_ e: DropboxCallError) -> Bool { e.status == 409 && e.tags.last == "not_found" }
    /// `path/not_found` or `path_lookup/not_found`: on `list_folder/continue`, the listed folder is gone.
    private func isListedRootGone(_ e: DropboxCallError) -> Bool {
        e.status == 409 && (e.tags.first == "path" || e.tags.first == "path_lookup") && e.tags.last == "not_found"
    }
    private func isPathConflict(_ e: DropboxCallError) -> Bool { e.status == 409 && e.tags.starts(with: ["path", "conflict"]) }

    private func isHidden(_ rel: String) -> Bool { rel.split(separator: "/").contains { $0.hasPrefix(".") } }

    private func info(_ rel: String, _ m: Meta) -> RemoteFileInfo {
        RemoteFileInfo(relativePath: rel, byteCount: m.size ?? 0,
                       providerHash: m.content_hash.map { ProviderHash(algorithm: Self.hashKind, value: $0) })
    }

    // MARK: Destination

    public func validateDestination() async throws {
        try await run {
            let account = try decode(Account.self, try await client.rpc("users/get_current_account"))
            guard account.account_id == accountID else { throw StorageError.permanent(code: "account_mismatch") }
        }
    }

    public func ensureContainer(relativePath: String) async throws {
        try await run { try await createFolder(try remote(relativePath)) }
    }

    private func createFolder(_ path: String) async throws {
        do { _ = try await client.rpc("files/create_folder_v2", CreateFolderArg(path: path)) }
        catch let e as DropboxCallError where e.status == 409 && e.tags.starts(with: ["path", "conflict", "folder"]) {}
    }

    public func inspectFile(relativePath: String) async throws -> RemoteFileInfo? {
        try await run { try await inspect(relativePath) }
    }

    private func inspect(_ rel: String) async throws -> RemoteFileInfo? {
        let path = try remote(rel)
        let data: Data
        do { data = try await client.rpc("files/get_metadata", MetadataArg(path: path)) }
        catch let e as DropboxCallError where isNotFound(e) { return nil }
        let meta = try decode(Meta.self, data)
        if meta.tag == "folder" { throw StorageError.permanent(code: "path_is_directory") }
        return info(rel, meta)
    }

    public func verify(remote: RemoteFileInfo, localURL: URL, expected: FileIntegrity) async throws -> VerificationEvidence? {
        try await run { try checkMatch(remote, localURL, expected) }
    }

    private func checkMatch(_ remote: RemoteFileInfo, _ localURL: URL, _ expected: FileIntegrity) throws -> VerificationEvidence? {
        guard remote.byteCount == expected.byteCount, let hash = remote.providerHash,
              hash.algorithm == Self.hashKind,
              try DropboxContentHash.of(localURL) == hash.value else { return nil }
        return VerificationEvidence(kind: Self.hashKind, value: hash.value)
    }

    // MARK: Upload

    public func uploadFile(localURL: URL, relativePath: String, expected: FileIntegrity, checkpoint: UploadCheckpoint?,
                           saveCheckpoint: @Sendable (UploadCheckpoint) async throws -> Void) async throws -> UploadReceipt {
        try await run {
            try Task.checkCancellation()
            let path = try remote(relativePath)
            if let existing = try await inspect(relativePath) {
                return try receiptOrConflict(existing, localURL, expected)
            }
            do {
                let meta = try await send(localURL: localURL, path: path, mode: "add", checkpoint: checkpoint,
                                          saveCheckpoint: saveCheckpoint)
                return try receipt(relativePath, meta)
            } catch let e as DropboxCallError where isPathConflict(e) {
                guard let existing = try await inspect(relativePath) else { throw StorageError.transient(code: "conflict_vanished") }
                return try receiptOrConflict(existing, localURL, expected)
            }
        }
    }

    public func replaceFile(localURL: URL, relativePath: String, expected: FileIntegrity) async throws -> UploadReceipt {
        try await run {
            let path = try remote(relativePath)
            guard relativePath.hasPrefix("enrichments/") || relativePath.hasPrefix("logs/") else {
                throw StorageError.permanent(code: "replace_not_allowed")
            }
            try Task.checkCancellation()
            let meta = try await send(localURL: localURL, path: path, mode: "overwrite", checkpoint: nil,
                                      saveCheckpoint: { _ in })
            guard meta.content_hash == (try DropboxContentHash.of(localURL)) else {
                throw StorageError.permanent(code: "integrity_mismatch")
            }
            return try receipt(relativePath, meta)
        }
    }

    private func receiptOrConflict(_ existing: RemoteFileInfo, _ localURL: URL, _ expected: FileIntegrity) throws -> UploadReceipt {
        guard let evidence = try checkMatch(existing, localURL, expected) else { throw StorageError.conflict(existing: existing) }
        return UploadReceipt(relativePath: existing.relativePath, byteCount: existing.byteCount, evidence: evidence)
    }

    private func receipt(_ rel: String, _ meta: Meta) throws -> UploadReceipt {
        guard let hash = meta.content_hash, let size = meta.size else { throw StorageError.transient(code: "bad_response") }
        return UploadReceipt(relativePath: rel, byteCount: size, evidence: VerificationEvidence(kind: Self.hashKind, value: hash))
    }

    private func send(localURL: URL, path: String, mode: String, checkpoint: UploadCheckpoint?,
                      saveCheckpoint: @Sendable (UploadCheckpoint) async throws -> Void) async throws -> Meta {
        let size: Int64
        do { size = (try FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?.int64Value ?? 0 }
        catch { throw StorageError.permanent(code: "local_file_missing") }
        if size <= cutoff, checkpoint == nil {
            let arg = UploadArg(path: path, mode: Tag(tag: mode))
            return try decode(Meta.self, try await client.upload("files/upload", arg: arg, file: localURL))
        }
        return try await sendInSessions(localURL: localURL, size: size, path: path, mode: mode, checkpoint: checkpoint,
                                        saveCheckpoint: saveCheckpoint)
    }

    private func sendInSessions(localURL: URL, size: Int64, path: String, mode: String, checkpoint: UploadCheckpoint?,
                                saveCheckpoint: @Sendable (UploadCheckpoint) async throws -> Void) async throws -> Meta {
        var sessionID: String
        var offset: Int64
        if let checkpoint {
            guard let cp = try? JSONDecoder().decode(Checkpoint.self, from: checkpoint.opaque),
                  (0...size).contains(cp.offset) else { throw StorageError.checkpointExpired }
            sessionID = cp.session_id
            offset = cp.offset
        } else {
            sessionID = try decode(SessionStart.self, try await client.upload("files/upload_session/start", arg: StartArg())).session_id
            offset = 0
        }
        func save() async throws {
            let data = (try? JSONEncoder().encode(Checkpoint(session_id: sessionID, offset: offset))) ?? Data()
            do { try await saveCheckpoint(UploadCheckpoint(opaque: data)) } catch { throw CallerError(error: error) }
        }
        var corrections = 0
        while true {
            try Task.checkCancellation()
            do {
                if offset < size {
                    let length = min(chunkSize, size - offset)
                    let slice = try writeSlice(of: localURL, offset: offset, length: length)
                    // A cancelled background append may still be read by the system; its transport then
                    // deletes the slice when that upload ends. Every other outcome deletes it here.
                    var handedOff = false
                    defer { if !handedOff { try? FileManager.default.removeItem(at: slice) } }
                    let arg = AppendArg(cursor: SessionCursor(session_id: sessionID, offset: offset))
                    do { _ = try await client.upload("files/upload_session/append_v2", arg: arg, file: slice, scratchFile: true) }
                    catch is CancellationError where client.usesBackgroundUploads {
                        handedOff = true
                        throw CancellationError()
                    }
                    offset += length
                    try await save()
                } else {
                    let arg = FinishArg(cursor: SessionCursor(session_id: sessionID, offset: offset),
                                        commit: Commit(path: path, mode: Tag(tag: mode)))
                    return try decode(Meta.self, try await client.upload("files/upload_session/finish", arg: arg))
                }
            } catch let e as DropboxCallError where e.status == 409 && e.tags.contains("incorrect_offset") {
                // Also covers a background append that finished after its pass was cancelled: Dropbox's
                // offset is then past the saved checkpoint, and the next attempt adopts it here.
                corrections += 1
                guard let correct = e.correctOffset, (0...size).contains(correct), corrections <= 5 else {
                    throw StorageError.checkpointExpired
                }
                offset = correct
                try await save()
            } catch let e as DropboxCallError where e.status == 409 && e.tags.first != "path" && e.tags.first != "path_lookup"
                && Set(e.tags).isDisjoint(with: ["not_found", "closed", "too_large"]) == false {
                throw StorageError.checkpointExpired
            }
        }
    }

    private func writeSlice(of url: URL, offset: Int64, length: Int64) throws -> URL {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let slice = scratch.appendingPathComponent("chunk-\(UUID().uuidString.lowercased())")
        do {
            let reader = try FileHandle(forReadingFrom: url)
            defer { try? reader.close() }
            try reader.seek(toOffset: UInt64(offset))
            let data = try reader.read(upToCount: Int(length)) ?? Data()
            guard data.count == Int(length) else { throw StorageError.permanent(code: "local_file_changed") }
            try data.write(to: slice)
        } catch let e as StorageError { throw e }
        catch { try? FileManager.default.removeItem(at: slice); throw StorageError.transient(code: "local_io") }
        return slice
    }

    // MARK: Changes and listing

    public func listChanges(under prefix: String, cursor: String?) async throws -> ChangePage {
        try await run {
            let dir = trimmed(prefix)
            guard let result = try await listPage(path: try folder(dir), recursive: true, cursor: cursor,
                                                  createIfMissing: dir) else { throw StorageError.transient(code: "bad_response") }
            var changes: [RemoteChange] = []
            for entry in result.entries {
                guard let display = entry.path_display, let rel = DropboxPaths.relative(display, root: root),
                      !isHidden(rel) else { continue }
                switch entry.tag ?? "" {
                case "file": changes.append(.upserted(info(rel, entry)))
                case "deleted": changes.append(.deleted(relativePath: rel))
                default: break
                }
            }
            return ChangePage(changes: changes, cursor: result.cursor, hasMore: result.has_more)
        }
    }

    /// `createIfMissing` names a folder (relative; "" is the root) to create when a first listing finds it absent.
    /// Without it, a missing folder returns nil.
    private func listPage(path: String, recursive: Bool, cursor: String?, createIfMissing: String? = nil,
                          emptyIfMissing: Bool = false) async throws -> ListResult? {
        if let cursor {
            do { return try decode(ListResult.self, try await client.rpc("files/list_folder/continue", CursorArg(cursor: cursor))) }
            catch let e as DropboxCallError where e.tags.contains("reset") || e.status == 400 || isListedRootGone(e) {
                // The listed folder itself was deleted (say, all of `captures/`): the caller re-baselines.
                throw StorageError.cursorReset
            }
        }
        let arg = ListArg(path: path, recursive: recursive)
        do { return try decode(ListResult.self, try await client.rpc("files/list_folder", arg)) }
        catch let e as DropboxCallError where isNotFound(e) {
            if emptyIfMissing { return nil }
            guard createIfMissing != nil else { throw e }
            if !path.isEmpty { try await createFolder(path) }
            return try decode(ListResult.self, try await client.rpc("files/list_folder", arg))
        }
    }

    public func latestCursor(under prefix: String) async throws -> String {
        try await run {
            let path = try folder(trimmed(prefix))
            let arg = LatestCursorArg(path: path, recursive: true)
            do { return try decode(CursorResult.self, try await client.rpc("files/list_folder/get_latest_cursor", arg)).cursor }
            catch let e as DropboxCallError where isNotFound(e) {
                if !path.isEmpty { try await createFolder(path) }
                return try decode(CursorResult.self, try await client.rpc("files/list_folder/get_latest_cursor", arg)).cursor
            }
        }
    }

    public func listFolder(relativePath: String, recursive: Bool, cursor: String?) async throws -> ListPage {
        try await run {
            guard let result = try await listPage(path: try folder(relativePath), recursive: recursive, cursor: cursor,
                                                  emptyIfMissing: true) else {
                return ListPage(entries: [], cursor: nil, hasMore: false)
            }
            var entries: [RemoteEntry] = []
            for entry in result.entries {
                guard entry.tag == "file" || entry.tag == "folder", let display = entry.path_display,
                      let rel = DropboxPaths.relative(display, root: root), !isHidden(rel) else { continue }
                let isFolder = entry.tag == "folder"
                entries.append(RemoteEntry(relativePath: rel, isFolder: isFolder, byteCount: isFolder ? 0 : (entry.size ?? 0),
                                           providerHash: isFolder ? nil : info(rel, entry).providerHash))
            }
            return ListPage(entries: entries, cursor: result.has_more ? result.cursor : nil, hasMore: result.has_more)
        }
    }

    // MARK: Delete, download, thumbnail

    public func deleteFolder(relativePath: String) async throws {
        try await run {
            let path = try remote(relativePath)
            let segments = relativePath.split(separator: "/")
            guard segments.count >= 2, segments[0] == "captures" || segments[0] == "enrichments" else {
                throw StorageError.permanent(code: "delete_not_allowed")
            }
            do { _ = try await client.rpc("files/delete_v2", PathArg(path: path)) }
            catch let e as DropboxCallError where e.status == 409 && e.tags.first == "path_lookup" && e.tags.last == "not_found" {}
        }
    }

    public func downloadFile(relativePath: String, to localURL: URL, maxBytes: Int64,
                             progress: (@Sendable (Int64) -> Void)?) async throws -> RemoteFileInfo {
        try await run {
            let path = try remote(relativePath)
            guard let existing = try await inspect(relativePath) else { throw StorageError.permanent(code: "not_found") }
            guard existing.byteCount <= maxBytes else { throw StorageError.permanent(code: "too_large") }
            let fm = FileManager.default
            let temp = localURL.deletingLastPathComponent()
                .appendingPathComponent(".\(localURL.lastPathComponent).part-\(UUID().uuidString.lowercased())")
            defer { try? fm.removeItem(at: temp) }
            let header = try await client.download("files/download", arg: PathArg(path: path), to: temp, progress: progress)
            let result: RemoteFileInfo = (try? JSONDecoder().decode(Meta.self, from: header)).flatMap { $0.size == nil ? nil : info(relativePath, $0) } ?? existing
            let written = (try fm.attributesOfItem(atPath: temp.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard written <= maxBytes else { throw StorageError.permanent(code: "too_large") }
            if fm.fileExists(atPath: localURL.path) { _ = try fm.replaceItemAt(localURL, withItemAt: temp) }
            else { try fm.moveItem(at: temp, to: localURL) }
            return result
        }
    }

    public func thumbnail(relativePath: String, maxPixelSize: Int) async throws -> Data? {
        try await run {
            let arg = ThumbnailArg(resource: .init(path: try remote(relativePath)),
                                   size: Tag(tag: maxPixelSize > 640 ? "w1024h768" : "w640h480"))
            do { return try await client.upload("files/get_thumbnail_v2", arg: arg) }
            catch let e as DropboxCallError where e.status == 409 { return nil }
        }
    }
}
