import Foundation
import Testing
@testable import DropboxAdapter

/// Never answers, so the request stays in flight until cancelled.
final class HangingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

/// Answers every request with 200 bytes.
final class BytesURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                   headerFields: ["Content-Length": "200"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 7, count: 200))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64] = []
    func add(_ v: Int64) { lock.lock(); values.append(v); lock.unlock() }
    var last: Int64? { lock.lock(); defer { lock.unlock() }; return values.last }
}

@Suite struct URLSessionTransportTests {
    func transport() -> URLSessionTransport {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HangingURLProtocol.self]
        return URLSessionTransport(session: URLSession(configuration: config))
    }

    let request = DropboxRequest(url: URL(string: "https://example.invalid/hang")!)

    @Test func cancelledSendThrowsCancellationErrorQuickly() async throws {
        let t = transport(), r = request
        let task = Task { try await t.send(r) }
        try await Task.sleep(for: .milliseconds(50))
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - start < .milliseconds(500))
    }

    @Test func cancelledDownloadThrowsCancellationErrorQuickly() async throws {
        let t = transport(), r = request
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let task = Task { try await t.download(r, to: dest, progress: { _ in }) }
        try await Task.sleep(for: .milliseconds(50))
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - start < .milliseconds(500))
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    @Test func downloadProgressEndsAtTheFileSize() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BytesURLProtocol.self]
        let t = URLSessionTransport(session: URLSession(configuration: config))
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dest) }
        let box = ProgressBox()
        let resp = try await t.download(request, to: dest, progress: { box.add($0) })
        #expect((200..<300).contains(resp.status))
        #expect(try Data(contentsOf: dest).count == 200)
        #expect(box.last == 200)
    }
}
