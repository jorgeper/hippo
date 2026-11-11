import Foundation
import CaptureCore
import Vision

/// Reads barcodes and QR codes in image attachments with Vision (design §5.3). A URL payload is recorded
/// only: nothing is fetched and the capture's `urls` are untouched.
public struct BarcodeEnricher: Enricher {
    static let maxPayloadLength = 2048
    static let maxItemsPerAttachment = 20

    public struct Detected: Sendable, Equatable {
        public var symbology: String
        public var payload: String
        public init(symbology: String, payload: String) { self.symbology = symbology; self.payload = payload }
    }
    /// Finds the barcodes in one image file. Tests substitute a fake.
    public typealias Detector = @Sendable (URL) async throws -> [Detected]

    public var kind: FacetKind { .barcodes }
    public var version: Int { 1 }
    public var usesNetwork: Bool { false }
    public var readsAttachmentBytes: Bool { true }
    public var readsCommentAudio: Bool { false }
    public var inputs: Set<FacetKind> { [] }

    private let detect: Detector

    public init(detect: @escaping Detector = BarcodeEnricher.liveDetector) { self.detect = detect }

    public func applies(to m: CaptureMetadata) -> Bool { m.attachments.contains(where: \.isImage) }

    /// `VNDetectBarcodesRequest` on the file; symbology lowercased, without its `VNBarcodeSymbology` prefix.
    public static let liveDetector: Detector = { url in
        let request = VNDetectBarcodesRequest()
        try VNImageRequestHandler(url: url).perform([request])
        return (request.results ?? []).compactMap { o in
            guard let payload = o.payloadStringValue else { return nil }
            var name = o.symbology.rawValue
            if name.hasPrefix("VNBarcodeSymbology") { name.removeFirst("VNBarcodeSymbology".count) }
            return Detected(symbology: name.lowercased(), payload: payload)
        }
    }

    public func run(_ input: EnricherInput) async throws -> EnricherOutput {
        var items: [BarcodesData.Item] = []
        var attempted = 0, failed = 0
        for a in input.metadata.attachments where a.isImage {
            try Task.checkCancellation()
            attempted += 1
            let found: [Detected]
            do { found = try await detect(input.packageURL.appendingPathComponent(a.relativePath)) }
            catch is CancellationError { throw CancellationError() }
            catch { failed += 1; continue }
            for d in found.prefix(Self.maxItemsPerAttachment) {
                // The schema counts Unicode scalars, not Characters.
                let payload = String(String.UnicodeScalarView(d.payload.unicodeScalars.prefix(Self.maxPayloadLength)))
                // A cut-off URL would point somewhere else, so a truncated payload never gets one.
                let url = payload.unicodeScalars.count == d.payload.unicodeScalars.count ? Self.webURL(payload) : nil
                items.append(BarcodesData.Item(attachmentID: a.attachmentID, symbology: d.symbology, payload: payload, url: url))
            }
        }
        // One bad image must not block the rest; only a pass where Vision failed on every image retries.
        if attempted > 0, failed == attempted { throw EnrichmentError.transient(code: "vision_failed") }
        if items.isEmpty { return EnricherOutput(status: .empty, data: nil, provenance: "vision") }
        return EnricherOutput(status: .ok, data: try .payload(BarcodesData(items: items)), provenance: "vision")
    }

    /// The payload when it is a single-token `http` or `https` URL with a host, else nil.
    private static func webURL(_ payload: String) -> String? {
        guard !payload.contains(where: { $0.isWhitespace || $0.isNewline }),
              let url = URL(string: payload), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false), !host.isEmpty else { return nil }
        return payload
    }
}
