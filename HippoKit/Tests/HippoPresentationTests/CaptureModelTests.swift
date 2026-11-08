import Foundation
import Testing
import CaptureCore
import ShareIntake
import SyncEngine
import LocalRepository
import HippoTestSupport
@testable import HippoPresentation

private let t0 = Date(timeIntervalSince1970: 1_794_070_860) // 2026-11-07T17:01:00Z
private let la = TimeZone(identifier: "America/Los_Angeles")!

private func fix(_ offset: TimeInterval, acc: Double = 10, lat: Double = 37.77) -> LocationFix {
    LocationFix(latitude: lat, longitude: -122.4, horizontalAccuracy: acc, timestamp: t0.addingTimeInterval(offset))
}

@MainActor
private final class FakeRecorder: AudioRecording {
    var startedURL: URL?
    var startCount = 0
    var stopCount = 0
    var currentTime: TimeInterval = 7.4
    var startError: Error?
    func start(writingTo url: URL) throws {
        if let startError { throw startError }
        startCount += 1
        startedURL = url
        try MediaMaker.writeAudio(to: url)
    }
    func stop() { stopCount += 1 }
}

@MainActor
private struct Rig {
    let ts: TestStore
    let intake: IntakeDirectory
    let recorder = FakeRecorder()
    let model: RecorderModel

    init(permission: MicPermission = .granted, location: CaptureLocation? = nil) throws {
        ts = try TestStore()
        intake = IntakeDirectory(storeRoot: ts.base.appendingPathComponent("Hippo"))
        model = RecorderModel(store: ts.store, intake: intake, recorder: recorder,
                              permission: { permission }, location: { _ in location }, now: { t0 })
    }
}

@Suite struct CaptureModelTests {
    @Test func noteDraftMatchesFixtureShape() async throws {
        let ts = try TestStore()
        defer { ts.cleanup() }
        let text = "Call the plumber about the upstairs sink."
        #expect(text.utf8.count == 41)
        let id = UUID()
        let draft = try #require(NoteComposer.draft(text: text, captureID: id, startedAt: t0, timeZone: la, location: nil))
        let pkg = try await ts.capture(draft)

        let data = try Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/packages/captures/2026/11/07/00000000-0000-4000-8000-000000000001/metadata.json"))
        let fixture = try HippoJSON.decodeMetadata(data)

        let m = pkg.metadata
        #expect(m.captureMethod == fixture.captureMethod)
        #expect(m.contentTypes == fixture.contentTypes)
        #expect(m.attachments.count == 1)
        let a = m.attachments[0], f = fixture.attachments[0]
        #expect(a.byteCount == f.byteCount)
        #expect(a.sha256 == f.sha256)
        #expect(a.mimeType == f.mimeType)
        #expect(a.uti == f.uti)
        #expect(a.representationSource == f.representationSource)
        #expect(a.originalFilename == f.originalFilename)
        #expect(a.relativePath.hasSuffix(".txt"))
        #expect(pkg.noteBody() == text)
    }

    @Test func whitespaceNoteIsNotSaved() {
        for text in ["", "   ", "\n\t \n"] {
            #expect(NoteComposer.draft(text: text, captureID: UUID(), startedAt: t0, timeZone: la, location: nil) == nil)
        }
    }

    @Test func locationPolicyRules() {
        func pick(enabled: Bool = true, session: LocationFix? = nil, last: LocationFix? = nil) -> CaptureLocation? {
            LocationPolicy.pick(enabled: enabled, sessionFix: session, lastKnown: last, captureStartedAt: t0)
        }
        #expect(pick(enabled: false, session: fix(0)) == nil)
        #expect(pick() == nil)
        // Staleness is 3600 s inclusive, in either direction.
        #expect(pick(session: fix(-3601)) == nil)
        #expect(pick(session: fix(3601)) == nil)
        #expect(pick(session: fix(-3600)) != nil)
        // Negative accuracy means invalid.
        #expect(pick(session: fix(0, acc: -1)) == nil)
        #expect(pick(session: fix(0, acc: .nan)) == nil)
        // The newer fix wins; an invalid newer one is skipped.
        let both = pick(session: fix(-5, lat: 1), last: fix(-60, lat: 2))
        #expect(both?.latitude == 1)
        #expect(both?.provenance == "core_location_request")
        #expect(pick(session: fix(0, acc: -1, lat: 1), last: fix(-60, lat: 2))?.latitude == 2)
        #expect(pick(session: fix(-3601, lat: 1), last: fix(-60, lat: 2))?.latitude == 2)
        // Last-known alone, and when newer than the session fix.
        let last = pick(last: fix(-60, acc: 25, lat: 2))
        #expect(last?.provenance == "core_location_last_known")
        #expect(last?.horizontalAccuracyMeters == 25)
        #expect(last?.observedAt == t0.addingTimeInterval(-60))
        #expect(pick(session: fix(-60, lat: 1), last: fix(-5, lat: 2))?.provenance == "core_location_last_known")
    }

