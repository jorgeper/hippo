import Foundation
import Testing
import os
@testable import DropboxAdapter

/// A queue of scripted HTTP results. A request with no matching entry records an `Issue` and gets a 500.
final class ScriptedTransport: DropboxTransport {
    private struct Entry {
        var matcher: @Sendable (DropboxRequest) -> Bool
        var result: Result<DropboxResponse, Error>
        var delay: Duration
    }
    private struct State { var queue: [Entry] = []; var requests: [DropboxRequest] = [] }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var requests: [DropboxRequest] { state.withLock { $0.requests } }

    func enqueue(matching matcher: @escaping @Sendable (DropboxRequest) -> Bool = { _ in true },
                 _ result: Result<DropboxResponse, Error>, delay: Duration = .zero) {
        state.withLock { $0.queue.append(Entry(matcher: matcher, result: result, delay: delay)) }
    }

    static func json(_ object: Any, status: Int = 200) -> Result<DropboxResponse, Error> {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return .success(DropboxResponse(status: status, headers: ["content-type": "application/json"], body: data))
    }

    private func take(_ r: DropboxRequest) -> Entry? {
        state.withLock { s in
            s.requests.append(r)
            guard let i = s.queue.firstIndex(where: { $0.matcher(r) }) else { return nil }
            return s.queue.remove(at: i)
        }
    }

    func send(_ r: DropboxRequest) async throws -> DropboxResponse {
        guard let entry = take(r) else {
            Issue.record("No scripted response for \(r.method) \(r.url.path)")
            return DropboxResponse(status: 500)
        }
        if entry.delay > .zero { try await Task.sleep(for: entry.delay) }
        return try entry.result.get()
    }

    func download(_ r: DropboxRequest, to localURL: URL,
                  progress: (@Sendable (Int64) -> Void)?) async throws -> DropboxResponse {
        var resp = try await send(r)
        if (200..<300).contains(resp.status) {
            try resp.body.write(to: localURL)
            progress?(Int64(resp.body.count))
            resp.body = Data()
        }
        return resp
    }
}
