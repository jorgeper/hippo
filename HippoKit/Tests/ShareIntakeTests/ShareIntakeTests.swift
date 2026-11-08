import Testing
import Foundation
import Synchronization
import UniformTypeIdentifiers
import CaptureCore
import ShareIntake
import HippoTestSupport

@Suite final class ShareIntakeTests {
    private let root: URL
    private let directory: IntakeDirectory
    private let intake: ShareIntake
    private let captureID = UUID(uuidString: "0A1B2C3D-0000-4000-8000-000000000001")!
    private let startedAt = Date(timeIntervalSince1970: 1_794_070_800)
    private let fm = FileManager.default

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hippo-intake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        directory = IntakeDirectory(storeRoot: root)
        intake = ShareIntake(directory: directory)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private func prepare(_ providers: [any ItemProviding], title: String? = nil, contentText: String? = nil,
                         userInfoKeys: [String] = [], captureID: UUID? = nil,
                         progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async -> IntakeResult {
        let input = ShareInput(title: title, contentText: contentText, providers: providers, userInfoKeys: userInfoKeys)
        return await intake.prepare(input, captureID: captureID ?? self.captureID, startedAt: startedAt,
                                    timeZone: TimeZone(identifier: "America/Los_Angeles")!, progress: progress)
    }

    private func fileURL(_ source: AttachmentSource) -> URL? {
        if case .file(let url) = source.body { return url }
        return nil
    }

    private func intakeFiles() throws -> [String] {
        try fm.contentsOfDirectory(atPath: directory.directory(for: captureID).path).sorted()
    }

    // MARK: - Files

    @Test func imageFileIsCopiedWithProviderTypeAndName() async throws {
        let bytes = try MediaMaker.imageData(width: 8, height: 6)
        let provider = FakeProvider(types: ["public.heic", "public.jpeg"], suggestedName: "IMG_1.HEIC", fileBytes: bytes)

        let result = await prepare([provider])

        #expect(result.failures.isEmpty)
        try #require(result.draft.attachments.count == 1)
        let attachment = result.draft.attachments[0]
        #expect(attachment.uti == "public.heic")
        #expect(attachment.mimeType == "image/heic")
        #expect(attachment.originalFilename == "IMG_1.HEIC")
        #expect(attachment.representationSource == "item_provider_file")
        let url = try #require(fileURL(attachment))
        #expect(url.pathExtension == "heic")
        #expect(url.deletingLastPathComponent().standardizedFileURL.path
                == directory.directory(for: captureID).standardizedFileURL.path)
        #expect(try Data(contentsOf: url) == bytes)
        #expect(result.totalBytes == Int64(bytes.count))
        #expect(result.firstImageURL == url)
        #expect(result.draft.captureID == captureID)
        #expect(result.draft.startedAt == startedAt)
        #expect(result.draft.timeZone.identifier == "America/Los_Angeles")
        #expect(result.draft.method == .shareExtension)
        #expect(result.draft.location == nil)
    }

    @Test func progressReportsEachProviderInOrder() async throws {
        let bytes = try MediaMaker.imageData(width: 4, height: 4)
        let providers: [any ItemProviding] = [
            FakeProvider(types: ["public.jpeg"], suggestedName: "a.jpg", fileBytes: bytes),
            FakeProvider(types: ["public.url"], url: URL(string: "https://example.com/a")),
            FakeProvider(types: ["public.jpeg"], suggestedName: "b.jpg", fileBytes: bytes),
        ]
        let calls = Mutex<[[Int]]>([])

        _ = await prepare(providers, progress: { done, total in calls.withLock { $0.append([done, total]) } })

        #expect(calls.withLock { $0 } == [[0, 3], [1, 3], [2, 3], [3, 3]])
    }

    @Test func fileTypesUseFileCopyOnly() async throws {
        let provider = FakeProvider(types: ["public.jpeg", "public.file-url", "public.url", "public.utf8-plain-text"],
                                    fileBytes: Data([1, 2, 3]), url: URL(string: "https://example.com")!, text: "hi")

        let result = await prepare([provider])

        #expect(provider.calls == [.copyFile("public.jpeg")])
        #expect(result.draft.attachments.count == 1)
        #expect(result.draft.urls.isEmpty)
        #expect(result.draft.sharedText == nil)
    }

