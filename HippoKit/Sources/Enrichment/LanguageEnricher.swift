import Foundation
import CaptureCore
import NaturalLanguage

/// Names the language of the capture's own text with `NLLanguageRecognizer` (design §5.4). Recognized text
/// and transcripts carry their own language fields and are not repeated here.
public struct LanguageEnricher: Enricher {
    /// The dominant language (a BCP 47 tag) and its probability, or nil when nothing is recognized.
    public typealias Recognizer = @Sendable (String) -> (language: String, confidence: Double)?

    /// Text shorter than this, in `Character`s after trimming, is skipped.
    public static let minimumLength = 20

    public var kind: FacetKind { .language }
    public var version: Int { 1 }
    public var usesNetwork: Bool { false }
    public var inputs: Set<FacetKind> { [] }

    private let recognize: Recognizer

    public init(recognize: @escaping Recognizer = LanguageEnricher.liveRecognizer) { self.recognize = recognize }

    public static let liveRecognizer: Recognizer = { text in
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        let confidence = recognizer.languageHypotheses(withMaximum: 1)[language] ?? 0
        return (language.rawValue, min(max(confidence, 0), 1))
    }

    /// A typed note's body is not in the metadata, so a typed note always applies; `run` then decides.
    public func applies(to m: CaptureMetadata) -> Bool {
        m.captureMethod == .typedNote || [m.userNote, m.sharedText].contains { Self.usable($0) != nil }
    }

    public func run(_ input: EnricherInput) async throws -> EnricherOutput {
        let candidates = [("user_note", input.metadata.userNote), ("shared_text", input.metadata.sharedText),
                          ("note_body", input.noteBody)]
        let texts = candidates.compactMap { source, text in Self.usable(text).map { (source, $0) } }
        // Nothing long enough is terminal, like `applies` returning false.
        if texts.isEmpty { throw EnrichmentError.notApplicable(code: "text_too_short") }
        let items = texts.compactMap { source, text in
            recognize(text).flatMap { $0.language.isEmpty || $0.language == "und" ? nil : $0 }.map { LanguageData.Item(source: source, language: $0.language, confidence: $0.confidence) }
        }
        if items.isEmpty { return EnricherOutput(status: .empty, data: nil, provenance: "natural_language") }
        return EnricherOutput(status: .ok, data: try .payload(LanguageData(items: items)), provenance: "natural_language")
    }

    /// The trimmed text when it has at least `minimumLength` characters.
    private static func usable(_ text: String?) -> String? {
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), t.count >= minimumLength else { return nil }
        return t
    }
}
