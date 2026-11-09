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
         permission: @escaping () async -> Bool = { true }, online: Bool = true,
         onEnrichmentEnabled: @escaping @Sendable (FacetKind) async -> Void = { _ in }) throws {
        t = try TestStore()
        remote = t.base.appendingPathComponent("Remote", isDirectory: true)
        provider = FakeStorageProvider(root: remote, faults: faults, adapter: adapter)
        remoteB = t.base.appendingPathComponent("RemoteB", isDirectory: true)
        providerB = FakeStorageProvider(root: remoteB, id: "dev-b", kind: "filesystem-b")
        let registry = ProviderRegistry([provider, providerB])
        suite = "hippo-settings-\(UUID().uuidString)"
        settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        coordinator = SyncCoordinator(store: t.store, registry: registry, ownerPrefix: "test", appVersion: "0.1.0",
                                      settings: settings)
        model = SettingsModel(store: t.store, registry: registry, coordinator: coordinator, settings: settings,
                              requestLocationPermission: permission, onEnrichmentEnabled: onEnrichmentEnabled,
                              isOnline: { online }, now: { Date(timeIntervalSince1970: 1_800_000_000) }, locale: Locale(identifier: "en_US"))
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
    @Test func switchChangeIsLogged() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        await h.model.setEnrichment(.transcript, on: false)
        await h.model.setLocationEnabled(true)
        let events = h.t.store.log.globalEvents(limit: 10, before: nil).filter { $0.event == .settingsChanged }.reversed()
        #expect(events.map(\.kind) == ["transcript", "location"])
        #expect(events.map(\.on) == [false, true])
    }

    @Test func layerStripesSwitchIsStoredAndLogged() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        #expect(h.model.showsLayerStripes)
        h.model.setShowsLayerStripes(false)
        #expect(!h.model.showsLayerStripes)
        #expect(!h.settings.showsLayerStripes)
        h.model.setShowsLayerStripes(true)
        let events = h.t.store.log.globalEvents(limit: 10, before: nil).filter { $0.event == .settingsChanged }.reversed()
        #expect(events.map(\.kind) == ["layer_stripes", "layer_stripes"])
        #expect(events.map(\.on) == [false, true])
    }

    @Test func developerModeToggleIsLogged() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        #expect(!h.model.developerMode)
        h.model.setDeveloperMode(true)
        #expect(h.model.developerMode)
        #expect(h.settings.developerMode)
        h.model.setDeveloperMode(false)
        #expect(!h.settings.developerMode)
        let events = h.t.store.log.globalEvents(limit: 10, before: nil).filter { $0.event == .settingsChanged }.reversed()
        #expect(events.map(\.kind) == ["developer_mode", "developer_mode"])
        #expect(events.map(\.on) == [true, false])
    }

    @Test func syncPassIsLoggedWithTrigger() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        _ = await h.coordinator.syncNow(trigger: "launch")
        let passes = h.t.store.log.globalEvents(limit: 10, before: nil).filter { $0.event == .syncPass }.reversed()
        #expect(passes.map(\.phase) == ["start", "end"])
        #expect(passes.allSatisfy { $0.trigger == "launch" })
        #expect(passes.last?.code == "ok")
        #expect(passes.last?.count == 0)
    }

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
                                          appVersion: "0.1.0",
                                          settings: AppSettings(defaults: UserDefaults(suiteName: "hippo-x-\(UUID().uuidString)")!))
        let result = await coordinator.syncNow()
        #expect(result.failed == 1)
        let job = try #require(try h.t.store.jobs.jobs(captureID: p.metadata.captureID).first)
        #expect(job.state == .blocked)
        #expect(job.lastErrorCode == "permanent:provider_unavailable")
    }

    @Test func statusSummaryCounts() async throws {
        let h = try Harness(online: false); defer { h.cleanup() }
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        var ids: [String] = []
        for n in 0..<5 { ids.append(try await h.t.note("n\(n)", at: at.addingTimeInterval(Double(n))).metadata.captureID) }
        let tasks = h.t.store.enrichmentTasks
        for id in ids.prefix(2) { try tasks.set(captureID: id, kind: .dataDetection, version: 1, status: "pending", now: at) }
        // Offline: a due network row with no stored code or retry time.
        try tasks.set(captureID: ids[2], kind: .linkPreview, version: 1, status: "pending", now: at)
        // Deferred for another reason.
        try tasks.set(captureID: ids[3], kind: .place, version: 1, status: "pending", now: at)
        try tasks.recordAttempt(captureID: ids[3], kind: .place, status: "pending", errorCode: "throttled",
                                nextAttemptAt: at.addingTimeInterval(300), incrementAttempts: true, now: at)
        try tasks.set(captureID: ids[4], kind: .transcript, version: 1, status: "failed", now: at)
        h.settings.recordSync(at: at.addingTimeInterval(-120), failed: false)
        await h.model.refresh()
        #expect(h.model.statusSummary == "Last sync 2 minutes ago · 2 being processed · 1 waiting for a connection · 1 waiting to retry · 1 couldn't be processed")
        h.settings.recordSync(at: at.addingTimeInterval(-120), failed: true)
        await h.model.refresh()
        #expect(h.model.statusSummary?.hasPrefix("Last sync 2 minutes ago · didn't finish · 2 being processed") == true)
    }

    @Test func statusSummaryNeverAndZeroCountsOmitted() async throws {
        let h = try Harness(); defer { h.cleanup() }
        await h.model.refresh()
        #expect(h.model.statusSummary == "Last sync never")
    }

    @Test func installIDIsStable() throws {
        let h = try Harness(); defer { h.cleanup() }
        let a = h.settings.installID, b = h.settings.installID
        #expect(a == b)
        #expect(a == a.lowercased())
        #expect(UUID(uuidString: a) != nil)
    }

    @Test func defaultsForNewSettings() throws {
        let h = try Harness(); defer { h.cleanup() }
        #expect(h.settings.showsLayerStripes)
        #expect(!h.settings.developerMode)
        #expect(h.settings.lastSync == nil)
    }

    @Test func syncUploadsLogsAndRecordsLastSync() async throws {
        let h = try Harness(); defer { h.cleanup() }
        _ = try h.t.store.destinations.connect(h.provider.destination)
        _ = await h.coordinator.syncNow()
        var isDir: ObjCBool = false
        let dir = h.remote.appendingPathComponent("logs/\(h.settings.installID)").path
        #expect(FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) && isDir.boolValue)
        let last = try #require(h.settings.lastSync)
        #expect(!last.failed)
    }

    // M9: a pass with no active destination synced nothing, so it must not read as "Last sync just now".
    @Test func syncWithoutDestinationDoesNotRecordLastSync() async throws {
        let h = try Harness(); defer { h.cleanup() }
        _ = await h.coordinator.syncNow()
        #expect(h.settings.lastSync == nil)
        await h.model.refresh()
        #expect(h.model.statusSummary == "Last sync never")
    }

    @Test func reviewPendingInSummary() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        let dest = h.provider.destination
        _ = try h.t.store.destinations.connect(dest)
        let p = try await h.t.note("looks different", at: start)
        try h.t.store.remoteState.addReviewItems([
            ReviewItem(captureID: p.metadata.captureID, destinationID: dest.id, reason: "threshold", createdAt: start)])
        await h.model.refresh()
        #expect(h.model.reviewPending == 1)
        #expect(h.model.summary.hasSuffix("\(dest.displayName) looks different · review"))
        try h.t.store.remoteState.clearReview(destinationID: dest.id)
        await h.model.refresh()
        #expect(h.model.reviewPending == 0)
        #expect(!h.model.summary.contains("looks different"))
        #expect(SettingsModel.summary(counts: [.notSynced: 1], reviewPending: 2, destinationName: "Dropbox")
                == "1 waiting to upload · Dropbox looks different · review")
    }

    @Test func trimmedTotalsFeedDisconnectPrompt() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        let dest = h.provider.destination
        _ = try h.t.store.destinations.connect(dest)
        let p = try await h.t.note("big", at: start)
        await h.model.refresh()
        #expect(h.model.trimmedTotals.captures == 0)
        #expect(h.model.disconnectPrompt(name: "Dropbox")
                == "Disconnect Dropbox? Nothing is deleted on this iPhone or in Dropbox.")
        let a = try #require(p.metadata.attachments.first)
        try h.t.store.trims.record(TrimmedAttachment(captureID: p.metadata.captureID, attachmentID: a.attachmentID,
                                                     relativePath: a.relativePath, byteCount: 4_000, sha256: "x",
                                                     destinationID: dest.id, state: .trimmed, trimmedAt: start))
        await h.model.refresh()
        #expect(h.model.trimmedTotals.captures == 1 && h.model.trimmedTotals.bytes == 4_000)
        #expect(h.model.disconnectPrompt(name: "Dropbox")
                == "Disconnect Dropbox? Nothing is deleted on this iPhone or in Dropbox. Files kept only in Dropbox can't be downloaded until you reconnect.")
    }

    @Test func needsSignInShowsInSummary() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        let dest = h.provider.destination
        _ = try h.t.store.destinations.connect(dest)
        await h.model.refresh()
        #expect(h.model.accountStatus == .ok)
        #expect(!h.model.needsReconnect)
        #expect(!h.model.summary.contains("Sign in again"))

        h.provider.setAccountStatus(.needsSignIn)
        await h.model.refresh()
        #expect(h.model.accountStatus == .needsSignIn)
        #expect(h.model.needsReconnect)
        #expect(h.model.summary.contains("Sign in again to Developer folder"))

        // A job that failed for lack of sign-in says so too, even while the provider reports `.ok`.
        h.provider.setAccountStatus(.ok)
        let p = try await h.t.note("waiting for sign-in", at: start)
        let job = try #require(try h.t.store.jobs.claimNext(owner: "w", now: Date(), lease: 60))
        #expect(job.captureID == p.metadata.captureID)
        try h.t.store.jobs.markFailed(jobID: job.jobID, owner: "w", state: .needsAuthentication,
                                      errorCode: "needs_authentication", nextAttemptAt: nil)
        await h.model.refresh()
        #expect(h.model.accountStatus == .ok)
        #expect(h.model.needsReconnect)
        #expect(h.model.summary.contains("Sign in again to Developer folder"))
        #expect(SettingsModel.summary(counts: [:], pendingRemoteDeletes: 1, needsSignIn: true, reviewPending: 1,
                                      destinationName: "Dropbox")
                == "1 delete waiting to reach Dropbox · Sign in again to Dropbox · Dropbox looks different · review")
    }

    @Test func refreshReadsTheAccountNameApartFromTheDestinationName() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        try await h.model.connect(h.provider)
        #expect(h.model.accountName == nil)

        h.provider.setAccountName("Sample Holder")
        await h.model.refresh()
        #expect(h.model.accountName == "Sample Holder")
        // Every `<name>` slot keeps reading the destination's (provider's) name.
        #expect(h.model.activeDestination?.displayName == "Developer folder")
        #expect(h.model.disconnectPrompt(name: "Developer folder")
                == "Disconnect Developer folder? Nothing is deleted on this iPhone or in Developer folder.")

        try await h.model.signOut()
        #expect(h.model.accountName == nil)

        // Provider-specific connect behaviour defaults off (Dropbox turns both on).
        let provider: any StorageProvider = h.provider
        #expect(!provider.explainsBeforeConnect)
        #expect(!provider.isUserCancellation(CancellationError()))
    }

    @Test func connectAndDisconnectAreLogged() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        #expect(SettingsModel.connectTitle(h.provider) == "Connect Developer folder")
        try await h.model.connect(h.provider)
        try await h.model.signOut()
        let all = h.t.store.log.globalEvents(limit: 100, before: nil)
        let auth = all.filter { [.authConnected, .authDisconnected].contains($0.event) }.reversed()
        #expect(auth.map(\.event) == [.authConnected, .authDisconnected])
        #expect(auth.allSatisfy { $0.dest == "filesystem" })
        let dest = h.provider.destination
        for e in all {
            let line = String(decoding: try JSONEncoder().encode(e), as: UTF8.self).lowercased()
            #expect(!line.contains(dest.displayName.lowercased()), "\(e.event)")
            #expect(!line.contains(dest.accountIdentifier.lowercased()), "\(e.event)")
        }
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

    @Test func pendingDeletesInSummary() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        _ = try h.t.store.destinations.connect(h.provider.destination)
        let dest = h.provider.destination
        for id in ["a", "b"] {
            try h.t.store.remoteState.addTombstone(captureID: id, relativeDirectory: "captures/2026/11/08/\(id)",
                                                   destinationID: dest.id, accountIdentifier: dest.accountIdentifier,
                                                   now: Date())
        }
        await h.model.refresh()
        #expect(h.model.pendingRemoteDeletes == 2)
        #expect(h.model.summary == "2 deletes waiting to reach \(dest.displayName)")
        try h.t.store.remoteState.removeTombstone(captureID: "b")
        await h.model.refresh()
        #expect(h.model.summary == "1 delete waiting to reach \(dest.displayName)")
        #expect(SettingsModel.summary(counts: [.notSynced: 1], pendingRemoteDeletes: 1, destinationName: "Dropbox")
                == "1 waiting to upload · 1 delete waiting to reach Dropbox")
    }

    @Test func passUploadsSilverAfterPackagesWithoutChangingTheResult() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        let p = try await h.t.note("with silver", at: start)
        _ = try h.t.store.destinations.connect(h.provider.destination)
        let digest = try #require(try h.t.store.index.packageDigest(captureID: p.metadata.captureID))
        let facet = Facet(version: 1, status: .ok, generatedAt: start, provenance: "test",
                          data: .object(["text": .string("hello")]))
        try h.t.store.enrichments.write(
            EnrichmentDocument(schemaVersion: 1, captureID: p.metadata.captureID, layer: .device, packageDigest: digest,
                               producer: EnrichmentProducer(name: "t", version: "1", build: "1"), generatedAt: start,
                               facets: [FacetKind.summary.rawValue: facet]), newAssets: [:])

        let result = await h.coordinator.syncNow()

        // Only the package counts toward the result.
        #expect(result.synced == 1 && result.failed == 0)
        let directory = try EnrichmentPaths.remoteDirectory(.device, packageDirectory: p.relativeDirectory)
        let remoteDoc = h.remote.appendingPathComponent(directory).appendingPathComponent("enrichment.json")
        #expect(FileManager.default.fileExists(atPath: remoteDoc.path))
        #expect(try h.t.store.enrichments.uploadCandidates(destinationID: h.provider.destination.id, now: Date(),
                                                           limit: 10).isEmpty)
    }

    @Test func passDrainsSilverBacklogInBoundedBatches() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        let extra = 7
        let count = SyncCoordinator.maxUploadRounds * 20 + extra   // 20 captures per uploader round
        var packages: [CommittedPackage] = []
        for i in 0..<count { packages.append(try await h.t.note("note \(i)", at: start.addingTimeInterval(Double(i)))) }
        _ = try h.t.store.destinations.connect(h.provider.destination)
        // Packages first, with no silver yet, so the next pass has silver to upload and no package work.
        #expect(await h.coordinator.syncNow().synced == count)
        for p in packages {
            let digest = try #require(try h.t.store.index.packageDigest(captureID: p.metadata.captureID))
            try h.t.store.enrichments.write(
                EnrichmentDocument(schemaVersion: 1, captureID: p.metadata.captureID, layer: .device,
                                   packageDigest: digest, producer: EnrichmentProducer(name: "t", version: "1", build: "1"),
                                   generatedAt: start,
                                   facets: [FacetKind.summary.rawValue: Facet(version: 1, status: .ok, generatedAt: start,
                                                                               provenance: "test", data: nil)]),
                newAssets: [:])
        }
        func pending() throws -> Int {
            try h.t.store.enrichments.uploadCandidates(destinationID: h.provider.destination.id, now: Date(),
                                                       limit: 10_000).count
        }
        #expect(try pending() == count)

        // One pass uploads many batches, but stops after `maxUploadRounds` of them.
        let result = await h.coordinator.syncNow()
        #expect(result == SyncPassResult(synced: 0, failed: 0, idle: true))   // silver never counts
        #expect(try pending() == extra)

        _ = await h.coordinator.syncNow()
        #expect(try pending() == 0)
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

    @Test func coordinatorExposesNextRetry() async throws {
        let faults = FaultPlan()
        let h = try Harness(faults: faults)
        defer { h.cleanup() }
        #expect(await h.coordinator.nextRetryAt() == nil)
        let p = try await h.t.note("offline", at: start)
        let first = try #require(p.marker.files.first { $0.relativePath != "complete.json" })
        faults.failBeforeWrite("\(p.relativeDirectory)/\(first.relativePath)", .offline)
        _ = try h.t.store.destinations.connect(h.provider.destination)
        _ = await h.coordinator.syncNow()
        #expect(try h.states(p) == [.retryableFailure])
        let next = try #require(await h.coordinator.nextRetryAt())
        #expect(next > Date())
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

    @Test func enrichmentDefaultsOn() throws {
        let suite = "hippo-defaults-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        for item in SettingsModel.enrichmentSwitches { #expect(settings.isEnrichmentEnabled(item.kind)) }
    }

    @Test func turningOnTriggersBackfill() async throws {
        let calls = Mutex<[String]>([])
        let h = try Harness(onEnrichmentEnabled: { kind in calls.withLock { $0.append(kind.rawValue) } })
        defer { h.cleanup() }
        await h.model.setEnrichment(.place, on: false)
        #expect(calls.withLock { $0 }.isEmpty)
        #expect(h.settings.isEnrichmentEnabled(.place) == false)
        await h.model.setEnrichment(.place, on: true)
        #expect(calls.withLock { $0 } == ["place"])
        #expect(h.settings.isEnrichmentEnabled(.place))
    }

    @Test func switchCopyExact() {
        #expect(SettingsModel.enrichmentSwitches.map(\.title) == [
            "Link previews", "Place names", "Text in images", "Voice note transcripts",
            "Dates, phone numbers and addresses", "App guesses"])
        #expect(SettingsModel.enrichmentSwitches.map(\.kind) == [
            .linkPreview, .place, .textRecognition, .transcript, .dataDetection, .sourceAppGuess])
        #expect(SettingsModel.enrichmentFooter == "Link previews fetch the page title and picture from the website. Place names are looked up with Apple Maps. Everything else runs on this iPhone.")
    }
}
