import Foundation
import Testing
import SyncEngine
@testable import DropboxAdapter

@Suite struct BackgroundTransportTests {
    func transport() -> BackgroundUploadTransport {
        BackgroundUploadTransport(identifier: "com.jorgeper.hippo.tests.\(UUID().uuidString)", sharedContainerIdentifier: nil)
    }

    @Test func rejectsNonFileBodies() async throws {
        let t = transport()
        let url = URL(string: "https://content.dropboxapi.com/2/files/upload")!
        for body in [DropboxRequest.Body.none, .json(Data("{}".utf8)), .form(Data("a=b".utf8))] {
            await #expect(throws: StorageError.transient(code: "not_file_body")) {
                _ = try await t.send(DropboxRequest(url: url, body: body))
            }
        }
        await #expect(throws: StorageError.transient(code: "unsupported")) {
            _ = try await t.download(DropboxRequest(url: url), to: URL(fileURLWithPath: "/dev/null"), progress: nil)
        }
    }
}

@Suite struct UploadBookkeepingTests {
    @Test func appendThenCompleteResumesWithBody() async throws {
        let b = UploadBookkeeping()
        let response = try await withCheckedThrowingContinuation { c in
            b.register(taskID: 7, c)
            b.append(Data("{\"a\":".utf8), taskID: 7)
            b.append(Data("1}".utf8), taskID: 7)
            b.complete(taskID: 7, status: 200, headers: ["content-type": "application/json"], error: nil)
        }
        #expect(response.status == 200)
        #expect(response.body == Data("{\"a\":1}".utf8))
        #expect(response.headers["content-type"] == "application/json")
        #expect(b.droppedCompletions == 0)
    }

    @Test func completeWithErrorThrows() async throws {
        let b = UploadBookkeeping()
        await #expect(throws: URLError(.timedOut)) {
            _ = try await withCheckedThrowingContinuation { c in
                b.register(taskID: 1, c)
                b.complete(taskID: 1, status: 0, headers: [:], error: URLError(.timedOut))
            }
        }
        await #expect(throws: CancellationError.self) {
            _ = try await withCheckedThrowingContinuation { c in
                b.register(taskID: 2, c)
                b.complete(taskID: 2, status: 0, headers: [:], error: URLError(.cancelled))
            }
        }
    }

    @Test func unknownTaskCompletionIsDropped() async throws {
        let b = UploadBookkeeping()
        b.append(Data("orphan".utf8), taskID: 99)
        b.complete(taskID: 99, status: 200, headers: [:], error: nil)
        #expect(b.droppedCompletions == 1)
        // A completed task is forgotten: a second completion for it is dropped too.
        _ = try await withCheckedThrowingContinuation { c in
            b.register(taskID: 3, c)
            b.complete(taskID: 3, status: 200, headers: [:], error: nil)
        }
        b.complete(taskID: 3, status: 200, headers: [:], error: nil)
        #expect(b.droppedCompletions == 2)
    }
}
