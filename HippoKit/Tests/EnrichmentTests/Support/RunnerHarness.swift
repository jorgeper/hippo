import Foundation
import Synchronization
import CaptureCore
import LocalRepository
import SyncEngine
import Enrichment

/// A settable value readable from `@Sendable` closures (the runner's clock, switches and connectivity).
final class Box<T: Sendable>: Sendable {
    private let m: Mutex<T>
    init(_ v: T) { m = Mutex(v) }
    var value: T {
        get { m.withLock { $0 } }
        set { m.withLock { $0 = newValue } }
    }
}

/// A `HippoStore` in a temp root with makers for committed captures and runners. Call `cleanup()` when done.
struct RunnerHarness {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let zone = TimeZone(identifier: "America/Los_Angeles")!
    static let producer = EnrichmentProducer(name: "hippo-ios", version: "0.2.0", build: "7")

    let base: URL
    let store: HippoStore
    let clock = Box(RunnerHarness.t0)
    let online = Box(true)
    let disabled = Box(Set<FacetKind>())

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("hippo-enrich-\(UUID().uuidString)")
        store = try HippoStore.open(root: base.appendingPathComponent("Hippo"),
                                    producer: Producer(appVersion: "0.2.0", build: "7", osVersion: "test"))
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }

    func runner(_ enrichers: [any Enricher]) -> EnrichmentRunner {
        let clock = clock, online = online, disabled = disabled
        return EnrichmentRunner(layout: store.layout, index: store.index, tasks: store.enrichmentTasks,
                                store: store.enrichments, enrichers: enrichers, producer: Self.producer,
                                isEnabled: { !disabled.value.contains($0) }, isOnline: { online.value },
                                now: { clock.value }, random: { 1 })
    }

    /// A typed note; returns its capture ID.
    func note(_ text: String, minutes: Double = 0) async throws -> String {
        try await store.capture(CaptureDraft(
            captureID: UUID(), startedAt: Self.t0.addingTimeInterval(minutes * 60), timeZone: Self.zone,
            method: .typedNote,
            attachments: [AttachmentSource(body: .data(Data(text.utf8)), originalFilename: "note.txt",
                                           uti: "public.plain-text", mimeType: "text/plain",
                                           representationSource: "typed_note")])).metadata.captureID
    }

    /// A shared link; returns its capture ID.
    func link(_ url: String, minutes: Double = 0) async throws -> String {
        try await store.capture(CaptureDraft(
            captureID: UUID(), startedAt: Self.t0.addingTimeInterval(minutes * 60), timeZone: Self.zone,
            method: .shareExtension, urls: [CapturedURL(url: url, source: "shared")])).metadata.captureID
    }

    func task(_ id: String, _ kind: FacetKind) throws -> EnrichmentTask? {
        try store.enrichmentTasks.task(captureID: id, kind: kind)
    }

    func deviceDoc(_ id: String) throws -> EnrichmentDocument? { try store.enrichments.document(.device, captureID: id) }

    /// Writes `bytes` where an enricher keeps temp files: `staging/enrichments/tmp-<uuid>/<name>`.
    func tempFile(_ name: String, _ bytes: Data) throws -> URL {
        let dir = store.layout.enrichmentStagingDir.appendingPathComponent("tmp-\(UUID().uuidString.lowercased())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }
}
