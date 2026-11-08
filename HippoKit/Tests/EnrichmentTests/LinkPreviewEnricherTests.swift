import Foundation
import Synchronization
import Testing
import ImageIO
import CaptureCore
import HippoTestSupport
@testable import Enrichment

private final class FakeHTTP: HTTPFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [URL] = []
    var handler: @Sendable (URL) throws -> Data
    init(_ handler: @escaping @Sendable (URL) throws -> Data) { self.handler = handler }
    var urls: [URL] { lock.withLock { _urls } }
    func get(_ url: URL, timeout: TimeInterval, maxBytes: Int) async throws -> Data {
        lock.withLock { _urls.append(url) }
        return try handler(url)
    }
}

private final class FakeMetadata: LinkMetadataFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [URL] = []
    var handler: @Sendable (URL) throws -> LinkMetadata
    init(_ handler: @escaping @Sendable (URL) throws -> LinkMetadata = { _ in LinkMetadata() }) { self.handler = handler }
    var urls: [URL] { lock.withLock { _urls } }
    func metadata(for url: URL, timeout: TimeInterval) async throws -> LinkMetadata {
        lock.withLock { _urls.append(url) }
        return try handler(url)
    }
}

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("hippo-link-\(UUID().uuidString)")
}

private func decode(_ out: EnricherOutput) throws -> LinkPreviewData {
    try JSONDecoder().decode(LinkPreviewData.self, from: JSONEncoder().encode(try #require(out.data)))
}

private func longestSide(_ url: URL) -> Int {
    guard let s = CGImageSourceCreateWithURL(url as CFURL, nil),
          let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any],
          let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return -1 }
    return max(w, h)
}

