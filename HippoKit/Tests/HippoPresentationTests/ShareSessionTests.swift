import Foundation
import Testing
import CaptureCore
import ShareIntake
import SyncEngine
import LocalRepository
import HippoTestSupport
@testable import HippoPresentation

private let t0 = Date(timeIntervalSince1970: 1_794_070_860)
private let la = TimeZone(identifier: "America/Los_Angeles")!

@MainActor
private struct Rig {
    let ts: TestStore
    let intake: IntakeDirectory
    let model: ShareSessionModel

    init(_ providers: [FakeProvider], text: String? = nil, destination: String? = "Dropbox") throws {
        ts = try TestStore()
        intake = IntakeDirectory(storeRoot: ts.base.appendingPathComponent("Hippo"))
        let input = ShareInput(title: nil, contentText: text, providers: providers, userInfoKeys: [])
        model = ShareSessionModel(store: ts.store, intake: intake, input: input, destinationName: destination,
                                  location: { _ in nil }, now: { t0 }, timeZone: la)
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
private let unsupported = FakeProvider(types: ["com.example.unknown"])

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
        #expect(rig.model.state == .confirmPartial(message: "Hippo can't save 1 of these items."))
        await rig.model.save()
        #expect(rig.model.state == .confirmPartial(message: "Hippo can't save 1 of these items."))
        #expect(try rig.committed().isEmpty)
        await rig.model.save(acceptPartial: true)
        #expect(rig.model.state == .saved)
        let rows = try rig.committed()
        #expect(rows.count == 1)
        #expect(rows[0].urls.map(\.url) == ["https://example.com/a/b"])
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
    }
}
