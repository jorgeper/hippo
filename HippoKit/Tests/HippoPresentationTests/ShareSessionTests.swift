import Foundation
import Synchronization
import Testing
import UniformTypeIdentifiers
import CaptureCore
import ShareIntake
import SyncEngine
import LocalRepository
import HippoTestSupport
@testable import HippoPresentation

private let t0 = Date(timeIntervalSince1970: 1_794_070_860)
private let la = TimeZone(identifier: "America/Los_Angeles")!

private let fix = CaptureLocation(latitude: 47.6205, longitude: -122.3493, horizontalAccuracyMeters: 5,
                                  observedAt: t0, provenance: "test")

@MainActor
private struct Rig {
    let ts: TestStore
    let intake: IntakeDirectory
    let model: ShareSessionModel
    let recorder = FakeRecorder()

    init(_ providers: [FakeProvider], text: String? = nil, destination: String? = "Dropbox",
         location: CaptureLocation? = nil) throws {
        ts = try TestStore()
        intake = IntakeDirectory(storeRoot: ts.base.appendingPathComponent("Hippo"))
        let input = ShareInput(title: nil, contentText: text, providers: providers, userInfoKeys: [])
        model = ShareSessionModel(store: ts.store, intake: intake, input: input, destinationName: destination,
                                  location: { _ in location }, now: { t0 }, timeZone: la)
    }

    /// A draft already on disk (camera) with a voice session. The location is never re-read.
    init(prepared: (IntakeDirectory) throws -> PreparedCapture) throws {
        ts = try TestStore()
        intake = IntakeDirectory(storeRoot: ts.base.appendingPathComponent("Hippo"))
        let voice = RecordingSession(intake: intake, recorder: recorder, permission: { .granted }, now: { t0 })
        model = ShareSessionModel(store: ts.store, intake: intake, prepared: try prepared(intake),
                                  destinationName: "Dropbox", voice: voice,
                                  location: { _ in Issue.record("a prepared capture re-read the location"); return nil },
                                  now: { t0 })
    }

    var captureDirectories: [URL] {
        let root = ts.base.appendingPathComponent("Hippo/intake")
        return (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    }

    func committed() throws -> [CaptureMetadata] {
        try ts.store.index.page(CaptureFilter(), after: nil, limit: 10)
            .compactMap { try ts.store.index.metadata(captureID: $0.id, layout: ts.store.layout) }
    }
}

private func link(_ url: String = "https://example.com/a/b") -> FakeProvider {
    FakeProvider(types: ["public.url"], url: URL(string: url))
}
/// Suspends in `loadURL` long enough for a test to cancel the session mid-prepare.
private final class SlowProvider: ItemProviding {
    let registeredTypeIdentifiers = ["public.url"]
    let suggestedName: String? = nil
    let started = Mutex(false)
    func copyFile(typeIdentifier: String, to destination: URL) async throws {}
    func loadURL() async throws -> URL {
        started.withLock { $0 = true }
        try await Task.sleep(for: .milliseconds(300))
        return URL(string: "https://example.com")!
    }
    func loadText() async throws -> String { "" }
}
private let unsupported = FakeProvider(types: ["com.example.unknown"])
private func jpeg() throws -> FakeProvider {
    FakeProvider(types: ["public.jpeg"], suggestedName: "a", fileBytes: try MediaMaker.imageData(width: 8, height: 8))
}

/// A camera photo staged in `intake/<capture-id>/`, as the camera flow leaves it. `missingFile` skips writing it.
private func stagedPhoto(_ intake: IntakeDirectory, method: CaptureMethod = .camera,
                         missingFile: Bool = false) throws -> PreparedCapture {
    let id = UUID()
    let dir = intake.directory(for: id)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("photo.heic")
    let bytes = try MediaMaker.imageData(width: 8, height: 8, type: .heic)
    if !missingFile { try bytes.write(to: url) }
    let draft = CaptureDraft(captureID: id, startedAt: t0, timeZone: la, method: method,
                             attachments: [AttachmentSource(body: .file(url), uti: "public.heic", mimeType: "image/heic",
                                                            representationSource: "camera")])
    return PreparedCapture(draft: draft, previewImageURL: missingFile ? nil : url, totalBytes: Int64(bytes.count))
}

@MainActor
@Suite struct ShareSessionTests {
    @Test func saveAddsTrimmedComment() async throws {
        let rig = try Rig([link()])
        defer { rig.ts.cleanup() }
        await rig.model.prepare()
        #expect(rig.model.state == .ready)
        rig.model.comment = "  worth reading \n"
        await rig.model.save()
        #expect(rig.model.state == .saved)
        let rows = try rig.committed()
        #expect(rows.count == 1)
        #expect(rows[0].userNote == "worth reading")
        #expect(rig.captureDirectories.isEmpty)
    }

