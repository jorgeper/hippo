import Foundation
import Testing
import CaptureCore
import Enrichment

@Suite struct SourceAppGuessEnricherTests {
    private func obs(types: [[String]] = [], names: [String?] = []) -> [MetadataObservation] {
        [MetadataObservation(key: "share.registered_type_identifiers",
                             value: .array(types.map { .array($0.map { .string($0) }) }), provenance: "p"),
         MetadataObservation(key: "share.suggested_names",
                             value: .array(names.map { $0.map { .string($0) } ?? .null }), provenance: "p")]
    }

    private func attachment(_ name: String) -> CaptureCore.Attachment {
        CaptureCore.Attachment(attachmentID: "a1", relativePath: "content/a1.bin", originalFilename: name, uti: "public.jpeg",
                   byteCount: 1, sha256: "x", representationSource: "item_provider_file")
    }

    struct Case: Sendable, CustomTestStringConvertible {
        var label: String
        var app: String?
        var reason: String?
        var testDescription: String { label }
    }

    @Test(arguments: [
        ("whatsapp uti", Case(label: "whatsapp uti", app: "WhatsApp", reason: "uti:net.whatsapp")),
        ("whatsapp filename", Case(label: "whatsapp filename", app: "WhatsApp", reason: "filename:whatsapp")),
        ("messages sms", Case(label: "messages sms", app: "Messages", reason: "uti:messages")),
        ("messages new", Case(label: "messages new", app: "Messages", reason: "uti:messages")),
        ("youtube", Case(label: "youtube", app: "YouTube", reason: "host:youtube")),
        ("youtu.be", Case(label: "youtu.be", app: "YouTube", reason: "host:youtube")),
        ("safari", Case(label: "safari", app: "Safari", reason: "uti:safari")),
        ("photos", Case(label: "photos", app: "Photos", reason: "filename:img")),
        ("none", Case(label: "none", app: nil, reason: nil)),
    ])
    func sourceAppGuessTable(_ name: String, _ expected: Case) async throws {
        let m: CaptureMetadata
        switch name {
        case "whatsapp uti": m = fixtureMetadata(observations: obs(types: [["public.jpeg", "net.whatsapp.image"]]))
        case "whatsapp filename": m = fixtureMetadata(attachments: [attachment("WhatsApp Image 2026-11-07.jpeg")])
        case "messages sms": m = fixtureMetadata(observations: obs(types: [["com.apple.MobileSMS.thing"]]))
        case "messages new": m = fixtureMetadata(observations: obs(types: [["com.apple.messages.x"]]))
        case "youtube": m = fixtureMetadata(urls: ["https://www.youtube.com/watch?v=1"])
        case "youtu.be": m = fixtureMetadata(urls: ["https://m.youtu.be/abc"])
        case "safari": m = fixtureMetadata(observations: obs(types: [["com.apple.mobilesafari.tab"]]))
        case "photos": m = fixtureMetadata(observations: obs(names: [nil, "IMG_0042"]))
        default: m = fixtureMetadata(urls: ["https://example.com"], observations: obs(types: [["public.url"]], names: [nil]))
        }
        let out = try await SourceAppGuessEnricher().run(fixtureInput(m))
        #expect(out.provenance == "heuristic")
        if let app = expected.app {
            #expect(out.status == .ok)
            let guess = try JSONDecoder().decode(SourceAppGuessData.self, from: JSONEncoder().encode(try #require(out.data)))
            #expect(guess == SourceAppGuessData(app: app, reason: try #require(expected.reason)))
        } else {
            #expect(out.status == .empty)
            #expect(out.data == nil)
        }
    }

    @Test func firstMatchingRuleWins() async throws {
        // WhatsApp's type identifier outranks a YouTube link.
        let m = fixtureMetadata(urls: ["https://youtube.com/x"], observations: obs(types: [["net.whatsapp.url"]]))
        let out = try await SourceAppGuessEnricher().run(fixtureInput(m))
        let guess = try JSONDecoder().decode(SourceAppGuessData.self, from: JSONEncoder().encode(try #require(out.data)))
        #expect(guess.app == "WhatsApp")
    }

    @Test func appliesOnlyToShares() {
        let e = SourceAppGuessEnricher()
        #expect(e.applies(to: fixtureMetadata(method: .shareExtension)))
        #expect(!e.applies(to: fixtureMetadata(method: .typedNote)))
        #expect(e.kind == .sourceAppGuess && e.version == 1 && !e.usesNetwork)
    }
}
