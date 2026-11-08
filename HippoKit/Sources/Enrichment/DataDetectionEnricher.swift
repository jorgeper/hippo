import Foundation
import CaptureCore

/// Finds dates, phone numbers, addresses and links in the capture's text (design §5.4).
public struct DataDetectionEnricher: Enricher {
    public var kind: FacetKind { .dataDetection }
    /// 2: a bare time on a screenshot's first OCR line (the status-bar clock) is not a date.
    /// 3: relative dates ("tomorrow", "Friday", "Nov 12") resolve against the capture's day, not the run day.
    public var version: Int { 3 }
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

        let anchor = DateAnchor(metadata: m)
        let known = Set(m.urls.map(\.url))
        var items: [Detection] = []
        var seen = Set<String>()
        for (source, text) in sources where !text.isEmpty {
            for d in Self.detect(in: text, source: source, ignoresClockLine: source.hasPrefix("text_recognition:"),
                                     anchor: anchor) {
                if d.type == "link", let v = d.value, known.contains(v) || known.contains(d.text) { continue }
                guard seen.insert("\(d.type)\u{1F}\(d.value ?? d.text)\u{1F}\(d.source)").inserted else { continue }
                items.append(d)
            }
        }
        if items.isEmpty { return EnricherOutput(status: .empty, data: nil, provenance: "ns_data_detector") }
        return EnricherOutput(status: .ok, data: try .payload(DataDetectionData(items: items)),
                              provenance: "ns_data_detector")
    }

    static func detect(in text: String, source: String, ignoresClockLine: Bool = false,
                       anchor: DateAnchor?) -> [Detection] {
        let types: NSTextCheckingResult.CheckingType = [.date, .phoneNumber, .address, .link]
        guard let detector = try? NSDataDetector(types: types.rawValue) else { return [] }
        let ns = text as NSString
        let firstLine = ns.lineRange(for: NSRange(location: 0, length: 0))
        var out: [Detection] = []
        // NSDataDetector reads dates in the system time zone; the wall-clock it found is formatted in that
        // same zone so it is reported as written (§5.4: never assign a zone the text did not state).
        for r in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let matched = ns.substring(with: r.range)
            switch r.resultType {
            case .date:
                guard let date = r.date else { continue }
                if ignoresClockLine, NSMaxRange(r.range) <= NSMaxRange(firstLine), Self.isBareTime(matched) { continue }
                let value = dateValue(Self.reanchored(date, matched: matched, anchor: anchor), zone: r.timeZone)
                out.append(Detection(type: "date", text: matched, value: value, source: source))
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

    private static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// NSDataDetector resolves against the real now. Move the result so it is relative to the capture's day.
    private static func reanchored(_ date: Date, matched: String, anchor: DateAnchor?) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let runDay = cal.startOfDay(for: Date())
        guard let anchor, let anchorDay = cal.date(from: anchor.day).map({ cal.startOfDay(for: $0) }),
              anchorDay != runDay else { return date }
        let t = cal.dateComponents([.hour, .minute, .second], from: date)
        let found = cal.startOfDay(for: date)
        func at(_ day: Date) -> Date {
            var c = cal.dateComponents([.year, .month, .day], from: day)
            c.hour = t.hour; c.minute = t.minute; c.second = t.second
            return cal.date(from: c) ?? date
        }
        let monthName = #"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\b"#
        let weekdayName = #"\b(mon|tue|wed|thu|fri|sat|sun)[a-z]*\b"#
        // Full: a four-digit year, or numeric date with a year part.
        if matches(matched, #"\b\d{4}\b"#) || matches(matched, #"\b\d{1,2}[/.-]\d{1,2}[/.-]\d{2}\b"#) { return date }
        // Month and day, no year: first occurrence on or after the anchor day.
        if matches(matched, monthName) || matches(matched, #"\b\d{1,2}/\d{1,2}\b"#) {
            let md = cal.dateComponents([.month, .day], from: date)
            for y in 0...8 {
                var c = DateComponents(year: (anchor.day.year ?? 0) + y, month: md.month, day: md.day)
                c.hour = t.hour; c.minute = t.minute; c.second = t.second
                guard let cand = cal.date(from: c), cal.component(.day, from: cand) == md.day else { continue }
                if cal.startOfDay(for: cand) >= anchorDay { return cand }
            }
            return date
        }
        let wd = cal.component(.weekday, from: date)
        if matches(matched, weekdayName) {
            // The detector's week offset depends on how far ahead the named day is: run on a Sunday,
            // "Sunday brunch" is +7, "lunch next Monday" +8, "next Friday" +5, "last Friday" -2. So ask
            // it again, with the weekday as far ahead of the run day as the named one is of the capture
            // day, and apply what it says from the capture day.
            let distance = (wd - cal.component(.weekday, from: anchorDay) + 7) % 7
            if let token = weekdayToken(in: matched, naming: wd),
               let probeDay = cal.date(byAdding: .day, value: distance, to: runDay) {
                let probeWeekday = cal.component(.weekday, from: probeDay)
                let probe = (matched as NSString).replacingCharacters(in: token, with: weekdayNames[probeWeekday - 1])
                if let offset = detectedDayOffset(probe, expectedWeekday: probeWeekday, runDay: runDay, calendar: cal) {
                    return cal.date(byAdding: .day, value: offset, to: anchorDay).map(at) ?? date
                }
            }
            // Fallback: keep the week offset the detector used from the run day.
            let k = cal.dateComponents([.day], from: runDay, to: found).day ?? 0
            let w = (k - (wd - cal.component(.weekday, from: runDay) + 7) % 7) / 7
            return cal.date(byAdding: .day, value: distance + 7 * w, to: anchorDay).map(at) ?? date
        }
        let shift = cal.dateComponents([.day], from: runDay, to: anchorDay).day ?? 0
        return cal.date(byAdding: .day, value: shift, to: found).map(at) ?? date
    }

    private static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    /// The range of the word in `text` that names `weekday` (1 = Sunday): the full English name or a
    /// prefix of it of three letters or more ("Fri", "Thurs"), or "Weds". Nil if no word does ("sunny" names none).
    private static func weekdayToken(in text: String, naming weekday: Int) -> NSRange? {
        let full = weekdayNames[weekday - 1].lowercased()
        guard let words = try? NSRegularExpression(pattern: #"\b[A-Za-z]{3,}\b"#) else { return nil }
        let ns = text as NSString
        return words.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
            .first {
                let word = ns.substring(with: $0).lowercased()
                return full.hasPrefix(word) || (weekday == 4 && word == "weds")
            }
    }

    /// Days from `runDay` to the date NSDataDetector finds in `text`, if it finds one on `expectedWeekday`.
    private static func detectedDayOffset(_ text: String, expectedWeekday: Int, runDay: Date,
                                          calendar cal: Calendar) -> Int? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let date = detector.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))?.date,
              cal.component(.weekday, from: date) == expectedWeekday else { return nil }
        return cal.dateComponents([.day], from: runDay, to: cal.startOfDay(for: date)).day
    }

    /// "8:14" or "18:05": a clock reading with no day, AM/PM or words.
    static func isBareTime(_ s: String) -> Bool {
        s.range(of: #"^\d{1,2}:\d{2}$"#, options: .regularExpression) != nil
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

/// The capture's local calendar day, which relative dates in its text are relative to.
struct DateAnchor: Sendable {
    var day: DateComponents

    init(day: DateComponents) { self.day = day }

    /// The capture's date in its own zone: the date part of `localDatetime` (already local), else
    /// `capturedAt` in `timezoneIdentifier`, else in `utcOffsetSeconds`.
    init?(metadata m: CaptureMetadata) {
        let head = m.localDatetime.prefix(10).split(separator: "-").compactMap { Int($0) }
        if m.localDatetime.prefix(10).count == 10, head.count == 3 {
            self.day = DateComponents(year: head[0], month: head[1], day: head[2])
            return
        }
        let zone = TimeZone(identifier: m.timezoneIdentifier) ?? TimeZone(secondsFromGMT: m.utcOffsetSeconds)
        guard let zone else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        self.day = cal.dateComponents([.year, .month, .day], from: m.capturedAt)
    }
}