    @Test func emptyCommentIsNil() async throws {
        let rig = try Rig([link()])
        defer { rig.ts.cleanup() }
        await rig.model.prepare()
        rig.model.comment = "  \n "
        await rig.model.save()
        #expect(rig.model.state == .saved)
        let rows = try rig.committed()
        #expect(rows.count == 1)
        #expect(rows[0].userNote == nil)
    }

    @Test func partialFailureRequiresConfirmation() async throws {
        let rig = try Rig([link(), unsupported])
        defer { rig.ts.cleanup() }
        await rig.model.prepare()
        #expect(rig.model.state == .ready)
        #expect(rig.model.partialNotice == "Hippo can't save 1 of these items.")
        rig.model.comment = " typed after the notice "
        await rig.model.save()
        #expect(rig.model.state == .confirmPartial(message: "Hippo can't save 1 of these items."))
        #expect(try rig.committed().isEmpty)
        await rig.model.save(acceptPartial: true)
        #expect(rig.model.state == .saved)
        let rows = try rig.committed()
        #expect(rows.count == 1)
        #expect(rows[0].urls.map(\.url) == ["https://example.com/a/b"])
        #expect(rows[0].userNote == "typed after the notice")
    }

    @Test func decliningPartialConfirmationReturnsToReady() async throws {
        let rig = try Rig([link(), unsupported])
        defer { rig.ts.cleanup() }
        await rig.model.prepare()
        await rig.model.save()
        #expect(rig.model.state == .confirmPartial(message: "Hippo can't save 1 of these items."))
        rig.model.declinePartial()
        #expect(rig.model.state == .ready)
        #expect(rig.model.partialNotice != nil)
        #expect(try rig.committed().isEmpty)
        #expect(rig.captureDirectories.count == 1)
        rig.model.declinePartial() // no-op outside the confirmation
        #expect(rig.model.state == .ready)
    }

    @Test func cleanShareHasNoNotice() async throws {
        let rig = try Rig([link()])
        defer { rig.ts.cleanup() }
        await rig.model.prepare()
        #expect(rig.model.partialNotice == nil)
    }

    @Test func cancelDuringPrepareDiscardsAndStaysPreparing() async throws {
        let slow = SlowProvider()
        let ts = try TestStore()
        defer { ts.cleanup() }
        let intake = IntakeDirectory(storeRoot: ts.base.appendingPathComponent("Hippo"))
        let model = ShareSessionModel(store: ts.store, intake: intake,
                                      input: ShareInput(title: nil, contentText: nil, providers: [slow], userInfoKeys: []),
                                      destinationName: nil, location: { _ in nil }, now: { t0 }, timeZone: la)
        let task = Task { await model.prepare() }
        while !slow.started.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
        model.cancel()
        await task.value
        let root = ts.base.appendingPathComponent("Hippo/intake")
        #expect(((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []).isEmpty)
        if case .preparing = model.state {} else { Issue.record("state moved on after cancel: \(model.state)") }
        await model.save()
        #expect(try ts.store.index.count() == 0)
    }

    @Test func storeAttachmentFailureOffersPartialConfirmation() {
        let failures = [AttachmentFailure(index: 0, reason: "x")]
        #expect(ShareSessionModel.message(for: .attachmentsFailed(failures)) == "1 item couldn't be saved.")
    }

