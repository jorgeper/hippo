import Foundation
import Testing
@testable import Enrichment

/// Serves canned responses; one handler per test run, keyed by URL host so suites can run in parallel.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case response(status: Int, headers: [String: String], chunks: [Data])
        case redirect(to: URL)
        case failure(URLError.Code)
    }
    nonisolated(unsafe) static var replies: [String: Reply] = [:]
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let host = request.url?.host ?? ""
        let reply = Self.lock.withLock { Self.replies[host] }
        switch reply {
        case .response(let status, let headers, let chunks):
            let r = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
            for c in chunks { client?.urlProtocol(self, didLoad: c) }
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let to):
            let r = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location": to.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: to), redirectResponse: r)
            // When the delegate refuses the redirect the 302 itself is the answer.
            client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case nil:
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
        }
    }
}

private func fetcher(_ host: String, _ reply: StubProtocol.Reply) -> URLSessionHTTPFetcher {
    StubProtocol.lock.withLock { StubProtocol.replies[host] = reply }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    return URLSessionHTTPFetcher(configuration: config)
}

private func fetch(_ f: URLSessionHTTPFetcher, _ host: String, maxBytes: Int = 1000) async throws -> Data {
    try await f.get(URL(string: "https://\(host)/x")!, timeout: 5, maxBytes: maxBytes)
}

@Suite struct HTTPFetcherTests {
    @Test func okReturnsBody() async throws {
        let f = fetcher("ok.test", .response(status: 200, headers: [:], chunks: [Data("hi".utf8)]))
        #expect(try await fetch(f, "ok.test") == Data("hi".utf8))
    }

    @Test func oversizeChunkedBodyIsPermanent() async throws {
        let chunks = (0..<10).map { _ in Data(repeating: 1, count: 300) }   // no Content-Length
        let f = fetcher("big.test", .response(status: 200, headers: [:], chunks: chunks))
        await #expect(throws: EnrichmentError.permanent(code: "too_large")) { _ = try await fetch(f, "big.test") }
    }

    @Test func oversizeContentLengthIsPermanent() async throws {
        let f = fetcher("big2.test", .response(status: 200, headers: ["Content-Length": "5000"], chunks: [Data(count: 5000)]))
        await #expect(throws: EnrichmentError.permanent(code: "too_large")) { _ = try await fetch(f, "big2.test") }
    }

    @Test func status404IsPermanent() async throws {
        let f = fetcher("nf.test", .response(status: 404, headers: [:], chunks: []))
        await #expect(throws: EnrichmentError.permanent(code: "http_4xx")) { _ = try await fetch(f, "nf.test") }
    }

    @Test func status503IsTransient() async throws {
        let f = fetcher("down.test", .response(status: 503, headers: [:], chunks: []))
        await #expect(throws: EnrichmentError.transient(code: "http_5xx")) { _ = try await fetch(f, "down.test") }
    }

    @Test func redirectToPrivateHostIsRefused() async throws {
        StubProtocol.lock.withLock { StubProtocol.replies["127.0.0.1"] = .response(status: 200, headers: [:], chunks: [Data("secret".utf8)]) }
        let f = fetcher("redir.test", .redirect(to: URL(string: "http://127.0.0.1/")!))
        // Refusing the redirect hands back the 302 itself, which is not a success.
        await #expect(throws: EnrichmentError.permanent(code: "http_3xx")) { _ = try await fetch(f, "redir.test") }
    }

    @Test(arguments: [
        (URLError.Code.notConnectedToInternet, "offline"), (.networkConnectionLost, "offline"), (.dataNotAllowed, "offline"),
        (.timedOut, "transient"), (.cannotFindHost, "transient"), (.dnsLookupFailed, "transient"),
        (.cannotConnectToHost, "transient"),
    ] as [(URLError.Code, String)])
    func urlErrorMapping(_ code: URLError.Code, _ kind: String) async throws {
        let host = "err\(code.rawValue).test"
        let f = fetcher(host, .failure(code))
        do { _ = try await fetch(f, host); Issue.record("expected throw") }
        catch let e as EnrichmentError {
            switch e {
            case .deferred(let c, let after): #expect(kind == "offline" && c == "offline" && after == 60)
            case .transient: #expect(kind == "transient")
            case .permanent: Issue.record("unexpected permanent")
            }
        }
    }
}
