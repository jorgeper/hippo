import Testing
import Foundation
import CaptureCore
import ShareIntake
import HippoTestSupport

@Suite final class PendingCaptureTests {
    private let root: URL
    private let directory: IntakeDirectory
    private let fm = FileManager.default
    private let t0 = HippoJSON.wholeMilliseconds(Date(timeIntervalSince1970: 1_794_070_800.123))

    init() throws {
        root = fm.temporaryDirectory.appendingPathComponent("hippo-pending-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        directory = IntakeDirectory(storeRoot: root)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func makePending(id: UUID = UUID(), savedAt: Date? = nil, withData: Bool = true) throws -> (PendingCapture, URL) {
        let dir = directory.directory(for: id)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("0.jpg")
        try MediaMaker.imageData(width: 8, height: 6).write(to: file)
        let preview = dir.appendingPathComponent("preview.jpg")
        try MediaMaker.imageData(width: 4, height: 3).write(to: preview)
        var attachments = [AttachmentSource(body: .file(file), originalFilename: "IMG_1.JPG", uti: "public.jpeg",
                                            mimeType: "image/jpeg", representationSource: "item_provider_file")]
        if withData {
            attachments.append(AttachmentSource(body: .data(Data("note".utf8)), uti: "public.plain-text",
                                                mimeType: "text/plain", representationSource: "typed_note"))
        }
        let draft = CaptureDraft(
            captureID: id, startedAt: t0, timeZone: TimeZone(identifier: "America/Los_Angeles")!,
            method: .shareExtension, userNote: "hi", sharedTitle: "T", sharedText: "body",
            urls: [CapturedURL(url: "https://example.com/a", source: "share_item")], attachments: attachments,
            location: CaptureLocation(latitude: 1.5, longitude: -2.5, horizontalAccuracyMeters: 10, observedAt: t0, provenance: "share_extension"),
            observations: [MetadataObservation(key: "k", value: .string("v"), provenance: "p")])
        return (PendingCapture(draft: draft, previewImageURL: preview, totalBytes: 1234, savedAt: savedAt ?? t0), file)
    }

    @Test func pendingRoundTrip() throws {
        let id = UUID()
        let (pending, file) = try makePending(id: id)
        try directory.savePending(pending)
        #expect(directory.isPending(captureID: id))

        let result = directory.pendingCaptures()
        #expect(result.dropped == 0)
        let loaded = try #require(result.captures.first)
        #expect(result.captures.count == 1)
        let d = loaded.draft, e = pending.draft
        #expect(d.captureID == id)
        #expect(d.startedAt == e.startedAt)
        #expect(d.timeZone.identifier == "America/Los_Angeles")
        #expect(d.method == .shareExtension)
        #expect(d.userNote == "hi")
        #expect(d.sharedTitle == "T")
        #expect(d.sharedText == "body")
        #expect(d.urls == e.urls)
        #expect(d.location == e.location)
        #expect(d.observations == e.observations)
        try #require(d.attachments.count == 2)
        guard case .file(let url) = d.attachments[0].body else { Issue.record("expected file"); return }
        #expect(url.standardizedFileURL.resolvingSymlinksInPath() == file.standardizedFileURL.resolvingSymlinksInPath())
        #expect(d.attachments[0].originalFilename == "IMG_1.JPG")
        #expect(d.attachments[0].uti == "public.jpeg")
        #expect(d.attachments[0].mimeType == "image/jpeg")
        #expect(d.attachments[0].representationSource == "item_provider_file")
        guard case .data(let bytes) = d.attachments[1].body else { Issue.record("expected data"); return }
        #expect(bytes == Data("note".utf8))
        #expect(d.attachments[1].originalFilename == nil)
        #expect(d.attachments[1].representationSource == "typed_note")
        #expect(loaded.previewImageURL?.lastPathComponent == "preview.jpg")
        #expect(loaded.totalBytes == 1234)
        #expect(loaded.savedAt == t0)
    }

    @Test func fileOutsideCaptureDirectoryIsRejected() throws {
        let id = UUID()
        var (pending, _) = try makePending(id: id)
        let outside = root.appendingPathComponent("elsewhere.jpg")
        try Data([1]).write(to: outside)
        pending.draft.attachments[0].body = .file(outside)
        #expect(throws: CocoaError.self) { try directory.savePending(pending) }
        #expect(!directory.isPending(captureID: id))
    }

    @Test func pendingCapturesSkipsAndRemovesMissingFiles() throws {
        let id = UUID()
        let (pending, file) = try makePending(id: id)
        try directory.savePending(pending)
        try fm.removeItem(at: file)

        let result = directory.pendingCaptures()
        #expect(result.captures.isEmpty)
        #expect(result.dropped == 1)
        #expect(!fm.fileExists(atPath: directory.directory(for: id).path))
    }

    @Test func sweepKeepsPendingCaptures() throws {
        let pendingID = UUID(), plainID = UUID()
        let (pending, _) = try makePending(id: pendingID)
        try directory.savePending(pending)
        let plain = directory.directory(for: plainID)
        try fm.createDirectory(at: plain, withIntermediateDirectories: true)
        try Data([1]).write(to: plain.appendingPathComponent("x"))
        let old = Date(timeIntervalSince1970: 1_000_000)
        for url in [directory.directory(for: pendingID), plain] {
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }

        directory.sweep(olderThan: 60, now: Date())

        #expect(fm.fileExists(atPath: directory.directory(for: pendingID).path))
        #expect(!fm.fileExists(atPath: plain.path))
        #expect(directory.pendingCaptures().captures.map(\.draft.captureID) == [pendingID])
    }

    @Test func pendingOrderIsOldestFirst() throws {
        let later = UUID(), earlier = UUID()
        try directory.savePending(try makePending(id: later, savedAt: t0.addingTimeInterval(10)).0)
        try directory.savePending(try makePending(id: earlier, savedAt: t0).0)

        let ids = directory.pendingCaptures().captures.map(\.draft.captureID)
        #expect(ids == [earlier, later])
    }

    @Test func corruptPendingJSONIsDropped() throws {
        let id = UUID()
        try directory.savePending(try makePending(id: id).0)
        try Data("not json".utf8).write(to: directory.directory(for: id).appendingPathComponent("pending.json"))

        let result = directory.pendingCaptures()
        #expect(result.captures.isEmpty)
        #expect(result.dropped == 1)
        #expect(!fm.fileExists(atPath: directory.directory(for: id).path))
    }

    @Test func newerSchemaVersionIsKeptAndNotReturned() throws {
        let id = UUID()
        try directory.savePending(try makePending(id: id).0)
        let json = directory.directory(for: id).appendingPathComponent("pending.json")
        let text = try String(contentsOf: json, encoding: .utf8).replacingOccurrences(of: "\"schema_version\" : 1", with: "\"schema_version\" : 2")
        try Data(text.utf8).write(to: json)

        let result = directory.pendingCaptures()
        #expect(result.captures.isEmpty)
        #expect(result.dropped == 0)
        #expect(directory.isPending(captureID: id))
    }

    @Test func unreadablePendingJSONIsKept() throws {
        if getuid() == 0 { return }   // root ignores POSIX permissions; this case cannot be exercised
        let id = UUID()
        try directory.savePending(try makePending(id: id).0)
        let json = directory.directory(for: id).appendingPathComponent("pending.json")
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: json.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: json.path) }

        let result = directory.pendingCaptures()
        #expect(result.captures.isEmpty)
        #expect(result.dropped == 0)
        #expect(directory.isPending(captureID: id))
    }

    @Test func savePendingCreatesMissingDirectoryForDataOnlyDrafts() throws {
        let id = UUID()
        let draft = CaptureDraft(captureID: id, startedAt: t0, timeZone: .gmt, method: .shareExtension, userNote: "x",
                                 attachments: [AttachmentSource(body: .data(Data([1])), uti: "public.data", representationSource: "typed_note")])
        try directory.savePending(PendingCapture(draft: draft, previewImageURL: nil, totalBytes: 1, savedAt: t0))
        #expect(directory.pendingCaptures().captures.count == 1)
    }
}
