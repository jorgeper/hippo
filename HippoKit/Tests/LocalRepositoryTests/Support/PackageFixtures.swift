import Foundation
import CaptureCore
import LocalRepository

/// A temp store with a database, an index and a package writer.
struct IndexHarness {
    let root: URL
    let layout: StoreLayout
    let db: Database
    let index: CaptureIndex
    let writer: PackageWriter
    let zone = TimeZone(identifier: "America/Los_Angeles")!

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hippo-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        layout = StoreLayout(root: root)
        db = try Database(url: layout.databaseURL)
        index = CaptureIndex(db: db)
        writer = PackageWriter(layout: layout, producer: Producer(appVersion: "0.1.0", build: "1", osVersion: "test"))
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    /// Commits a package and registers it. Returns the committed package.
    @discardableResult
    func add(id: UUID = UUID(), at date: Date = Date(timeIntervalSince1970: 1_794_070_800),
             method: CaptureMethod = .shareExtension, note: String? = nil, title: String? = nil,
             sharedText: String? = nil, urls: [String] = [], attachments: [AttachmentSource] = [],
             location: CaptureLocation? = nil) async throws -> CommittedPackage {
        let draft = CaptureDraft(captureID: id, startedAt: date, timeZone: zone, method: method, userNote: note,
                                 sharedTitle: title, sharedText: sharedText,
                                 urls: urls.map { CapturedURL(url: $0, source: "shared") },
                                 attachments: attachments, location: location)
        let pkg = try await writer.commit(draft)
        _ = try index.register(pkg, noteBody: pkg.noteBody())
        return pkg
    }
}

func textAttachment(_ text: String, name: String? = nil) -> AttachmentSource {
    AttachmentSource(body: .data(Data(text.utf8)), originalFilename: name, uti: "public.utf8-plain-text",
                     mimeType: "text/plain", representationSource: "typed_note")
}

func imageAttachment(name: String? = nil, data: Data) -> AttachmentSource {
    AttachmentSource(body: .data(data), originalFilename: name, uti: "public.png", mimeType: "image/png",
                     representationSource: "item_provider_data")
}