@Suite struct LinkPreviewEnricherTests {
    @Test(arguments: [
        ("https://www.youtube.com/watch?v=abc", "youtube"),
        ("https://youtu.be/abc", "youtube"),
        ("https://www.youtube.com/shorts/abc", "youtube"),
        ("https://example.com/a", "fetch"),
        ("ftp://x", "scheme"),
        ("http://192.168.1.4/", "private_host"),
        ("https://8.8.8.8/", "private_host"),
        ("http://[fe80::1]/", "private_host"),
        ("http://printer.local/", "private_host"),
        ("http://localhost:8080/", "private_host"),
        ("https://x.com/unsubscribe?u=1", "single_use"),
        ("https://x.com/a?token=abc", "single_use"),
        ("https://x.com/a?Sig=1", "single_use"),
        ("https://x.com/a?code=1", "single_use"),
        ("https://x.com/reset-password", "single_use"),
        ("https://x.com/login/magic", "single_use"),
        ("https://x.com/Verify/me", "single_use"),
        ("https://x.com/codes/list", "fetch"),
        ("https://x.com/a?keyword=1", "fetch"),
        ("http://2130706433/", "private_host"),
        ("http://127.1/", "private_host"),
        ("http://0x7f.1/", "private_host"),
        ("http://LOCALHOST./", "private_host"),
        ("http://localhost./", "private_host"),
        ("http://Printer.LOCAL/", "private_host"),
        ("http://user:pw@localhost/", "private_host"),
        ("HTTPS://EXAMPLE.com/a", "fetch"),
        ("FTP://example.com/a", "scheme"),
        ("https://x.com/a?%74oken=1", "single_use"),
        ("https://x.com/a?TOKEN=1", "single_use"),
        ("https://x.com/%75nsubscribe", "single_use"),
        ("https://x.com/Account/LOGIN", "single_use"),
    ] as [(String, String)])
    func linkPolicyTable(_ urlString: String, _ expected: String) throws {
        let decision = LinkFetchPolicy.decide(try #require(URL(string: urlString)))
        switch decision {
        case .youTube: #expect(expected == "youtube")
        case .fetch: #expect(expected == "fetch")
        case .skip(let reason): #expect(reason == expected)
        }
    }

    @Test func oembedRequestURL() throws {
        let u = YouTubeOEmbed.requestURL(for: try #require(URL(string: "https://youtu.be/abc?t=1")))
        #expect(u.absoluteString.hasPrefix("https://www.youtube.com/oembed?url=https%3A%2F%2Fyoutu.be%2Fabc"))
        #expect(u.absoluteString.hasSuffix("&format=json"))
    }

    @Test func youTubeUsesOEmbed() async throws {
        let jpeg = try MediaMaker.imageData(width: 1600, height: 900)
        let http = FakeHTTP { url in
            if url.host == "i.ytimg.com" { return jpeg }
            return Data(#"{"title":"T","author_name":"C","thumbnail_url":"https://i.ytimg.com/x.jpg"}"#.utf8)
        }
        let meta = FakeMetadata()
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let e = LinkPreviewEnricher(http: http, metadata: meta, tempDirectory: dir)
        let out = try await e.run(fixtureInput(fixtureMetadata(urls: ["https://www.youtube.com/watch?v=abc"])))
        #expect(out.status == .ok)
        #expect(out.provenance == "oembed")
        let item = try #require(try decode(out).items.first)
        #expect(item.title == "T"); #expect(item.channel == "C"); #expect(item.siteName == "YouTube")
        let thumb = try #require(item.thumbnail)
        #expect(thumb.relativePath == "assets/\(thumb.sha256).jpg")
        let file = try #require(out.newAssets[thumb.relativePath])
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(longestSide(file) <= 640)
        #expect(thumb.byteCount == Int64(try Data(contentsOf: file).count))
        #expect(meta.urls.isEmpty)
    }

    @Test func genericUsesLinkPresentation() async throws {
        let jpeg = try MediaMaker.imageData(width: 800, height: 800)
        let meta = FakeMetadata { _ in LinkMetadata(title: "Hello", siteName: nil, summary: "S", imageData: jpeg) }
        let http = FakeHTTP { _ in throw EnrichmentError.permanent(code: "x") }
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let e = LinkPreviewEnricher(http: http, metadata: meta, tempDirectory: dir)
        let out = try await e.run(fixtureInput(fixtureMetadata(urls: ["https://www.example.com/a"])))
        #expect(out.provenance == "link_presentation")
        let item = try #require(try decode(out).items.first)
        #expect(item.title == "Hello"); #expect(item.siteName == "example.com"); #expect(item.summary == "S")
        #expect(item.thumbnail != nil)
        #expect(out.newAssets.count == 1)
        #expect(http.urls.isEmpty)
    }

    @Test func onlyFirstFiveURLs() async throws {
        let meta = FakeMetadata { _ in LinkMetadata(title: "t") }
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let e = LinkPreviewEnricher(http: FakeHTTP { _ in Data() }, metadata: meta, tempDirectory: dir)
        let urls = (1...7).map { "https://example.com/\($0)" }
        let out = try await e.run(fixtureInput(fixtureMetadata(urls: urls)))
        #expect(meta.urls.count == 5)
        #expect(try decode(out).items.count == 5)
    }

    @Test func allOfflineRethrowsDeferred() async throws {
        let meta = FakeMetadata { _ in throw EnrichmentError.deferred(code: "offline", retryAfter: 60) }
        let dir = tempDir()
        let e = LinkPreviewEnricher(http: FakeHTTP { _ in Data() }, metadata: meta, tempDirectory: dir)
        await #expect(throws: EnrichmentError.deferred(code: "offline", retryAfter: 60)) {
            _ = try await e.run(fixtureInput(fixtureMetadata(urls: ["https://a.com/1", "https://b.com/2"])))
        }
    }

    @Test func allFailedRethrowsFirstError() async throws {
        let meta = FakeMetadata { u in
            throw u.host == "a.com" ? EnrichmentError.transient(code: "timeout") : EnrichmentError.permanent(code: "http_4xx")
        }
        let e = LinkPreviewEnricher(http: FakeHTTP { _ in Data() }, metadata: meta, tempDirectory: tempDir())
        await #expect(throws: EnrichmentError.transient(code: "timeout")) {
            _ = try await e.run(fixtureInput(fixtureMetadata(urls: ["https://a.com/1", "https://b.com/2"])))
        }
    }

    @Test func partialFailureKeepsSuccesses() async throws {
        let meta = FakeMetadata { u in
            if u.host == "a.com" { throw EnrichmentError.transient(code: "timeout") }
            return LinkMetadata(title: "ok")
        }
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let e = LinkPreviewEnricher(http: FakeHTTP { _ in Data() }, metadata: meta, tempDirectory: dir)
        let out = try await e.run(fixtureInput(fixtureMetadata(urls: ["https://a.com/1", "https://b.com/2"])))
        #expect(out.status == .ok)
        let items = try decode(out).items
        #expect(items.count == 1); #expect(items[0].title == "ok")
    }

    @Test func allSkippedIsEmpty() async throws {
        let meta = FakeMetadata()
        let e = LinkPreviewEnricher(http: FakeHTTP { _ in Data() }, metadata: meta, tempDirectory: tempDir())
        let out = try await e.run(fixtureInput(fixtureMetadata(urls: ["ftp://x", "http://localhost/", "https://x.com/a?token=1"])))
        #expect(out.status == .empty)
        #expect(meta.urls.isEmpty)
    }

    @Test func appliesOnlyWithURLs() {
        let e = LinkPreviewEnricher(http: FakeHTTP { _ in Data() }, metadata: FakeMetadata(), tempDirectory: tempDir())
        #expect(!e.applies(to: fixtureMetadata()))
        #expect(e.applies(to: fixtureMetadata(urls: ["https://a.com"])))
    }

    @Test func stagingRemovedWhenLaterURLFails() async throws {
        let jpeg = try MediaMaker.imageData(width: 400, height: 400)
        let meta = FakeMetadata { u in
            if u.host == "b.com" { throw CancellationError() }
            return LinkMetadata(title: "t", imageData: jpeg)
        }
        let dir = tempDir(); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let e = LinkPreviewEnricher(http: FakeHTTP { _ in Data() }, metadata: meta, tempDirectory: dir)
        await #expect(throws: CancellationError.self) {
            _ = try await e.run(fixtureInput(fixtureMetadata(urls: ["https://a.com/1", "https://b.com/2"])))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func stagingKeptOnSuccess() async throws {
        let jpeg = try MediaMaker.imageData(width: 400, height: 400)
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let e = LinkPreviewEnricher(http: FakeHTTP { _ in Data() },
                                    metadata: FakeMetadata { _ in LinkMetadata(title: "t", imageData: jpeg) }, tempDirectory: dir)
        let out = try await e.run(fixtureInput(fixtureMetadata(urls: ["https://a.com/1"])))
        #expect(FileManager.default.fileExists(atPath: try #require(out.newAssets.values.first).path))
    }

    @Test func finalURLSkippedDiscardsPreview() async throws {
        let meta = FakeMetadata { u in
            LinkMetadata(title: "t", finalURL: u.host == "a.com" ? URL(string: "https://a.com/reset?x=1") : u)
        }
        let e = LinkPreviewEnricher(http: FakeHTTP { _ in Data() }, metadata: meta, tempDirectory: tempDir())
        let out = try await e.run(fixtureInput(fixtureMetadata(urls: ["https://a.com/1", "https://b.com/2"])))
        let items = try decode(out).items
        #expect(items.count == 1); #expect(items[0].url == "https://b.com/2")
    }
}
