import Foundation
import Testing
import CaptureCore
import LocalRepository
import SyncEngine
import Enrichment

private let t0 = RunnerHarness.t0

@Suite struct EnrichmentRunnerTests {
    @Test func scheduleMarksApplicability() async throws {
        let h = try RunnerHarness(); defer { h.cleanup() }
        let linkID = try await h.link("https://example.com/a")
        let noteID = try await h.note("hello", minutes: 1)
        let fake = FakeEnricher(kind: .linkPreview, usesNetwork: true, applies: { !$0.urls.isEmpty })
        let runner = h.runner([fake])

        #expect(try await runner.schedule() == 1)
        #expect(try h.task(linkID, .linkPreview)?.status == "pending")
        #expect(try h.task(linkID, .linkPreview)?.version == 1)
        #expect(try h.task(noteID, .linkPreview)?.status == "not_applicable")
        // Nothing is left to schedule, so a second call changes nothing.
        #expect(try await runner.schedule() == 0)
        #expect(try await runner.hasWork())
        #expect(fake.invocations == 0)
    }

    @Test func successWritesFacet() async throws {
        let h = try RunnerHarness(); defer { h.cleanup() }
        let id = try await h.note("call me at 555-0100")
        let thumb = Data("thumbnail bytes".utf8)
        let temp = try h.tempFile("thumb.jpg", thumb)
        let digest = try StreamingHasher.digest(of: temp)
        let assetPath = "assets/\(digest.sha256).jpg"
        let data = JSONValue.object(["text": .string("call me"),
                                     "image": .object(["relative_path": .string(assetPath),
                                                       "byte_count": .number(Double(digest.byteCount)),
                                                       "sha256": .string(digest.sha256)])])
        let fake = FakeEnricher(kind: .textRecognition, version: 3,
                                steps: [.output(FakeEnricher.ok(data, provenance: "vision", newAssets: [assetPath: temp]))])
        let runner = h.runner([fake])
        try await runner.schedule()

        let result = await runner.runPending()
        #expect(result == EnrichmentPassResult(ran: 1, failed: 0, idle: false))

        // The enricher saw the capture's metadata, package and note body, and no previous document.
        let input = try #require(fake.received.first)
        #expect(input.captureID == id)
        #expect(input.metadata.captureID == id)
        #expect(input.noteBody == "call me at 555-0100")
        #expect(input.current == nil)
        #expect(FileManager.default.fileExists(atPath: input.packageURL.appendingPathComponent("metadata.json").path))

        let doc = try #require(try h.deviceDoc(id))
        #expect(doc.layer == .device)
        #expect(doc.producer == RunnerHarness.producer)
        #expect(doc.packageDigest == (try h.store.index.packageDigest(captureID: id)))
        #expect(doc.generatedAt == t0)
        #expect(doc[.textRecognition] == Facet(version: 3, status: .ok, generatedAt: t0, provenance: "vision", data: data))
        #expect(try h.task(id, .textRecognition)?.status == "ok")
        // The asset was stored with the document, and the temp file and its directory are gone.
        let stored = h.store.enrichments.assetURL(.device, captureID: id, asset: doc.referencedAssets()[0])
        #expect(try Data(contentsOf: stored) == thumb)
        #expect(!FileManager.default.fileExists(atPath: temp.deletingLastPathComponent().path))

        // Nothing is left: the next pass is idle.
        #expect(await runner.runPending() == EnrichmentPassResult(ran: 0, failed: 0, idle: true))
        #expect(try await !runner.hasWork())
    }

