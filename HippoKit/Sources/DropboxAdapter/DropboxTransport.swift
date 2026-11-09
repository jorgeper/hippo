import Foundation

public struct DropboxRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Method and URL only: headers (Authorization) and bodies are never printed.
    public var description: String { "DropboxRequest(\(method) \(url.absoluteString))" }
    public var debugDescription: String { description }

    public enum Body: Sendable { case none, json(Data), form(Data), file(URL) }
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Body
    /// The `.file` body is a scratch copy. A background transport whose caller stops waiting deletes it
    /// once the system has finished reading it; otherwise it stays the caller's to delete.
    public var removesFileIfAbandoned: Bool

    public init(url: URL, method: String = "POST", headers: [String: String] = [:], body: Body = .none,
                removesFileIfAbandoned: Bool = false) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.removesFileIfAbandoned = removesFileIfAbandoned
    }
}

public struct DropboxResponse: Sendable {
    public var status: Int
    /// Lowercased keys.
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

public protocol DropboxTransport: Sendable {
    func send(_ r: DropboxRequest) async throws -> DropboxResponse
    /// Streams the response body to `localURL`; the returned response body is empty.
    func download(_ r: DropboxRequest, to localURL: URL,
                  progress: (@Sendable (Int64) -> Void)?) async throws -> DropboxResponse
}

public final class URLSessionTransport: DropboxTransport {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    private static func urlRequest(_ r: DropboxRequest) -> URLRequest {
        var req = URLRequest(url: r.url)
        req.httpMethod = r.method
        for (k, v) in r.headers { req.setValue(v, forHTTPHeaderField: k) }
        switch r.body {
        case .none, .file: break
        case .json(let d):
            req.httpBody = d
            if req.value(forHTTPHeaderField: "Content-Type") == nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        case .form(let d):
            req.httpBody = d
            if req.value(forHTTPHeaderField: "Content-Type") == nil {
                req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            }
        }
        return req
    }

    private static func response(_ r: URLResponse, body: Data) -> DropboxResponse {
        let http = r as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (k, v) in http?.allHeaderFields ?? [:] {
            if let k = k as? String, let v = v as? String { headers[k.lowercased()] = v }
        }
        return DropboxResponse(status: http?.statusCode ?? 0, headers: headers, body: body)
    }

    /// Task cancellation surfaces from URLSession as `URLError.cancelled`; callers see `CancellationError`.
    private static func mapped(_ error: Error) -> Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if let e = error as? URLError, e.code == .cancelled { return CancellationError() }
        return error
    }

    public func send(_ r: DropboxRequest) async throws -> DropboxResponse {
        try Task.checkCancellation()
        let req = Self.urlRequest(r)
        do {
            let (data, resp): (Data, URLResponse)
            if case .file(let url) = r.body { (data, resp) = try await session.upload(for: req, fromFile: url) }
            else { (data, resp) = try await session.data(for: req) }
            return Self.response(resp, body: data)
        } catch { throw Self.mapped(error) }
    }

    private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let progress: @Sendable (Int64) -> Void
        init(_ p: @escaping @Sendable (Int64) -> Void) { progress = p }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { progress(totalBytesWritten) }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }

    public func download(_ r: DropboxRequest, to localURL: URL,
                         progress: (@Sendable (Int64) -> Void)?) async throws -> DropboxResponse {
        try Task.checkCancellation()
        let req = Self.urlRequest(r)
        let delegate = progress.map { ProgressDelegate($0) }
        let tmp: URL, resp: URLResponse
        do { (tmp, resp) = try await session.download(for: req, delegate: delegate) }
        catch { throw Self.mapped(error) }
        defer { try? FileManager.default.removeItem(at: tmp) }
        var out = Self.response(resp, body: Data())
        guard (200..<300).contains(out.status) else {
            out.body = (try? Data(contentsOf: tmp)) ?? Data()  // an error body is small JSON
            return out
        }
        // The delegate's last callback may be short or arrive after this call returns, so the final value is
        // always the file's size.
        let size = (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? NSNumber)?.int64Value
        try? FileManager.default.removeItem(at: localURL)
        try FileManager.default.moveItem(at: tmp, to: localURL)
        if let size { progress?(size) }
        return out
    }
}
