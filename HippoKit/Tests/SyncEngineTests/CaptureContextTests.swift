import Foundation
import Testing
import CaptureCore
import LocalRepository
@testable import SyncEngine

private final class HookBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _groups: (deviceContext: Bool, location: Bool)
    private var _last: LastSaved?
    private var _recorded: [LastSaved] = []
    init(groups: (Bool, Bool), last: LastSaved? = nil) { _groups = (groups.0, groups.1); _last = last }
    var groups: (deviceContext: Bool, location: Bool) {
        get { lock.lock(); defer { lock.unlock() }; return _groups }
        set { lock.lock(); _groups = newValue; lock.unlock() }
    }
    var recorded: [LastSaved] { lock.lock(); defer { lock.unlock() }; return _recorded }
    var hooks: CaptureContextHooks {
        CaptureContextHooks(
            enabledGroups: { [self] in groups },
            lastSaved: { [self] in lock.lock(); defer { lock.unlock() }; return _last },
            recordSaved: { [self] v in lock.lock(); _last = v; _recorded.append(v); lock.unlock() })
    }
}

private func field(_ v: JSONValue?, _ key: String) -> JSONValue? {
    guard case .object(let d)? = v else { return nil }
    return d[key]
}

private let base = Date(timeIntervalSince1970: 1_794_070_800)

private struct Rig {
    let root: URL
    let store: HippoStore
    init(_ hooks: CaptureContextHooks?) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hippo-ctx-\(UUID().uuidString)")
        store = try HippoStore.open(root: root.appendingPathComponent("Hippo"),
                                    producer: Producer(appVersion: "0.1.0", build: "1", osVersion: "test"),
                                    context: hooks)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func draft(at offset: TimeInterval = 0, observations: [MetadataObservation] = []) -> CaptureDraft {
        CaptureDraft(captureID: UUID(), startedAt: base.addingTimeInterval(offset),
                     timeZone: TimeZone(identifier: "America/Los_Angeles")!, method: .typedNote,
                     attachments: [AttachmentSource(body: .data(Data("hello".utf8)), originalFilename: nil,
                                                    uti: "public.utf8-plain-text", mimeType: "text/plain",
                                                    representationSource: "typed_note")],
                     observations: observations)
    }
}

private func context(_ p: CommittedPackage) -> [MetadataObservation] {
    p.metadata.metadataObservations.filter { $0.key.hasPrefix("context.") }
}

@Suite struct CaptureContextTests {
    @Test func enabledAlwaysWritten() async throws {
        let box = HookBox(groups: (false, false))
        let rig = try Rig(box.hooks); defer { rig.cleanup() }
        let p = try await rig.store.capture(rig.draft())
        let c = context(p)
        #expect(c.count == 1)
        #expect(c[0].key == "context.enabled")
        #expect(field(c[0].value, "groups") == .array([]))
    }

    @Test func burstWrittenWhenEnabled() async throws {
        let box = HookBox(groups: (true, false))
        let rig = try Rig(box.hooks); defer { rig.cleanup() }
        let first = try await rig.store.capture(rig.draft())
        let second = try await rig.store.capture(rig.draft(at: 41.2))
        #expect(!context(first).contains { $0.key == "context.burst" })
        let burst = try #require(context(second).first { $0.key == "context.burst" })
        #expect(field(burst.value, "previous_capture_id") == .string(first.metadata.captureID))
        #expect(field(burst.value, "seconds_since_previous") == .number(41.2))
        #expect(box.recorded.map(\.captureID) == [first.metadata.captureID, second.metadata.captureID])
        #expect(box.recorded[0].capturedAt == base)
    }

    @Test func burstNotWrittenWhenDisabledButLastSavedStillRecorded() async throws {
        let box = HookBox(groups: (false, false))
        let rig = try Rig(box.hooks); defer { rig.cleanup() }
        let a = try await rig.store.capture(rig.draft())
        #expect(!context(a).contains { $0.key == "context.burst" })
        box.groups = (true, false)
        let b = try await rig.store.capture(rig.draft(at: 10))
        let burst = try #require(context(b).first { $0.key == "context.burst" })
        #expect(field(burst.value, "previous_capture_id") == .string(a.metadata.captureID))
    }

    @Test func failedSaveDoesNotRecord() async throws {
        let box = HookBox(groups: (true, false))
        let rig = try Rig(box.hooks); defer { rig.cleanup() }
        var empty = rig.draft()
        empty.attachments = []
        await #expect(throws: CaptureError.self) { try await rig.store.capture(empty) }
        #expect(box.recorded.isEmpty)
    }

    @Test func saveWithoutSnapshotStillSaves() async throws {
        let box = HookBox(groups: (true, true))
        let rig = try Rig(box.hooks); defer { rig.cleanup() }
        let p = try await rig.store.capture(rig.draft())
        let c = context(p)
        #expect(c.map(\.key) == ["context.enabled"])
        #expect(field(c[0].value, "groups") == .array([.string("device_context"), .string("location")]))
    }

    @Test func noHooksNoEntries() async throws {
        let rig = try Rig(nil); defer { rig.cleanup() }
        let p = try await rig.store.capture(rig.draft())
        #expect(context(p).isEmpty)
    }

    @Test func existingKeysNotDuplicated() async throws {
        let box = HookBox(groups: (true, false), last: LastSaved(captureID: "prev", capturedAt: base.addingTimeInterval(-5)))
        let rig = try Rig(box.hooks); defer { rig.cleanup() }
        let existing = [ContextObservations.enabled(deviceContext: false, location: false),
                        MetadataObservation(key: "context.burst", value: .object(["seconds_since_previous": .number(1)]),
                                            provenance: "last_saved")]
        let p = try await rig.store.capture(rig.draft(observations: existing))
        #expect(context(p).filter { $0.key == "context.enabled" }.count == 1)
        #expect(context(p).filter { $0.key == "context.burst" }.count == 1)
        #expect(field(context(p).first { $0.key == "context.enabled" }?.value, "groups") == .array([]))
    }
}