    @MainActor @Test func recorderDeniedPermission() async throws {
        let rig = try Rig(permission: .denied)
        defer { rig.ts.cleanup() }
        await rig.model.start()
        #expect(rig.model.state == .denied)
        #expect(rig.recorder.startCount == 0)
        let undetermined = try Rig(permission: .undetermined)
        defer { undetermined.ts.cleanup() }
        await undetermined.model.start()
        #expect(undetermined.model.state == .denied)
    }

    @MainActor @Test func recorderStartStopSave() async throws {
        let loc = CaptureLocation(latitude: 1, longitude: 2, horizontalAccuracyMeters: 5, observedAt: t0,
                                  provenance: "core_location_last_known")
        let rig = try Rig(location: loc)
        defer { rig.ts.cleanup() }
        await rig.model.start()
        #expect(rig.model.state == .recording(startedAt: t0))
        let url = try #require(rig.recorder.startedURL)
        #expect(url.deletingLastPathComponent().lastPathComponent == "intake")
        #expect(FileManager.default.fileExists(atPath: url.path))

        rig.model.stop()
        #expect(rig.model.state == .stopped(duration: 7.4, interrupted: false))
        #expect(rig.recorder.stopCount == 1)

        await rig.model.save()
        #expect(rig.model.state == .saved)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let page = try rig.ts.store.index.page(CaptureFilter(), after: nil, limit: 10)
        #expect(page.count == 1)
        #expect(page[0].method == .voiceRecording)
        #expect(page[0].attachmentCount == 1)
        #expect(page[0].capturedAt == t0)
    }

    @MainActor @Test func interruptionStopsAndOffersSave() async throws {
        let rig = try Rig()
        defer { rig.ts.cleanup() }
        rig.model.interruptionBegan()           // not recording: ignored
        #expect(rig.model.state == .idle)
        await rig.model.start()
        rig.model.interruptionBegan()
        #expect(rig.model.state == .stopped(duration: 7.4, interrupted: true))
        #expect(rig.recorder.stopCount == 1)
        await rig.model.save()
        #expect(rig.model.state == .saved)
    }

    @MainActor @Test func discardDeletesTempFile() async throws {
        let rig = try Rig()
        defer { rig.ts.cleanup() }
        await rig.model.start()
        let url = try #require(rig.recorder.startedURL)
        rig.model.stop()
        rig.model.discard()
        #expect(rig.model.state == .idle)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        await rig.model.start()                  // discard while still recording
        let url2 = try #require(rig.recorder.startedURL)
        rig.model.discard()
        #expect(rig.model.state == .idle)
        #expect(!FileManager.default.fileExists(atPath: url2.path))
        #expect(rig.recorder.stopCount == 2)
    }

    @MainActor @Test func failedSaveKeepsFileAndCanRetry() async throws {
        let rig = try Rig()
        defer { rig.ts.cleanup() }
        await rig.model.start()
        let url = try #require(rig.recorder.startedURL)
        rig.model.stop()
        try FileManager.default.removeItem(at: url)   // the commit cannot find its file
        await rig.model.save()
        #expect(rig.model.state == .failed("Hippo couldn't save this recording. It's still here. Try again."))
        try MediaMaker.writeAudio(to: url)
        await rig.model.save()
        #expect(rig.model.state == .saved)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor @Test func startFailureIsReportedAndCleansUp() async throws {
        let rig = try Rig()
        defer { rig.ts.cleanup() }
        rig.recorder.startError = CocoaError(.fileWriteUnknown)
        await rig.model.start()
        guard case .failed = rig.model.state else { Issue.record("expected failed"); return }
        await rig.model.save()                     // nothing recorded: ignored
        guard case .failed = rig.model.state else { Issue.record("expected failed"); return }
    }

    @Test func elapsedTextFormats() {
        #expect(RecorderModel.elapsedText(7) == "0:07")
        #expect(RecorderModel.elapsedText(7.9) == "0:07")
        #expect(RecorderModel.elapsedText(0) == "0:00")
        #expect(RecorderModel.elapsedText(725) == "12:05")
        #expect(RecorderModel.elapsedText(3723) == "1:02:03")
        #expect(RecorderModel.elapsedText(-3) == "0:00")
    }
}
