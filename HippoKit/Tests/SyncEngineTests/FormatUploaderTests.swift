import Foundation
import Testing
import CaptureCore
import LocalRepository
@testable import SyncEngine
import FilesystemAdapter

/// The repo's own `docs/` and `schema/`, found from this file's path.
private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let repoDocs = repoRoot.appendingPathComponent("docs", isDirectory: true)
private let repoSchema = repoRoot.appendingPathComponent("schema", isDirectory: true)

private let formatPaths = [
    "format/README.md", "format/context-signals.md", "format/enrichment-format.md", "format/package-format.md",
    "format/schema/capture-comment-v1.schema.json", "format/schema/capture-metadata-v1.schema.json",
    "format/schema/complete-v1.schema.json", "format/schema/enrichment-v1.schema.json",
]

/// Fails the `n`th `replaceFile` call (1-based) with a transient error; every other call goes through.
private struct FailingReplaceAdapter: StorageAdapter {
    let inner: FilesystemAdapter
    let failingCall: Int
    let calls = Counter()

    var capabilities: StorageCapabilities { inner.capabilities }
    func replaceFile(localURL: URL, relativePath: String, expected: FileIntegrity) async throws -> UploadReceipt {
        if calls.next() == failingCall { throw StorageError.transient(code: "boom") }
        return try await inner.replaceFile(localURL: localURL, relativePath: relativePath, expected: expected)
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
        try await inner.uploadFile(localURL: localURL, relativePath: relativePath, expected: expected,
                                   checkpoint: checkpoint, saveCheckpoint: saveCheckpoint)
    }
}

private struct Setup {
    let h: SyncHarness
    let bundle: FormatBundle

    init() throws {
        h = try SyncHarness()
        bundle = try FormatBundle.load(docsDirectory: repoDocs, schemaDirectory: repoSchema)
    }

    var stateURL: URL { h.layout.root.appendingPathComponent("format-upload-state.json") }

    func uploader(_ bundle: FormatBundle?, _ adapter: (any StorageAdapter)? = nil) -> FormatUploader {
        let a: any StorageAdapter = adapter ?? h.adapter
        return FormatUploader(layout: h.layout, log: h.log, destinations: h.destinations, bundle: bundle,
                              adapterFor: { _ in a })
    }

    func remote(_ path: String) -> URL { h.remote.appendingPathComponent(path) }
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: remote(path).path) }

    func events(_ name: LogEventName) -> [LogEvent] {
        h.log.globalEvents(limit: 200, before: nil).filter { $0.event == name }
    }

    func storedDigest() -> String? {
        guard let data = try? Data(contentsOf: stateURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]] else { return nil }
        return json["dest-fs"]?["digest"]
    }

    var replaces: [String] { h.faults.operations.filter { $0.hasPrefix("replace ") } }

    /// A copy of `docs/` and `schema/` in a temp folder, so a test can edit a document.
    func copyOfRepoFiles() throws -> (docs: URL, schema: URL) {
        let base = h.root.deletingLastPathComponent().appendingPathComponent("bundle-copy")
        let docs = base.appendingPathComponent("docs"), schema = base.appendingPathComponent("schema")
        let fm = FileManager.default
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        try fm.copyItem(at: repoDocs, to: docs)
        try fm.copyItem(at: repoSchema, to: schema)
        return (docs, schema)
    }
}

@Suite struct FormatUploaderTests {
    @Test func repoBundleLoads() throws {
        let s = try Setup(); defer { s.h.cleanup() }
        #expect(s.bundle.formatFiles.map(\.relativePath) == formatPaths)
        #expect(s.bundle.readme.relativePath == "README.md")
        #expect(s.bundle.readme.localURL == s.bundle.formatFiles[0].localURL)
        let text = try String(contentsOf: s.bundle.readme.localURL, encoding: .utf8)
        #expect(text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) == FormatBundle.readmeMarker)
        #expect(s.bundle.digest.count == 64)
    }

