import Foundation

public struct StorageCapabilities: Sendable {
    public var supportsFolders: Bool
    public var supportsResumableUpload: Bool
    public var supportsBackgroundTransfers: Bool
    public var serverSideSHA256: Bool
    public var maxSingleRequestBytes: Int64

    public init(supportsFolders: Bool, supportsResumableUpload: Bool, supportsBackgroundTransfers: Bool,
                serverSideSHA256: Bool, maxSingleRequestBytes: Int64) {
        self.supportsFolders = supportsFolders
        self.supportsResumableUpload = supportsResumableUpload
        self.supportsBackgroundTransfers = supportsBackgroundTransfers
        self.serverSideSHA256 = serverSideSHA256
        self.maxSingleRequestBytes = maxSingleRequestBytes
    }
}

public struct FileIntegrity: Sendable, Equatable {
    public var byteCount: Int64
    public var sha256: String

    public init(byteCount: Int64, sha256: String) {
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public struct ProviderHash: Sendable, Equatable {
    public var algorithm: String
    public var value: String

    public init(algorithm: String, value: String) {
        self.algorithm = algorithm
        self.value = value
    }
}

public struct RemoteFileInfo: Sendable, Equatable {
    public var relativePath: String
    public var byteCount: Int64
    public var providerHash: ProviderHash?

    public init(relativePath: String, byteCount: Int64, providerHash: ProviderHash?) {
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.providerHash = providerHash
    }
}

public struct VerificationEvidence: Sendable, Equatable {
    /// "sha256" | "dropbox_content_hash" | "size_only"
    public var kind: String
    public var value: String

    public init(kind: String, value: String) {
        self.kind = kind
        self.value = value
    }
}

public struct UploadCheckpoint: Sendable, Equatable {
    public var opaque: Data

    public init(opaque: Data) {
        self.opaque = opaque
    }
}

public struct UploadReceipt: Sendable, Equatable {
    public var relativePath: String
    public var byteCount: Int64
    public var evidence: VerificationEvidence

    public init(relativePath: String, byteCount: Int64, evidence: VerificationEvidence) {
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.evidence = evidence
    }
}

public enum RemoteChange: Sendable, Equatable {
    case upserted(RemoteFileInfo)
    case deleted(relativePath: String)
}

public struct ChangePage: Sendable, Equatable {
    public var changes: [RemoteChange]
    public var cursor: String
    public var hasMore: Bool

    public init(changes: [RemoteChange], cursor: String, hasMore: Bool) {
        self.changes = changes
        self.cursor = cursor
        self.hasMore = hasMore
    }
}

public enum StorageError: Error, Sendable, Equatable {
    case offline
    case needsAuthentication
    case rateLimited(retryAfter: TimeInterval?)
    case quotaExceeded
    case conflict(existing: RemoteFileInfo)
    case checkpointExpired
    case cursorReset
    case transient(code: String)
    case permanent(code: String)
}

public protocol StorageAdapter: Sendable {
    var capabilities: StorageCapabilities { get }
    func validateDestination() async throws
    func ensureContainer(relativePath: String) async throws
    func inspectFile(relativePath: String) async throws -> RemoteFileInfo?
    /// Returns evidence if `remote` provably matches the local file, nil if it differs.
    func verify(remote: RemoteFileInfo, localURL: URL, expected: FileIntegrity) async throws -> VerificationEvidence?
    /// Calls `saveCheckpoint` as resumable progress is made. Any error `saveCheckpoint` throws must
    /// end the upload and propagate unchanged: adapters must not wrap or translate it (the sync engine
    /// uses it to stop an upload whose lease was lost or whose job was cancelled).
    func uploadFile(localURL: URL, relativePath: String, expected: FileIntegrity, checkpoint: UploadCheckpoint?,
                    saveCheckpoint: @Sendable (UploadCheckpoint) async throws -> Void) async throws -> UploadReceipt

    /// Atomic overwrite. Throws `.permanent(code: "replace_not_allowed")` unless `relativePath` starts with
    /// `enrichments/` or `logs/`. A provider's overwrite-capable upload (Plan 3) must allow both prefixes.
    func replaceFile(localURL: URL, relativePath: String, expected: FileIntegrity) async throws -> UploadReceipt
    /// A nil cursor returns every file under `prefix` as `.upserted`; otherwise the changes since `cursor`.
    /// An unknown or garbled cursor throws `.cursorReset`. Directories and hidden or temporary entries
    /// (any path segment starting with `.`) are never reported.
    func listChanges(under prefix: String, cursor: String?) async throws -> ChangePage
    /// Over `maxBytes` throws `.permanent(code: "too_large")` and leaves no file at `localURL`.
    /// A missing file throws `.permanent(code: "not_found")`.
    func downloadFile(relativePath: String, to localURL: URL, maxBytes: Int64) async throws -> RemoteFileInfo
}
