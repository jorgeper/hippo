import Foundation
import Testing
import ShareIntake
import HippoTestSupport
@testable import HippoPresentation

private let t0 = Date(timeIntervalSince1970: 1_794_070_860)

@MainActor
private struct Rig {
    let base: URL
    let recorder = FakeRecorder()
    let session: RecordingSession

    init(permission: MicPermission = .granted) throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        session = RecordingSession(intake: IntakeDirectory(storeRoot: base.appendingPathComponent("Hippo")),
                                   recorder: recorder, permission: { permission }, now: { t0 })
    }
    func cleanup() { try? FileManager.default.removeItem(at: base) }
}

@MainActor
@Suite struct RecordingSessionTests {
    @Test func deniedPermission() async throws {
        let rig = try Rig(permission: .denied)
        defer { rig.cleanup() }
        await rig.session.start()
        #expect(rig.session.state == .denied)
        #expect(rig.recorder.startCount == 0)
    }

    @Test func startStopLeavesPendingFile() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        await rig.session.start()
        #expect(rig.session.state == .recording(startedAt: t0))
        rig.session.stop()
        #expect(rig.session.state == .stopped(duration: 7.4, interrupted: false))
        let pending = try #require(rig.session.pending)
        #expect(FileManager.default.fileExists(atPath: pending.url.path))
    }

    @Test func interruptionKeepsRecording() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        await rig.session.start()
        rig.session.interruptionBegan()
        #expect(rig.session.state == .stopped(duration: 7.4, interrupted: true))
        #expect(rig.session.pending != nil)
    }

    @Test func discardDeletesFile() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        await rig.session.start()
        rig.session.stop()
        let url = try #require(rig.session.pending?.url)
        rig.session.discard()
        #expect(rig.session.state == .idle)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func takePendingReturnsToIdleAndKeepsFile() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        await rig.session.start()
        rig.session.stop()
        let taken = try #require(rig.session.takePending())
        #expect(rig.session.state == .idle)
        #expect(rig.session.pending == nil)
        #expect(taken.startedAt == t0)
        #expect(FileManager.default.fileExists(atPath: taken.url.path))
        rig.session.restorePending(taken)
        #expect(rig.session.state == .stopped(duration: 7.4, interrupted: false))
        #expect(rig.session.pending?.url == taken.url)
    }

    @Test func startWhileRecordingIsIgnored() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        await rig.session.start()
        await rig.session.start()
        #expect(rig.recorder.startCount == 1)
    }
}
