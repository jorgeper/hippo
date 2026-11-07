import Testing
import Foundation
@testable import CaptureCore
import HippoTestSupport

private struct FakeSpace: SpaceChecking {
    let bytes: Int64
    func availableBytes(at url: URL) throws -> Int64 { bytes }
}

/// Deterministic attachment IDs: 00000000-0000-4000-8000-00000000000N, N = 1, 2, …
private final class IDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> UUID {
        lock.lock(); defer { lock.unlock() }
        n += 1
        return UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!
    }
}

@Suite struct PackageWriterTests {
    private let root: URL
    private let layout: StoreLayout
    private let producer = Producer(appVersion: "0.1.0", build: "1", osVersion: "test")
    // 2026-11-07T17:00:00.123456Z = 09:00 local in Los Angeles; sub-millisecond part must be dropped.
    private let startedAt = Date(timeIntervalSince1970: 1_794_070_800.123456)
    private let la = TimeZone(identifier: "America/Los_Angeles")!

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hippo-writer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        layout = StoreLayout(root: root)
    }

    private func writer(space: Int64 = 1 << 40, ids: IDSequence = IDSequence()) -> PackageWriter {
        PackageWriter(layout: layout, producer: producer, space: FakeSpace(bytes: space), makeID: { ids.next() })
    }

    private func draft(_ method: CaptureMethod = .shareExtension, id: UUID = UUID(),
                       userNote: String? = nil, sharedText: String? = nil,
                       urls: [CapturedURL] = [], attachments: [AttachmentSource] = [],
                       observations: [MetadataObservation] = []) -> CaptureDraft {
        CaptureDraft(captureID: id, startedAt: startedAt, timeZone: la, method: method,
                     userNote: userNote, sharedTitle: nil, sharedText: sharedText, urls: urls,
                     attachments: attachments, location: nil, observations: observations)
    }

    /// Relative paths of every regular file under `dir` (empty if `dir` doesn't exist).
    private func files(under dir: URL) -> Set<String> {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: Set<String> = []
        let base = dir.resolvingSymlinksInPath().path + "/"
        for case let url as URL in e where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            out.insert(String(url.resolvingSymlinksInPath().path.dropFirst(base.count)))
        }
        return out
    }

    private func entries(in dir: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    }

    private func expectNoResidue() {
        #expect(entries(in: layout.stagingDir).isEmpty)
        #expect(files(under: layout.capturesDir).isEmpty)
    }

    private func pngFile() throws -> URL {
        let url = root.appendingPathComponent("source-screenshot.png")
        try MediaMaker.imageData(width: 120, height: 80, type: .png).write(to: url)
        return url
    }

    private let emptySHA = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    @Test func commitsPackageWithExactLayout() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let png = try pngFile()
        let d = draft(id: id, urls: [CapturedURL(url: "https://example.com/item", source: "shared_payload")],
                      attachments: [AttachmentSource(body: .file(png), originalFilename: "screenshot.png",
                                                     uti: "public.png", mimeType: "image/png",
                                                     representationSource: "item_provider_file")])
        let pkg = try await writer().commit(d)

        let cid = id.uuidString.lowercased()
        let aid = "00000000-0000-4000-8000-000000000001"
        #expect(pkg.relativeDirectory == "captures/2026/11/07/\(cid)")
        #expect(pkg.directoryURL.standardizedFileURL == root.appendingPathComponent("captures/2026/11/07/\(cid)").standardizedFileURL)
        #expect(files(under: pkg.directoryURL) == ["metadata.json", "complete.json", "content/\(aid).png"])

        let m = pkg.metadata
        #expect(m.schemaVersion == 1)
        #expect(m.captureID == cid)
        #expect(HippoJSON.timestamp(m.capturedAt) == "2026-11-07T17:00:00.123Z")
        #expect(m.localDatetime == "2026-11-07T09:00:00-08:00")
        #expect(m.timezoneIdentifier == "America/Los_Angeles")
        #expect(m.utcOffsetSeconds == -28800)
        #expect(m.captureMethod == .shareExtension)
        #expect(m.contentTypes == [.image, .url])
        #expect(m.producer == producer)
        #expect(m.sourceApplication == nil)
        #expect(m.attachments.count == 1)
        let a = try #require(m.attachments.first)
        #expect(a.attachmentID == aid)
        #expect(a.relativePath == "content/\(aid).png")
        #expect(a.originalFilename == "screenshot.png")
        #expect(a.mimeType == "image/png")
        #expect(a.representationSource == "item_provider_file")
        #expect(a.media?.widthPixels == 120)
        #expect(a.media?.heightPixels == 80)
        let sourceDigest = try StreamingHasher.digest(of: png)
        #expect(a.byteCount == sourceDigest.byteCount)
        #expect(a.sha256 == sourceDigest.sha256)

        // What's on disk is exactly what was returned.
        let onDisk = try HippoJSON.decodeMetadata(Data(contentsOf: pkg.directoryURL.appendingPathComponent("metadata.json")))
        #expect(onDisk == m)
        let json = try String(contentsOf: pkg.directoryURL.appendingPathComponent("metadata.json"), encoding: .utf8)
        #expect(json.contains("\"captured_at\" : \"2026-11-07T17:00:00.123Z\""))
        let marker = try HippoJSON.decodeMarker(Data(contentsOf: pkg.directoryURL.appendingPathComponent("complete.json")))
        #expect(marker == pkg.marker)
        #expect(marker.captureID == cid)
        #expect(marker.files.map(\.relativePath) == ["metadata.json", "content/\(aid).png"])
        for entry in marker.files {
            let digest = try StreamingHasher.digest(of: pkg.directoryURL.appendingPathComponent(entry.relativePath))
            #expect(entry.byteCount == digest.byteCount)
            #expect(entry.sha256 == digest.sha256)
        }
        #expect(entries(in: layout.stagingDir).isEmpty)
    }

    @Test func typedNoteStoresBodyAsTxtAttachment() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let d = draft(.typedNote, attachments: [AttachmentSource(body: .data(Data("Call plumber".utf8)),
                                                                  uti: "public.utf8-plain-text",
                                                                  representationSource: "typed_note")])
        let pkg = try await writer().commit(d)
        #expect(pkg.metadata.attachments.map(\.relativePath) == ["content/00000000-0000-4000-8000-000000000001.txt"])
        #expect(pkg.metadata.contentTypes == [.text])
        #expect(pkg.metadata.userNote == nil)
        #expect(pkg.metadata.captureMethod == .typedNote)
        #expect(pkg.noteBody() == "Call plumber")
        #expect(DisplayTitle.make(pkg.metadata, noteBody: pkg.noteBody()) == "Call plumber")
    }

    @Test func noteBodyIsNilForNonTypedNotes() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let d = draft(.shareExtension, attachments: [AttachmentSource(body: .data(Data("shared text file".utf8)),
                                                                       uti: "public.plain-text",
                                                                       representationSource: "item_provider_data")])
        let pkg = try await writer().commit(d)
        #expect(pkg.metadata.contentTypes == [.text])
        #expect(pkg.noteBody() == nil)
    }

    @Test func noteBodyIsCappedAt4KiBOnACharacterBoundary() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        // 4095 ASCII bytes then a 4-byte emoji: the cap falls inside the emoji, which must be dropped whole.
        let body = String(repeating: "a", count: 4095) + "😀" + "tail"
        let d = draft(.typedNote, attachments: [AttachmentSource(body: .data(Data(body.utf8)),
                                                                  uti: "public.utf8-plain-text",
                                                                  representationSource: "typed_note")])
        let pkg = try await writer().commit(d)
        #expect(pkg.noteBody() == String(repeating: "a", count: 4095))
    }

    @Test func urlOnlyCaptureHasNoAttachments() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let d = draft(urls: [CapturedURL(url: "https://example.com/item", source: "shared_payload")])
        let pkg = try await writer().commit(d)
        #expect(pkg.metadata.attachments.isEmpty)
        #expect(pkg.metadata.contentTypes == [.url])
        #expect(files(under: pkg.directoryURL) == ["metadata.json", "complete.json"])
        #expect(entries(in: pkg.directoryURL).sorted() == ["complete.json", "metadata.json"])
        #expect(pkg.marker.files.map(\.relativePath) == ["metadata.json"])
    }

    @Test func zeroByteAttachmentCommits() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let d = draft(.fileImport, attachments: [AttachmentSource(body: .data(Data()), originalFilename: "empty",
                                                                   uti: "public.data",
                                                                   representationSource: "item_provider_data")])
        let pkg = try await writer().commit(d)
        let a = try #require(pkg.metadata.attachments.first)
        #expect(a.byteCount == 0)
        #expect(a.sha256 == emptySHA)
        #expect(a.relativePath == "content/00000000-0000-4000-8000-000000000001.bin")
        #expect(pkg.metadata.contentTypes == [.file])
        #expect(pkg.marker.files.last == ManifestEntry(relativePath: a.relativePath, byteCount: 0, sha256: emptySHA))
    }

    @Test func preservesOriginalFilenameVerbatim() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "../😀 weird name.JPEG"
        let d = draft(attachments: [AttachmentSource(body: .data(Data([0xFF, 0xD8, 0xFF])), originalFilename: name,
                                                     uti: "public.jpeg", representationSource: "item_provider_data")])
        let pkg = try await writer().commit(d)
        let a = try #require(pkg.metadata.attachments.first)
        #expect(a.originalFilename == name)
        #expect(a.relativePath == "content/00000000-0000-4000-8000-000000000001.jpeg")
        let onDisk = try HippoJSON.decodeMetadata(Data(contentsOf: pkg.directoryURL.appendingPathComponent("metadata.json")))
        #expect(onDisk.attachments.first?.originalFilename == name)
        #expect(files(under: pkg.directoryURL) == ["metadata.json", "complete.json", a.relativePath])
        // Nothing escaped the package.
        #expect(files(under: layout.capturesDir) == ["2026/11/07/\(pkg.metadata.captureID)/metadata.json",
                                                     "2026/11/07/\(pkg.metadata.captureID)/complete.json",
                                                     "2026/11/07/\(pkg.metadata.captureID)/\(a.relativePath)"])
    }

    @Test func readOnlySourceFileCommits() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try pngFile()
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: png.path)
        let d = draft(attachments: [AttachmentSource(body: .file(png), uti: "public.png",
                                                     representationSource: "item_provider_file")])
        let pkg = try await writer().commit(d)
        let a = try #require(pkg.metadata.attachments.first)
        #expect(a.sha256 == (try StreamingHasher.digest(of: png)).sha256)
        #expect(files(under: pkg.directoryURL) == ["metadata.json", "complete.json", a.relativePath])
        #expect(entries(in: layout.stagingDir).isEmpty)
    }

    @Test func insufficientSpaceWritesNothing() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try pngFile()
        let size = try StreamingHasher.digest(of: png).byteCount
        let d = draft(attachments: [AttachmentSource(body: .file(png), uti: "public.png",
                                                     representationSource: "item_provider_file")])
        await #expect(throws: CaptureError.insufficientSpace(requiredBytes: size + 1_048_576, availableBytes: 10)) {
            try await writer(space: 10).commit(d)
        }
        expectNoResidue()
    }

    @Test func failedAttachmentRejectsByDefault() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("does-not-exist.jpg")
        let d = draft(attachments: [
            AttachmentSource(body: .data(Data("ok".utf8)), uti: "public.plain-text", representationSource: "item_provider_data"),
            AttachmentSource(body: .file(missing), uti: "public.jpeg", representationSource: "item_provider_file"),
        ])
        do {
            _ = try await writer().commit(d)
            Issue.record("expected attachmentsFailed")
        } catch let CaptureError.attachmentsFailed(failures) {
            #expect(failures.map(\.index) == [1])
            #expect(failures.allSatisfy { !$0.reason.isEmpty && !$0.reason.contains("does-not-exist") })
        }
        expectNoResidue()
    }

    @Test func acceptPartialRecordsObservation() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("does-not-exist.jpg")
        let prior = MetadataObservation(key: "registered_type_identifiers", value: .array([.string("public.jpeg")]),
                                        provenance: "item_provider")
        let d = draft(attachments: [
            AttachmentSource(body: .data(Data("ok".utf8)), uti: "public.plain-text", representationSource: "item_provider_data"),
            AttachmentSource(body: .file(missing), uti: "public.jpeg", representationSource: "item_provider_file"),
        ], observations: [prior])
        let pkg = try await writer().commit(d, partialPolicy: .acceptPartial)
        #expect(pkg.metadata.attachments.count == 1)
        #expect(pkg.metadata.contentTypes == [.text])
        #expect(pkg.metadata.metadataObservations.count == 2)
        #expect(pkg.metadata.metadataObservations.first == prior)
        let obs = try #require(pkg.metadata.metadataObservations.last)
        #expect(obs.key == "attachment_copy_failed")
        #expect(obs.provenance == "package_writer")
        guard case .object(let value) = obs.value else { Issue.record("value is not an object"); return }
        #expect(value["index"] == .number(1))
        guard case .string(let reason)? = value["reason"] else { Issue.record("reason is not a string"); return }
        #expect(!reason.isEmpty)
        #expect(files(under: pkg.directoryURL).count == 3)
        #expect(entries(in: layout.stagingDir).isEmpty)
    }

    @Test func acceptPartialWithEveryAttachmentDroppedLeavesNoContentDirectory() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let d = draft(urls: [CapturedURL(url: "https://example.com/item", source: "shared_payload")],
                      attachments: [AttachmentSource(body: .file(root.appendingPathComponent("gone.png")),
                                                     uti: "public.png", representationSource: "item_provider_file")])
        let pkg = try await writer().commit(d, partialPolicy: .acceptPartial)
        #expect(pkg.metadata.attachments.isEmpty)
        #expect(pkg.metadata.contentTypes == [.url])
        #expect(entries(in: pkg.directoryURL).sorted() == ["complete.json", "metadata.json"])
        #expect(entries(in: layout.stagingDir).isEmpty)
    }

    @Test func acceptPartialStillRejectsWhenNothingWouldRemain() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let d = draft(attachments: [AttachmentSource(body: .file(root.appendingPathComponent("gone.png")),
                                                     uti: "public.png", representationSource: "item_provider_file")])
        do {
            _ = try await writer().commit(d, partialPolicy: .acceptPartial)
            Issue.record("expected attachmentsFailed")
        } catch let CaptureError.attachmentsFailed(failures) {
            #expect(failures.map(\.index) == [0])
        }
        expectNoResidue()
    }

    @Test func directorySourceIsAFailedAttachment() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("a-bundle")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let d = draft(attachments: [AttachmentSource(body: .file(dir), uti: "public.data", representationSource: "item_provider_file")])
        do {
            _ = try await writer().commit(d)
            Issue.record("expected attachmentsFailed")
        } catch let CaptureError.attachmentsFailed(failures) {
            #expect(failures.map(\.index) == [0])
        }
        expectNoResidue()
    }

    @Test func emptyDraftIsRejected() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: CaptureError.emptyCapture) { try await writer().commit(draft()) }
        await #expect(throws: CaptureError.emptyCapture) {
            try await writer().commit(draft(userNote: "  \n", sharedText: ""))
        }
        expectNoResidue()
    }

    @Test func blankOptionalTextIsOmitted() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let d = draft(userNote: "", sharedText: "Some shared text")
        let pkg = try await writer().commit(d)
        #expect(pkg.metadata.userNote == nil)
        #expect(pkg.metadata.sharedText == "Some shared text")
        #expect(pkg.metadata.contentTypes == [.text])
        let json = try String(contentsOf: pkg.directoryURL.appendingPathComponent("metadata.json"), encoding: .utf8)
        #expect(!json.contains("user_note"))
        #expect(!json.contains("source_application"))
    }

    @Test func secondCommitOfSameIDThrowsAlreadyCommitted() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let d = draft(userNote: "first")
        let first = try await writer().commit(d)
        let before = try Data(contentsOf: first.directoryURL.appendingPathComponent("metadata.json"))
        var again = d
        again.userNote = "second"
        await #expect(throws: CaptureError.io("already committed")) { try await writer().commit(again) }
        #expect(entries(in: layout.stagingDir).isEmpty)
        #expect(try Data(contentsOf: first.directoryURL.appendingPathComponent("metadata.json")) == before)
        #expect(files(under: layout.capturesDir).count == 2)
    }

    @Test func layoutPaths() {
        let l = StoreLayout(root: URL(fileURLWithPath: "/tmp/hippo"))
        #expect(l.stagingDir.path == "/tmp/hippo/staging")
        #expect(l.capturesDir.path == "/tmp/hippo/captures")
        #expect(l.databaseURL.path == "/tmp/hippo/hippo.sqlite")
        #expect(l.diagnosticsURL.path == "/tmp/hippo/diagnostics.json")
        #expect(l.packageURL(relativeDirectory: "captures/2026/11/07/abc").path == "/tmp/hippo/captures/2026/11/07/abc")
    }

    @Test func volumeSpaceCheckerReportsSpaceEvenForMissingPaths() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let checker = VolumeSpaceChecker()
        #expect(try checker.availableBytes(at: FileManager.default.temporaryDirectory) > 0)
        #expect(try checker.availableBytes(at: root.appendingPathComponent("not/yet/created")) > 0)
    }
}