    @Test func fileURLOnlyIsCopiedWithItsOwnType() async throws {
        let source = root.appendingPathComponent("Report.pdf")
        let bytes = try MediaMaker.pdfData()
        try bytes.write(to: source)
        let provider = FakeProvider(types: ["public.file-url"], url: source)

        let result = await prepare([provider])

        #expect(provider.calls == [.loadURL])
        try #require(result.draft.attachments.count == 1)
        let attachment = result.draft.attachments[0]
        #expect(attachment.uti == "com.adobe.pdf")
        #expect(attachment.mimeType == "application/pdf")
        #expect(attachment.originalFilename == "Report.pdf")
        #expect(attachment.representationSource == "item_provider_file")
        let url = try #require(fileURL(attachment))
        #expect(url.lastPathComponent == "0.pdf")
        #expect(try Data(contentsOf: url) == bytes)
        #expect(result.totalBytes == Int64(bytes.count))
        #expect(result.firstImageURL == nil)
        #expect(result.draft.urls.isEmpty)
    }

    // MARK: - URLs and text

    @Test func urlWithDistinctTextKeepsBoth() async throws {
        let provider = FakeProvider(types: ["public.url", "public.utf8-plain-text"],
                                    url: URL(string: "https://example.com/a")!, text: "Look at this")

        let result = await prepare([provider])

        #expect(result.draft.urls == [CapturedURL(url: "https://example.com/a", source: "shared_payload")])
        #expect(result.draft.sharedText == "Look at this")
        #expect(result.draft.attachments.isEmpty)
        #expect(result.failures.isEmpty)
    }

    @Test func urlTextDuplicateNotRepeated() async throws {
        let provider = FakeProvider(types: ["public.url", "public.utf8-plain-text"],
                                    url: URL(string: "https://example.com/a")!, text: " https://example.com/a\n")

        let result = await prepare([provider], contentText: "https://example.com/a")

        #expect(result.draft.urls.count == 1)
        #expect(result.draft.sharedText == nil)
    }

    // YouTube shares only text, and the text is the link.
    @Test func textThatIsOnlyALinkBecomesALink() async throws {
        let link = "https://youtube.com/watch?v=VIDEO000001&is=SHARETAG0000000"
        let provider = FakeProvider(types: ["public.utf8-plain-text"], text: link)

        let result = await prepare([provider])

        #expect(result.draft.urls == [CapturedURL(url: link, source: "detected_in_text")])
        #expect(result.draft.sharedText == nil)
        #expect(result.failures.isEmpty)

        let viaContent = await prepare([], contentText: " https://example.com/c\n", captureID: UUID())
        #expect(viaContent.draft.urls == [CapturedURL(url: "https://example.com/c", source: "detected_in_text")])
        #expect(viaContent.draft.sharedText == nil)
    }

    @Test func webLinksInSharedTextAreAddedAndTextKept() async throws {
        let provider = FakeProvider(types: ["public.utf8-plain-text"],
                                    text: "Check this out https://example.com/b or mail a@example.com")

        let result = await prepare([provider])

        #expect(result.draft.urls == [CapturedURL(url: "https://example.com/b", source: "detected_in_text")])
        #expect(result.draft.sharedText == "Check this out https://example.com/b or mail a@example.com")
    }

    @Test func linkInTextAlreadySharedAsURLIsNotAddedAgain() async throws {
        let url = FakeProvider(types: ["public.url"], url: URL(string: "https://example.com/a")!)
        let text = FakeProvider(types: ["public.utf8-plain-text"], text: "Read https://example.com/a?utm_source=share")

        let result = await prepare([url, text])

        #expect(result.draft.urls == [CapturedURL(url: "https://example.com/a", source: "shared_payload")])
    }

    // Instagram offers the same reel twice, once with `?l=1`.
    @Test func trackingVariantsOfASharedURLAreOneLink() async throws {
        let first = FakeProvider(types: ["public.url"], url: URL(string: "https://www.instagram.com/reel/X/")!)
        let again = FakeProvider(types: ["public.url"], url: URL(string: "https://www.instagram.com/reel/X/?l=1")!)

        let result = await prepare([first, again])

        #expect(result.draft.urls.map(\.url) == ["https://www.instagram.com/reel/X/"])
    }

    @Test func plainTextWithRichEquivalentsSavesTextOnly() async throws {
        let provider = FakeProvider(types: ["public.rtf", "public.utf8-plain-text"],
                                    fileBytes: Data("{\\rtf1 Hello}".utf8), text: "Hello")

        let result = await prepare([provider])

        #expect(result.draft.attachments.isEmpty)
        #expect(result.draft.sharedText == "Hello")
        #expect(provider.calls == [.loadText])
    }

