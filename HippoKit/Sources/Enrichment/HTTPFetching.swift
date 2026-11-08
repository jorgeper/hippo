import Foundation

/// A GET that returns at most `maxBytes`. Errors are `EnrichmentError`: `deferred(offline)` when there is no
/// connection, `transient` for timeouts and 5xx, `permanent` for 4xx and oversized bodies.
public protocol HTTPFetching: Sendable {
    func get(_ url: URL, timeout: TimeInterval, maxBytes: Int) async throws -> Data
}

/// URLSession-backed fetcher: ephemeral session, no cookies, no credentials, and redirects only to links the
/// fetch policy would allow.
public struct URLSessionHTTPFetcher: HTTPFetching {
    private let baseConfiguration: URLSessionConfiguration?

    public init() { baseConfiguration = nil }
    /// Tests pass a configuration carrying a stub `URLProtocol`.
    init(configuration: URLSessionConfiguration) { baseConfiguration = configuration }

    private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            guard let url = request.url else { return nil }
            if case .skip = LinkFetchPolicy.decide(url) { return nil }
            return request
        }
    }

    public func get(_ url: URL, timeout: TimeInterval, maxBytes: Int) async throws -> Data {
        let config = baseConfiguration ?? URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpShouldHandleCookies = false
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: RedirectGuard())
            if let http = response as? HTTPURLResponse {
                switch http.statusCode {
                case 200..<300: break
                case 408, 429, 500..<600: throw EnrichmentError.transient(code: "http_\(http.statusCode / 100)xx")
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
            switch error.code {
            case .cancelled: throw CancellationError()
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff,
                 .callIsActive:
                throw EnrichmentError.deferred(code: "offline", retryAfter: 60)
            case .timedOut: throw EnrichmentError.transient(code: "timeout")
            case .badURL, .unsupportedURL, .userCancelledAuthentication: throw EnrichmentError.permanent(code: "bad_url")
            default: throw EnrichmentError.transient(code: "network")   // includes unreachable or unknown hosts
            }
        }
    }
}
