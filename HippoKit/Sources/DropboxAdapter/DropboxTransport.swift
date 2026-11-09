import Foundation

public struct DropboxRequest: Sendable {
    public enum Body: Sendable { case none, json(Data), form(Data), file(URL) }
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Body

    public init(url: URL, method: String = "POST", headers: [String: String] = [:], body: Body = .none) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
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

    /// Cancels the task when the Swift task is cancelled, so cancellation surfaces within the request's latency.
    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionTask?
        private var cancelled = false
        func set(_ t: URLSessionTask) {
            lock.lock(); defer { lock.unlock() }
            task = t
            if cancelled { t.cancel() }
        }
        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
            task?.cancel()
        }
    }

    public func send(_ r: DropboxRequest) async throws -> DropboxResponse {
        try Task.checkCancellation()
        let req = Self.urlRequest(r)
        let box = TaskBox()
        let (data, resp): (Data, URLResponse) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                let handler: @Sendable (Data?, URLResponse?, Error?) -> Void = { data, resp, error in
                    if let error { cont.resume(throwing: error) }
                    else if let resp { cont.resume(returning: (data ?? Data(), resp)) }
                    else { cont.resume(throwing: URLError(.badServerResponse)) }
                }
                let task: URLSessionTask
                if case .file(let url) = r.body { task = session.uploadTask(with: req, fromFile: url, completionHandler: handler) }
                else { task = session.dataTask(with: req, completionHandler: handler) }
                box.set(task)
                task.resume()
            }
        } onCancel: { box.cancel() }
        try Task.checkCancellation()
        return Self.response(resp, body: data)
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
        let box = TaskBox()
        let (tmp, resp): (URL, URLResponse) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                let task = session.downloadTask(with: req) { url, resp, error in
                    if let error { cont.resume(throwing: error); return }
                    guard let url, let resp else { cont.resume(throwing: URLError(.badServerResponse)); return }
                    // The system deletes `url` when this handler returns, so move it now.
                    let keep = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    do { try FileManager.default.moveItem(at: url, to: keep); cont.resume(returning: (keep, resp)) }
                    catch { cont.resume(throwing: error) }
                }
                if let delegate { task.delegate = delegate }
                box.set(task)
                task.resume()
            }
        } onCancel: { box.cancel() }
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Task.checkCancellation()
        var out = Self.response(resp, body: Data())
        guard (200..<300).contains(out.status) else {
            out.body = (try? Data(contentsOf: tmp)) ?? Data()  // an error body is small JSON
            return out
        }
        try? FileManager.default.removeItem(at: localURL)
        try FileManager.default.moveItem(at: tmp, to: localURL)
        return out
    }
}