    @Test func successMergesIntoExistingDocumentAndRecordsEmpty() async throws {
        let h = try RunnerHarness(); defer { h.cleanup() }
        let id = try await h.note("hi")
        let a = FakeEnricher(kind: .sourceAppGuess, steps: [.output(FakeEnricher.ok(.string("notes")))])
        let b = FakeEnricher(kind: .transcript, steps: [.output(EnricherOutput(status: .empty, data: nil,
                                                                               provenance: "speech", newAssets: [:]))])
        let runner = h.runner([a, b])
        try await runner.schedule()
        h.disabled.value = [.transcript]
        _ = await runner.runPending()
        h.disabled.value = []
        h.clock.value = t0.addingTimeInterval(10)
        _ = await runner.runPending()

        #expect(b.received.first?.current?[.sourceAppGuess]?.data == .string("notes"))
        let doc = try #require(try h.deviceDoc(id))
        #expect(doc.generatedAt == t0.addingTimeInterval(10))
        #expect(doc[.sourceAppGuess]?.generatedAt == t0)
        #expect(doc[.transcript] == Facet(version: 1, status: .empty, generatedAt: t0.addingTimeInterval(10),
                                          provenance: "speech", data: nil))
        #expect(try h.task(id, .transcript)?.status == "empty")
    }

    @Test func versionBumpReruns() async throws {
        let h = try RunnerHarness(); defer { h.cleanup() }
        let id = try await h.note("hi")
        let v1 = FakeEnricher(kind: .sourceAppGuess, version: 1, fallback: FakeEnricher.ok(.string("v1")))
        let r1 = h.runner([v1])
        try await r1.schedule()
        _ = await r1.runPending()
        #expect(v1.invocations == 1)

        let v2 = FakeEnricher(kind: .sourceAppGuess, version: 2, fallback: FakeEnricher.ok(.string("v2")))
        let r2 = h.runner([v2])
        #expect(try await r2.schedule() == 1)
        #expect(try h.task(id, .sourceAppGuess)?.version == 2)
        #expect(try h.task(id, .sourceAppGuess)?.status == "pending")
        #expect(await r2.runPending().ran == 1)
        #expect(v2.invocations == 1)
        #expect(try h.deviceDoc(id)?[.sourceAppGuess]?.version == 2)
        #expect(try h.deviceDoc(id)?[.sourceAppGuess]?.data == .string("v2"))
        #expect(try h.task(id, .sourceAppGuess)?.status == "ok")
    }

    @Test func pendingRowAtOldVersionIsRescheduledNotRunStale() async throws {
        let h = try RunnerHarness(); defer { h.cleanup() }
        let id = try await h.note("hi")
        // A row left pending at version 1, then the app updates to version 2 and runs without scheduling.
        try h.store.enrichmentTasks.set(captureID: id, kind: .sourceAppGuess, version: 1, status: "pending", now: t0)
        let v2 = FakeEnricher(kind: .sourceAppGuess, version: 2)
        let runner = h.runner([v2])
        _ = await runner.runPending()
        #expect(v2.invocations == 1)
        #expect(try h.task(id, .sourceAppGuess)?.version == 2)
        #expect(try h.task(id, .sourceAppGuess)?.status == "ok")
        #expect(try h.deviceDoc(id)?[.sourceAppGuess]?.version == 2)
    }

    @Test func transientRetriesThenFails() async throws {
        let h = try RunnerHarness(); defer { h.cleanup() }
        let id = try await h.note("hi")
        let fake = FakeEnricher(kind: .textRecognition,
                                fallback: FakeEnricher.ok(.string("never")))
        for _ in 0..<5 { fake.enqueue(.error(.transient(code: "busy"))) }
        let runner = h.runner([fake])
        try await runner.schedule()

        var delays: [TimeInterval] = []
        for attempt in 1...4 {
            let result = await runner.runPending()
            #expect(result == EnrichmentPassResult(ran: 1, failed: 1, idle: false))
            let task = try #require(try h.task(id, .textRecognition))
            #expect(task.status == "pending")
            #expect(task.attemptCount == attempt)
            #expect(task.lastErrorCode == "busy")
            let next = try #require(task.nextAttemptAt)
            delays.append(next.timeIntervalSince(h.clock.value))
            // Not due yet: nothing runs until the clock reaches it.
            #expect(await runner.runPending().idle)
            h.clock.value = next
        }
        // random() == 1 gives the full backoff ceiling: 30, 60, 120, 240 seconds.
        #expect(delays == [30, 60, 120, 240])

        #expect(await runner.runPending() == EnrichmentPassResult(ran: 1, failed: 1, idle: false))
        let task = try #require(try h.task(id, .textRecognition))
        #expect(task.status == "failed")
        #expect(task.attemptCount == RunnerHarness.maxAttempts)
        #expect(task.nextAttemptAt == nil)
        let facet = try #require(try h.deviceDoc(id)?[.textRecognition])
        #expect(facet.status == .failed)
        #expect(facet.data == nil)
        #expect(facet.version == 1)
        #expect(fake.invocations == 5)
        h.clock.value = h.clock.value.addingTimeInterval(86_400)
        #expect(await runner.runPending().idle)
    }

    @Test func permanentWritesFailedFacet() async throws {
        let h = try RunnerHarness(); defer { h.cleanup() }
        let id = try await h.note("hi")
        let fake = FakeEnricher(kind: .transcript, steps: [.error(.permanent(code: "too_long"))])
        let runner = h.runner([fake])
        try await runner.schedule()
        #expect(await runner.runPending() == EnrichmentPassResult(ran: 1, failed: 1, idle: false))
        let task = try #require(try h.task(id, .transcript))
        #expect(task.status == "failed")
        #expect(task.attemptCount == 1)
        #expect(task.lastErrorCode == "too_long")
        #expect(try h.deviceDoc(id)?[.transcript]?.status == .failed)
        #expect(try h.deviceDoc(id)?[.transcript]?.data == nil)
    }

    @Test func offlineDefersNetworkKindsWithoutAttempts() async throws {
        let h = try RunnerHarness(); defer { h.cleanup() }
        let id = try await h.link("https://example.com/a")
        let network = FakeEnricher(kind: .linkPreview, usesNetwork: true)
        let local = FakeEnricher(kind: .sourceAppGuess)
        let runner = h.runner([network, local])
        try await runner.schedule()

        h.online.value = false
        #expect(await runner.runPending() == EnrichmentPassResult(ran: 1, failed: 0, idle: false))
        #expect(network.invocations == 0)
        #expect(local.invocations == 1)
        #expect(try h.task(id, .linkPreview)?.attemptCount == 0)
        #expect(try h.task(id, .linkPreview)?.status == "pending")
        #expect(try await !runner.hasWork())

        h.online.value = true
        #expect(try await runner.hasWork())
        #expect(await runner.runPending() == EnrichmentPassResult(ran: 1, failed: 0, idle: false))
        #expect(network.invocations == 1)
        #expect(try h.task(id, .linkPreview)?.status == "ok")
    }

    @Test func deferredDoesNotCountAttempts() async throws {
        let h = try RunnerHarness(); defer { h.cleanup() }
        let id = try await h.note("hi")
        let fake = FakeEnricher(kind: .transcript, steps: [.error(.deferred(code: "model_missing", retryAfter: 900))])
        let runner = h.runner([fake])
        try await runner.schedule()
        #expect(await runner.runPending() == EnrichmentPassResult(ran: 1, failed: 0, idle: false))
        let task = try #require(try h.task(id, .transcript))
        #expect(task.status == "pending")
        #expect(task.attemptCount == 0)
        #expect(task.lastErrorCode == "model_missing")
        #expect(task.nextAttemptAt == t0.addingTimeInterval(900))
        #expect(try h.deviceDoc(id) == nil)
    }

    @Test func disabledKindNotRun() async throws {
        let h = try RunnerHarness(); defer { h.cleanup() }
        let id = try await h.note("hi")
        let fake = FakeEnricher(kind: .dataDetection)
        let runner = h.runner([fake])
        h.disabled.value = [.dataDetection]
        #expect(try await runner.schedule() == 0)
        #expect(try h.task(id, .dataDetection) == nil)
        // Even a pending row is not claimed while the kind is off.
        try h.store.enrichmentTasks.set(captureID: id, kind: .dataDetection, version: 1, status: "pending", now: t0)
        #expect(await runner.runPending().idle)
        #expect(try await !runner.hasWork())
        #expect(fake.invocations == 0)
    }

    @Test func inputChangeResetsDependent() async throws {
        let h = try RunnerHarness(); defer { h.cleanup() }
        let id = try await h.note("hi")
        let ocr = FakeEnricher(kind: .textRecognition, steps: [.output(FakeEnricher.ok(.string("first"))),
                                                               .output(FakeEnricher.ok(.string("first"))),
                                                               .output(FakeEnricher.ok(.string("second")))])
        let detect = FakeEnricher(kind: .dataDetection, inputs: [.textRecognition])
        let runner = h.runner([ocr, detect])
        try await runner.schedule()

        // data_detection runs first, while text_recognition is off.
        h.disabled.value = [.textRecognition]
        _ = await runner.runPending()
        #expect(detect.invocations == 1)
        #expect(try h.task(id, .dataDetection)?.status == "ok")

        // text_recognition writes new data: data_detection is pending again and reruns, seeing it.
        h.disabled.value = []
        #expect(await runner.runPending().ran == 2)
        #expect(detect.invocations == 2)
        #expect(detect.received.last?.current?[.textRecognition]?.data == .string("first"))
        #expect(try h.task(id, .dataDetection)?.status == "ok")

        // Same data again: the dependent is left alone.
        try h.store.enrichmentTasks.resetToPending(captureID: id, kind: .textRecognition, now: t0)
        #expect(await runner.runPending().ran == 1)
        #expect(detect.invocations == 2)

        // Different data: it reruns.
        try h.store.enrichmentTasks.resetToPending(captureID: id, kind: .textRecognition, now: t0)
        #expect(await runner.runPending().ran == 2)
        #expect(detect.invocations == 3)
        #expect(detect.received.last?.current?[.textRecognition]?.data == .string("second"))
    }

    @Test func deletedMidRunDropsResult() async throws {
        let h = try RunnerHarness(); defer { h.cleanup() }
        let id = try await h.note("hi")
        let store = h.store
        let temp = try h.tempFile("x.bin", Data("x".utf8))
        let digest = try StreamingHasher.digest(of: temp)
        let path = "assets/\(digest.sha256).bin"
        let data = JSONValue.object(["relative_path": .string(path), "byte_count": .number(1),
                                     "sha256": .string(digest.sha256)])
        let fake = FakeEnricher(kind: .sourceAppGuess, steps: [.custom({ input in
            _ = try await store.delete(captureID: input.captureID)
            return FakeEnricher.ok(data, newAssets: [path: temp])
        })])
        let runner = h.runner([fake])
        try await runner.schedule()
        let packageDir = try #require(try h.store.index.relativeDirectory(captureID: id))

        let result = await runner.runPending()
        #expect(result.failed == 0)
        #expect(fake.invocations == 1)
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: h.store.layout.enrichmentDirectory(.device, captureID: id).path))
        #expect(!fm.fileExists(atPath: h.store.layout.packageURL(relativeDirectory: packageDir).path))
        #expect(!fm.fileExists(atPath: temp.deletingLastPathComponent().path))
        #expect(try h.task(id, .sourceAppGuess) == nil)
    }

    @Test func cancellationLeavesTaskPending() async throws {
        let h = try RunnerHarness(); defer { h.cleanup() }
        let id = try await h.note("hi")
        let fake = FakeEnricher(kind: .transcript, steps: [.custom({ _ in
            try await Task.sleep(for: .seconds(3600))
            return FakeEnricher.ok(.string("late"))
        })])
        let runner = h.runner([fake])
        try await runner.schedule()

        let pass = Task { await runner.runPending() }
        while fake.invocations == 0 { try await Task.sleep(for: .milliseconds(5)) }
        pass.cancel()
        _ = await pass.value

        let task = try #require(try h.task(id, .transcript))
        #expect(task.status == "pending")
        #expect(task.attemptCount == 0)
        #expect(task.nextAttemptAt == nil)
        #expect(task.lastErrorCode == nil)
        #expect(try h.deviceDoc(id) == nil)
        #expect(fake.invocations == 1)
    }

    @Test func overlappingPassesNeverRunATaskTwice() async throws {
        let h = try RunnerHarness(); defer { h.cleanup() }
        _ = try await h.note("a")
        _ = try await h.note("b", minutes: 1)
        let slow = FakeEnricher(kind: .sourceAppGuess)
        for _ in 0..<4 {
            slow.enqueue(.custom({ _ in
                try await Task.sleep(for: .milliseconds(50))
                return FakeEnricher.ok(.string("x"))
            }))
        }
        let runner = h.runner([slow])
        try await runner.schedule()
        async let first = runner.runPending()
        async let second = runner.runPending()
        let results = await [first, second]
        #expect(results.map(\.ran).reduce(0, +) == 2)
        #expect(slow.invocations == 2)
    }

    @Test func passFinishedIsPostedOnTheMainActorWithTheRunner() async throws {
        let h = try RunnerHarness(); defer { h.cleanup() }
        let runner = h.runner([FakeEnricher(kind: .sourceAppGuess)])
        // Other suites post the same name in parallel, so only this runner's posts are counted.
        let posts = Box<[Bool]>([])
        let observer = NotificationCenter.default.addObserver(forName: EnrichmentRunner.passFinished, object: runner,
                                                              queue: nil) { _ in
            posts.value.append(Thread.isMainThread)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        _ = await runner.runPending()
        #expect(posts.value == [true])
        _ = await runner.runPending()
        #expect(posts.value == [true, true])
        #expect(EnrichmentRunner.passFinished.rawValue == "HippoEnrichmentPassFinished")
    }

    @Test func unreadableDocumentRebuiltOnFailureRefillsOtherKinds() async throws {
        let h = try RunnerHarness(); defer { h.cleanup() }
        let id = try await h.note("hi")
        let guess = FakeEnricher(kind: .sourceAppGuess, fallback: FakeEnricher.ok(.string("notes")))
        let transcript = FakeEnricher(kind: .transcript, steps: [.output(FakeEnricher.ok(.string("words"))),
                                                                 .error(.permanent(code: "too_long"))])
        let runner = h.runner([guess, transcript])
        try await runner.schedule()
        #expect(await runner.runPending().ran == 2)
        #expect(try h.task(id, .sourceAppGuess)?.status == "ok")

        // The device document becomes unreadable; then the transcript reruns and fails for good.
        let json = h.store.layout.enrichmentDirectory(.device, captureID: id)
            .appendingPathComponent(EnrichmentPaths.documentName)
        try Data("{not json".utf8).write(to: json)
        try h.store.enrichmentTasks.resetToPending(captureID: id, kind: .transcript, now: t0)
        h.disabled.value = [.sourceAppGuess]
        #expect(await runner.runPending() == EnrichmentPassResult(ran: 1, failed: 1, idle: false))

        // The rebuilt document holds only the failed facet, so the other kind is pending again ...
        #expect(try h.deviceDoc(id)?.facets.keys.sorted() == ["transcript"])
        #expect(try h.task(id, .transcript)?.status == "failed")
        #expect(try h.task(id, .sourceAppGuess)?.status == "pending")
        // ... and the next pass refills it.
        h.disabled.value = []
        #expect(await runner.runPending().ran == 1)
        #expect(try h.deviceDoc(id)?[.sourceAppGuess]?.data == .string("notes"))
        #expect(try h.deviceDoc(id)?[.transcript]?.status == .failed)
    }

    @Test func queuedPassReturnsAtOnceWhenCancelled() async throws {
        let h = try RunnerHarness(); defer { h.cleanup() }
        _ = try await h.note("hi")
        let slow = FakeEnricher(kind: .transcript, steps: [.custom({ _ in
            try await Task.sleep(for: .seconds(30))
            return FakeEnricher.ok(.string("late"))
        })])
        let runner = h.runner([slow])
        try await runner.schedule()
        let finishedFirst = Box(false)
        let first = Task {
            let r = await runner.runPending()
            finishedFirst.value = true
            return r
        }
        while slow.invocations == 0 { try await Task.sleep(for: .milliseconds(5)) }

        let queued = Task { await runner.runPending() }
        try await Task.sleep(for: .milliseconds(50))  // let it queue behind the running pass
        queued.cancel()
        #expect(await queued.value == EnrichmentPassResult(ran: 0, failed: 0, idle: true))
        #expect(!finishedFirst.value)

        first.cancel()
        _ = await first.value
        #expect(slow.invocations == 1)
        // The runner is still usable: a new pass runs the (untouched) task.
        slow.enqueue(.output(FakeEnricher.ok(.string("now"))))
        #expect(await runner.runPending().ran == 1)
    }

    @Test func outputWithAFailureStatusIsAPermanentFailure() async throws {
        let h = try RunnerHarness(); defer { h.cleanup() }
        let id = try await h.note("hi")
        let fake = FakeEnricher(kind: .sourceAppGuess, steps: [.output(EnricherOutput(
            status: .failed, data: .string("odd"), provenance: "fake", newAssets: [:]))])
        let runner = h.runner([fake])
        try await runner.schedule()
        #expect(await runner.runPending() == EnrichmentPassResult(ran: 1, failed: 1, idle: false))
        let task = try #require(try h.task(id, .sourceAppGuess))
        #expect(task.status == "failed")
        #expect(task.lastErrorCode == "invalid_status")
        let facet = try #require(try h.deviceDoc(id)?[.sourceAppGuess])
        #expect(facet.status == .failed)
        #expect(facet.data == nil)
        #expect(facet.provenance == "invalid_status")
    }
}

extension RunnerHarness {
    static var maxAttempts: Int { EnrichmentRunner.maxAttempts }
}
