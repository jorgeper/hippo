import Foundation
import Testing
@testable import Enrichment

/// Serves canned responses; one handler per test run, keyed by URL host so suites can run in parallel.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        case response(status: Int, headers: [String: String], chunks: [Data])
        case redirect(to: URL)
        case failure(URLError.Code)
        /// A different reply for HEAD than for every other method.
        indirect case byMethod(head: Reply, other: Reply)
    }
    nonisolated(unsafe) static var replies: [String: Reply] = [:]
    /// "METHOD host" for every request that reached the stub.
    nonisolated(unsafe) static var requested: [String] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let host = request.url?.host ?? ""
        let method = request.httpMethod ?? "GET"
        var reply = Self.lock.withLock {
            Self.requested.append("\(method) \(host)")
            return Self.replies[host]
        }
        if case .byMethod(let head, let other) = reply { reply = method == "HEAD" ? head : other }
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
        case .byMethod, nil:
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

private func stubConfiguration() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    return config
}

private func resolver(_ replies: [String: StubProtocol.Reply]) -> URLSessionRedirectResolver {
    StubProtocol.lock.withLock { for (host, reply) in replies { StubProtocol.replies[host] = reply } }
    return URLSessionRedirectResolver(configuration: stubConfiguration())
}

private func requests(_ host: String) -> [String] {
    StubProtocol.lock.withLock { StubProtocol.requested.filter { $0.hasSuffix(" \(host)") } }
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

    @Test func status429IsTransientWithItsOwnCode() async throws {
        let f = fetcher("rl.test", .response(status: 429, headers: [:], chunks: []))
        await #expect(throws: EnrichmentError.transient(code: "http_429")) { _ = try await fetch(f, "rl.test") }
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
        (URLError.Code.notConnectedToInternet, "offline"), (.networkConnectionLost, "transient"), (.dataNotAllowed, "offline"),
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
            case .permanent, .notApplicable: Issue.record("unexpected permanent")
            }
        }
    }
}

@Suite struct RedirectResolverTests {
    private static let ok = StubProtocol.Reply.response(status: 200, headers: [:], chunks: [Data("page".utf8)])

    @Test func noRedirectResolvesToItself() async throws {
        let r = resolver(["plain.rr": Self.ok])
        let url = try #require(URL(string: "https://plain.rr/a"))
        #expect(try await r.resolve(url, timeout: 5) == .final(url))
        // A HEAD is enough: the page itself is never asked for.
        #expect(requests("plain.rr") == ["HEAD plain.rr"])
    }

    @Test func cleanRedirectResolvesToTheLanding() async throws {
        let landing = try #require(URL(string: "https://landing.rr/article"))
        let r = resolver(["short.rr": .redirect(to: landing), "landing.rr": Self.ok])
        #expect(try await r.resolve(try #require(URL(string: "https://short.rr/x")), timeout: 5) == .final(landing))
        #expect(requests("landing.rr") == ["HEAD landing.rr"])
    }

    @Test func redirectToSingleUseLinkIsRefusedAndNeverRequested() async throws {
        let target = try #require(URL(string: "https://magic.rr/session?token=abc"))
        let r = resolver(["click.rr": .redirect(to: target), "magic.rr": Self.ok])
        #expect(try await r.resolve(try #require(URL(string: "https://click.rr/ls/click?upn=1")), timeout: 5) == .refused)
        #expect(requests("magic.rr").isEmpty)
    }

    @Test func redirectToUnsubscribeIsRefused() async throws {
        let target = try #require(URL(string: "https://list.rr/unsubscribe/42"))
        let r = resolver(["track.rr": .redirect(to: target), "list.rr": Self.ok])
        #expect(try await r.resolve(try #require(URL(string: "https://track.rr/c/1")), timeout: 5) == .refused)
        #expect(requests("list.rr").isEmpty)
    }

    @Test func redirectToPrivateHostIsRefused() async throws {
        let r = resolver(["lan.rr": .redirect(to: try #require(URL(string: "http://192.168.1.1/admin")))])
        #expect(try await r.resolve(try #require(URL(string: "https://lan.rr/x")), timeout: 5) == .refused)
    }

    @Test(arguments: [405, 501])
    func headRejectedFallsBackToGet(_ status: Int) async throws {
        let host = "nohead\(status).rr"
        let landing = try #require(URL(string: "https://landing\(status).rr/page"))
        let r = resolver([host: .byMethod(head: .response(status: status, headers: [:], chunks: []),
                                          other: .redirect(to: landing)),
                          "landing\(status).rr": Self.ok])
        #expect(try await r.resolve(try #require(URL(string: "https://\(host)/x")), timeout: 5) == .final(landing))
        #expect(requests(host) == ["HEAD \(host)", "GET \(host)"])
    }

    @Test func getFallbackStillRefusesSingleUseRedirect() async throws {
        let target = try #require(URL(string: "https://reset.rr/reset-password"))
        let r = resolver(["nohead.rr": .byMethod(head: .response(status: 405, headers: [:], chunks: []),
                                                 other: .redirect(to: target)),
                          "reset.rr": Self.ok])
        #expect(try await r.resolve(try #require(URL(string: "https://nohead.rr/x")), timeout: 5) == .refused)
        #expect(requests("reset.rr").isEmpty)
    }

    @Test(arguments: [
        (URLError.Code.notConnectedToInternet, "offline"), (.networkConnectionLost, "transient"),
        (.dataNotAllowed, "offline"), (.timedOut, "transient"), (.cannotFindHost, "transient"),
    ] as [(URLError.Code, String)])
    func errorMappingMatchesTheFetcher(_ code: URLError.Code, _ kind: String) async throws {
        let host = "rerr\(code.rawValue).rr"
        let r = resolver([host: .failure(code)])
        do { _ = try await r.resolve(try #require(URL(string: "https://\(host)/x")), timeout: 5); Issue.record("expected throw") }
        catch let e as EnrichmentError {
            switch e {
            case .deferred(let c, let after): #expect(kind == "offline" && c == "offline" && after == 60)
            case .transient: #expect(kind == "transient")
            case .permanent, .notApplicable: Issue.record("unexpected permanent")
            }
        }
    }
}
