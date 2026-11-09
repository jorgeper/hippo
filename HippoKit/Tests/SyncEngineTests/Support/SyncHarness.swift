import Foundation
import CaptureCore
import LocalRepository
import SyncEngine
import FilesystemAdapter

let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// A settable clock for the worker's `now`.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ start: Date) { value = start }
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ d: Date) { lock.lock(); value = d; lock.unlock() }
}

/// A temp local store (database, index, writer, stores) with one active destination backed by a
/// filesystem adapter rooted at a temp "remote" directory.
struct SyncHarness {
    let root: URL
    let remote: URL
    let layout: StoreLayout
    let db: Database
    let index: CaptureIndex
    let writer: PackageWriter
    let destinations: DestinationStore
    let jobs: JobStore
    let log: ActivityLog
    let faults = FaultPlan()
    let clock = TestClock(t0)

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("hippo-sync-\(UUID().uuidString)")
        root = base.appendingPathComponent("local")
        remote = base.appendingPathComponent("remote")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        layout = StoreLayout(root: root)
        db = try Database(url: layout.databaseURL)
        index = CaptureIndex(db: db)
        writer = PackageWriter(layout: layout, producer: Producer(appVersion: "0.1.0", build: "1", osVersion: "test"))
        destinations = DestinationStore(db: db)
        jobs = JobStore(db: db)
        log = ActivityLog(layout: layout, process: .app)
        _ = try destinations.connect(Destination(id: "dest-fs", providerKind: "filesystem", accountIdentifier: "local",
                                                 remoteRoot: "/", displayName: "Local folder", status: .active))
    }

    func cleanup() { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

    var adapter: FilesystemAdapter { FilesystemAdapter(root: remote, faults: faults) }

    func worker(_ adapter: (any StorageAdapter)? = nil, owner: String = "test-worker",
                random: @escaping @Sendable () -> Double = { 1 }) -> SyncWorker {
        let a: any StorageAdapter = adapter ?? self.adapter
        let clock = self.clock, log = self.log
        return SyncWorker(layout: layout, jobs: jobs, destinations: destinations, index: index,
                          adapterFor: { _ in a }, owner: owner, now: { clock.now }, random: random, log: log)
    }

    /// Commits, registers and enqueues a capture with one attachment of `attachmentBytes` bytes, or a
    /// URL-only capture when `attachmentBytes` is nil.
    func capture(attachmentBytes: Int? = 1_000) async throws -> CommittedPackage {
        var attachments: [AttachmentSource] = []
        if let n = attachmentBytes {
            var data = Data(count: n)
            for i in 0..<n { data[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7) }
            attachments.append(AttachmentSource(body: .data(data), originalFilename: "blob.bin", uti: "public.data",
                                                mimeType: "application/octet-stream",
                                                representationSource: "item_provider_data"))
        }
        let draft = CaptureDraft(captureID: UUID(), startedAt: Date(timeIntervalSince1970: 1_794_070_800),
                                 timeZone: TimeZone(identifier: "America/Los_Angeles")!, method: .shareExtension,
                                 userNote: "note",
                                 urls: attachmentBytes == nil ? [CapturedURL(url: "https://example.com/a", source: "shared")] : [],
                                 attachments: attachments)
        let pkg = try await writer.commit(draft)
        _ = try index.register(pkg, noteBody: pkg.noteBody())
        try jobs.enqueueIfActive(captureID: pkg.metadata.captureID)
        return pkg
    }

    func job(_ pkg: CommittedPackage) throws -> UploadJob {
        let all = try jobs.jobs(captureID: pkg.metadata.captureID)
        precondition(all.count == 1)
        return all[0]
    }

    func remoteURL(_ pkg: CommittedPackage) -> URL { remote.appendingPathComponent(pkg.relativeDirectory) }

    var uploads: [String] { faults.operations.filter { $0.hasPrefix("upload ") } }
}

extension CommittedPackage {
    /// Remote path of the first attachment.
    var attachmentPath: String { relativeDirectory + "/" + metadata.attachments[0].relativePath }
    var markerPath: String { relativeDirectory + "/complete.json" }
    var metadataPath: String { relativeDirectory + "/metadata.json" }
}

/// A thread-safe counter for hooks.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    /// Increments and returns the new value.
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}

/// Wraps the filesystem adapter with test hooks: hide paths from `inspectFile`, act before an upload,
/// or act before each checkpoint is handed to the worker.
struct HookedAdapter: StorageAdapter {
    let inner: FilesystemAdapter
    var hideFromInspect: @Sendable (String) -> Bool = { _ in false }
    var beforeUpload: @Sendable (String) throws -> Void = { _ in }
    var onCheckpoint: @Sendable (String) throws -> Void = { _ in }
    var afterUpload: @Sendable (String) -> Void = { _ in }
    var beforeDownload: @Sendable (String) throws -> Void = { _ in }

