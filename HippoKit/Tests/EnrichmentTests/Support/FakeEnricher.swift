import Foundation
import Synchronization
import CaptureCore
import Enrichment

/// A scripted `Enricher`. Each `run` takes the next step from the queue; an empty queue gives `fallback`.
final class FakeEnricher: Enricher {
    enum Step: Sendable {
        case output(EnricherOutput)
        case error(EnrichmentError)
        /// Runs the closure (it may await, throw, or touch the store).
        case custom(@Sendable (EnricherInput) async throws -> EnricherOutput)
    }

    let kind: FacetKind
    let version: Int
    let usesNetwork: Bool
    let inputs: Set<FacetKind>
    let readsAttachmentBytes: Bool
    private let appliesTo: @Sendable (CaptureMetadata) -> Bool
    private let fallback: EnricherOutput
    private let state: Mutex<(steps: [Step], received: [EnricherInput])>

    init(kind: FacetKind, version: Int = 1, usesNetwork: Bool = false, inputs: Set<FacetKind> = [], readsAttachmentBytes: Bool = false,
         applies: @escaping @Sendable (CaptureMetadata) -> Bool = { _ in true },
         steps: [Step] = [], fallback: EnricherOutput = FakeEnricher.ok(.string("fake"))) {
        self.kind = kind; self.version = version; self.usesNetwork = usesNetwork; self.inputs = inputs
        self.readsAttachmentBytes = readsAttachmentBytes
        self.appliesTo = applies; self.fallback = fallback
        state = Mutex((steps, []))
    }

    static func ok(_ data: JSONValue, provenance: String = "fake", newAssets: [String: URL] = [:]) -> EnricherOutput {
        EnricherOutput(status: .ok, data: data, provenance: provenance, newAssets: newAssets)
    }

    /// Inputs of every `run` call so far, in order.
    var received: [EnricherInput] { state.withLock { $0.received } }
    var invocations: Int { received.count }

    func enqueue(_ steps: Step...) { state.withLock { $0.steps.append(contentsOf: steps) } }

    func applies(to m: CaptureMetadata) -> Bool { appliesTo(m) }

    func run(_ input: EnricherInput) async throws -> EnricherOutput {
        let step: Step? = state.withLock {
            $0.received.append(input)
            return $0.steps.isEmpty ? nil : $0.steps.removeFirst()
        }
        switch step {
        case nil: return fallback
        case .output(let o): return o
        case .error(let e): throw e
        case .custom(let body): return try await body(input)
        }
    }
}
