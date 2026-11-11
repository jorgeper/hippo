import Foundation

/// A GET that returns at most `maxBytes`. Errors are `EnrichmentError`: `deferred(offline)` when there is no
/// connection, `transient` for timeouts and 5xx, `permanent` for 4xx and oversized bodies.
public protocol HTTPFetching: Sendable {
    func get(_ url: URL, timeout: TimeInterval, maxBytes: Int) async throws -> Data
}

/// Where a link's redirects lead.
public enum RedirectResolution: Equatable, Sendable {
    /// The last URL in the chain. Every hop was allowed by `LinkFetchPolicy`.
    case final(URL)
    /// A hop pointed at a link the policy never fetches; that hop was not requested.
    case refused
}

/// Follows a link's redirects without fetching the page, so a fetcher that can't vet redirects itself
/// (LinkPresentation) is handed only a checked final URL. Errors are `EnrichmentError`, mapped like
/// `HTTPFetching`.
public protocol RedirectResolving: Sendable {
    func resolve(_ url: URL, timeout: TimeInterval) async throws -> RedirectResolution
}

/// Refuses any redirect to a link the fetch policy would skip, and remembers that it did.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _refused = false
    var refused: Bool { lock.withLock { _refused } }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url, !Self.skips(url) else {
            lock.withLock { _refused = true }
            return nil
        }
        // A redirect resolver probes with HEAD (or a one-byte GET): keep it that way on every hop.
        var next = request
        if let original = task.originalRequest {
            if original.httpMethod == "HEAD" { next.httpMethod = "HEAD" }
            if let range = original.value(forHTTPHeaderField: "Range") { next.setValue(range, forHTTPHeaderField: "Range") }
        }
        return next
    }

    static func skips(_ url: URL) -> Bool {
        if case .skip = LinkFetchPolicy.decide(url) { return true }
        return false
    }
}

/// An ephemeral session with no cookies, credentials or cache.
private func makeSession(_ base: URLSessionConfiguration?, timeout: TimeInterval) -> URLSession {
    let config = base ?? URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.httpCookieAcceptPolicy = .never
    config.urlCredentialStorage = nil
    config.urlCache = nil
    config.timeoutIntervalForRequest = timeout
    config.timeoutIntervalForResource = timeout
    return URLSession(configuration: config)
}

/// Only "no network" defers (without spending an attempt). A lost connection is transient: a host that
/// always drops the connection must not be retried forever.
private func mapURLError(_ error: URLError) -> Error {
    switch error.code {
    case .cancelled: return CancellationError()
    case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
        return EnrichmentError.deferred(code: "offline", retryAfter: 60)
    case .timedOut: return EnrichmentError.transient(code: "timeout")
    case .badURL, .unsupportedURL, .userCancelledAuthentication: return EnrichmentError.permanent(code: "bad_url")
    default: return EnrichmentError.transient(code: "network")   // includes lost connections, unreachable or unknown hosts
    }
}

/// URLSession-backed fetcher: ephemeral session, no cookies, no credentials, and redirects only to links the
/// fetch policy would allow.
public struct URLSessionHTTPFetcher: HTTPFetching {
    private let baseConfiguration: URLSessionConfiguration?

    public init() { baseConfiguration = nil }
    /// Tests pass a configuration carrying a stub `URLProtocol`.
    init(configuration: URLSessionConfiguration) { baseConfiguration = configuration }

    public func get(_ url: URL, timeout: TimeInterval, maxBytes: Int) async throws -> Data {
        let session = makeSession(baseConfiguration, timeout: timeout)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpShouldHandleCookies = false
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: RedirectGuard())
            if let http = response as? HTTPURLResponse {
                switch http.statusCode {
                case 200..<300: break
                case 429: throw EnrichmentError.transient(code: "http_429")  // Distinct so a caller can defer it.
                case 408, 500..<600: throw EnrichmentError.transient(code: "http_\(http.statusCode / 100)xx")
                default: throw EnrichmentError.permanent(code: "http_\(http.statusCode / 100)xx")
                }
            }
            if response.expectedContentLength > Int64(maxBytes) { throw EnrichmentError.permanent(code: "too_large") }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxBytes { throw EnrichmentError.permanent(code: "too_large") }
            }
            return data
        } catch let error as EnrichmentError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            throw mapURLError(error)
        }
    }
}

/// Resolves redirects with a HEAD request through the same guarded session as `URLSessionHTTPFetcher`:
/// each hop is checked against `LinkFetchPolicy` before it is requested. A server that rejects HEAD
/// (405, 501) gets a GET for the first byte only, whose body is never read.
public struct URLSessionRedirectResolver: RedirectResolving {
    private let baseConfiguration: URLSessionConfiguration?

    public init() { baseConfiguration = nil }
    /// Tests pass a configuration carrying a stub `URLProtocol`.
    init(configuration: URLSessionConfiguration) { baseConfiguration = configuration }

    public func resolve(_ url: URL, timeout: TimeInterval) async throws -> RedirectResolution {
        if RedirectGuard.skips(url) { return .refused }
        do {
            switch try await probe(url, method: "HEAD", timeout: timeout) {
            case .rejected: break
            case .done(let resolution): return resolution
            }
            switch try await probe(url, method: "GET", timeout: timeout) {
            case .rejected: return .final(url)   // the page answers neither; LinkPresentation reports the failure
            case .done(let resolution): return resolution
            }
        } catch let error as EnrichmentError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            throw mapURLError(error)
        }
    }

    private enum Probe { case rejected, done(RedirectResolution) }

    private func probe(_ url: URL, method: String, timeout: TimeInterval) async throws -> Probe {
        let session = makeSession(baseConfiguration, timeout: timeout)
        // The body is never wanted: cancel whatever is still loading.
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        if method == "GET" { request.setValue("bytes=0-0", forHTTPHeaderField: "Range") }
        let guardian = RedirectGuard()
        let (_, response) = try await session.bytes(for: request, delegate: guardian)
        if guardian.refused { return .done(.refused) }
        if let http = response as? HTTPURLResponse, http.statusCode == 405 || http.statusCode == 501 {
            return .rejected
        }
        let final = response.url ?? url
        return .done(RedirectGuard.skips(final) ? .refused : .final(final))
    }
}
