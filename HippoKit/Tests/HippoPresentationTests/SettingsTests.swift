import Foundation
import Testing
import Synchronization
import CaptureCore
import FilesystemAdapter
import LocalRepository
import SyncEngine
@testable import HippoPresentation

private let start = Date(timeIntervalSince1970: 1_794_081_600)

/// A store, a fake provider whose remote is a temp folder, and the settings stack over them.
@MainActor
private struct Harness {
    let t: TestStore
    let remote: URL
    let provider: FakeStorageProvider
    /// A second account, uploading to `remoteB`.
    let providerB: FakeStorageProvider
    let remoteB: URL
    let coordinator: SyncCoordinator
    let settings: AppSettings
    let suite: String
    let model: SettingsModel

    init(faults: FaultPlan = FaultPlan(), adapter: (@Sendable (Destination) -> any StorageAdapter)? = nil,
         permission: @escaping () async -> Bool = { true }) throws {
        t = try TestStore()
        remote = t.base.appendingPathComponent("Remote", isDirectory: true)
        provider = FakeStorageProvider(root: remote, faults: faults, adapter: adapter)
        remoteB = t.base.appendingPathComponent("RemoteB", isDirectory: true)
        providerB = FakeStorageProvider(root: remoteB, id: "dev-b", kind: "filesystem-b")
        let registry = ProviderRegistry([provider, providerB])
        coordinator = SyncCoordinator(store: t.store, registry: registry, ownerPrefix: "test", appVersion: "0.1.0")
        suite = "hippo-settings-\(UUID().uuidString)"
        settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        model = SettingsModel(store: t.store, registry: registry, coordinator: coordinator, settings: settings,
                              requestLocationPermission: permission)
    }

    func cleanup() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        t.cleanup()
    }

    func states(_ p: CommittedPackage) throws -> [JobState] {
        try t.store.jobs.jobs(captureID: p.metadata.captureID).map(\.state)
    }

    /// Waits until the coordinator has received `n` `syncNow()` calls in total.
    func waitForCalls(_ n: Int) async throws {
        while await coordinator.callsReceived < n { try await Task.sleep(for: .milliseconds(1)) }
    }

    /// The `upload` operations a complete, first-time sync of these packages performs, marker included.
    static func expectedUploads(_ packages: [CommittedPackage]) -> [String] {
        packages.flatMap { p in
            (p.marker.files.map(\.relativePath).filter { $0 != "complete.json" } + ["complete.json"])
                .map { "upload \(p.relativeDirectory)/\($0)" }
        }.sorted()
    }
}

