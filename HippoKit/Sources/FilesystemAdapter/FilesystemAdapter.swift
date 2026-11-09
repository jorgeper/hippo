import Foundation
import CaptureCore
import SyncEngine
import UniformTypeIdentifiers

/// Local-directory storage adapter for development and contract tests. Not a cloud provider.
public struct FilesystemAdapter: StorageAdapter {
    public static let chunkSize = 1 << 20

    /// Carries an error thrown by `saveCheckpoint` past the I/O error translation, unchanged.
    private struct CallerError: Error { let error: any Error }

    private struct TempState: Codable {
        var temp: String
        var offset: Int64
    }

    private let root: URL
    private let faults: FaultPlan

    public init(root: URL, faults: FaultPlan = .none) {
        self.root = root
        self.faults = faults
    }

    public var capabilities: StorageCapabilities {
        StorageCapabilities(supportsFolders: true, supportsResumableUpload: true,
                            supportsBackgroundTransfers: false, serverSideSHA256: true,
                            maxSingleRequestBytes: Int64(Self.chunkSize), supportsThumbnails: true)
    }

    public func validateDestination() async throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw StorageError.permanent(code: "root_missing")
        }
    }

    public func ensureContainer(relativePath: String) async throws {
        faults.record("ensure \(relativePath)")
        let url = try resolve(relativePath)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw StorageError.transient(code: "create_directory_failed")
        }
    }

    public func inspectFile(relativePath: String) async throws -> RemoteFileInfo? {
        faults.record("inspect \(relativePath)")
        return try info(relativePath)
    }

    public func verify(remote: RemoteFileInfo, localURL: URL, expected: FileIntegrity) async throws -> VerificationEvidence? {
        guard remote.byteCount == expected.byteCount,
              let hash = remote.providerHash, hash.algorithm == "sha256",
              hash.value == expected.sha256 else { return nil }
        return VerificationEvidence(kind: "sha256", value: hash.value)
    }

    public func uploadFile(localURL: URL, relativePath: String, expected: FileIntegrity, checkpoint: UploadCheckpoint?,
                           saveCheckpoint: @Sendable (UploadCheckpoint) async throws -> Void) async throws -> UploadReceipt {
        faults.record("upload \(relativePath)")
        let finalURL = try resolve(relativePath)
        try Task.checkCancellation()
        if let e = faults.takeBeforeWrite(relativePath) { throw e }

        if let existing = try info(relativePath) {
            if let evidence = try await verify(remote: existing, localURL: localURL, expected: expected) {
                return UploadReceipt(relativePath: relativePath, byteCount: existing.byteCount, evidence: evidence)
            }
            throw StorageError.conflict(existing: existing)
        }

        let fm = FileManager.default
        var state: TempState
        if let checkpoint {
            guard let decoded = try? JSONDecoder().decode(TempState.self, from: checkpoint.opaque),
                  !decoded.temp.isEmpty, !decoded.temp.contains("/"), decoded.temp.hasPrefix(".tmp-"),
                  decoded.offset >= 0 else {
                throw StorageError.checkpointExpired
            }
            let size = (try? fm.attributesOfItem(atPath: root.appendingPathComponent(decoded.temp).path)[.size] as? Int64) ?? nil
            guard let size, size >= decoded.offset else { throw StorageError.checkpointExpired }
            state = decoded
        } else {
            state = TempState(temp: ".tmp-\(UUID().uuidString.lowercased())", offset: 0)
        }
        let tempURL = root.appendingPathComponent(state.temp)

        do {
            if state.offset == 0 { fm.createFile(atPath: tempURL.path, contents: nil) }
            let src = try FileHandle(forReadingFrom: localURL)
            defer { try? src.close() }
            let dst = try FileHandle(forWritingTo: tempURL)
            defer { try? dst.close() }
            try dst.truncate(atOffset: UInt64(state.offset))
            try dst.seekToEnd()
            try src.seek(toOffset: UInt64(state.offset))

            while true {
                try Task.checkCancellation()
                guard let chunk = try src.read(upToCount: Self.chunkSize), !chunk.isEmpty else { break }
                try dst.write(contentsOf: chunk)
                state.offset += Int64(chunk.count)
                let data = try JSONEncoder().encode(state)
                do { try await saveCheckpoint(UploadCheckpoint(opaque: data)) } catch { throw CallerError(error: error) }
                if let e = faults.takeAfterBytes(relativePath, copied: state.offset) { throw e }
            }
        } catch let e as CallerError {
            throw e.error
        } catch let e as StorageError {
            throw e
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as CocoaError where e.code == .fileNoSuchFile || e.code == .fileReadNoSuchFile {
            throw StorageError.permanent(code: "local_file_missing")
        } catch {
            if error is CocoaError || error is POSIXError { throw StorageError.transient(code: "io_error") }
            throw error
        }

        let digest = try StreamingHasher.digest(of: tempURL)
        guard digest.byteCount == expected.byteCount, digest.sha256 == expected.sha256 else {
            try? fm.removeItem(at: tempURL)
            // A resumed temp that no longer matches is a stale checkpoint: restart cleanly.
            throw checkpoint != nil ? StorageError.checkpointExpired : StorageError.permanent(code: "integrity_mismatch")
        }

        do {
            try fm.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: tempURL, to: finalURL)
        } catch {
            throw StorageError.transient(code: "rename_failed")
        }
        if let e = faults.takeWriteButThrow(relativePath) { throw e }
        return UploadReceipt(relativePath: relativePath, byteCount: digest.byteCount,
                             evidence: VerificationEvidence(kind: "sha256", value: digest.sha256))
    }

    // MARK: - Replace, list changes, download

    public func replaceFile(localURL: URL, relativePath: String, expected: FileIntegrity) async throws -> UploadReceipt {
        faults.record("replace \(relativePath)")
        let finalURL = try resolve(relativePath)
        guard relativePath.hasPrefix("enrichments/") || relativePath.hasPrefix("logs/") else { throw StorageError.permanent(code: "replace_not_allowed") }
        try Task.checkCancellation()
        let fm = FileManager.default
        let tempURL = root.appendingPathComponent(".tmp-\(UUID().uuidString.lowercased())")
        defer { try? fm.removeItem(at: tempURL) }
        let digest: FileDigest
        do {
            try fm.copyItem(at: localURL, to: tempURL)
            digest = try StreamingHasher.digest(of: tempURL)
        } catch let e as CocoaError where e.code == .fileNoSuchFile || e.code == .fileReadNoSuchFile {
            throw StorageError.permanent(code: "local_file_missing")
        } catch {
            throw StorageError.transient(code: "io_error")
        }
        guard digest.byteCount == expected.byteCount, digest.sha256 == expected.sha256 else {
            throw StorageError.permanent(code: "integrity_mismatch")
        }
        do {
            try fm.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: finalURL.path) {
                _ = try fm.replaceItemAt(finalURL, withItemAt: tempURL)
            } else {
                try fm.moveItem(at: tempURL, to: finalURL)
            }
        } catch {
            throw StorageError.transient(code: "replace_failed")
        }
        return UploadReceipt(relativePath: relativePath, byteCount: digest.byteCount,
                             evidence: VerificationEvidence(kind: "sha256", value: digest.sha256))
    }

    private struct Snapshot: Codable {
        var prefix: String
        var files: [String: Entry]
        struct Entry: Codable, Equatable { var size: Int64; var sha256: String }
    }

    private var cursorDirectory: URL { root.appendingPathComponent(".hippo-cursors") }

    public func listChanges(under prefix: String, cursor: String?) async throws -> ChangePage {
        faults.record("list \(prefix)")
        return try changePage(under: prefix, cursor: cursor)
    }

    private func changePage(under prefix: String, cursor: String?) throws -> ChangePage {
        guard !prefix.hasPrefix("/"), !prefix.contains("\\"), !prefix.contains("\0"),
              !prefix.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." })
        else { throw StorageError.permanent(code: "invalid_path") }

        var previous: Snapshot?
        if let cursor {
            guard cursor.utf8.count <= 4096, UUID(uuidString: cursor) != nil,
                  let data = try? Data(contentsOf: cursorDirectory.appendingPathComponent("\(cursor).json")),
                  let snap = try? JSONDecoder().decode(Snapshot.self, from: data), snap.prefix == prefix else {
                throw StorageError.cursorReset
            }
            previous = snap
        }

        let (scanned, unreadable) = try scan(prefix: prefix)
        var currentFiles = scanned
        // An unreadable entry is neither reported nor treated as deleted: keep its previous entry (if any)
        // so it surfaces as a change once it is readable again.
        for path in unreadable { if let old = previous?.files[path] { currentFiles[path] = old } }
        let current = Snapshot(prefix: prefix, files: currentFiles)

        var changes: [RemoteChange] = []
        for path in current.files.keys.sorted() where previous?.files[path] != current.files[path] {
            if let entry = current.files[path] {
                changes.append(.upserted(RemoteFileInfo(relativePath: path, byteCount: entry.size,
                                                        providerHash: ProviderHash(algorithm: "sha256", value: entry.sha256))))
            }
        }
        if let previous {
            for path in previous.files.keys.sorted() where current.files[path] == nil {
                changes.append(.deleted(relativePath: path))
            }
        }

        let id = UUID().uuidString.lowercased()
        let newURL = cursorDirectory.appendingPathComponent("\(id).json")
        do {
            try FileManager.default.createDirectory(at: cursorDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(current).write(to: newURL, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: newURL)
            throw StorageError.transient(code: "cursor_write_failed")
        }
        // The superseded snapshot is no longer needed; a caller that retries the old cursor gets cursorReset.
        if let cursor { try? FileManager.default.removeItem(at: cursorDirectory.appendingPathComponent("\(cursor).json")) }
        return ChangePage(changes: changes, cursor: id, hasMore: false)
    }

    private func scan(prefix: String) throws -> (files: [String: Snapshot.Entry], unreadable: Set<String>) {
        let fm = FileManager.default
        let dirPart = prefix.contains("/") ? String(prefix[..<prefix.lastIndex(of: "/")!]) : ""
        let start = dirPart.isEmpty ? root : try resolve(dirPart)
        var result: [String: Snapshot.Entry] = [:]
        var unreadable: Set<String> = []
        guard let walker = fm.enumerator(at: start, includingPropertiesForKeys: [.isDirectoryKey],
                                         options: [.skipsHiddenFiles]) else { return (result, unreadable) }
        let basePath = root.resolvingSymlinksInPath().path
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory != true else { continue }
            let full = url.resolvingSymlinksInPath().path
            guard full.hasPrefix(basePath + "/") else { continue }
            let rel = String(full.dropFirst(basePath.count + 1))
            guard rel.hasPrefix(prefix), !rel.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }
            guard let digest = try? StreamingHasher.digest(of: url) else { unreadable.insert(rel); continue }
            result[rel] = Snapshot.Entry(size: digest.byteCount, sha256: digest.sha256)
        }
        return (result, unreadable)
    }

    public func downloadFile(relativePath: String, to localURL: URL, maxBytes: Int64,
                             progress: (@Sendable (Int64) -> Void)?) async throws -> RemoteFileInfo {
        faults.record("download \(relativePath)")
        let url = try resolve(relativePath)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            throw StorageError.permanent(code: "not_found")
        }
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
        guard let size else { throw StorageError.transient(code: "read_failed") }
        guard size <= maxBytes else { throw StorageError.permanent(code: "too_large") }
        try Task.checkCancellation()
        do {
            try? fm.removeItem(at: localURL)
            try fm.copyItem(at: url, to: localURL)
        } catch {
            try? fm.removeItem(at: localURL)
            throw StorageError.transient(code: "io_error")
        }
        let digest: FileDigest
        do { digest = try StreamingHasher.digest(of: localURL) } catch {
            try? fm.removeItem(at: localURL)
            throw StorageError.transient(code: "read_failed")
        }
        if digest.byteCount > maxBytes {
            try? fm.removeItem(at: localURL)
            throw StorageError.permanent(code: "too_large")
        }
        progress?(digest.byteCount)
        return RemoteFileInfo(relativePath: relativePath, byteCount: digest.byteCount,
                              providerHash: ProviderHash(algorithm: "sha256", value: digest.sha256))
    }

    // MARK: - Folders, cursor, thumbnails

    public func deleteFolder(relativePath: String) async throws {
        faults.record("deleteFolder \(relativePath)")
        let url = try resolve(relativePath)
        let segments = relativePath.split(separator: "/")
        guard segments.count >= 2, segments[0] == "captures" || segments[0] == "enrichments" else {
            throw StorageError.permanent(code: "delete_not_allowed")
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            if !FileManager.default.fileExists(atPath: url.path) { return }
            throw StorageError.transient(code: "delete_failed")
        }
    }

    public func latestCursor(under prefix: String) async throws -> String {
        faults.record("latestCursor \(prefix)")
        let dirPart = prefix.contains("/") ? String(prefix[..<prefix.lastIndex(of: "/")!]) : ""
        if !dirPart.isEmpty {
            let dir = try resolve(dirPart)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                throw StorageError.transient(code: "create_directory_failed")
            }
        }
        return try changePage(under: prefix, cursor: nil).cursor
    }

    public func listFolder(relativePath: String, recursive: Bool, cursor: String?) async throws -> ListPage {
        faults.record("listFolder \(relativePath)")
        let start = try resolve(relativePath)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: start.path, isDirectory: &isDir), isDir.boolValue else {
            return ListPage(entries: [], cursor: nil, hasMore: false)
        }
        let keys: [URLResourceKey] = [.isDirectoryKey]
        var urls: [URL] = []
        if recursive {
            guard let walker = fm.enumerator(at: start, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
                return ListPage(entries: [], cursor: nil, hasMore: false)
            }
            urls = walker.compactMap { $0 as? URL }
        } else {
            urls = (try? fm.contentsOfDirectory(at: start, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        }
        let basePath = root.resolvingSymlinksInPath().path
        var entries: [RemoteEntry] = []
        for url in urls {
            let full = url.resolvingSymlinksInPath().path
            guard full.hasPrefix(basePath + "/") else { continue }
            let rel = String(full.dropFirst(basePath.count + 1))
            guard !rel.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                entries.append(RemoteEntry(relativePath: rel, isFolder: true, byteCount: 0, providerHash: nil))
            } else if let digest = try? StreamingHasher.digest(of: url) {
                entries.append(RemoteEntry(relativePath: rel, isFolder: false, byteCount: digest.byteCount,
                                           providerHash: ProviderHash(algorithm: "sha256", value: digest.sha256)))
            }
        }
        entries.sort { $0.relativePath < $1.relativePath }
        return ListPage(entries: entries, cursor: nil, hasMore: false)
    }

    public func thumbnail(relativePath: String, maxPixelSize: Int) async throws -> Data? {
        faults.record("thumbnail \(relativePath)")
        let url = try resolve(relativePath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            throw StorageError.permanent(code: "not_found")
        }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        return await LocalThumbnailer.jpeg(for: url, uti: type.identifier, maxPixelSize: maxPixelSize)
    }

    // MARK: - Helpers

    private func info(_ relativePath: String) throws -> RemoteFileInfo? {
        let url = try resolve(relativePath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        if isDir.boolValue { throw StorageError.permanent(code: "path_is_directory") }
        let digest: FileDigest
        do { digest = try StreamingHasher.digest(of: url) } catch { throw StorageError.transient(code: "read_failed") }
        return RemoteFileInfo(relativePath: relativePath, byteCount: digest.byteCount,
                              providerHash: ProviderHash(algorithm: "sha256", value: digest.sha256))
    }

    private func resolve(_ relativePath: String) throws -> URL {
        let invalid = StorageError.permanent(code: "invalid_path")
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"), !relativePath.contains("\0") else { throw invalid }
        var url = root
        for seg in relativePath.split(separator: "/", omittingEmptySubsequences: false) {
            if seg.isEmpty || seg == "." || seg == ".." { throw invalid }
            url.appendPathComponent(String(seg))
        }
        return url
    }
}
