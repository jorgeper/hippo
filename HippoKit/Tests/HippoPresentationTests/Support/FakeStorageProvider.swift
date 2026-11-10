import Foundation
import Synchronization
import FilesystemAdapter
import LocalRepository
import SyncEngine
@testable import HippoPresentation

/// A non-interactive provider whose destination is a local folder, uploaded to with `FilesystemAdapter`.
/// `adapter` replaces the adapter it builds, for tests that need to hold an upload.
final class FakeStorageProvider: StorageProvider {
    let kind: String
    let displayName = "Developer folder"
    let id: String
    let root: URL
    let faults: FaultPlan
    private let adapter: (@Sendable (Destination) -> any StorageAdapter)?
    private let signOuts = Mutex(0)
    private let status = Mutex(ProviderAccountStatus.ok)
    private let account = Mutex<String?>(nil)

    init(root: URL, id: String = "dev", kind: String = "filesystem", faults: FaultPlan = FaultPlan(),
         adapter: (@Sendable (Destination) -> any StorageAdapter)? = nil) {
        self.root = root
        self.id = id
        self.kind = kind
        self.faults = faults
        self.adapter = adapter
    }

    var destination: Destination {
        Destination(id: id, providerKind: kind, accountIdentifier: "this-iphone", remoteRoot: root.path,
                    displayName: displayName, status: .active)
    }

    /// How many times `signOut` was called.
    var signOutCount: Int { signOuts.withLock { $0 } }

    @MainActor func connect() async throws -> Destination {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return destination
    }

    func makeAdapter(for d: Destination) throws -> any StorageAdapter {
        adapter?(d) ?? FilesystemAdapter(root: URL(fileURLWithPath: d.remoteRoot, isDirectory: true), faults: faults)
    }

    func signOut(_ d: Destination) async { signOuts.withLock { $0 += 1 } }

    /// What `accountStatus` reports; `.ok` until set.
    func setAccountStatus(_ s: ProviderAccountStatus) { status.withLock { $0 = s } }
    func accountStatus(_ d: Destination) async -> ProviderAccountStatus { status.withLock { $0 } }

    /// What `accountName` reports; nil until set.
    func setAccountName(_ name: String?) { account.withLock { $0 = name } }
    func accountName(_ d: Destination) async -> String? { account.withLock { $0 } }
}

/// Wraps an adapter and holds the first upload until `release()`; `started()` returns once it is held.
final class HeldAdapter: StorageAdapter {
    private let base: any StorageAdapter
    private let held = Mutex(false)
    private let (startedStream, startedSignal) = AsyncStream<Void>.makeStream()
    private let (releaseStream, releaseSignal) = AsyncStream<Void>.makeStream()

    init(_ base: any StorageAdapter) { self.base = base }

    func started() async { for await _ in startedStream { return } }
    func release() { releaseSignal.finish() }

    var capabilities: StorageCapabilities { base.capabilities }
    func replaceFile(localURL: URL, relativePath: String, expected: FileIntegrity) async throws -> UploadReceipt {
        try await base.replaceFile(localURL: localURL, relativePath: relativePath, expected: expected)
    }
    func listChanges(under prefix: String, cursor: String?) async throws -> ChangePage {
        try await base.listChanges(under: prefix, cursor: cursor)
    }
    func downloadFile(relativePath: String, to localURL: URL, maxBytes: Int64,
                      progress: (@Sendable (Int64) -> Void)?) async throws -> RemoteFileInfo {
        try await base.downloadFile(relativePath: relativePath, to: localURL, maxBytes: maxBytes, progress: progress)
    }
    func deleteFolder(relativePath: String) async throws { try await base.deleteFolder(relativePath: relativePath) }
    func latestCursor(under prefix: String) async throws -> String { try await base.latestCursor(under: prefix) }
    func listFolder(relativePath: String, recursive: Bool, cursor: String?) async throws -> ListPage {
        try await base.listFolder(relativePath: relativePath, recursive: recursive, cursor: cursor)
    }
    func thumbnail(relativePath: String, maxPixelSize: Int) async throws -> Data? {
        try await base.thumbnail(relativePath: relativePath, maxPixelSize: maxPixelSize)
    }
    func validateDestination() async throws { try await base.validateDestination() }
    func ensureContainer(relativePath: String) async throws { try await base.ensureContainer(relativePath: relativePath) }
    func inspectFile(relativePath: String) async throws -> RemoteFileInfo? {
        try await base.inspectFile(relativePath: relativePath)
    }
    func verify(remote: RemoteFileInfo, localURL: URL, expected: FileIntegrity) async throws -> VerificationEvidence? {
        try await base.verify(remote: remote, localURL: localURL, expected: expected)
    }
    func uploadFile(localURL: URL, relativePath: String, expected: FileIntegrity, checkpoint: UploadCheckpoint?,
                    saveCheckpoint: @Sendable (UploadCheckpoint) async throws -> Void) async throws -> UploadReceipt {
        let first = held.withLock { wasHeld in
            defer { wasHeld = true }
            return !wasHeld
        }
        if first {
            startedSignal.yield()
            for await _ in releaseStream {}
        }
        return try await base.uploadFile(localURL: localURL, relativePath: relativePath, expected: expected,
                                         checkpoint: checkpoint, saveCheckpoint: saveCheckpoint)
    }
}