    @Test func loadRejectsAMissingDocumentAndAReadmeWithoutTheMarker() throws {
        let s = try Setup(); defer { s.h.cleanup() }
        let copy = try s.copyOfRepoFiles()
        try Data("no marker\n".utf8).write(to: copy.docs.appendingPathComponent("folder-readme.md"))
        #expect(throws: (any Error).self) { try FormatBundle.load(docsDirectory: copy.docs, schemaDirectory: copy.schema) }
        try FileManager.default.removeItem(at: copy.docs.appendingPathComponent("folder-readme.md"))
        #expect(throws: (any Error).self) { try FormatBundle.load(docsDirectory: copy.docs, schemaDirectory: copy.schema) }
        #expect(throws: (any Error).self) {
            try FormatBundle.load(docsDirectory: repoDocs, schemaDirectory: s.h.root.appendingPathComponent("nope"))
        }
    }

    @Test func firstPassUploadsEverything() async throws {
        let s = try Setup(); defer { s.h.cleanup() }
        let result = await s.uploader(s.bundle).upload()
        #expect(result == .uploaded(files: 9, readmeSkipped: false))
        for f in s.bundle.formatFiles + [s.bundle.readme] {
            #expect(try Data(contentsOf: s.remote(f.relativePath)) == Data(contentsOf: f.localURL), "\(f.relativePath)")
        }
        #expect(s.replaces.last == "replace README.md")
        #expect(s.replaces.count == 9)
        #expect(s.replaces.dropLast().allSatisfy { $0.hasPrefix("replace format/") })
        let lines = s.events(.formatUploaded)
        #expect(lines.count == 1)
        #expect(lines.first?.count == 9)
        #expect(s.storedDigest() == s.bundle.digest)
    }

    @Test func secondPassIsUnchanged() async throws {
        let s = try Setup(); defer { s.h.cleanup() }
        let u = s.uploader(s.bundle)
        _ = await u.upload()
        let before = s.h.faults.operations
        #expect(await u.upload() == .unchanged)
        #expect(s.h.faults.operations == before)
    }

    @Test func changedBundleReuploads() async throws {
        let s = try Setup(); defer { s.h.cleanup() }
        _ = await s.uploader(s.bundle).upload()
        let copy = try s.copyOfRepoFiles()
        let doc = copy.docs.appendingPathComponent("context-signals.md")
        try (try String(contentsOf: doc, encoding: .utf8) + "\nAn edit.\n").write(to: doc, atomically: true, encoding: .utf8)
        let edited = try FormatBundle.load(docsDirectory: copy.docs, schemaDirectory: copy.schema)
        #expect(edited.digest != s.bundle.digest)
        #expect(await s.uploader(edited).upload() == .uploaded(files: 9, readmeSkipped: false))
        #expect(s.storedDigest() == edited.digest)
        #expect(try Data(contentsOf: s.remote("format/context-signals.md")) == Data(contentsOf: doc))
    }

    @Test func hippoReadmeIsReplaced() async throws {
        let s = try Setup(); defer { s.h.cleanup() }
        try Data((FormatBundle.readmeMarker + "\nan older readme\n").utf8).write(to: s.remote("README.md"))
        #expect(await s.uploader(s.bundle).upload() == .uploaded(files: 9, readmeSkipped: false))
        #expect(try Data(contentsOf: s.remote("README.md")) == Data(contentsOf: s.bundle.readme.localURL))
    }

    @Test func foreignReadmeIsLeftAlone() async throws {
        let s = try Setup(); defer { s.h.cleanup() }
        try Data("my notes".utf8).write(to: s.remote("README.md"))
        let u = s.uploader(s.bundle)
        #expect(await u.upload() == .uploaded(files: 8, readmeSkipped: true))
        #expect(try Data(contentsOf: s.remote("README.md")) == Data("my notes".utf8))
        #expect(try Data(contentsOf: s.remote("format/README.md")) == Data(contentsOf: s.bundle.readme.localURL))
        let skipped = s.events(.formatReadmeSkipped)
        #expect(skipped.count == 1)
        #expect(skipped.first?.code == "readme_foreign")
        #expect(s.events(.formatUploaded).count == 1)
        // No retry until the bundle changes.
        let before = s.h.faults.operations
        #expect(await u.upload() == .unchanged)
        #expect(s.h.faults.operations == before)
    }

    @Test func folderNamedReadmeIsForeign() async throws {
        let s = try Setup(); defer { s.h.cleanup() }
        try FileManager.default.createDirectory(at: s.remote("README.md"), withIntermediateDirectories: true)
        let u = s.uploader(s.bundle)
        #expect(await u.upload() == .uploaded(files: 8, readmeSkipped: true))
        #expect(s.events(.formatReadmeSkipped).count == 1)
        #expect(s.events(.formatReadmeSkipped).first?.code == "readme_foreign")
        #expect(s.storedDigest() == s.bundle.digest)
        let before = s.h.faults.operations
        #expect(await u.upload() == .unchanged)
        #expect(s.h.faults.operations == before)
    }

    @Test func forgettingTheDestinationUploadsAgain() async throws {
        let s = try Setup(); defer { s.h.cleanup() }
        let u = s.uploader(s.bundle)
        #expect(await u.upload() == .uploaded(files: 9, readmeSkipped: false))
        #expect(await u.upload() == .unchanged)
        try FileManager.default.removeItem(at: s.remote("format"))
        let active = try s.h.destinations.active()
        u.forgetUpload(destinationID: try #require(active).id)
        #expect(await u.upload() == .uploaded(files: 9, readmeSkipped: false))
        #expect(s.exists("format/README.md"))
    }

    @Test func oversizedReadmeIsForeign() async throws {
        let s = try Setup(); defer { s.h.cleanup() }
        var big = Data((FormatBundle.readmeMarker + "\n").utf8)
        big.append(Data(repeating: UInt8(ascii: "x"), count: 70 * 1024))
        try big.write(to: s.remote("README.md"))
        #expect(await s.uploader(s.bundle).upload() == .uploaded(files: 8, readmeSkipped: true))
        #expect(try Data(contentsOf: s.remote("README.md")) == big)
    }

    @Test func unreadableReadmeFailsThePassAndKeepsState() async throws {
        let s = try Setup(); defer { s.h.cleanup() }
        try Data(FormatBundle.readmeMarker.utf8).write(to: s.remote("README.md"))
        var hooked = HookedAdapter(inner: s.h.adapter)
        hooked.beforeDownload = { path in if path == "README.md" { throw StorageError.offline } }
        #expect(await s.uploader(s.bundle, hooked).upload() == .failed(code: "offline"))
        #expect(s.storedDigest() == nil)
        #expect(s.events(.formatReadmeSkipped).isEmpty)
        #expect(s.events(.formatUploadFailed).count == 1)
    }

    @Test func failureIsRetried() async throws {
        let s = try Setup(); defer { s.h.cleanup() }
        let failing = FailingReplaceAdapter(inner: s.h.adapter, failingCall: 3)
        let result = await s.uploader(s.bundle, failing).upload()
        #expect(result == .failed(code: "boom"))
        let lines = s.events(.formatUploadFailed)
        #expect(lines.count == 1)
        #expect(lines.first?.code == "boom")
        #expect(s.events(.formatUploaded).isEmpty)
        #expect(s.storedDigest() == nil)
        #expect(await s.uploader(s.bundle).upload() == .uploaded(files: 9, readmeSkipped: false))
        #expect(s.storedDigest() == s.bundle.digest)
    }

    @Test func noDestinationAndNoBundle() async throws {
        let s = try Setup(); defer { s.h.cleanup() }
        #expect(await s.uploader(nil).upload() == .noBundle)
        try s.h.destinations.signOut(destinationID: "dest-fs")
        #expect(await s.uploader(s.bundle).upload() == .noDestination)
        #expect(s.h.faults.operations.isEmpty)
        #expect(s.events(.formatUploaded).isEmpty && s.events(.formatUploadFailed).isEmpty
                && s.events(.formatReadmeSkipped).isEmpty)
    }

    // MARK: Invisible to readers

    @Test func formatFilesInvisibleToReaders() async throws {
        let s = try Setup(); defer { s.h.cleanup() }
        let clock = s.h.clock
        let store = try HippoStore.open(root: s.h.root, producer: Producer(appVersion: "0.1.0", build: "1", osVersion: "test"),
                                        leaseWaitLimit: .seconds(1), now: { clock.now })
        let pkg = try await s.h.capture()
        #expect(await s.h.worker().runOnce(maxJobs: 10).synced == 1)
        let adapter: any StorageAdapter = s.h.adapter
        let detector = store.makeChangeDetector(adapterFor: { _ in adapter })
        #expect(await detector.run() == RemoteChangeReport())      // baseline
        let puller = store.makeGoldPuller(adapterFor: { _ in adapter })
        _ = await puller.pull()

        #expect(await s.uploader(s.bundle).upload() == .uploaded(files: 9, readmeSkipped: false))

        #expect(await detector.run() == RemoteChangeReport())
        let pulled = await puller.pull()
        #expect(pulled.code == nil)
        #expect(try s.h.remoteState.reviewItems(destinationID: "dest-fs").isEmpty)
        #expect(try s.h.remoteState.changed(captureID: pkg.metadata.captureID) == nil)
        #expect((try? s.h.index.relativeDirectory(captureID: pkg.metadata.captureID)) != nil)

        let listing = RemoteListing(calendar: Calendar(identifier: .gregorian), lightAttachmentLimit: 1 << 20)
        let found = try await listing.completeCaptures(window: DownloadWindow(seconds: nil), now: clock.now, adapter: adapter)
        #expect(found.map(\.captureID) == [pkg.metadata.captureID])
        #expect(found.flatMap(\.files).allSatisfy { $0.relativePath.hasPrefix("captures/") })
    }

    @Test func deleteEverywhereLeavesFormatFiles() async throws {
        let s = try Setup(); defer { s.h.cleanup() }
        let pkg = try await s.h.capture()
        #expect(await s.h.worker().runOnce(maxJobs: 10).synced == 1)
        _ = await s.uploader(s.bundle).upload()
        let dest = try #require(try s.h.destinations.active())
        let remoteState = RemoteStateStore(db: s.h.db)
        try remoteState.addTombstone(captureID: pkg.metadata.captureID, relativeDirectory: pkg.relativeDirectory,
                                     destinationID: dest.id, accountIdentifier: dest.accountIdentifier, now: s.h.clock.now)
        let adapter: any StorageAdapter = s.h.adapter
        let clock = s.h.clock
        let deleter = RemoteDeleter(destinations: s.h.destinations, remoteState: remoteState, adapterFor: { _ in adapter },
                                    now: { clock.now }, random: { 1 }, log: s.h.log)
        #expect(await deleter.runOnce().deleted == 1)
        #expect(!s.exists(pkg.relativeDirectory))
        #expect(s.exists("README.md"))
        for path in formatPaths { #expect(s.exists(path), "\(path)") }
    }
}
