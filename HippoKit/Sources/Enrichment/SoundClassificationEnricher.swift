import Foundation
import CaptureCore
import SoundAnalysis

/// Labels the sounds in audio attachments and audio comments with Apple's built-in classifier (design §5.5).
public struct SoundClassificationEnricher: Enricher {
    public struct Label: Sendable, Equatable {
        public var label: String
        public var confidence: Double
        public init(label: String, confidence: Double) { self.label = label; self.confidence = confidence }
    }
    /// Classifies one audio file: each label with its mean confidence over the file. Tests substitute a fake.
    public typealias Classifier = @Sendable (URL) async throws -> [Label]

    public static let minimumConfidence = 0.3
    public static let maxLabels = 8

    public var kind: FacetKind { .soundClassification }
    public var version: Int { 1 }
    public var usesNetwork: Bool { false }
    public var readsAttachmentBytes: Bool { true }
    public var readsCommentAudio: Bool { true }
    public var inputs: Set<FacetKind> { [] }

    private let classify: Classifier

    public init(classify: @escaping Classifier = SoundClassificationEnricher.liveClassifier) { self.classify = classify }

    public func applies(to m: CaptureMetadata) -> Bool { m.attachments.contains(where: \.isAudio) }

    public func applies(to m: CaptureMetadata, comments: [CaptureComment]) -> Bool {
        applies(to: m) || comments.contains { $0.audio != nil }
    }

    /// `SNClassifySoundRequest` (version 1) over the whole file; a label's confidence is its sum over all
    /// result windows divided by the number of windows.
    public static let liveClassifier: Classifier = { url in
        let analyzer = try SNAudioFileAnalyzer(url: url)
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        let collector = MeanCollector()
        try analyzer.add(request, withObserver: collector)
        await analyzer.analyze()
        if let error = collector.failure { throw error }
        return collector.means()
    }

    public func run(_ input: EnricherInput) async throws -> EnricherOutput {
        var files: [(id: String, path: String)] = []
        for a in input.metadata.attachments where a.isAudio { files.append((a.attachmentID, a.relativePath)) }
        for c in input.comments { if let audio = c.audio { files.append((c.commentID, audio.relativePath)) } }

        var items: [SoundClassificationData.Item] = []
        var attempted = 0, failed = 0
        for f in files {
            try Task.checkCancellation()
            let url = input.packageURL.appendingPathComponent(f.path)
            // A trimmed attachment's file is gone; its comments' files never are.
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            attempted += 1
            let found: [Label]
            do { found = try await classify(url) }
            catch is CancellationError { throw CancellationError() }
            catch { failed += 1; continue }
            let kept = found.filter { $0.confidence >= Self.minimumConfidence }
                .sorted { $0.confidence > $1.confidence }
                .prefix(Self.maxLabels)
                .map { SoundClassificationData.Label(label: $0.label, confidence: $0.confidence) }
            if !kept.isEmpty { items.append(SoundClassificationData.Item(attachmentID: f.id, labels: Array(kept))) }
        }
        // One bad file must not block the rest; only a pass where the classifier failed on every file retries.
        if attempted > 0, failed == attempted { throw EnrichmentError.transient(code: "sound_analysis_failed") }
        if items.isEmpty { return EnricherOutput(status: .empty, data: nil, provenance: "sound_analysis") }
        return EnricherOutput(status: .ok, data: try .payload(SoundClassificationData(items: items)), provenance: "sound_analysis")
    }
}

/// Sums each label's confidence over the result windows. The analyzer calls it from its own queue.
private final class MeanCollector: NSObject, SNResultsObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var sums: [String: Double] = [:]
    private var windows = 0
    private var error: Error?

    var failure: Error? { lock.lock(); defer { lock.unlock() }; return error }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        lock.lock(); defer { lock.unlock() }
        windows += 1
        for c in result.classifications { sums[c.identifier, default: 0] += c.confidence }
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        lock.lock(); self.error = error; lock.unlock()
    }

    func means() -> [SoundClassificationEnricher.Label] {
        lock.lock(); defer { lock.unlock() }
        guard windows > 0 else { return [] }
        return sums.map { .init(label: $0.key, confidence: $0.value / Double(windows)) }
    }
}