    @Test func previewSymbols() async throws {
        let kb = Data(repeating: 1, count: 16)
        let cases: [(FakeProvider, String)] = [
            (FakeProvider(types: ["public.mpeg-4"], fileBytes: kb), "video"),
            (FakeProvider(types: ["com.adobe.pdf"], fileBytes: kb), "doc"),
            (link(), "link"),
            (FakeProvider(types: ["public.utf8-plain-text"], text: "hello"), "text.alignment"),
        ]
        for (provider, symbol) in cases {
            let rig = try Rig([provider])
            defer { rig.ts.cleanup() }
            await rig.model.prepare()
            #expect(rig.model.previewSymbol == symbol)
        }
    }

    @Test func nothingSavableFails() async throws {
        let rig = try Rig([unsupported])
        defer { rig.ts.cleanup() }
        await rig.model.prepare()
        #expect(rig.model.state == .failed(message: "Nothing Hippo can save was shared.", canSave: false))
        await rig.model.save()
        #expect(try rig.committed().isEmpty)
        #expect(rig.captureDirectories.isEmpty)
    }

    @Test func cancelDiscardsIntake() async throws {
        let bytes = try MediaMaker.imageData(width: 8, height: 8)
        let rig = try Rig([FakeProvider(types: ["public.jpeg"], suggestedName: "a", fileBytes: bytes)])
        defer { rig.ts.cleanup() }
        await rig.model.prepare()
        #expect(rig.model.previewImageURL != nil)
        #expect(rig.captureDirectories.count == 1)
        rig.model.cancel()
        #expect(rig.captureDirectories.isEmpty)
    }

    @Test func summaryTexts() async throws {
        let kb = Data(repeating: 1, count: 2048)
        let cases: [(providers: [FakeProvider], expected: String)] = [
            ([FakeProvider(types: ["public.jpeg"], fileBytes: kb), FakeProvider(types: ["public.png"], fileBytes: kb)], "2 items · 4 KB"),
            ([FakeProvider(types: ["public.jpeg"], fileBytes: kb)], "1 photo · 2 KB"),
            ([FakeProvider(types: ["public.mpeg-4"], fileBytes: kb)], "1 video · 2 KB"),
            ([FakeProvider(types: ["com.adobe.pdf"], fileBytes: kb)], "1 file · 2 KB"),
            ([FakeProvider(types: ["com.adobe.pdf"], suggestedName: "Lease.pdf", fileBytes: kb)], "Lease.pdf · 2 KB"),
            ([link("https://www.example.com/path?q=1")], "www.example.com"),
            ([FakeProvider(types: ["public.utf8-plain-text"], text: "hello")], "Text"),
        ]
        for c in cases {
            let rig = try Rig(c.providers)
            defer { rig.ts.cleanup() }
            await rig.model.prepare()
            #expect(rig.model.summary == c.expected)
        }
    }

    @Test func destinationLineCopy() throws {
        let named = try Rig([link()], destination: "Dropbox")
        defer { named.ts.cleanup() }
        #expect(named.model.destinationLine == "Saves on this iPhone first. Uploads to Dropbox when it can.")
        let none = try Rig([link()], destination: nil)
        defer { none.ts.cleanup() }
        #expect(none.model.destinationLine == "Saves on this iPhone. Uploads once you connect Dropbox in Hippo.")
    }