    @Test func assemblyJoinsTextsTrimsTitleAndDedupesURLs() async throws {
        let first = FakeProvider(types: ["public.url"], url: URL(string: "https://example.com/a")!)
        let again = FakeProvider(types: ["public.url"], url: URL(string: "https://example.com/a")!)
        let other = FakeProvider(types: ["public.url"], url: URL(string: "https://example.com/b")!)
        let text = FakeProvider(types: ["public.utf8-plain-text"], text: "  Hello\n")

        let result = await prepare([first, again, other, text], title: "  A page \n", contentText: " Intro ")

        #expect(result.draft.sharedTitle == "A page")
        #expect(result.draft.urls.map(\.url) == ["https://example.com/a", "https://example.com/b"])
        #expect(result.draft.sharedText == "Intro\n\nHello")

        let blank = await prepare([text], title: "  \n", contentText: "Hello", captureID: UUID())
        #expect(blank.draft.sharedTitle == nil)
        #expect(blank.draft.sharedText == "Hello")
    }

    @Test func largeTextBecomesAttachment() async throws {
        let large = String(repeating: "a", count: 100_001)
        let result = await prepare([FakeProvider(types: ["public.utf8-plain-text"], text: large)])

        #expect(result.draft.sharedText == nil)
        try #require(result.draft.attachments.count == 1)
        let attachment = result.draft.attachments[0]
        guard case .data(let data) = attachment.body else { Issue.record("expected a data attachment"); return }
        #expect(data == Data(large.utf8))
        #expect(attachment.uti == "public.utf8-plain-text")
        #expect(attachment.mimeType == "text/plain")
        #expect(attachment.representationSource == "item_provider_data")
        #expect(result.totalBytes == 100_001)

        let limit = String(repeating: "a", count: 100_000)
        let small = await prepare([FakeProvider(types: ["public.utf8-plain-text"], text: limit)], captureID: UUID())
        #expect(small.draft.sharedText == limit)
        #expect(small.draft.attachments.isEmpty)
    }

    // MARK: - Failures

    @Test func unsupportedAndFailedProvidersAreReported() async throws {
        let weird = FakeProvider(types: ["com.example.weird"])
        let broken = FakeProvider(types: ["public.jpeg"], fileBytes: Data(repeating: 7, count: 64), fails: true)
        let link = FakeProvider(types: ["public.url"], url: URL(string: "https://example.com")!)
        let steps = Mutex<[[Int]]>([])

        let result = await prepare([weird, broken, link]) { done, total in steps.withLock { $0.append([done, total]) } }

        #expect(result.failures == [IntakeFailure(index: 0, kind: .unsupported), IntakeFailure(index: 1, kind: .loadFailed)])
        #expect(weird.calls.isEmpty)
        #expect(broken.calls == [.copyFile("public.jpeg")])
        #expect(result.draft.urls.map(\.url) == ["https://example.com"])
        #expect(result.draft.attachments.isEmpty)
        #expect(result.totalBytes == 0)
        #expect(try intakeFiles().isEmpty)
        #expect(steps.withLock { $0 } == [[0, 3], [1, 3], [2, 3], [3, 3]])
    }

    @Test func urlKeptWhenSecondaryTextFails() async throws {
        // No text configured, so loadText throws.
        let provider = FakeProvider(types: ["public.url", "public.utf8-plain-text"], url: URL(string: "https://example.com/a")!)

        let result = await prepare([provider])

        #expect(provider.calls == [.loadURL, .loadText])
        #expect(result.failures.isEmpty)
        #expect(result.draft.urls.map(\.url) == ["https://example.com/a"])
        #expect(result.draft.sharedText == nil)
    }

    @Test func directoryFileURLIsUnsupported() async throws {
        let folder = root.appendingPathComponent("Shared Folder", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: folder.appendingPathComponent("inside.txt"))
        let provider = FakeProvider(types: ["public.file-url"], url: folder)

        let result = await prepare([provider])

        #expect(result.failures == [IntakeFailure(index: 0, kind: .unsupported)])
        #expect(result.draft.attachments.isEmpty)
        #expect(result.draft.urls.isEmpty)
        #expect(result.totalBytes == 0)
        #expect(try intakeFiles().isEmpty)
    }

