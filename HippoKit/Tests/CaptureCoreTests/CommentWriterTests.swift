import Testing
import Foundation
@testable import CaptureCore
import HippoTestSupport

private struct FakeSpace: SpaceChecking {
    let bytes: Int64
    func availableBytes(at url: URL) throws -> Int64 { bytes }
}

@Suite struct CommentWriterTests {
    private let root: URL
    private let layout: StoreLayout
    private let producer = Producer(appVersion: "0.1.0", build: "1", osVersion: "test")
    private let la = TimeZone(identifier: "America/Los_Angeles")!
    // 2026-11-07T17:00:00Z = 09:00 local in Los Angeles.
    private let now = Date(timeIntervalSince1970: 1_794_070_800)

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hippo-comments-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        layout = StoreLayout(root: root)
    }

    private func commit() async throws -> CommittedPackage {
        let draft = CaptureDraft(captureID: UUID(), startedAt: now, timeZone: la, method: .typedNote, userNote: "a capture")
        return try await PackageWriter(layout: layout, producer: producer).commit(draft)
    }

    private func writer(space: Int64 = 1 << 40) -> CommentWriter {
        CommentWriter(layout: layout, producer: producer, space: FakeSpace(bytes: space))
    }

    private func entries(in dir: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    }

    private func audioSource() throws -> URL {
        let url = root.appendingPathComponent("source-\(UUID().uuidString).m4a")
        try MediaMaker.writeAudio(to: url)
        return url
    }

    private func audioDraft(_ url: URL) -> CommentDraft {
        .audio(fileURL: url, uti: "com.apple.m4a-audio", mimeType: "audio/mp4", durationSeconds: 1.5)
    }

    @Test func textCommentRoundTrips() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try await commit()
        let comment = try writer().add(.text("  hello  "), to: package, now: now, timeZone: la)

        let json = package.directoryURL.appendingPathComponent("comments/\(comment.commentID).json")
        #expect(FileManager.default.fileExists(atPath: json.path))
        let decoded = try HippoJSON.decodeComment(Data(contentsOf: json))
        #expect(decoded.text == "hello")
        #expect(decoded.audio == nil)
        #expect(decoded.captureID == package.metadata.captureID)
        #expect(decoded.localDatetime.hasSuffix("-08:00"))
        #expect(decoded == comment)
        let listing = PackageComments.load(directory: package.directoryURL)
        #expect(listing.comments == [comment])
        #expect(listing.pendingCount == 0)
    }

    @Test func audioCommentWritesAudioThenJson() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try await commit()
        let source = try audioSource()
        let before = try Data(contentsOf: source)
        let comment = try writer().add(audioDraft(source), to: package, now: now, timeZone: la)

        let id = comment.commentID
        let copy = package.directoryURL.appendingPathComponent("comments/\(id).m4a")
        #expect(try Data(contentsOf: copy) == before)
        let audio = try #require(comment.audio)
        let digest = try StreamingHasher.digest(of: copy)
        #expect(audio.byteCount == digest.byteCount)
        #expect(audio.sha256 == digest.sha256)
        #expect(audio.media?.durationSeconds == 1.5)
        #expect(comment.filePaths == ["comments/\(id).m4a", "comments/\(id).json"])
        #expect(try Data(contentsOf: source) == before)
        #expect(PackageComments.load(directory: package.directoryURL).comments == [comment])
        #expect(entries(in: layout.stagingDir).isEmpty)
    }

    @Test func whitespaceTextIsRejected() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try await commit()
        #expect(throws: CaptureError.emptyCapture) {
            try writer().add(.text("  \n"), to: package, now: now, timeZone: la)
        }
        #expect(!FileManager.default.fileExists(atPath: package.directoryURL.appendingPathComponent("comments").path))
    }

    @Test func failureLeavesNoJson() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try await commit()
        let source = try audioSource()
        do {
            _ = try writer(space: 0).add(audioDraft(source), to: package, now: now, timeZone: la)
            Issue.record("expected insufficientSpace")
        } catch CaptureError.insufficientSpace {
        } catch {
            Issue.record("unexpected error \(error)")
        }
        #expect(entries(in: package.directoryURL.appendingPathComponent("comments")).isEmpty)
        #expect(entries(in: layout.stagingDir).isEmpty)
    }

    @Test func loaderTreatsMissingAudioAsPending() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try await commit()
        let comment = try writer().add(audioDraft(try audioSource()), to: package, now: now, timeZone: la)
        let audio = package.directoryURL.appendingPathComponent(try #require(comment.audio).relativePath)

        try FileManager.default.removeItem(at: audio)
        var listing = PackageComments.load(directory: package.directoryURL)
        #expect(listing.comments == [])
        #expect(listing.pendingCount == 1)

        try Data("other bytes".utf8).write(to: audio)
        listing = PackageComments.load(directory: package.directoryURL)
        #expect(listing.comments == [])
        #expect(listing.pendingCount == 1)
    }

    @Test func loaderIgnoresUnsupportedSchema() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try await commit()
        let comment = try writer().add(.text("hi"), to: package, now: now, timeZone: la)
        let json = package.directoryURL.appendingPathComponent(comment.relativePath)
        var future = comment
        future.schemaVersion = 2
        try HippoJSON.encode(future).write(to: json)
        let listing = PackageComments.load(directory: package.directoryURL)
        #expect(listing.comments == [])
        #expect(listing.pendingCount == 1)
    }

    @Test func loaderOrdersByAddedAt() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try await commit()
        let later = try writer().add(.text("second"), to: package, now: now.addingTimeInterval(1), timeZone: la)
        let earlier = try writer().add(.text("first"), to: package, now: now, timeZone: la)
        #expect(PackageComments.load(directory: package.directoryURL).comments.map(\.commentID)
                == [earlier.commentID, later.commentID])
    }

    @Test func committedPackageLoadIncludesComments() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try await commit()
        guard case .complete(_, let before) = PackageValidator.validate(directory: package.directoryURL) else {
            Issue.record("not complete"); return
        }
        _ = try writer().add(.text("note"), to: package, now: now, timeZone: la)
        let loaded = try #require(CommittedPackage.load(directory: package.directoryURL, layout: layout))
        #expect(loaded.comments.count == 1)
        guard case .complete(_, let after) = PackageValidator.validate(directory: package.directoryURL) else {
            Issue.record("not complete"); return
        }
        #expect(after == before)
    }
}