@MainActor
struct SettingsTests {
    @Test func registryUnknownKindIsProviderUnavailable() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        let dropbox = Destination(id: "dbx", providerKind: "dropbox", accountIdentifier: "a", remoteRoot: "/",
                                  displayName: "Dropbox", status: .active)
        let registry = ProviderRegistry([h.provider])
        #expect((registry.provider(kind: "filesystem") as? FakeStorageProvider) === h.provider)
        #expect(registry.provider(kind: "dropbox") == nil)
        #expect(throws: StorageError.permanent(code: "provider_unavailable")) {
            try registry.adapter(for: dropbox)
        }

        // A job bound to a destination this build has no provider for is surfaced, not retried.
        _ = try h.t.store.destinations.connect(dropbox)
        let p = try await h.t.note("hello", at: start)
        let coordinator = SyncCoordinator(store: h.t.store, registry: ProviderRegistry([]), ownerPrefix: "test",
                                          appVersion: "0.1.0")
        let result = await coordinator.syncNow()
        #expect(result.failed == 1)
        let job = try #require(try h.t.store.jobs.jobs(captureID: p.metadata.captureID).first)
        #expect(job.state == .blocked)
        #expect(job.lastErrorCode == "permanent:provider_unavailable")
    }

    @Test func connectBindsUnassignedAndSyncs() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        let p = try await h.t.note("before connecting", at: start)
        await h.model.refresh()
        #expect(h.model.activeDestination == nil)
        #expect(h.model.summary == "1 waiting to upload")

        try await h.model.connect(h.provider)

        #expect(try h.states(p) == [.synced])
        let marker = h.remote.appendingPathComponent(p.relativeDirectory).appendingPathComponent("complete.json")
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(h.model.activeDestination == h.provider.destination)
        #expect(h.model.counts[.synced] == 1)
        #expect(h.model.summary == "All captures synced")
        #expect(FileManager.default.fileExists(atPath: h.t.store.layout.diagnosticsURL.path))
    }

    @Test func coordinatorCoalescesConcurrentCalls() async throws {
        let faults = FaultPlan()
        let h = try Harness(faults: faults)
        defer { h.cleanup() }
        var packages: [CommittedPackage] = []
        for i in 0..<3 { packages.append(try await h.t.note("note \(i)", at: start.addingTimeInterval(Double(i)))) }
        _ = try h.t.store.destinations.connect(h.provider.destination)

        async let a = h.coordinator.syncNow()
        async let b = h.coordinator.syncNow()
        let (ra, rb) = await (a, b)

        let uploads = faults.operations.filter { $0.hasPrefix("upload ") }.sorted()
        #expect(uploads == Harness.expectedUploads(packages))
        #expect(ra.failed == 0 && rb.failed == 0)
        for p in packages { #expect(try h.states(p) == [.synced]) }
        #expect(await h.coordinator.isRunning == false)
    }

    @Test func callsDuringAPassShareOneFollowUpPass() async throws {
        let remote = FileManager.default.temporaryDirectory.appendingPathComponent("hippo-held-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: remote) }
        let held = HeldAdapter(FilesystemAdapter(root: remote))
        let h = try Harness(adapter: { _ in held })
        defer { h.cleanup() }
        for i in 0..<2 { try await h.t.note("note \(i)", at: start.addingTimeInterval(Double(i))) }
        _ = try h.t.store.destinations.connect(h.provider.destination)
        let passes = Mutex(0)
        let observer = NotificationCenter.default.addObserver(forName: SyncCoordinator.passFinished,
                                                              object: h.coordinator, queue: nil) { _ in
            passes.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let first = Task { await h.coordinator.syncNow() }
        await held.started()
        #expect(await h.coordinator.isRunning)
        let second = Task { await h.coordinator.syncNow() }
        let third = Task { await h.coordinator.syncNow() }
        try await h.waitForCalls(3)
        held.release()

        let r1 = await first.value
        let (r2, r3) = await (second.value, third.value)
        #expect(r1.synced == 2)
        #expect(r2.idle && r3.idle)
        #expect(passes.withLock { $0 } == 2)
        #expect(await h.coordinator.isRunning == false)
        #expect(await h.coordinator.isBusy == false)
    }

    @Test func singleSyncNowDrainsMoreThanOnePassOfJobs() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        var packages: [CommittedPackage] = []
        for i in 0..<250 { packages.append(try await h.t.note("note \(i)", at: start.addingTimeInterval(Double(i)))) }
        _ = try h.t.store.destinations.connect(h.provider.destination)

        let result = await h.coordinator.syncNow()

        #expect(result.synced == 250)
        #expect(result.failed == 0)
        for p in packages { #expect(try h.states(p) == [.synced]) }
        #expect(await h.coordinator.isBusy == false)
    }

    @Test func passFinishedIsPostedOnTheMainThread() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.t.note("one", at: start)
        _ = try h.t.store.destinations.connect(h.provider.destination)
        let onMain = Mutex<[Bool]>([])
        let observer = NotificationCenter.default.addObserver(forName: SyncCoordinator.passFinished,
                                                              object: h.coordinator, queue: nil) { _ in
            onMain.withLock { $0.append(Thread.isMainThread) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        _ = await h.coordinator.syncNow()

        #expect(onMain.withLock { $0 } == [true])
    }

    @Test func followUpPassEndsAfterStop() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        var packages: [CommittedPackage] = []
        for i in 0..<250 { packages.append(try await h.t.note("note \(i)", at: start.addingTimeInterval(Double(i)))) }
        _ = try h.t.store.destinations.connect(h.provider.destination)
        let passes = Mutex(0)
        let coordinator = h.coordinator
        let observer = NotificationCenter.default.addObserver(forName: SyncCoordinator.passFinished,
                                                              object: coordinator, queue: nil) { _ in
            passes.withLock { $0 += 1 }
            coordinator.requestStop()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let result = await coordinator.syncNow()

        #expect(passes.withLock { $0 } == 1)
        #expect(result.synced == 200)
        var pending = 0
        for p in packages where try h.states(p) != [.synced] { pending += 1 }
        #expect(pending == 50)
    }

    @Test func stopCancelsRunningPassAndNextCallStillSyncs() async throws {
        let remote = FileManager.default.temporaryDirectory.appendingPathComponent("hippo-held-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: remote) }
        let held = HeldAdapter(FilesystemAdapter(root: remote))
        let h = try Harness(adapter: { _ in held })
        defer { h.cleanup() }
        let interrupted = try await h.t.note("held", at: start)
        _ = try h.t.store.destinations.connect(h.provider.destination)

        let first = Task { await h.coordinator.syncNow() }
        await held.started()
        let waiting = Task { await h.coordinator.syncNow() }
        try await h.waitForCalls(2)
        await h.coordinator.stop()

        let r1 = await first.value
        let r2 = await waiting.value
        #expect(r1.synced == 0 && r2.synced == 0)
        #expect(await h.coordinator.isBusy == false)
        // The interrupted job keeps its lease until it expires; it is not lost.
        #expect(try h.states(interrupted) == [.uploading])

        let later = try await h.t.note("after stop", at: start.addingTimeInterval(1))
        let r3 = await h.coordinator.syncNow()
        #expect(r3.synced == 1)
        #expect(try h.states(later) == [.synced])
        #expect(await h.coordinator.isBusy == false)
    }

    @Test func requestStopCancelsWithoutAwaiting() async throws {
        let remote = FileManager.default.temporaryDirectory.appendingPathComponent("hippo-held-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: remote) }
        let held = HeldAdapter(FilesystemAdapter(root: remote))
        let h = try Harness(adapter: { _ in held })
        defer { h.cleanup() }
        _ = try await h.t.note("held", at: start)
        _ = try h.t.store.destinations.connect(h.provider.destination)

        let first = Task { await h.coordinator.syncNow() }
        await held.started()
        h.coordinator.requestStop()  // synchronous, no await
        let r = await first.value
        #expect(r.synced == 0)
        let deadline = ContinuousClock.now + .seconds(5)
        while await h.coordinator.isBusy {
            #expect(ContinuousClock.now < deadline, "coordinator still busy 5 s after requestStop")
            if ContinuousClock.now >= deadline { break }
            try await Task.sleep(for: .milliseconds(1))
        }

        let later = try await h.t.note("after stop", at: start.addingTimeInterval(1))
        #expect(await h.coordinator.syncNow().synced == 1)
        #expect(try h.states(later) == [.synced])
    }

    @Test func cancelledCallerDoesNotStopSharedPass() async throws {
        let remote = FileManager.default.temporaryDirectory.appendingPathComponent("hippo-held-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: remote) }
        let held = HeldAdapter(FilesystemAdapter(root: remote))
        let h = try Harness(adapter: { _ in held })
        defer { h.cleanup() }
        var packages: [CommittedPackage] = []
        for i in 0..<2 { packages.append(try await h.t.note("note \(i)", at: start.addingTimeInterval(Double(i)))) }
        _ = try h.t.store.destinations.connect(h.provider.destination)

        let first = Task { await h.coordinator.syncNow() }
        await held.started()
        let joinedFollowUp = Task { await h.coordinator.syncNow() }
        let alsoJoined = Task { await h.coordinator.syncNow() }
        try await h.waitForCalls(3)
        first.cancel()
        joinedFollowUp.cancel()
        held.release()

        #expect(await first.value.synced == 2)
        for p in packages { #expect(try h.states(p) == [.synced]) }
        // The follow-up still ran for the caller that was not cancelled.
        #expect(await alsoJoined.value.idle)
        #expect(await joinedFollowUp.value.idle)
        #expect(await h.coordinator.isBusy == false)
    }

    @Test func signOutPausesJobs() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.model.connect(h.provider)
        let bound = try await h.t.note("bound, not yet uploaded", at: start)
        #expect(try h.states(bound) == [.pending])

        try await h.model.signOut()

        #expect(h.provider.signOutCount == 1)
        #expect(try h.states(bound) == [.paused])
        #expect(try h.t.store.destinations.active() == nil)
        #expect(h.model.activeDestination == nil)
        let later = try await h.t.note("after sign-out", at: start.addingTimeInterval(1))
        #expect(try h.states(later).isEmpty)
    }

    @Test func retryAllSyncsBlockedUpload() async throws {
        let faults = FaultPlan()
        let h = try Harness(faults: faults)
        defer { h.cleanup() }
        let p = try await h.t.note("quota", at: start)
        let first = try #require(p.marker.files.first { $0.relativePath != "complete.json" })
        faults.failBeforeWrite("\(p.relativeDirectory)/\(first.relativePath)", .quotaExceeded)
        try await h.model.connect(h.provider)
        #expect(try h.states(p) == [.blocked])
        #expect(h.model.summary == "1 need attention")

        try await h.model.retryAll()

        #expect(try h.states(p) == [.synced])
        #expect(h.model.summary == "All captures synced")
    }

    @Test func uploadExistingCopiesToNewDestination() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        let p = try await h.t.note("first account", at: start)
        try await h.model.connect(h.provider)
        try await h.model.signOut()
        try await h.model.connect(h.providerB)
        // Connecting B never picks up a capture already bound to A.
        #expect(try h.states(p) == [.synced])
        #expect(h.model.activeDestination == h.providerB.destination)

        #expect(try await h.model.uploadExisting() == 1)

        #expect(try h.states(p) == [.synced, .synced])
        let marker = h.remoteB.appendingPathComponent(p.relativeDirectory).appendingPathComponent("complete.json")
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(try await h.model.uploadExisting() == 0)
    }

    @Test func summaryCopy() {
        #expect(SettingsModel.summary(counts: [:]) == "All captures synced")
        #expect(SettingsModel.summary(counts: [.synced: 4, .notSynced: 0, .needsAttention: 0]) == "All captures synced")
        #expect(SettingsModel.summary(counts: [.synced: 4, .notSynced: 3]) == "3 waiting to upload")
        #expect(SettingsModel.summary(counts: [.needsAttention: 1]) == "1 need attention")
        #expect(SettingsModel.summary(counts: [.needsAttention: 2, .notSynced: 5]) == "2 need attention · 5 waiting to upload")
    }

    @Test func storageUsageSumsFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hippo-usage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let nested = dir.appendingPathComponent("a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let files = [dir.appendingPathComponent("one.bin"), nested.appendingPathComponent("two.bin")]
        try Data(count: 10_000).write(to: files[0])
        try Data(count: 70_000).write(to: files[1])
        let expected = try files.reduce(Int64(0)) {
            $0 + Int64(try $1.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? 0)
        }

        #expect(expected >= 80_000)
        #expect(StorageUsage.bytes(under: dir) == expected)
        #expect(StorageUsage.bytes(under: dir.appendingPathComponent("missing")) == 0)
    }

    @Test func locationStaysOffWhenPermissionDenied() async throws {
        let asked = Mutex(0)
        let denied = try Harness(permission: { asked.withLock { $0 += 1 }; return false })
        defer { denied.cleanup() }
        await denied.model.setLocationEnabled(true)
        #expect(asked.withLock { $0 } == 1)
        #expect(denied.model.locationEnabled == false)
        #expect(denied.settings.locationEnabled == false)

        let granted = try Harness(permission: { true })
        defer { granted.cleanup() }
        await granted.model.setLocationEnabled(true)
        #expect(granted.model.locationEnabled)
        #expect(granted.settings.locationEnabled)
        await granted.model.setLocationEnabled(false)
        #expect(granted.model.locationEnabled == false)
        #expect(granted.settings.locationEnabled == false)
    }

    @Test func appSettingsDefaultsLocationOff() throws {
        let suite = "hippo-defaults-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.locationEnabled == false)
        settings.locationEnabled = true
        #expect(defaults.bool(forKey: "location_enabled"))
        #expect(AppSettings(defaults: defaults).locationEnabled)
    }
}
