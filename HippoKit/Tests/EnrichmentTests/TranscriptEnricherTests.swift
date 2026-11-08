import Foundation
import Synchronization
import Testing
import CaptureCore
@testable import Enrichment

private final class FakeTranscriber: Transcribing {
    let calls = Mutex<[(url: URL, locale: String)]>([])
    let result: @Sendable (URL) throws -> (text: String, segments: [TranscriptSegment])
    init(_ result: @escaping @Sendable (URL) throws -> (text: String, segments: [TranscriptSegment])) { self.result = result }
    func transcribe(fileURL: URL, locale: Locale) async throws -> (text: String, segments: [TranscriptSegment]) {
        calls.withLock { $0.append((fileURL, locale.identifier)) }
        return try result(fileURL)
    }
}

private func audio(_ id: String, seconds: Double? = 10) -> CaptureCore.Attachment {
    CaptureCore.Attachment(attachmentID: id, relativePath: "content/\(id).m4a", uti: "public.mpeg-4-audio", byteCount: 1,
                           sha256: "x", representationSource: "item_provider_file",
                           media: seconds.map { MediaFacts(durationSeconds: $0) })
}

@Suite struct TranscriptEnricherTests {
    @Test func localeChoice() {
        #expect(TranscriptLocale.choose(current: Locale(identifier: "en_GB")).identifier == "en_GB")
        #expect(TranscriptLocale.choose(current: Locale(identifier: "es_ES")).identifier == "en_US")
        #expect(TranscriptLocale.choose(current: Locale(identifier: "fr")).identifier == "en_US")
    }

    @Test func appliesOnlyToAudio() {
        let e = TranscriptEnricher(transcriber: FakeTranscriber { _ in ("", []) }, locale: Locale(identifier: "en_US"))
        #expect(e.applies(to: fixtureMetadata(attachments: [audio("a1")])))
        let png = CaptureCore.Attachment(attachmentID: "p", relativePath: "content/p.png", uti: "public.png", byteCount: 1,
                                         sha256: "x", representationSource: "item_provider_file")
        #expect(!e.applies(to: fixtureMetadata(attachments: [png])))
    }

    @Test func transcribesEachAudio() async throws {
        let seg = [TranscriptSegment(start: 0, end: 1.5, text: "hello")]
        let fake = FakeTranscriber { url in (url.lastPathComponent, seg) }
        let e = TranscriptEnricher(transcriber: fake, locale: Locale(identifier: "en_GB"))
        let out = try await e.run(fixtureInput(fixtureMetadata(attachments: [audio("a1"), audio("a2")])))
        #expect(out.status == .ok)
        #expect(out.provenance == "speech_analyzer")
        let data = try JSONDecoder().decode(TranscriptData.self, from: JSONEncoder().encode(try #require(out.data)))
        #expect(data.items.map(\.attachmentID) == ["a1", "a2"])
        #expect(data.items[0].segments == seg)
        #expect(data.items[0].locale == "en_GB")
        #expect(fake.calls.withLock { $0.count } == 2)
    }

    @Test func skipsOverAnHour() async throws {
        let fake = FakeTranscriber { _ in ("x", []) }
        let e = TranscriptEnricher(transcriber: fake, locale: Locale(identifier: "en_US"))
        let out = try await e.run(fixtureInput(fixtureMetadata(attachments: [audio("a1", seconds: 3601)])))
        #expect(out.status == .empty)
        #expect(fake.calls.withLock { $0.isEmpty })
    }

    @Test func blankTextGivesNoItem() async throws {
        let e = TranscriptEnricher(transcriber: FakeTranscriber { _ in ("  \n ", []) }, locale: Locale(identifier: "en_US"))
        let out = try await e.run(fixtureInput(fixtureMetadata(attachments: [audio("a1")])))
        #expect(out.status == .empty)
    }

    @Test func modelMissingIsDeferred() async throws {
        let err = EnrichmentError.deferred(code: "model_missing", retryAfter: 900)
        let e = TranscriptEnricher(transcriber: FakeTranscriber { _ in throw err }, locale: Locale(identifier: "en_US"))
        await #expect(throws: err) {
            _ = try await e.run(fixtureInput(fixtureMetadata(attachments: [audio("a1")])))
        }
    }
}
