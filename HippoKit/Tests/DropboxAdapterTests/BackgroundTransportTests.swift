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
        defer { t.shutdown() }
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

extension BackgroundTransportTests {
    /// The system keeps the started upload; the cancelled caller returns at once.
    @Test func cancelledSendReturnsAtOnce() async throws {
        let t = transport()
        defer { t.shutdown() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("chunk-\(UUID().uuidString)")
        try Data("slice".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let r = DropboxRequest(url: URL(string: "https://example.invalid/upload")!, body: .file(file),
                               removesFileIfAbandoned: true)
        let task = Task { try await t.send(r) }
        try await Task.sleep(for: .milliseconds(50))
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - start < .milliseconds(500))
    }


    @Test func eventsFinishedBeforeTheHandlerIsSetStillCallIt() async throws {
        let t = transport()
        defer { t.shutdown() }
        t.urlSessionDidFinishEvents(forBackgroundURLSession: .shared)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            t.setEventsCompletion { c.resume() }
        }
    }

    @Test func aReplacedHandlerIsCalledNotDropped() async throws {
        let t = transport()
        defer { t.shutdown() }
        await withCheckedContinuation { (first: CheckedContinuation<Void, Never>) in
            t.setEventsCompletion { first.resume() }
            t.setEventsCompletion {}
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

    @Test func cancelThenCompleteThrowsAndDropsTheCompletion() async throws {
        let b = UploadBookkeeping()
        let scratch = try scratchFile()
        b.removeWhenAbandoned(scratch, taskID: 5)
        await #expect(throws: CancellationError.self) {
            _ = try await withCheckedThrowingContinuation { c in
                #expect(b.register(taskID: 5, c))
                b.cancel(taskID: 5)
            }
        }
        // The system was still reading the file: it stays until the task completes.
        #expect(FileManager.default.fileExists(atPath: scratch.path))
        b.complete(taskID: 5, status: 200, headers: [:], error: nil)
        #expect(b.droppedCompletions == 1)
        #expect(!FileManager.default.fileExists(atPath: scratch.path))
    }

    @Test func cancelBeforeRegisterThrowsWithoutStarting() async throws {
        let b = UploadBookkeeping()
        b.cancel(taskID: 6)
        await #expect(throws: CancellationError.self) {
            _ = try await withCheckedThrowingContinuation { c in
                // false: the caller must not resume the task.
                #expect(!b.register(taskID: 6, c))
            }
        }
        // The marker is used up: a later task with the same ID registers normally.
        let response = try await withCheckedThrowingContinuation { c in
            #expect(b.register(taskID: 6, c))
            b.complete(taskID: 6, status: 204, headers: [:], error: nil)
        }
        #expect(response.status == 204)
    }

    @Test func completedTaskKeepsItsFileForTheCaller() async throws {
        let b = UploadBookkeeping()
        let scratch = try scratchFile()
        defer { try? FileManager.default.removeItem(at: scratch) }
        b.removeWhenAbandoned(scratch, taskID: 8)
        _ = try await withCheckedThrowingContinuation { c in
            b.register(taskID: 8, c)
            b.complete(taskID: 8, status: 200, headers: [:], error: nil)
        }
        #expect(FileManager.default.fileExists(atPath: scratch.path))
    }

    private func scratchFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chunk-\(UUID().uuidString)")
        try Data("slice".utf8).write(to: url)
        return url
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
