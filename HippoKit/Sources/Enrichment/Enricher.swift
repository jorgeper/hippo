import Foundation
import CaptureCore

/// What an enricher gets for one capture.
public struct EnricherInput: Sendable {
    public var captureID: String
    public var metadata: CaptureMetadata
    /// The capture's package directory (read-only: bronze is never modified).
    public var packageURL: URL
    /// The typed note's text (first 4 KiB), for `typed_note` captures only.
    public var noteBody: String?
    /// The capture's current device (silver) document, if any. Enrichers with `inputs` read them here.
    public var current: EnrichmentDocument?
    /// The capture's comments, oldest first, as loaded from its package.
    public var comments: [CaptureComment]

    public init(captureID: String, metadata: CaptureMetadata, packageURL: URL, noteBody: String?,
                current: EnrichmentDocument?, comments: [CaptureComment] = []) {
        self.captureID = captureID; self.metadata = metadata; self.packageURL = packageURL
        self.noteBody = noteBody; self.current = current; self.comments = comments
    }
}

/// What an enricher produced: the facet's status, data and provenance, plus any new asset files.
public struct EnricherOutput: Sendable {
    public var status: FacetStatus
    public var data: JSONValue?
    public var provenance: String
    /// New asset files keyed by their relative path in the document (`assets/<sha256>.<ext>`). The
    /// enricher writes them under `layout.enrichmentStagingDir/tmp-<uuid>/`; the runner deletes them
    /// after the write.
    public var newAssets: [String: URL]

    public init(status: FacetStatus, data: JSONValue?, provenance: String, newAssets: [String: URL] = [:]) {
        self.status = status; self.data = data; self.provenance = provenance; self.newAssets = newAssets
    }
}

/// Why an enricher produced nothing. Codes are fixed category strings, never content.
public enum EnrichmentError: Error, Sendable, Equatable {
    /// Not now, through no fault of the attempt (for example, a model still downloading). Retried after
    /// `retryAfter` seconds without counting an attempt.
    case deferred(code: String, retryAfter: TimeInterval)
    /// Might work next time. Counts an attempt; retried with backoff up to `EnrichmentRunner.maxAttempts`.
    case transient(code: String)
    /// Will never work for this capture at this version.
    case permanent(code: String)
}

/// Derives one facet kind from a capture (design §5). Runs at most once per (capture, kind, version).
public protocol Enricher: Sendable {
    var kind: FacetKind { get }
    /// Bumping it reruns the enricher on every capture.
    var version: Int { get }
    /// Network kinds are not claimed while offline.
    var usesNetwork: Bool { get }
    /// Facet kinds this enricher reads from `EnricherInput.current`. When one of them gets new data,
    /// this enricher runs again for that capture.
    var inputs: Set<FacetKind> { get }
    /// Whether the capture has anything for this enricher. False records `not_applicable`.
    func applies(to m: CaptureMetadata) -> Bool
    /// Like `applies(to:)`, for enrichers that also read comments. The default ignores them.
    func applies(to m: CaptureMetadata, comments: [CaptureComment]) -> Bool
    /// True when `run` reads the attachment files' bytes. Such a kind isn't scheduled for a capture with a
    /// trimmed attachment (its local original is gone), unless it also `readsCommentAudio` and the capture
    /// has an audio comment.
    var readsAttachmentBytes: Bool { get }
    /// True when `run` reads audio comments' files. Comment files are never trimmed, so such a kind still
    /// runs for a capture with a trimmed attachment once it has an audio comment, and skips absent attachments.
    var readsCommentAudio: Bool { get }
    func run(_ input: EnricherInput) async throws -> EnricherOutput
}

extension Enricher {
    public var readsAttachmentBytes: Bool { false }
    public var readsCommentAudio: Bool { false }
    public func applies(to m: CaptureMetadata, comments: [CaptureComment]) -> Bool { applies(to: m) }
}
