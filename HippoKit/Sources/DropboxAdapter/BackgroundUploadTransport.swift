import Foundation
import Synchronization
import SyncEngine

/// Matches background-session delegate callbacks to the `send` calls waiting on them, by task identifier.
/// A completion nobody waits for (the process was relaunched since the upload started) is dropped and
/// counted: the next sync pass finds the file through `inspectFile` or uploads it again.
public final class UploadBookkeeping: Sendable {
    private struct Waiting {
        var continuation: CheckedContinuation<DropboxResponse, Error>
        var body = Data()
    }

    private struct State {
        var waiting: [Int: Waiting] = [:]
        var dropped = 0
    }

    private let state = Mutex(State())

    public init() {}

    /// Completions that arrived for a task with no registered continuation.
    public var droppedCompletions: Int { state.withLock { $0.dropped } }

    /// Call before the task is resumed, so no callback can arrive first.
    public func register(taskID: Int, _ continuation: CheckedContinuation<DropboxResponse, Error>) {
        state.withLock { $0.waiting[taskID] = Waiting(continuation: continuation) }
    }

    /// Accumulates response body bytes; ignored for a task nobody waits for.
    public func append(_ data: Data, taskID: Int) {
        state.withLock { $0.waiting[taskID]?.body.append(data) }
    }

    /// Resumes and forgets the task's continuation. `URLError.cancelled` surfaces as `CancellationError`,
    /// as `URLSessionTransport` does.
    public func complete(taskID: Int, status: Int, headers: [String: String], error: Error?) {
        let waiting: Waiting? = state.withLock { s in
            guard let w = s.waiting.removeValue(forKey: taskID) else {
                s.dropped += 1
                return nil
            }
            return w
        }
        guard let waiting else { return }
        if let error {
            if let e = error as? URLError, e.code == .cancelled {
                waiting.continuation.resume(throwing: CancellationError())
            } else {
                waiting.continuation.resume(throwing: error)
            }
        } else {
            waiting.continuation.resume(returning: DropboxResponse(status: status, headers: headers, body: waiting.body))
        }
    }
}

/// Carries `.file` upload bodies on a background `URLSession`, so an upload the system has started keeps
/// going while Hippo is suspended. Foreground calls (RPC, downloads) stay on `URLSessionTransport`.
///
/// Cancellation (design §6.7 exemption): the system owns a background upload, so Task cancellation never
/// cancels its `URLSessionTask`. A call already cancelled throws `CancellationError` before starting; once
/// started, the call waits for the system to finish the upload and returns its response.
public final class BackgroundUploadTransport: NSObject, DropboxTransport, URLSessionDataDelegate {
    public let identifier: String
    let bookkeeping = UploadBookkeeping()

    private struct State {
        var session: URLSession?
        var eventsCompletion: (@Sendable () -> Void)?
    }

    private let state = Mutex(State())

    public init(identifier: String, sharedContainerIdentifier: String?) {
        self.identifier = identifier
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.sharedContainerIdentifier = sharedContainerIdentifier
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        state.withLock { $0.session = session }
    }

    /// The handler iOS passed to `application(_:handleEventsForBackgroundURLSession:completionHandler:)`;
    /// called on the main queue once the session has delivered every pending event.
    public func setEventsCompletion(_ handler: @escaping @Sendable () -> Void) {
        state.withLock { $0.eventsCompletion = handler }
    }

    public func send(_ r: DropboxRequest) async throws -> DropboxResponse {
        guard case .file(let fileURL) = r.body else { throw StorageError.transient(code: "not_file_body") }
        try Task.checkCancellation()
        guard let session = state.withLock({ $0.session }) else { throw StorageError.transient(code: "no_session") }
        var request = URLRequest(url: r.url)
        request.httpMethod = r.method
        for (k, v) in r.headers { request.setValue(v, forHTTPHeaderField: k) }
        let task = session.uploadTask(with: request, fromFile: fileURL)
        let bookkeeping = bookkeeping
        return try await withCheckedThrowingContinuation { continuation in
            bookkeeping.register(taskID: task.taskIdentifier, continuation)
            task.resume()
        }
    }

    public func download(_ r: DropboxRequest, to localURL: URL,
                         progress: (@Sendable (Int64) -> Void)?) async throws -> DropboxResponse {
        throw StorageError.transient(code: "unsupported")
    }

    // MARK: URLSession delegate

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        bookkeeping.append(data, taskID: dataTask.taskIdentifier)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let http = task.response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (k, v) in http?.allHeaderFields ?? [:] {
            if let k = k as? String, let v = v as? String { headers[k.lowercased()] = v }
        }
        bookkeeping.complete(taskID: task.taskIdentifier, status: http?.statusCode ?? 0, headers: headers, error: error)
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let handler = state.withLock({ s in defer { s.eventsCompletion = nil }; return s.eventsCompletion })
        else { return }
        DispatchQueue.main.async { handler() }
    }
}