    var capabilities: StorageCapabilities { inner.capabilities }
    func replaceFile(localURL: URL, relativePath: String, expected: FileIntegrity) async throws -> UploadReceipt {
        try await inner.replaceFile(localURL: localURL, relativePath: relativePath, expected: expected)
    }
    func listChanges(under prefix: String, cursor: String?) async throws -> ChangePage {
        try await inner.listChanges(under: prefix, cursor: cursor)
    }
    func downloadFile(relativePath: String, to localURL: URL, maxBytes: Int64,
                      progress: (@Sendable (Int64) -> Void)?) async throws -> RemoteFileInfo {
        try beforeDownload(relativePath)
        return try await inner.downloadFile(relativePath: relativePath, to: localURL, maxBytes: maxBytes, progress: progress)
    }
    func deleteFolder(relativePath: String) async throws { try await inner.deleteFolder(relativePath: relativePath) }
    func latestCursor(under prefix: String) async throws -> String { try await inner.latestCursor(under: prefix) }
    func listFolder(relativePath: String, recursive: Bool, cursor: String?) async throws -> ListPage {
        try await inner.listFolder(relativePath: relativePath, recursive: recursive, cursor: cursor)
    }
    func thumbnail(relativePath: String, maxPixelSize: Int) async throws -> Data? {
        try await inner.thumbnail(relativePath: relativePath, maxPixelSize: maxPixelSize)
    }
    func validateDestination() async throws { try await inner.validateDestination() }
    func ensureContainer(relativePath: String) async throws { try await inner.ensureContainer(relativePath: relativePath) }
    func inspectFile(relativePath: String) async throws -> RemoteFileInfo? {
        let info = try await inner.inspectFile(relativePath: relativePath)
        return hideFromInspect(relativePath) ? nil : info
    }
    func verify(remote: RemoteFileInfo, localURL: URL, expected: FileIntegrity) async throws -> VerificationEvidence? {
        try await inner.verify(remote: remote, localURL: localURL, expected: expected)
    }
    func uploadFile(localURL: URL, relativePath: String, expected: FileIntegrity, checkpoint: UploadCheckpoint?,
                    saveCheckpoint: @Sendable (UploadCheckpoint) async throws -> Void) async throws -> UploadReceipt {
        try beforeUpload(relativePath)
        let hook = onCheckpoint
        let receipt = try await inner.uploadFile(localURL: localURL, relativePath: relativePath, expected: expected,
                                                 checkpoint: checkpoint, saveCheckpoint: { cp in
            try hook(relativePath)
            try await saveCheckpoint(cp)
        })
        afterUpload(relativePath)
        return receipt
    }
}

/// A one-shot signal: `wait()` returns once `open()` has been called, before or after the wait began.
/// One waiter per gate.
final class Gate: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() { (stream, continuation) = AsyncStream.makeStream() }

    func open() { continuation.finish() }
    func wait() async { for await _ in stream {} }
}

/// Wraps the filesystem adapter and suspends the upload of `path` just after its first checkpoint
/// has been saved, so a worker is genuinely mid-file until `release` opens.
struct PausingAdapter: StorageAdapter {
    let inner: FilesystemAdapter
    let path: String
    let paused = Gate()
    let release = Gate()

    var capabilities: StorageCapabilities { inner.capabilities }
    func replaceFile(localURL: URL, relativePath: String, expected: FileIntegrity) async throws -> UploadReceipt {
        try await inner.replaceFile(localURL: localURL, relativePath: relativePath, expected: expected)
    }
    func listChanges(under prefix: String, cursor: String?) async throws -> ChangePage {
        try await inner.listChanges(under: prefix, cursor: cursor)
    }
    func downloadFile(relativePath: String, to localURL: URL, maxBytes: Int64,
                      progress: (@Sendable (Int64) -> Void)?) async throws -> RemoteFileInfo {
        try await inner.downloadFile(relativePath: relativePath, to: localURL, maxBytes: maxBytes, progress: progress)
    }
    func deleteFolder(relativePath: String) async throws { try await inner.deleteFolder(relativePath: relativePath) }
    func latestCursor(under prefix: String) async throws -> String { try await inner.latestCursor(under: prefix) }
    func listFolder(relativePath: String, recursive: Bool, cursor: String?) async throws -> ListPage {
        try await inner.listFolder(relativePath: relativePath, recursive: recursive, cursor: cursor)
    }
    func thumbnail(relativePath: String, maxPixelSize: Int) async throws -> Data? {
        try await inner.thumbnail(relativePath: relativePath, maxPixelSize: maxPixelSize)
    }
    func validateDestination() async throws { try await inner.validateDestination() }
    func ensureContainer(relativePath: String) async throws { try await inner.ensureContainer(relativePath: relativePath) }
    func inspectFile(relativePath: String) async throws -> RemoteFileInfo? {
        try await inner.inspectFile(relativePath: relativePath)
    }
    func verify(remote: RemoteFileInfo, localURL: URL, expected: FileIntegrity) async throws -> VerificationEvidence? {
        try await inner.verify(remote: remote, localURL: localURL, expected: expected)
    }
    func uploadFile(localURL: URL, relativePath: String, expected: FileIntegrity, checkpoint: UploadCheckpoint?,
                    saveCheckpoint: @Sendable (UploadCheckpoint) async throws -> Void) async throws -> UploadReceipt {
        guard relativePath == path else {
            return try await inner.uploadFile(localURL: localURL, relativePath: relativePath, expected: expected,
                                              checkpoint: checkpoint, saveCheckpoint: saveCheckpoint)
        }
        let (count, paused, release) = (Counter(), self.paused, self.release)
        return try await inner.uploadFile(localURL: localURL, relativePath: relativePath, expected: expected,
                                          checkpoint: checkpoint, saveCheckpoint: { cp in
            try await saveCheckpoint(cp)
            if count.next() == 1 {
                paused.open()
                await release.wait()
            }
        })
    }
}
