import Foundation
import CaptureCore

/// Finds dates, phone numbers, addresses and links in the capture's text (design §5.4).
public struct DataDetectionEnricher: Enricher {
    public var kind: FacetKind { .dataDetection }
    public var version: Int { 1 }
    public var usesNetwork: Bool { false }
    public var inputs: Set<FacetKind> { [.textRecognition, .transcript] }

    public init() {}

    /// Always true: the runner never resets `not_applicable` rows, and OCR or transcripts can land later.
    public func applies(to m: CaptureMetadata) -> Bool { true }

    public func run(_ input: EnricherInput) async throws -> EnricherOutput {
        let m = input.metadata
        var sources: [(source: String, text: String)] = []
        if let t = m.userNote { sources.append(("user_note", t)) }
        if let t = m.sharedText { sources.append(("shared_text", t)) }
        if let t = input.noteBody { sources.append(("note_body", t)) }
        if let facet = input.current?[.textRecognition], facet.status == .ok,
           let data = facet.decodeData(TextRecognitionData.self) {
            for item in data.items { sources.append(("text_recognition:\(item.attachmentID)", item.text)) }
        }
        if let facet = input.current?[.transcript], facet.status == .ok,
           let data = facet.decodeData(TranscriptData.self) {
            for item in data.items { sources.append(("transcript:\(item.attachmentID)", item.text)) }
        }

        let known = Set(m.urls.map(\.url))
        var items: [Detection] = []
        var seen = Set<String>()
        for (source, text) in sources where !text.isEmpty {
            for d in Self.detect(in: text, source: source) {
                if d.type == "link", let v = d.value, known.contains(v) || known.contains(d.text) { continue }
                guard seen.insert("\(d.type)\u{1F}\(d.value ?? d.text)\u{1F}\(d.source)").inserted else { continue }
                items.append(d)
            }
        }
        if items.isEmpty { return EnricherOutput(status: .empty, data: nil, provenance: "ns_data_detector") }
        return EnricherOutput(status: .ok, data: try .payload(DataDetectionData(items: items)),
                              provenance: "ns_data_detector")
    }

    static func detect(in text: String, source: String) -> [Detection] {
        let types: NSTextCheckingResult.CheckingType = [.date, .phoneNumber, .address, .link]
        guard let detector = try? NSDataDetector(types: types.rawValue) else { return [] }
        let ns = text as NSString
        var out: [Detection] = []
        // NSDataDetector reads dates in the system time zone; the wall-clock it found is formatted in that
        // same zone so it is reported as written (§5.4: never assign a zone the text did not state).
        for r in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let matched = ns.substring(with: r.range)
            switch r.resultType {
            case .date:
                guard let date = r.date else { continue }
                out.append(Detection(type: "date", text: matched, value: dateValue(date, zone: r.timeZone), source: source))
            case .phoneNumber:
                out.append(Detection(type: "phone", text: matched, value: r.phoneNumber ?? matched, source: source))
            case .address:
                var comps: [String: String] = [:]
                for (k, v) in r.addressComponents ?? [:] { comps[k.rawValue] = v }
                out.append(Detection(type: "address", text: matched, components: comps.isEmpty ? nil : comps, source: source))
            case .link:
                guard let url = r.url else { continue }
                out.append(Detection(type: "link", text: matched, value: url.absoluteString, source: source))
            default: break
            }
        }
        return out
    }

    private static func dateValue(_ date: Date, zone: TimeZone?) -> String {
        if let zone {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            f.timeZone = zone
            return f.string(from: date)
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.string(from: date)
    }
}
