import Foundation
import Testing
import CaptureCore
@testable import Enrichment

private func decode(_ out: EnricherOutput) throws -> LanguageData {
    try JSONDecoder().decode(LanguageData.self, from: JSONEncoder().encode(try #require(out.data)))
}

private let twenty = String(repeating: "a", count: 20)
private let nineteen = String(repeating: "a", count: 19)

@Suite struct LanguageEnricherTests {
    @Test func descriptor() {
        let e = LanguageEnricher(recognize: { _ in nil })
        #expect(e.kind == .language)
        #expect(e.version == 1)
        #expect(!e.usesNetwork)
        #expect(e.inputs.isEmpty)
        #expect(!e.readsAttachmentBytes)
        #expect(!e.readsCommentAudio)
        #expect(LanguageEnricher.minimumLength == 20)
    }

    @Test func sourcesInOrder() async throws {
        let m = fixtureMetadata(method: .typedNote, userNote: "note note note note note note",
                                sharedText: "shared shared shared shared")
        let e = LanguageEnricher(recognize: { _ in ("en", 0.9) })
        #expect(e.applies(to: m))
        let out = try await e.run(fixtureInput(m, noteBody: "body body body body body body"))
        #expect(out.status == .ok)
        #expect(out.provenance == "natural_language")
        #expect(try decode(out).items.map(\.source) == ["user_note", "shared_text", "note_body"])
        #expect(try decode(out).items.allSatisfy { $0.language == "en" && $0.confidence == 0.9 })
    }

    @Test func shortTextSkipped() async throws {
        let e = LanguageEnricher(recognize: { _ in ("en", 0.5) })
        let m = fixtureMetadata(userNote: "  \n" + nineteen + " \n", sharedText: " " + twenty + "\n")
        let out = try await e.run(fixtureInput(m))
        #expect(try decode(out).items.map(\.source) == ["shared_text"])

        // Counted in Characters, not UTF-16 units: ten flags are 10 Characters.
        let flags = String(repeating: "\u{1F1EA}\u{1F1F8}", count: 10)
        await #expect(throws: EnrichmentError.notApplicable(code: "text_too_short")) {
            _ = try await e.run(fixtureInput(fixtureMetadata(userNote: flags)))
        }
    }

    @Test func allSkippedIsNotApplicable() async throws {
        let e = LanguageEnricher(recognize: { _ in ("en", 0.5) })
        let m = fixtureMetadata(userNote: nineteen, sharedText: "   ")
        #expect(!e.applies(to: m))
        #expect(!e.applies(to: fixtureMetadata()))
        await #expect(throws: EnrichmentError.self) { _ = try await e.run(fixtureInput(m)) }
    }

    @Test func shortNoteBodyIsNotApplicable() async throws {
        let e = LanguageEnricher(recognize: { _ in ("en", 0.5) })
        await #expect(throws: EnrichmentError.notApplicable(code: "text_too_short")) {
            _ = try await e.run(fixtureInput(fixtureMetadata(method: .typedNote), noteBody: nineteen))
        }
    }

    @Test func unrecognizedIsEmpty() async throws {
        let e = LanguageEnricher(recognize: { _ in nil })
        let out = try await e.run(fixtureInput(fixtureMetadata(userNote: twenty, sharedText: twenty)))
        #expect(out.status == .empty)
        #expect(out.data == nil)
        #expect(out.provenance == "natural_language")
    }

    @Test func undeterminedResultIsDropped() async throws {
        let only = LanguageEnricher(recognize: { _ in ("und", 0.9) })
        let out = try await only.run(fixtureInput(fixtureMetadata(userNote: twenty)))
        #expect(out.status == .empty)

        let mixed = LanguageEnricher(recognize: { $0 == twenty ? ("und", 0.9) : ("en", 0.8) })
        let m = fixtureMetadata(userNote: twenty, sharedText: twenty + "b")
        #expect(try decode(try await mixed.run(fixtureInput(m))).items.map(\.source) == ["shared_text"])

        let blank = LanguageEnricher(recognize: { _ in ("", 0.9) })
        #expect(try await blank.run(fixtureInput(fixtureMetadata(userNote: twenty))).status == .empty)
    }

    @Test func liveRecognizerReturnsNilWhenUndetermined() {
        let r = LanguageEnricher.liveRecognizer("1234567890 1234567890 !!!")
        #expect(r == nil || (r?.language != "und" && r?.language.isEmpty == false))
    }

    @Test func recognizerSeesTrimmedText() async throws {
        let seen = Seen()
        let e = LanguageEnricher(recognize: { seen.add($0); return ("en", 1) })
        _ = try await e.run(fixtureInput(fixtureMetadata(userNote: "  " + twenty + "\n")))
        #expect(seen.values == [twenty])
    }

    @Test func liveRecognizerKnowsSpanishAndEnglish() throws {
        let es = try #require(LanguageEnricher.liveRecognizer("Mañana tengo que comprar pan y leche en el mercado."))
        #expect(es.language == "es")
        #expect((0...1).contains(es.confidence))
        let en = try #require(LanguageEnricher.liveRecognizer("Tomorrow I need to buy bread and milk at the market."))
        #expect(en.language == "en")
        #expect((0...1).contains(en.confidence))
    }
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return items }
}
