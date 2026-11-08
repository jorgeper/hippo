import Foundation
import CaptureCore
import SyncEngine

/// A `HippoStore` in a temp root, with makers for committed captures. Call `cleanup()` when done.
struct TestStore {
    let base: URL
    let store: HippoStore
    static let zone = TimeZone(identifier: "America/Los_Angeles")!

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("hippo-pres-\(UUID().uuidString)")
        store = try HippoStore.open(root: base.appendingPathComponent("Hippo"),
                                    producer: Producer(appVersion: "0.1.0", build: "1", osVersion: "test"))
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }

    @discardableResult
    func capture(_ draft: CaptureDraft) async throws -> CommittedPackage { try await store.capture(draft) }

    /// A typed note captured at `at`.
    @discardableResult
    func note(_ text: String, at: Date, zone: TimeZone = TestStore.zone) async throws -> CommittedPackage {
        try await capture(CaptureDraft(
            captureID: UUID(), startedAt: at, timeZone: zone, method: .typedNote,
            attachments: [AttachmentSource(body: .data(Data(text.utf8)), originalFilename: "note.txt",
                                           uti: "public.plain-text", mimeType: "text/plain",
                                           representationSource: "typed_note")]))
    }

    /// A shared link captured at `at`.
    @discardableResult
    func link(_ url: String, at: Date, zone: TimeZone = TestStore.zone) async throws -> CommittedPackage {
        try await capture(CaptureDraft(captureID: UUID(), startedAt: at, timeZone: zone, method: .shareExtension,
                                       urls: [CapturedURL(url: url, source: "shared")]))
    }
}