@Suite struct DisplayTitleTests {
    private func base(_ method: CaptureMethod = .shareExtension, types: [ContentType] = [.file],
                      sharedTitle: String? = nil, urls: [CapturedURL] = [],
                      attachments: [CaptureCore.Attachment] = []) -> CaptureMetadata {
        var m = CaptureMetadata.sample()
        m.captureMethod = method
        m.contentTypes = types
        m.sharedTitle = sharedTitle
        m.urls = urls
        m.attachments = attachments
        return m
    }

    private func attachment(_ name: String? = nil, uti: String = "public.data", duration: Double? = nil) -> CaptureCore.Attachment {
        CaptureCore.Attachment(attachmentID: "a", relativePath: "content/a.bin", originalFilename: name, uti: uti,
                   byteCount: 1, sha256: String(repeating: "0", count: 64), representationSource: "recording",
                   media: duration.map { MediaFacts(durationSeconds: $0) })
    }

    @Test func displayTitleFallbacks() {
        let url = [CapturedURL(url: "https://example.com/item/42?q=1", source: "shared_payload")]
        let file = [attachment("report.pdf", uti: "com.adobe.pdf")]

        // 1. shared title wins over everything.
        #expect(DisplayTitle.make(base(sharedTitle: "Shared Title", urls: url, attachments: file), noteBody: "Note") == "Shared Title")
        // 2. first non-empty line of the note body, truncated to 80 characters.
        #expect(DisplayTitle.make(base(urls: url, attachments: file), noteBody: "\n   \n  Buy milk  \nand eggs") == "Buy milk")
        let long = String(repeating: "x", count: 100)
        #expect(DisplayTitle.make(base(), noteBody: long) == String(repeating: "x", count: 80))
        // 3. first URL's host + path.
        #expect(DisplayTitle.make(base(types: [.url], urls: url, attachments: file), noteBody: nil) == "example.com/item/42")
        #expect(DisplayTitle.make(base(types: [.url], urls: [CapturedURL(url: "https://example.com/", source: "s")]), noteBody: nil) == "example.com")
        // 4. first attachment's original filename.
        #expect(DisplayTitle.make(base(types: [.pdf], attachments: file), noteBody: "   ") == "report.pdf")
        // 5. voice recording with its duration.
        #expect(DisplayTitle.make(base(.voiceRecording, types: [.audio], attachments: [attachment(uti: "com.apple.m4a-audio", duration: 75.4)]),
                                  noteBody: nil) == "Voice note · 1:15")
        #expect(DisplayTitle.make(base(.voiceRecording, types: [.audio], attachments: [attachment(uti: "com.apple.m4a-audio", duration: 9)]),
                                  noteBody: nil) == "Voice note · 0:09")
        // 6. a type word from the first content type.
        let words: [(ContentType, String)] = [(.image, "Image"), (.video, "Video"), (.audio, "Audio"), (.pdf, "PDF"),
                                              (.file, "File"), (.text, "Note"), (.url, "Link")]
        for (type, word) in words {
            #expect(DisplayTitle.make(base(types: [type], attachments: [attachment()]), noteBody: nil) == word)
        }
    }
}
