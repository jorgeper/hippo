import Foundation
import Testing
import CaptureCore
import HippoTestSupport
@testable import Enrichment

private typealias Label = SoundClassificationEnricher.Label

private func audio(_ id: String) -> CaptureCore.Attachment {
    CaptureCore.Attachment(attachmentID: id, relativePath: "content/\(id).m4a", uti: "com.apple.m4a-audio", byteCount: 1,
                           sha256: "x", representationSource: "item_provider_file")
}

private func image(_ id: String) -> CaptureCore.Attachment {
    CaptureCore.Attachment(attachmentID: id, relativePath: "content/\(id).png", uti: "public.png", byteCount: 1, sha256: "x",
                           representationSource: "item_provider_file")
}

private func comment(_ id: String, text: String? = nil, audio hasAudio: Bool = false) -> CaptureComment {
    CaptureComment(captureID: "c1", commentID: id, addedAt: Date(timeIntervalSince1970: 0),
                   localDatetime: "1970-01-01T00:00:00", timezoneIdentifier: "UTC", utcOffsetSeconds: 0,
                   producer: Producer(appVersion: "1", build: "1", osVersion: "t"), text: text,
                   audio: hasAudio ? CommentAudio(relativePath: "comments/\(id).m4a", uti: "com.apple.m4a-audio",
                                                  mimeType: "audio/mp4", byteCount: 1, sha256: "x", media: nil) : nil)
}

/// A package directory with an (empty) file for each relative path; fakes never read them.
private func package(_ paths: [String]) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sound-\(UUID().uuidString)")
    for p in paths {
        let url = dir.appendingPathComponent(p)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }
    return dir
}

private func decode(_ out: EnricherOutput) throws -> SoundClassificationData {
    try JSONDecoder().decode(SoundClassificationData.self, from: JSONEncoder().encode(try #require(out.data)))
}

private func run(_ attachments: [CaptureCore.Attachment] = [], comments: [CaptureComment] = [], files: [String],
                 classify: @escaping SoundClassificationEnricher.Classifier) async throws -> EnricherOutput {
    let dir = try package(files)
    defer { try? FileManager.default.removeItem(at: dir) }
    let m = fixtureMetadata(attachments: attachments)
    let input = EnricherInput(captureID: m.captureID, metadata: m, packageURL: dir, noteBody: nil, current: nil, comments: comments)
    return try await SoundClassificationEnricher(classify: classify).run(input)
}

private struct Boom: Error {}

@Suite struct SoundClassificationEnricherTests {
    @Test func descriptor() {
        let e = SoundClassificationEnricher(classify: { _ in [] })
        #expect(e.kind == .soundClassification)
        #expect(e.version == 1)
        #expect(!e.usesNetwork)
        #expect(e.inputs.isEmpty)
        #expect(e.readsAttachmentBytes)
        #expect(e.readsCommentAudio)
        #expect(SoundClassificationEnricher.minimumConfidence == 0.3)
        #expect(SoundClassificationEnricher.maxLabels == 8)
        #expect(e.applies(to: fixtureMetadata(attachments: [audio("a")])))
        #expect(!e.applies(to: fixtureMetadata(attachments: [image("a")])))
        #expect(!e.applies(to: fixtureMetadata()))
        #expect(e.applies(to: fixtureMetadata(), comments: [comment("k", audio: true)]))
        #expect(!e.applies(to: fixtureMetadata(), comments: [comment("k", text: "hi")]))
    }

    @Test func filtersSortsAndCaps() async throws {
        // 0.05 ... 0.95 in a shuffled order.
        let labels = (0..<12).map { Label(label: "l\($0)", confidence: 0.95 - Double($0) * 0.0818181818) }.reversed()
        let out = try await run([audio("A")], files: ["content/A.m4a"]) { _ in Array(labels) }
        #expect(out.status == .ok)
        #expect(out.provenance == "sound_analysis")
        let got = try decode(out).items
        #expect(got.map(\.attachmentID) == ["A"])
        #expect(got[0].labels.map(\.label) == ["l0", "l1", "l2", "l3", "l4", "l5", "l6", "l7"])
        #expect(got[0].labels.allSatisfy { $0.confidence >= 0.3 })
    }

    @Test func thresholdIsInclusiveAndCapsAtEight() async throws {
        let out = try await run([audio("A")], files: ["content/A.m4a"]) { _ in
            [Label(label: "edge", confidence: 0.3), Label(label: "below", confidence: 0.29)]
        }
        #expect(try decode(out).items[0].labels == [.init(label: "edge", confidence: 0.3)])

        let many = (0..<12).map { Label(label: "l\($0)", confidence: 0.9) }
        let out2 = try await run([audio("A")], files: ["content/A.m4a"]) { _ in many }
        #expect(try decode(out2).items[0].labels.count == 8)
    }

    @Test func commentAudioUsesCommentID() async throws {
        let out = try await run(comments: [comment("K1", audio: true), comment("K2", text: "words")],
                                files: ["comments/K1.m4a"]) { url in
            #expect(url.lastPathComponent == "K1.m4a")
            return [Label(label: "speech", confidence: 0.8)]
        }
        #expect(try decode(out).items.map(\.attachmentID) == ["K1"])
    }

    @Test func absentAttachmentFileIsSkipped() async throws {
        let out = try await run([audio("A")], comments: [comment("K1", audio: true)], files: ["comments/K1.m4a"]) { _ in
            [Label(label: "speech", confidence: 0.8)]
        }
        #expect(try decode(out).items.map(\.attachmentID) == ["K1"])
    }

    @Test func nothingAboveThresholdIsEmpty() async throws {
        let out = try await run([audio("A")], files: ["content/A.m4a"]) { _ in [Label(label: "x", confidence: 0.2)] }
        #expect(out.status == .empty)
        #expect(out.data == nil)
        #expect(out.provenance == "sound_analysis")
    }

    @Test func oneThrowingFileDoesNotBlockTheOther() async throws {
        let out = try await run([audio("A"), audio("B")], files: ["content/A.m4a", "content/B.m4a"]) { url in
            if url.lastPathComponent == "A.m4a" { throw Boom() }
            return [Label(label: "music", confidence: 0.7)]
        }
        #expect(out.status == .ok)
        #expect(try decode(out).items.map(\.attachmentID) == ["B"])
    }

    @Test func allThrowingIsTransient() async throws {
        await #expect(throws: EnrichmentError.transient(code: "sound_analysis_failed")) {
            _ = try await run([audio("A"), audio("B")], files: ["content/A.m4a", "content/B.m4a"]) { _ in throw Boom() }
        }
    }

    @Test func liveClassifierAcceptsRecordedM4A() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hippo-snd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.m4a")
        try MediaMaker.writeAudio(to: url)
        let labels = try await SoundClassificationEnricher.liveClassifier(url)
        #expect(labels.allSatisfy { (0...1).contains($0.confidence) })
    }
}
