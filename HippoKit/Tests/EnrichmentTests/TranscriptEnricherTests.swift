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

/// A temporary package directory holding an (empty) `content/<id>.m4a` for each ID; the fake transcriber
/// never reads it, but the enricher skips an attachment whose file is absent.
private func audioPackage(_ ids: [String]) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("content"), withIntermediateDirectories: true)
    for id in ids { try Data().write(to: dir.appendingPathComponent("content/\(id).m4a")) }
    return dir
}

private func transcriptDoc(_ items: [TranscriptItem], version: Int = 1) throws -> EnrichmentDocument {
    let data = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(TranscriptData(items: items)))
    let facet = Facet(version: version, status: .ok, generatedAt: Date(timeIntervalSince1970: 0),
                      provenance: "speech_analyzer", data: data)
    return EnrichmentDocument(schemaVersion: 1, captureID: "c1", layer: .device, packageDigest: "d",
                              producer: EnrichmentProducer(name: "t", version: "1", build: "1"),
                              generatedAt: Date(timeIntervalSince1970: 0), facets: ["transcript": facet])
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
        let pkg = try audioPackage(["a1", "a2"]); defer { try? FileManager.default.removeItem(at: pkg) }
        let out = try await e.run(fixtureInput(fixtureMetadata(attachments: [audio("a1"), audio("a2")]), packageURL: pkg))
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
        let pkg = try audioPackage(["a1"]); defer { try? FileManager.default.removeItem(at: pkg) }
        let out = try await e.run(fixtureInput(fixtureMetadata(attachments: [audio("a1", seconds: 3601)]), packageURL: pkg))
        #expect(out.status == .empty)
        #expect(fake.calls.withLock { $0.isEmpty })
    }

    @Test func blankTextGivesNoItem() async throws {
        let e = TranscriptEnricher(transcriber: FakeTranscriber { _ in ("  \n ", []) }, locale: Locale(identifier: "en_US"))
        let pkg = try audioPackage(["a1"]); defer { try? FileManager.default.removeItem(at: pkg) }
        let out = try await e.run(fixtureInput(fixtureMetadata(attachments: [audio("a1")]), packageURL: pkg))
        #expect(out.status == .empty)
    }

    @Test func modelMissingIsDeferred() async throws {
        let err = EnrichmentError.deferred(code: "model_missing", retryAfter: 900)
        let e = TranscriptEnricher(transcriber: FakeTranscriber { _ in throw err }, locale: Locale(identifier: "en_US"))
        let pkg = try audioPackage(["a1"]); defer { try? FileManager.default.removeItem(at: pkg) }
        await #expect(throws: err) {
            _ = try await e.run(fixtureInput(fixtureMetadata(attachments: [audio("a1")]), packageURL: pkg))
        }
    }

    @Test func audioCommentIsTranscribedByCommentID() async throws {
        let e = TranscriptEnricher(transcriber: FakeTranscriber { _ in ("spoken", []) }, locale: Locale(identifier: "en_US"))
        let m = fixtureMetadata()
        let c = commentFixture(id: "c1", audio: CommentAudio(relativePath: "comments/c1.m4a", uti: "com.apple.m4a-audio",
                                                              mimeType: "audio/mp4", byteCount: 1, sha256: "x",
                                                              media: MediaFacts(durationSeconds: 5)))
        #expect(e.applies(to: m, comments: [c]))
        var input = fixtureInput(m)
        input.comments = [c]
        let out = try await e.run(input)
        #expect(out.status == .ok)
        let data = try JSONDecoder().decode(TranscriptData.self, from: JSONEncoder().encode(try #require(out.data)))
        #expect(data.items.map(\.attachmentID) == ["c1"])
    }

    @Test func absentAttachmentIsSkippedAndCommentStillTranscribed() async throws {
        let fake = FakeTranscriber { _ in ("spoken", []) }
        let e = TranscriptEnricher(transcriber: fake, locale: Locale(identifier: "en_US"))
        // a1 was trimmed by Save space: its file is gone from the (otherwise empty) package.
        let pkg = try audioPackage([]); defer { try? FileManager.default.removeItem(at: pkg) }
        var input = fixtureInput(fixtureMetadata(attachments: [audio("a1")]), packageURL: pkg)
        input.comments = [commentFixture(id: "c1", audio: commentAudio("c1"))]
        let out = try await e.run(input)
        #expect(out.status == .ok)
        let data = try JSONDecoder().decode(TranscriptData.self, from: JSONEncoder().encode(try #require(out.data)))
        #expect(data.items.map(\.attachmentID) == ["c1"])
        #expect(fake.calls.withLock { $0.map(\.url.lastPathComponent) } == ["c1.m4a"])
    }

    @Test func existingItemsAreReusedNotTranscribedAgain() async throws {
        let fake = FakeTranscriber { _ in ("new words", []) }
        let e = TranscriptEnricher(transcriber: fake, locale: Locale(identifier: "en_US"))
        let a = TranscriptItem(attachmentID: "a1", text: "old words", locale: "en_GB",
                               segments: [TranscriptSegment(start: 0, end: 1, text: "old")])
        let pkg = try audioPackage(["a1"]); defer { try? FileManager.default.removeItem(at: pkg) }
        var input = fixtureInput(fixtureMetadata(attachments: [audio("a1")]), current: try transcriptDoc([a]),
                                 packageURL: pkg)
        input.comments = [commentFixture(id: "c1", audio: commentAudio("c1"))]
        let out = try await e.run(input)
        #expect(out.status == .ok)
        let data = try JSONDecoder().decode(TranscriptData.self, from: JSONEncoder().encode(try #require(out.data)))
        #expect(data.items.map(\.attachmentID) == ["a1", "c1"])
        #expect(data.items[0] == a)
        #expect(data.items[1].text == "new words")
        #expect(fake.calls.withLock { $0.map(\.url.lastPathComponent) } == ["c1.m4a"])

        // A facet from another version is not reused.
        let older = TranscriptEnricher(transcriber: fake, locale: Locale(identifier: "en_US"))
        input.current = try transcriptDoc([a], version: older.version + 1)
        _ = try await older.run(input)
        #expect(fake.calls.withLock { $0.count } == 3)
    }

    @Test func textCommentOnlyIsNotApplicable() {
        let e = TranscriptEnricher(transcriber: FakeTranscriber { _ in ("", []) }, locale: Locale(identifier: "en_US"))
        #expect(!e.applies(to: fixtureMetadata(), comments: [commentFixture(id: "c1", text: "hi")]))
    }
}

private func commentFixture(id: String, text: String? = nil, audio: CommentAudio? = nil) -> CaptureComment {
    CaptureComment(captureID: "cap", commentID: id, addedAt: Date(timeIntervalSince1970: 0),
                   localDatetime: "1970-01-01T00:00:00", timezoneIdentifier: "UTC", utcOffsetSeconds: 0,
                   producer: Producer(appVersion: "1", build: "1", osVersion: "t"), text: text, audio: audio)
}

private func commentAudio(_ id: String) -> CommentAudio {
    CommentAudio(relativePath: "comments/\(id).m4a", uti: "com.apple.m4a-audio", mimeType: "audio/mp4", byteCount: 1,
                 sha256: "x", media: MediaFacts(durationSeconds: 5))
}
