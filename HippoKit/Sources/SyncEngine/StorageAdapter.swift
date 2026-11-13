import Foundation

public struct StorageCapabilities: Sendable {
    public var supportsFolders: Bool
    public var supportsResumableUpload: Bool
    public var supportsBackgroundTransfers: Bool
    public var serverSideSHA256: Bool
    public var maxSingleRequestBytes: Int64
    /// True when `thumbnail(relativePath:maxPixelSize:)` can return an image.
    public var supportsThumbnails: Bool

    public init(supportsFolders: Bool, supportsResumableUpload: Bool, supportsBackgroundTransfers: Bool,
                serverSideSHA256: Bool, maxSingleRequestBytes: Int64, supportsThumbnails: Bool = false) {
        self.supportsFolders = supportsFolders
        self.supportsResumableUpload = supportsResumableUpload
        self.supportsBackgroundTransfers = supportsBackgroundTransfers
        self.serverSideSHA256 = serverSideSHA256
        self.maxSingleRequestBytes = maxSingleRequestBytes
        self.supportsThumbnails = supportsThumbnails
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

public struct RemoteEntry: Sendable, Equatable {
    public var relativePath: String
    public var isFolder: Bool
    public var byteCount: Int64
    public var providerHash: ProviderHash?

    public init(relativePath: String, isFolder: Bool, byteCount: Int64, providerHash: ProviderHash?) {
        self.relativePath = relativePath
        self.isFolder = isFolder
        self.byteCount = byteCount
        self.providerHash = providerHash
    }
}

public struct ListPage: Sendable, Equatable {
    public var entries: [RemoteEntry]
    public var cursor: String?
    public var hasMore: Bool

    public init(entries: [RemoteEntry], cursor: String?, hasMore: Bool) {
        self.entries = entries
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

/// Which destination paths an adapter's `replaceFile` may overwrite. Every adapter calls this, so the set is
/// defined once. Exact and case-sensitive.
public enum ReplacePolicy {
    private static let prefixes = ["enrichments/", "logs/", "format/"]

    /// True for the prefixes `enrichments/`, `logs/` and `format/` (with the slash, so `format` alone and
    /// `formatting/a.md` are refused) and the exact path `README.md`. A path that is empty, starts with `/`
    /// or has an empty, `.` or `..` component is refused.
    public static func allows(_ relativePath: String) -> Bool {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return false }
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return false }
        return relativePath == "README.md" || prefixes.contains { relativePath.hasPrefix($0) }
    }
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

    /// Atomic overwrite. Throws `.permanent(code: "replace_not_allowed")` unless `ReplacePolicy.allows(relativePath)`.
    func replaceFile(localURL: URL, relativePath: String, expected: FileIntegrity) async throws -> UploadReceipt
    /// A nil cursor returns every file under `prefix` as `.upserted`; otherwise the changes since `cursor`.
    /// A `.deleted` entry may name a folder (the whole subtree is gone) or a file; implementations may
    /// report either. An unknown or garbled cursor throws `.cursorReset`. Directories and hidden or temporary entries
    /// (any path segment starting with `.`) are never reported.
    func listChanges(under prefix: String, cursor: String?) async throws -> ChangePage
    /// Over `maxBytes` throws `.permanent(code: "too_large")` and leaves no file at `localURL`.
    /// A missing file throws `.permanent(code: "not_found")`. `progress` receives the bytes written so far.
    func downloadFile(relativePath: String, to localURL: URL, maxBytes: Int64,
                      progress: (@Sendable (Int64) -> Void)?) async throws -> RemoteFileInfo
    /// Recursive and idempotent: a missing folder is success. Throws `.permanent(code: "invalid_path")` for an
    /// unsafe path and `.permanent(code: "delete_not_allowed")` unless the path starts with `captures/` or
    /// `enrichments/` and has at least two segments.
    func deleteFolder(relativePath: String) async throws
    /// A cursor for changes from now on under `prefix`, listing nothing. `prefix` is a folder path ending in `/`
    /// (a missing trailing slash is treated the same). Creates that folder if it doesn't exist.
    func latestCursor(under prefix: String) async throws -> String
    /// Files and folders with sizes and hashes. A nil `cursor` starts; an empty `relativePath` lists the root; a missing folder returns an empty page
    /// with `hasMore == false`. Hidden entries (a segment starting with `.`) are never reported.
    func listFolder(relativePath: String, recursive: Bool, cursor: String?) async throws -> ListPage
    /// JPEG bytes, or nil when the provider can't make one (including for a folder). A missing file's behaviour
    /// is adapter-specific (the filesystem adapter throws `not_found`). Callers check `capabilities.supportsThumbnails` first.
    func thumbnail(relativePath: String, maxPixelSize: Int) async throws -> Data?
}

extension StorageAdapter {
    public func downloadFile(relativePath: String, to localURL: URL, maxBytes: Int64) async throws -> RemoteFileInfo {
        try await downloadFile(relativePath: relativePath, to: localURL, maxBytes: maxBytes, progress: nil)
    }
}
