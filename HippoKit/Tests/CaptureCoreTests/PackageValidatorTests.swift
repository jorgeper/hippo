import Testing
import Foundation
import CryptoKit
@testable import CaptureCore

@Suite struct PackageValidatorTests {
    private let root: URL
    private let layout: StoreLayout
    private let la = TimeZone(identifier: "America/Los_Angeles")!

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hippo-validator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        layout = StoreLayout(root: root)
    }

    private func makePackage() async throws -> CommittedPackage {
        let writer = PackageWriter(layout: layout, producer: Producer(appVersion: "0.1.0", build: "1", osVersion: "test"))
        let draft = CaptureDraft(
            captureID: UUID(), startedAt: Date(timeIntervalSince1970: 1_794_070_800), timeZone: la,
            method: .shareExtension, userNote: "hi", sharedTitle: nil, sharedText: nil, urls: [],
            attachments: [AttachmentSource(body: .data(Data("hello attachment".utf8)), originalFilename: "a.txt",
                                           uti: "public.plain-text", mimeType: nil, representationSource: "test")],
            location: nil, observations: [])
        return try await writer.commit(draft)
    }

    private func rewrite(_ url: URL, _ bytes: Data) throws {
        try? FileManager.default.removeItem(at: url)
        try bytes.write(to: url)
    }

    private func editMarker(_ pkg: CommittedPackage, _ change: (inout CompletionMarker) -> Void) throws {
        var marker = pkg.marker
        change(&marker)
        try rewrite(pkg.directoryURL.appendingPathComponent("complete.json"), try HippoJSON.encode(marker))
    }

    @Test func validPackageIsComplete() async throws {
        let pkg = try await makePackage()
        let bytes = try Data(contentsOf: pkg.directoryURL.appendingPathComponent("complete.json"))
        let hex = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(PackageValidator.validate(directory: pkg.directoryURL) == .complete(metadata: pkg.metadata, packageDigest: hex))
    }

    @Test func missingMarkerIsIncomplete() async throws {
        let pkg = try await makePackage()
        try FileManager.default.removeItem(at: pkg.directoryURL.appendingPathComponent("complete.json"))
        #expect(PackageValidator.validate(directory: pkg.directoryURL) == .incomplete("no completion marker"))
    }

    @Test func markerFirstButFileMissingIsIncomplete() async throws {
        let pkg = try await makePackage()
        let path = pkg.metadata.attachments[0].relativePath
        try FileManager.default.removeItem(at: pkg.directoryURL.appendingPathComponent(path))
        #expect(PackageValidator.validate(directory: pkg.directoryURL) == .incomplete("missing \(path)"))
    }

    @Test func hashMismatchIsIncomplete() async throws {
        let pkg = try await makePackage()
        let path = pkg.metadata.attachments[0].relativePath
        // Same size, different bytes.
        try rewrite(pkg.directoryURL.appendingPathComponent(path), Data("HELLO attachment".utf8))
        #expect(PackageValidator.validate(directory: pkg.directoryURL) == .incomplete("mismatch \(path)"))
    }

    @Test func sizeMismatchIsIncomplete() async throws {
        let pkg = try await makePackage()
        let path = pkg.metadata.attachments[0].relativePath
        try rewrite(pkg.directoryURL.appendingPathComponent(path), Data("short".utf8))
        #expect(PackageValidator.validate(directory: pkg.directoryURL) == .incomplete("mismatch \(path)"))
    }

    @Test func traversalInManifestIsCorrupt() async throws {
        let pkg = try await makePackage()
        try editMarker(pkg) { $0.files.append(ManifestEntry(relativePath: "content/../../etc/passwd", byteCount: 1, sha256: "00")) }
        guard case .corrupt = PackageValidator.validate(directory: pkg.directoryURL) else {
            Issue.record("expected corrupt"); return
        }
    }

    @Test func manifestWithoutMetadataIsCorrupt() async throws {
        let pkg = try await makePackage()
        try editMarker(pkg) { $0.files.removeAll { $0.relativePath == "metadata.json" } }
        guard case .corrupt = PackageValidator.validate(directory: pkg.directoryURL) else {
            Issue.record("expected corrupt"); return
        }
    }

    @Test func idMismatchIsCorrupt() async throws {
        let pkg = try await makePackage()
        try editMarker(pkg) { $0.captureID = UUID().uuidString.lowercased() }
        guard case .corrupt = PackageValidator.validate(directory: pkg.directoryURL) else {
            Issue.record("expected corrupt"); return
        }
    }

    @Test func directoryNameMismatchIsCorrupt() async throws {
        let pkg = try await makePackage()
        let moved = pkg.directoryURL.deletingLastPathComponent().appendingPathComponent(UUID().uuidString.lowercased())
        try FileManager.default.moveItem(at: pkg.directoryURL, to: moved)
        guard case .corrupt = PackageValidator.validate(directory: moved) else {
            Issue.record("expected corrupt"); return
        }
    }

    @Test func attachmentAbsentFromManifestIsCorrupt() async throws {
        let pkg = try await makePackage()
        let path = pkg.metadata.attachments[0].relativePath
        try editMarker(pkg) { $0.files.removeAll { $0.relativePath == path } }
        guard case .corrupt = PackageValidator.validate(directory: pkg.directoryURL) else {
            Issue.record("expected corrupt"); return
        }
    }

    @Test func schemaV2MarkerIsUnsupported() async throws {
        let pkg = try await makePackage()
        try editMarker(pkg) { $0.schemaVersion = 2 }
        #expect(PackageValidator.validate(directory: pkg.directoryURL) == .unsupportedSchema(2))
    }

    @Test func schemaV2MetadataIsUnsupported() async throws {
        let pkg = try await makePackage()
        var meta = pkg.metadata
        meta.schemaVersion = 2
        let metaURL = pkg.directoryURL.appendingPathComponent("metadata.json")
        try rewrite(metaURL, try HippoJSON.encode(meta))
        let d = try StreamingHasher.digest(of: metaURL)
        try editMarker(pkg) {
            $0.files[0] = ManifestEntry(relativePath: "metadata.json", byteCount: d.byteCount, sha256: d.sha256)
        }
        #expect(PackageValidator.validate(directory: pkg.directoryURL) == .unsupportedSchema(2))
    }

    @Test func loadReturnsPackageOnlyWhenCompleteAndUnderRoot() async throws {
        let pkg = try await makePackage()
        let loaded = CommittedPackage.load(directory: pkg.directoryURL, layout: layout)
        #expect(loaded?.relativeDirectory == pkg.relativeDirectory)
        #expect(loaded?.metadata == pkg.metadata)
        #expect(CommittedPackage.load(directory: pkg.directoryURL, layout: StoreLayout(root: root.appendingPathComponent("other"))) == nil)
        try FileManager.default.removeItem(at: pkg.directoryURL.appendingPathComponent("complete.json"))
        #expect(CommittedPackage.load(directory: pkg.directoryURL, layout: layout) == nil)
    }
}
