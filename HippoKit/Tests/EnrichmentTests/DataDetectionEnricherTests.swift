import Foundation
import Testing
import CaptureCore
@testable import Enrichment

@Suite struct DataDetectionEnricherTests {
    private func ocrDoc(_ text: String, attachment: String = "att1") throws -> EnrichmentDocument {
        let data = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(
            TextRecognitionData(items: [RecognizedText(attachmentID: attachment, text: text, languages: ["en-US"])])))
        let facet = Facet(version: 1, status: .ok, generatedAt: Date(timeIntervalSince1970: 0),
                          provenance: "vision_accurate", data: data)
        return EnrichmentDocument(schemaVersion: 1, captureID: "c1", layer: .device, packageDigest: "d",
                                  producer: EnrichmentProducer(name: "t", version: "1", build: "1"),
                                  generatedAt: Date(timeIntervalSince1970: 0), facets: ["text_recognition": facet])
    }

    private func detections(_ out: EnricherOutput) throws -> [Detection] {
        let data = try #require(out.data)
        return try JSONDecoder().decode(DataDetectionData.self, from: JSONEncoder().encode(data)).items
    }

    @Test func detectsPhoneDateAddressWithSources() async throws {
        let m = fixtureMetadata(zone: "Asia/Tokyo", userNote: "Call 415-555-0100 tomorrow")
        let doc = try ocrDoc("Meet 12 Dec 2026 at 3pm at 1 Infinite Loop, Cupertino, CA")
        let out = try await DataDetectionEnricher().run(fixtureInput(m, current: doc))
        #expect(out.status == .ok)
        #expect(out.provenance == "ns_data_detector")
        let items = try detections(out)
        let phone = try #require(items.first { $0.type == "phone" })
        #expect(phone.source == "user_note")
        #expect(phone.value?.contains("415-555-0100") == true)
        let date = try #require(items.first { $0.type == "date" && $0.source == "text_recognition:att1" })
        #expect(date.value == "2026-12-12T15:00:00")
        let address = try #require(items.first { $0.type == "address" })
        #expect(address.source == "text_recognition:att1")
        #expect(address.components?["City"] == "Cupertino")
    }

    @Test func dateWithZoneKeepsOffset() async throws {
        let m = fixtureMetadata(zone: "Asia/Tokyo", userNote: "3pm PST on Dec 12 2026")
        let out = try await DataDetectionEnricher().run(fixtureInput(m))
        let date = try #require(try detections(out).first { $0.type == "date" })
        #expect(try #require(date.value).hasSuffix("-08:00"))
    }

    @Test func sharedURLNotRepeated() async throws {
        let m = fixtureMetadata(sharedText: "Look at https://example.com/a/b now", urls: ["https://example.com/a/b"])
        let out = try await DataDetectionEnricher().run(fixtureInput(m))
        #expect(out.status == .empty)
        // A different link is kept.
        let other = fixtureMetadata(sharedText: "see https://other.example.org/x", urls: ["https://example.com/a/b"])
        let kept = try detections(try await DataDetectionEnricher().run(fixtureInput(other)))
        #expect(kept.map(\.type) == ["link"])
        #expect(kept.first?.value == "https://other.example.org/x")
    }

    // A screenshot's first OCR line is the status bar; its clock is not a date the user captured.
    @Test func screenshotStatusBarClockIsIgnored() async throws {
        let doc = try ocrDoc("8:14 •\n100\n< 2\nLunch on 12 Dec 2026 at 1pm")
        let items = try detections(try await DataDetectionEnricher().run(fixtureInput(fixtureMetadata(), current: doc)))
        #expect(items.filter { $0.type == "date" }.map(\.value) == ["2026-12-12T13:00:00"])

        // A bare time further down is kept, and so is one the user typed.
        let later = try ocrDoc("Agenda\nStand-up 9:30")
        let kept = try detections(try await DataDetectionEnricher().run(fixtureInput(fixtureMetadata(), current: later)))
        #expect(kept.contains { $0.type == "date" && $0.text == "9:30" })
        let typed = try detections(try await DataDetectionEnricher().run(fixtureInput(fixtureMetadata(userNote: "8:14"))))
        #expect(typed.contains { $0.type == "date" && $0.source == "user_note" })
    }

    @Test func noTextIsEmpty() async throws {
        let out = try await DataDetectionEnricher().run(fixtureInput(fixtureMetadata()))
        #expect(out.status == .empty)
        #expect(out.data == nil)
    }

    @Test func duplicatesWithinASourceAreDropped() async throws {
        let m = fixtureMetadata(userNote: "Call 415-555-0100 or 415-555-0100", sharedText: "415-555-0100")
        let items = try detections(try await DataDetectionEnricher().run(fixtureInput(m))).filter { $0.type == "phone" }
        #expect(items.map(\.source) == ["user_note", "shared_text"])
    }

    @Test func readsNoteBodyAndIgnoresNonOKFacets() async throws {
        var doc = try ocrDoc("call 415-555-0199")
        doc.facets["text_recognition"]?.status = .failed
        let out = try await DataDetectionEnricher().run(fixtureInput(fixtureMetadata(), noteBody: "ring 415-555-0100", current: doc))
        let items = try detections(out)
        #expect(items.map(\.source) == ["note_body"])
    }

    @Test func declaredShape() {
        let e = DataDetectionEnricher()
        #expect(e.kind == .dataDetection && e.version == 3 && !e.usesNetwork)
        #expect(e.inputs == [.textRecognition, .transcript])
        #expect(e.applies(to: fixtureMetadata(method: .typedNote)))
    }

    // MARK: relative dates resolve against the capture (v3)

    private var cal: Calendar { Calendar.current }
    private func noon(daysFromToday n: Int) -> Date {
        let today = cal.startOfDay(for: Date())
        return cal.date(byAdding: .hour, value: 12, to: cal.date(byAdding: .day, value: n, to: today)!)!
    }
    private func ymd(_ d: Date) -> DateComponents { cal.dateComponents([.year, .month, .day], from: d) }
    private func stamp(_ d: Date, _ h: Int, _ m: Int = 0) -> String {
        let c = ymd(d)
        return String(format: "%04d-%02d-%02dT%02d:%02d:00", c.year!, c.month!, c.day!, h, m)
    }
    private func metadataAt(_ d: Date, note: String) -> CaptureMetadata {
        var m = fixtureMetadata(zone: cal.timeZone.identifier, userNote: note)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = cal.timeZone
        m.localDatetime = f.string(from: d)
        m.utcOffsetSeconds = cal.timeZone.secondsFromGMT(for: d)
        return m
    }
    private func dateValue(_ note: String, capturedAt d: Date) async throws -> String {
        let out = try await DataDetectionEnricher().run(fixtureInput(metadataAt(d, note: note)))
        return try #require(try detections(out).first { $0.type == "date" }?.value)
    }

    @Test func tomorrowResolvesAgainstCapture() async throws {
        let cap = noon(daysFromToday: -6)
        let v = try await dateValue("tomorrow at 3pm", capturedAt: cap)
        #expect(v == stamp(cal.date(byAdding: .day, value: 1, to: cap)!, 15))
    }

    @Test func tonightResolvesAgainstCapture() async throws {
        let cap = noon(daysFromToday: -6)
        #expect(try await dateValue("tonight at 7pm", capturedAt: cap) == stamp(cap, 19))
    }

    @Test func weekdayResolvesAgainstCapture() async throws {
        let cap = noon(daysFromToday: -6)
        #expect(try await dateValue("Friday", capturedAt: cap) == expectedWeekday("%@", 6, capturedOn: cap))
    }

    @Test func monthDayWithoutYearUsesCaptureYear() throws {
        let year = cal.component(.year, from: Date())
        let anchor = DateAnchor(day: DateComponents(year: year - 1, month: 12, day: 30))
        let items = DataDetectionEnricher.detect(in: "Jan 3", source: "s", anchor: anchor)
        #expect(items.first?.value == "\(year)-01-03T12:00:00")
    }

    @Test func fullDateUnchanged() async throws {
        let v = try await dateValue("12 Nov 2027", capturedAt: noon(daysFromToday: -6))
        #expect(v == "2027-11-12T12:00:00")
    }

    @Test func sameDayUnchanged() async throws {
        let cap = noon(daysFromToday: 0)
        let plain = DataDetectionEnricher.detect(in: "tomorrow at 3pm", source: "s", anchor: nil)
        #expect(try await dateValue("tomorrow at 3pm", capturedAt: cap) == plain.first?.value)
    }

    @Test func tomorrowNearMidnightUsesCaptureZone() async throws {
        let la = TimeZone(identifier: "America/Los_Angeles")!
        var lac = Calendar(identifier: .gregorian); lac.timeZone = la
        let day = lac.date(byAdding: .day, value: -3, to: Date())!
        let c = lac.dateComponents([.year, .month, .day], from: day)
        var m = fixtureMetadata(zone: "America/Los_Angeles", userNote: "tomorrow at 9am")
        let off = la.secondsFromGMT(for: day)
        m.localDatetime = String(format: "%04d-%02d-%02dT23:30:00%@%02d:%02d", c.year!, c.month!, c.day!,
                                 off < 0 ? "-" : "+", abs(off) / 3600, abs(off) % 3600 / 60)
        m.utcOffsetSeconds = off
        let out = try await DataDetectionEnricher().run(fixtureInput(m))
        let v = try #require(try detections(out).first { $0.type == "date" }?.value)
        let next = lac.date(byAdding: .day, value: 1, to: lac.date(from: c)!)!
        let n = lac.dateComponents([.year, .month, .day], from: next)
        #expect(v == String(format: "%04d-%02d-%02dT09:00:00", n.year!, n.month!, n.day!))
    }

    @Test func bareAtTwoStillNotDetected() {
        let a = DateAnchor(day: ymd(noon(daysFromToday: -6)))
        #expect(DataDetectionEnricher.detect(in: "at 2", source: "s", anchor: a).filter { $0.type == "date" }.isEmpty)
    }

    private func recentNoon(weekday: Int) -> Date {
        var d = noon(daysFromToday: -13)
        while cal.component(.weekday, from: d) != weekday { d = cal.date(byAdding: .day, value: 1, to: d)! }
        return d
    }

    private static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    /// What NSDataDetector itself gives for `template` (with `%@` for the weekday name) when run on the
    /// capture day: probed on today, with the weekday that is as far ahead of today as `weekday` (1 = Sunday)
    /// is of the capture day. No run weekday is hard-coded, so this holds whatever day the suite runs.
    private func expectedWeekday(_ template: String, _ weekday: Int, capturedOn cap: Date) -> String? {
        let today = cal.startOfDay(for: Date())
        let distance = (weekday - cal.component(.weekday, from: cap) + 7) % 7
        let probeDay = cal.date(byAdding: .day, value: distance, to: today)!
        let probe = template.replacingOccurrences(
            of: "%@", with: Self.weekdayNames[cal.component(.weekday, from: probeDay) - 1])
        guard let raw = DataDetectionEnricher.detect(in: probe, source: "s", anchor: nil)
                .first(where: { $0.type == "date" })?.value,
              let found = Self.floating.date(from: raw) else { return nil }
        let days = cal.dateComponents([.day], from: today, to: cal.startOfDay(for: found)).day!
        let time = cal.dateComponents([.hour, .minute, .second], from: found)
        var c = ymd(cal.date(byAdding: .day, value: days, to: cal.startOfDay(for: cap))!)
        c.hour = time.hour; c.minute = time.minute; c.second = time.second
        return Self.floating.string(from: cal.date(from: c)!)
    }

    private static let floating: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    private func actualWeekday(_ template: String, _ weekday: Int, capturedOn cap: Date) -> String? {
        let text = template.replacingOccurrences(of: "%@", with: Self.weekdayNames[weekday - 1])
        return DataDetectionEnricher.detect(in: text, source: "s", anchor: DateAnchor(day: ymd(cap)))
            .first { $0.type == "date" }?.value
    }

    // M1: the detector reads a weekday equal to today's as a week later; a backfill must do the same.
    @Test func sameWeekdayFollowsDetector() async throws {
        let sunday = recentNoon(weekday: 1)
        let expected = try #require(expectedWeekday("%@ brunch", 1, capturedOn: sunday))
        #expect(try await dateValue("Sunday brunch", capturedAt: sunday) == expected)
    }

    // M1: the match includes the leading word ("lunch next Monday"), and "next" is the detector's own rule.
    @Test func nextWeekdayWithLeadingWordFollowsDetector() async throws {
        let sunday = recentNoon(weekday: 1)
        let expected = try #require(expectedWeekday("lunch next %@", 2, capturedOn: sunday))
        #expect(try await dateValue("lunch next Monday", capturedAt: sunday) == expected)
    }

    // M1: "last Friday" stays in the past of the capture day, as the detector would have read it then.
    @Test func lastWeekdayFollowsDetector() async throws {
        let sunday = recentNoon(weekday: 1)
        let expected = try #require(expectedWeekday("I saw him last %@", 6, capturedOn: sunday))
        let v = try await dateValue("I saw him last Friday", capturedAt: sunday)
        #expect(v == expected)
        #expect(v < Self.floating.string(from: cal.startOfDay(for: sunday)))
    }

    @Test func nextWeekdayOnCaptureWeekday() async throws {
        let cap = recentNoon(weekday: 6)  // a Friday
        #expect(try await dateValue("next Friday", capturedAt: cap) == expectedWeekday("next %@", 6, capturedOn: cap))
        #expect(try await dateValue("Friday", capturedAt: cap) == expectedWeekday("%@", 6, capturedOn: cap))
    }

    @Test func nextWeekdayOtherwise() async throws {
        let cap = recentNoon(weekday: 2)  // a Monday
        #expect(try await dateValue("next Friday", capturedAt: cap) == expectedWeekday("next %@", 6, capturedOn: cap))
    }

    // M1: every capture weekday against every named weekday, so distances other than today's are covered
    // on any run day (the detector's week offset depends on the distance: "next" adds a week only when
    // the named day is near).
    @Test(arguments: ["%@ brunch", "lunch next %@", "I saw him last %@", "dinner on %@ at 7pm"])
    func everyWeekdayFollowsDetector(template: String) {
        for capWeekday in 1...7 {
            let cap = recentNoon(weekday: capWeekday)
            for named in 1...7 {
                let expected = expectedWeekday(template, named, capturedOn: cap)
                #expect(expected != nil)
                #expect(actualWeekday(template, named, capturedOn: cap) == expected,
                        "\(template) · \(Self.weekdayNames[named - 1]) captured on \(Self.weekdayNames[capWeekday - 1])")
            }
        }
    }

    // "Weds" is read as Wednesday by the detector but is not a prefix of "wednesday"; it must still re-anchor as a weekday.
    @Test func wedsAbbreviationFollowsDetector() {
        for capWeekday in 1...7 {
            let cap = recentNoon(weekday: capWeekday)
            let expected = expectedWeekday("dinner %@ at 7", 4, capturedOn: cap)
            #expect(expected != nil)
            let actual = DataDetectionEnricher.detect(in: "dinner Weds at 7", source: "s", anchor: DateAnchor(day: ymd(cap)))
                .first { $0.type == "date" }?.value
            #expect(actual == expected, "Weds captured on \(Self.weekdayNames[capWeekday - 1])")
        }
    }

    @Test func versionIsThree() { #expect(DataDetectionEnricher().version == 3) }
}
