import Foundation
import Synchronization
import SyncEngine

/// Matches background-session delegate callbacks to the `send` calls waiting on them, by task identifier.
/// A completion nobody waits for (the caller was cancelled, or the process was relaunched since the
/// upload started) is dropped and counted: the next sync pass finds the file through `inspectFile`, or
/// uploads it again.
public final class UploadBookkeeping: Sendable {
    private struct Waiting {
        var continuation: CheckedContinuation<DropboxResponse, Error>
        var body = Data()
    }

    private struct State {
        var waiting: [Int: Waiting] = [:]
        /// Cancelled before `register`: the task must not start.
        var cancelledEarly: Set<Int> = []
        /// Scratch files to delete once their task ends with nobody waiting.
        var abandonedFiles: [Int: URL] = [:]
        var dropped = 0
    }

    private let state = Mutex(State())

    public init() {}

    /// Completions that arrived for a task with no registered continuation.
    public var droppedCompletions: Int { state.withLock { $0.dropped } }

    /// `file` is a scratch copy the task reads: deleted when the task ends after its caller stopped
    /// waiting. While the caller waits, the file stays the caller's.
    public func removeWhenAbandoned(_ file: URL, taskID: Int) {
        state.withLock { $0.abandonedFiles[taskID] = file }
    }

    /// Call before the task is resumed, so no callback can arrive first. Returns false, having already
    /// thrown `CancellationError` into `continuation`, when the caller was cancelled first: the task must
    /// then not be resumed.
    @discardableResult
    public func register(taskID: Int, _ continuation: CheckedContinuation<DropboxResponse, Error>) -> Bool {
        let early = state.withLock { s in
            if s.cancelledEarly.remove(taskID) != nil { return true }
            s.waiting[taskID] = Waiting(continuation: continuation)
            return false
        }
        if early { continuation.resume(throwing: CancellationError()) }
        return !early
    }

    /// The caller was cancelled: it gets `CancellationError` now, and the task keeps running on its own
    /// (design §6.7); its completion is then dropped. Before `register`, marks the task so it never starts.
    public func cancel(taskID: Int) {
        let waiting: Waiting? = state.withLock { s in
            guard let w = s.waiting.removeValue(forKey: taskID) else {
                s.cancelledEarly.insert(taskID)
                return nil
            }
            return w
        }
        waiting?.continuation.resume(throwing: CancellationError())
    }

    /// Accumulates response body bytes; ignored for a task nobody waits for.
    public func append(_ data: Data, taskID: Int) {
        state.withLock { $0.waiting[taskID]?.body.append(data) }
    }

    /// Resumes and forgets the task's continuation. `URLError.cancelled` surfaces as `CancellationError`,
    /// as `URLSessionTransport` does. With nobody waiting, deletes the task's abandoned scratch file.
    public func complete(taskID: Int, status: Int, headers: [String: String], error: Error?) {
        let (waiting, abandoned): (Waiting?, URL?) = state.withLock { s in
            let file = s.abandonedFiles.removeValue(forKey: taskID)
            guard let w = s.waiting.removeValue(forKey: taskID) else {
                s.dropped += 1
                return (nil, file)
            }
            return (w, nil)
        }
        if let abandoned { try? FileManager.default.removeItem(at: abandoned) }
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

    /// Forgets the task's scratch file without deleting it, returning it.
    func takeAbandonedFile(taskID: Int) -> URL? {
        state.withLock { $0.abandonedFiles.removeValue(forKey: taskID) }
    }
}

/// Carries `.file` upload bodies on a background `URLSession`, so an upload the system has started keeps
/// going while Hippo is suspended. Foreground calls (RPC, downloads) stay on `URLSessionTransport`.
///
/// Cancellation (design §6.7 exemption): the system owns a background upload, so Task cancellation never
/// cancels its `URLSessionTask`. The caller gets `CancellationError` at once, so a sync pass ends within its
/// grace; the upload finishes on its own and its completion is dropped. A `removesFileIfAbandoned` body is
/// then deleted by the transport when that upload ends, since the system may still be reading it.
public final class BackgroundUploadTransport: NSObject, DropboxTransport, URLSessionDataDelegate {
    public let identifier: String
    let bookkeeping = UploadBookkeeping()

    private struct State {
        var session: URLSession?
        var eventsCompletion: (@Sendable () -> Void)?
        /// The session finished its events before a handler was set.
        var eventsFinished = false
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

    /// Invalidates the session, cancelling its tasks. For tests; the app keeps its session for its lifetime.
    public func shutdown() {
        state.withLock { s in
            s.session?.invalidateAndCancel()
            s.session = nil
        }
    }

    /// The handler iOS passed to `application(_:handleEventsForBackgroundURLSession:completionHandler:)`;
    /// called on the main queue once the session has delivered every pending event (at once if it already
    /// has). A handler this replaces is called rather than dropped.
    public func setEventsCompletion(_ handler: @escaping @Sendable () -> Void) {
        let (callNow, replaced): ((@Sendable () -> Void)?, (@Sendable () -> Void)?) = state.withLock { s in
            if s.eventsFinished {
                s.eventsFinished = false
                return (handler, nil)
            }
            let old = s.eventsCompletion
            s.eventsCompletion = handler
            return (nil, old)
        }
        for h in [replaced, callNow].compactMap({ $0 }) { DispatchQueue.main.async { h() } }
    }

    public func send(_ r: DropboxRequest) async throws -> DropboxResponse {
        guard case .file(let fileURL) = r.body else { throw StorageError.transient(code: "not_file_body") }
        let scratch = r.removesFileIfAbandoned ? fileURL : nil
        guard !Task.isCancelled else {
            if let scratch { try? FileManager.default.removeItem(at: scratch) }
            throw CancellationError()
        }
        guard let session = state.withLock({ $0.session }) else { throw StorageError.transient(code: "no_session") }
        var request = URLRequest(url: r.url)
        request.httpMethod = r.method
        for (k, v) in r.headers { request.setValue(v, forHTTPHeaderField: k) }
        let task = session.uploadTask(with: request, fromFile: fileURL)
        let id = task.taskIdentifier
        let bookkeeping = bookkeeping
        if let scratch { bookkeeping.removeWhenAbandoned(scratch, taskID: id) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if bookkeeping.register(taskID: id, continuation) {
                    task.resume()
                } else {
                    // Cancelled before it started: nothing reads the file, so it goes now.
                    if let file = bookkeeping.takeAbandonedFile(taskID: id) { try? FileManager.default.removeItem(at: file) }
                    task.cancel()
                }
            }
        } onCancel: {
            bookkeeping.cancel(taskID: id)  // never `task.cancel()`: the system finishes a started upload
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
        let handler: (@Sendable () -> Void)? = state.withLock { s in
            guard let h = s.eventsCompletion else {
                s.eventsFinished = true
                return nil
            }
            s.eventsCompletion = nil
            return h
        }
        if let handler { DispatchQueue.main.async { handler() } }
    }
}