    @Test func blankTextIsReported() async throws {
        let blank = FakeProvider(types: ["public.utf8-plain-text"], text: "  \n\t ")
        let good = FakeProvider(types: ["public.utf8-plain-text"], text: "Hello")

        let result = await prepare([blank, good])

        #expect(result.failures == [IntakeFailure(index: 0, kind: .unsupported)])
        #expect(result.draft.sharedText == "Hello")
    }

    // MARK: - Observations

    @Test func observationsRecordTypeClues() async throws {
        let photo = FakeProvider(types: ["public.jpeg", "com.example.app-specific"], suggestedName: "photo.jpg",
                                 fileBytes: Data([1]))
        let link = FakeProvider(types: ["public.url"], url: URL(string: "https://example.com")!)

        let result = await prepare([photo, link], userInfoKeys: ["b", "a"])

        #expect(result.draft.observations == [
            MetadataObservation(key: "share.registered_type_identifiers",
                                value: .array([.array([.string("public.jpeg"), .string("com.example.app-specific")]),
                                               .array([.string("public.url")])]),
                                provenance: "ns_extension_item"),
            MetadataObservation(key: "share.suggested_names", value: .array([.string("photo.jpg"), .null]),
                                provenance: "ns_extension_item"),
            MetadataObservation(key: "share.userinfo_keys", value: .array([.string("a"), .string("b")]),
                                provenance: "ns_extension_item"),
        ])
    }

    @Test func observationsAreBounded() async throws {
        let types = ["public.jpeg", String(repeating: "t", count: 300)] + (0..<40).map { "com.example.t\($0)" }
        let provider = FakeProvider(types: types, suggestedName: String(repeating: "n", count: 300), fileBytes: Data([1]))

        let none = await prepare([provider])
        #expect(none.draft.observations.map(\.key) == ["share.registered_type_identifiers", "share.suggested_names"])
        let recordedTypes = none.draft.observations[0].value
        guard case .array(let perProvider) = recordedTypes, case .array(let first)? = perProvider.first else {
            Issue.record("expected an array of arrays"); return
        }
        #expect(first.count == 32)
        #expect(first[0] == .string("public.jpeg"))
        #expect(first[1] == .string(String(repeating: "t", count: 200)))
        #expect(none.draft.observations[1].value == .array([.string(String(repeating: "n", count: 255))]))

        let keys = [String(repeating: "a", count: 150)] + (0..<30).map { String(format: "key%02d", $0) }
        let many = await prepare([provider], userInfoKeys: keys, captureID: UUID())
        let recordedKeys = try #require(many.draft.observations.first { $0.key == "share.userinfo_keys" })
        guard case .array(let values) = recordedKeys.value else { Issue.record("expected an array"); return }
        #expect(values.count == 20)
        let expected = ([String(repeating: "a", count: 100)] + (0..<30).map { String(format: "key%02d", $0) }).sorted()
        #expect(values == expected.prefix(20).map { .string($0) })
    }

    // MARK: - ShareInput

    @Test func shareInputFromExtensionItems() throws {
        let first = NSExtensionItem()
        first.userInfo = ["com.example.flag": true]
        first.attributedTitle = NSAttributedString(string: "Title")
        first.attributedContentText = NSAttributedString(string: "Body")
        first.attachments = [NSItemProvider(object: NSURL(string: "https://example.com")!)]
        let second = NSExtensionItem()
        second.attributedContentText = NSAttributedString(string: "More")
        second.attachments = [NSItemProvider(object: "hello" as NSString)]

        let input = ShareInput.from([first, second])

        #expect(input.title == "Title")
        #expect(input.contentText == "Body\n\nMore")
        #expect(input.providers.map(\.registeredTypeIdentifiers) == [["public.url"], ["public.utf8-plain-text"]])
        #expect(input.userInfoKeys == ["com.example.flag"])
    }

    // MARK: - Intake directory

    @Test func discardRemovesIntakeDirectory() async throws {
        let other = UUID()
        _ = await prepare([FakeProvider(types: ["public.jpeg"], fileBytes: Data([1, 2]))])
        _ = await prepare([FakeProvider(types: ["public.jpeg"], fileBytes: Data([3]))], captureID: other)
        #expect(try intakeFiles() == ["0.jpeg"])

        directory.discard(captureID: captureID)

        #expect(!fm.fileExists(atPath: directory.directory(for: captureID).path))
        #expect(fm.fileExists(atPath: directory.directory(for: other).path))
    }

    @Test func intakePathsAreUnderStoreRoot() {
        let id = UUID(uuidString: "ABCDEF00-0000-4000-8000-000000000002")!
        #expect(directory.directory(for: id).path == root.appendingPathComponent("intake/abcdef00-0000-4000-8000-000000000002").path)
        #expect(directory.recordingURL(id: id).path
                == root.appendingPathComponent("intake/recording-abcdef00-0000-4000-8000-000000000002.m4a").path)
    }

    @Test func sweepRemovesOnlyOldEntries() throws {
        let now = Date(timeIntervalSince1970: 1_794_070_800)
        let old = UUID(), fresh = UUID(), oldRecording = UUID(), freshRecording = UUID()
        func touch(_ url: URL, _ date: Date) throws {
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        for id in [old, fresh] { try fm.createDirectory(at: directory.directory(for: id), withIntermediateDirectories: true) }
        for id in [oldRecording, freshRecording] { try Data([1]).write(to: directory.recordingURL(id: id)) }
        try touch(directory.directory(for: old), now.addingTimeInterval(-25 * 3600))
        try touch(directory.recordingURL(id: oldRecording), now.addingTimeInterval(-25 * 3600))
        try touch(directory.directory(for: fresh), now.addingTimeInterval(-3600))
        try touch(directory.recordingURL(id: freshRecording), now.addingTimeInterval(-3600))

        directory.sweep(olderThan: 24 * 3600, now: now)

        #expect(!fm.fileExists(atPath: directory.directory(for: old).path))
        #expect(!fm.fileExists(atPath: directory.recordingURL(id: oldRecording).path))
        #expect(fm.fileExists(atPath: directory.directory(for: fresh).path))
        #expect(fm.fileExists(atPath: directory.recordingURL(id: freshRecording).path))

        // A store with no intake directory yet is fine.
        IntakeDirectory(storeRoot: root.appendingPathComponent("empty")).sweep(olderThan: 0, now: now)
    }

    // MARK: - System provider

    @Test func systemItemProviderRoundTrip() async throws {
        let png = root.appendingPathComponent("shared.png")
        let bytes = try MediaMaker.imageData(width: 4, height: 4, type: .png)
        try bytes.write(to: png)
        let file = SystemItemProvider(try #require(NSItemProvider(contentsOf: png)))
        let link = SystemItemProvider(NSItemProvider(object: NSURL(string: "https://example.com")!))

        let result = await prepare([file, link])

        #expect(result.failures.isEmpty)
        try #require(result.draft.attachments.count == 1)
        let attachment = result.draft.attachments[0]
        #expect(attachment.uti == "public.png")
        let url = try #require(fileURL(attachment))
        #expect(url.lastPathComponent == "0.png")
        #expect(try Data(contentsOf: url) == bytes)
        #expect(result.draft.urls.map(\.url) == ["https://example.com"])

        let text = SystemItemProvider(NSItemProvider(object: "hello" as NSString))
        #expect(try await text.loadText() == "hello")
    }

    // YouTube registers its link as an NSString item under `public.plain-text`, which
    // `loadObject(ofClass: String.self)` can't coerce; the share then reported "1 items couldn't be copied".
    @Test func plainTextItemsRegisteredTheOldWayStillLoad() async throws {
        let link = "https://youtube.com/watch?v=VIDEO000001"
        let legacy = NSItemProvider()
        legacy.registerItem(forTypeIdentifier: "public.plain-text") { completion, _, _ in completion?(link as NSString, nil) }
        let shapes: [NSItemProvider] = [
            NSItemProvider(item: link as NSString, typeIdentifier: "public.plain-text"),
            NSItemProvider(item: NSAttributedString(string: link), typeIdentifier: "public.plain-text"),
            NSItemProvider(item: NSURL(string: link)!, typeIdentifier: "public.plain-text"),
            NSItemProvider(item: Data(link.utf8) as NSData, typeIdentifier: "public.plain-text"),
            legacy,
        ]
        for shape in shapes {
            #expect(try await SystemItemProvider(shape).loadText() == link)
        }

        let result = await prepare([SystemItemProvider(shapes[0])], contentText: link)
        #expect(result.failures.isEmpty)
        #expect(result.draft.urls == [CapturedURL(url: link, source: "detected_in_text")])
    }
}