    @Test func errorMessages() {
        #expect(ShareSessionModel.message(for: .insufficientSpace(requiredBytes: 10, availableBytes: 1))
                == "Not enough space on this iPhone. Nothing was saved.")
        #expect(ShareSessionModel.message(for: .attachmentsFailed([AttachmentFailure(index: 0, reason: "x"), AttachmentFailure(index: 1, reason: "y")]))
                == "2 items couldn't be saved.")
        #expect(ShareSessionModel.message(for: .emptyCapture) == "Nothing Hippo can save was shared.")
        #expect(ShareSessionModel.message(for: .io("x")) == "Hippo couldn't save this. Nothing was saved.")
        #expect(ShareSessionModel.partialMessage(unsupported: 0, loadFailed: 3) == "3 items couldn't be copied.")
        #expect(ShareSessionModel.partialMessage(unsupported: 2, loadFailed: 1) == "2 items can't be saved and 1 couldn't be copied.")
        // One item reads as one item.
        #expect(ShareSessionModel.partialMessage(unsupported: 0, loadFailed: 1) == "1 item couldn't be copied.")
        #expect(ShareSessionModel.partialMessage(unsupported: 1, loadFailed: 2) == "1 item can't be saved and 2 couldn't be copied.")
        #expect(ShareSessionModel.message(for: .attachmentsFailed([AttachmentFailure(index: 0, reason: "x")]))
                == "1 item couldn't be saved.")
    }
    // MARK: - Capture sheet: prepared drafts, voice comment, hand-off

    @Test func preparedStartsReadyWithSummary() async throws {
        var staged: PreparedCapture?
        let rig = try Rig { intake in
            let p = try stagedPhoto(intake)
            staged = p
            return p
        }
        defer { rig.ts.cleanup() }
        let prepared = try #require(staged)
        #expect(rig.model.state == .ready)
        let size = ByteCountFormatter.string(fromByteCount: prepared.totalBytes, countStyle: .file)
        #expect(rig.model.summary == "1 photo · \(size)")
        #expect(rig.model.previewSymbol == "photo")
        #expect(rig.model.previewImageURL == prepared.previewImageURL)
        #expect(rig.model.partialNotice == nil)
        await rig.model.prepare() // no-op
        #expect(rig.model.state == .ready)
    }

    @Test func saveAppendsVoiceComment() async throws {
        let rig = try Rig { try stagedPhoto($0) }
        defer { rig.ts.cleanup() }
        let voice = try #require(rig.model.voice)
        await voice.start()
        voice.stop()
        let recording = try #require(voice.pending?.url)
        await rig.model.save()
        #expect(rig.model.state == .saved)
        let rows = try rig.committed()
        #expect(rows.count == 1)
        #expect(rows[0].captureMethod == .camera)
        #expect(rows[0].attachments.count == 2)
        #expect(rows[0].attachments.last?.uti == "com.apple.m4a-audio")
        #expect(rows[0].attachments.last?.mimeType == "audio/mp4")
        #expect(rows[0].attachments.last?.representationSource == "recording")
        #expect(!FileManager.default.fileExists(atPath: recording.path))
        #expect(rig.captureDirectories.isEmpty)
    }

    @Test func saveStopsRunningRecordingAndAttachesIt() async throws {
        let rig = try Rig { try stagedPhoto($0) }
        defer { rig.ts.cleanup() }
        let voice = try #require(rig.model.voice)
        await voice.start()
        await rig.model.save()
        #expect(rig.recorder.stopCount == 1)
        #expect(rig.model.state == .saved)
        let rows = try rig.committed()
        #expect(rows.count == 1)
        #expect(rows[0].attachments.map(\.representationSource) == ["camera", "recording"])
        #expect(rig.captureDirectories.isEmpty)
    }

    @Test func saveWithoutVoiceHasOneAttachment() async throws {
        let rig = try Rig { try stagedPhoto($0) }
        defer { rig.ts.cleanup() }
        rig.model.comment = " on the way home "
        await rig.model.save()
        #expect(rig.model.state == .saved)
        let rows = try rig.committed()
        #expect(rows.count == 1)
        #expect(rows[0].attachments.count == 1)
        #expect(rows[0].attachments[0].uti == "public.heic")
        #expect(rows[0].userNote == "on the way home")
        #expect(rig.captureDirectories.isEmpty)
    }

    @Test func rejectedCommitKeepsRecordingForRetry() async throws {
        let rig = try Rig { try stagedPhoto($0, missingFile: true) }
        defer { rig.ts.cleanup() }
        let voice = try #require(rig.model.voice)
        await voice.start()
        voice.stop()
        let recording = try #require(voice.pending?.url)
        await rig.model.save()
        #expect(rig.model.state == .confirmPartial(message: "1 item couldn't be saved."))
        #expect(try rig.committed().isEmpty)
        #expect(FileManager.default.fileExists(atPath: recording.path))
        #expect(voice.pending?.url == recording)
        await rig.model.save(acceptPartial: true)
        #expect(rig.model.state == .saved)
        let rows = try rig.committed()
        #expect(rows.count == 1)
        #expect(rows[0].attachments.map(\.uti) == ["com.apple.m4a-audio"])
        #expect(!FileManager.default.fileExists(atPath: recording.path))
        #expect(rig.captureDirectories.isEmpty)
    }
}
