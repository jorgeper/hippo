import Foundation
import CaptureCore
import SyncEngine

/// Local-directory storage adapter for development and contract tests. Not a cloud provider.
public struct FilesystemAdapter: StorageAdapter {
    public static let chunkSize = 1 << 20

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
                            maxSingleRequestBytes: Int64(Self.chunkSize))
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
                try await saveCheckpoint(UploadCheckpoint(opaque: data))
                if let e = faults.takeAfterBytes(relativePath, copied: state.offset) { throw e }
            }
        } catch let e as StorageError {
            throw e
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as CocoaError where e.code == .fileNoSuchFile || e.code == .fileReadNoSuchFile {
            throw StorageError.permanent(code: "local_file_missing")
        } catch {
            // Errors thrown by saveCheckpoint (or I/O) propagate unchanged unless they are filesystem errors.
            if error is CocoaError || error is POSIXError { throw StorageError.transient(code: "io_error") }
            throw error
        }

        let digest = try StreamingHasher.digest(of: tempURL)
        guard digest.byteCount == expected.byteCount, digest.sha256 == expected.sha256 else {
            try? fm.removeItem(at: tempURL)
            throw StorageError.permanent(code: "integrity_mismatch")
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
