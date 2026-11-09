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
}
