import Foundation
import CaptureCore
import UniformTypeIdentifiers

/// On-device speech recognition. The app implements it with SpeechAnalyzer; tests use a fake.
/// Throws `EnrichmentError.deferred(code: "model_missing", retryAfter: 900)` when the model isn't installed yet.
public protocol Transcribing: Sendable {
    func transcribe(fileURL: URL, locale: Locale) async throws -> (text: String, segments: [TranscriptSegment])
}

/// Transcription is English only: the phone's locale if its language is English, else `en_US` (design §14 Q1).
public enum TranscriptLocale {
    public static func choose(current: Locale) -> Locale {
        current.language.languageCode == .english ? current : Locale(identifier: "en_US")
    }
}

/// Transcribes audio attachments on device (design §5.5).
public struct TranscriptEnricher: Enricher {
    static let maxSeconds = 3600.0

    public var kind: FacetKind { .transcript }
    public var version: Int { 1 }
    public var usesNetwork: Bool { false }
    public var inputs: Set<FacetKind> { [] }

    private let transcriber: any Transcribing
    private let locale: Locale

    public init(transcriber: any Transcribing, locale: Locale) {
        self.transcriber = transcriber; self.locale = locale
    }

    public func applies(to m: CaptureMetadata) -> Bool { m.attachments.contains(where: Self.isAudio) }

    private static func isAudio(_ a: Attachment) -> Bool { UTType(a.uti)?.conforms(to: .audio) ?? false }

    public func run(_ input: EnricherInput) async throws -> EnricherOutput {
        var items: [TranscriptItem] = []
        for a in input.metadata.attachments where Self.isAudio(a) {
            try Task.checkCancellation()
            if let d = a.media?.durationSeconds, d > Self.maxSeconds { continue }
            let url = input.packageURL.appendingPathComponent(a.relativePath)
            let result: (text: String, segments: [TranscriptSegment])
            do { result = try await transcriber.transcribe(fileURL: url, locale: locale) }
            catch let e as EnrichmentError { throw e }
            catch is CancellationError { throw CancellationError() }
            catch { throw EnrichmentError.transient(code: "transcription_failed") }
            guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            items.append(TranscriptItem(attachmentID: a.attachmentID, text: result.text,
                                        locale: locale.identifier, segments: result.segments))
        }
        if items.isEmpty { return EnricherOutput(status: .empty, data: nil, provenance: "speech_analyzer") }
        return EnricherOutput(status: .ok, data: try .payload(TranscriptData(items: items)), provenance: "speech_analyzer")
    }
}
