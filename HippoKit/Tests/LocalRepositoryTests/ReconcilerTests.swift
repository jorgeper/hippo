import Foundation
import Testing
import CaptureCore
@testable import LocalRepository

private struct Rig {
    let h: IndexHarness
    let jobs: JobStore
    let destinations: DestinationStore
    let reconciler: Reconciler

    init() throws {
        h = try IndexHarness()
        jobs = JobStore(db: h.db)
        destinations = DestinationStore(db: h.db)
        reconciler = Reconciler(layout: h.layout, index: h.index, jobs: jobs, destinations: destinations)
    }

    /// Commits without registering: a crash between rename and index insert.
    func commitOnly(note: String = "n") async throws -> CommittedPackage {
        let draft = CaptureDraft(captureID: UUID(), startedAt: Date(timeIntervalSince1970: 1_794_070_800), timeZone: h.zone,
                                 method: .typedNote, userNote: note, sharedTitle: nil, sharedText: nil, urls: [],
                                 attachments: [], location: nil)
        return try await h.writer.commit(draft)
    }

    func staging(_ id: String) throws -> URL {
        let dir = h.layout.stagingDir.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("partial"))
        return dir
    }
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

@Suite struct ReconcilerTests {
    @Test func crashAfterCommitBeforeIndexRecoversExactlyOnce() async throws {
        let r = try Rig(); defer { r.h.cleanup() }
        _ = try r.destinations.connect(Destination(id: "d", providerKind: "filesystem", accountIdentifier: "a",
                                                    remoteRoot: "/H", displayName: "A", status: .active))
        let pkg = try await r.commitOnly()
        #expect(try r.reconciler.run().registered == 1)
        #expect(try r.reconciler.run().registered == 0)
        #expect(try r.h.index.count() == 1)
        #expect(try r.jobs.jobs(captureID: pkg.metadata.captureID).count == 1)
    }

    @Test func abandonedStagingIsRemoved() throws {
        let r = try Rig(); defer { r.h.cleanup() }
        let id = UUID().uuidString.lowercased()
        let dir = try r.staging(id)
        let orphanLock = r.h.layout.stagingDir.appendingPathComponent("orphan.lock")
        try Data().write(to: orphanLock)
        let report = try r.reconciler.run()
        #expect(report.removedStaging == 1)
        #expect(!exists(dir))
        #expect(!exists(r.h.layout.stagingDir.appendingPathComponent("\(id).lock")))
        #expect(!exists(orphanLock))
    }

    @Test func lockedStagingIsKept() throws {
        let r = try Rig(); defer { r.h.cleanup() }
        let id = UUID().uuidString.lowercased()
        let dir = try r.staging(id)
        let lock = try StagingLock.acquire(at: r.h.layout.stagingDir.appendingPathComponent("\(id).lock"))
        #expect(try r.reconciler.run().removedStaging == 0)
        #expect(exists(dir))
        lock.release()
        #expect(try r.reconciler.run().removedStaging == 1)
        #expect(!exists(dir))
    }

    @Test func invalidPackageIsCountedNotDeleted() async throws {
        let r = try Rig(); defer { r.h.cleanup() }
        let pkg = try await r.commitOnly()
        // Wrong date directory: a complete package at the wrong path.
        let wrong = r.h.layout.capturesDir.appendingPathComponent("2020/01/01", isDirectory: true)
        try FileManager.default.createDirectory(at: wrong, withIntermediateDirectories: true)
        let moved = wrong.appendingPathComponent(pkg.metadata.captureID)
        try FileManager.default.moveItem(at: pkg.directoryURL, to: moved)
        // Junk and an empty partition.
        try FileManager.default.createDirectory(at: r.h.layout.capturesDir.appendingPathComponent("2021/05/05"),
                                                withIntermediateDirectories: true)
        try Data().write(to: r.h.layout.capturesDir.appendingPathComponent(".DS_Store"))
        // A package with no marker.
        let partial = wrong.appendingPathComponent(UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)

        let report = try r.reconciler.run()
        #expect(report.invalidPackages == 2)
        #expect(report.registered == 0)
        #expect(exists(moved) && exists(partial))
        #expect(try r.h.index.count() == 0)
    }

    @Test func orphanRowsAreRemoved() async throws {
        let r = try Rig(); defer { r.h.cleanup() }
        _ = try r.destinations.connect(Destination(id: "d", providerKind: "filesystem", accountIdentifier: "a",
                                                    remoteRoot: "/H", displayName: "A", status: .active))
        let pkg = try await r.h.add(note: "gone")
        try r.jobs.enqueueIfActive(captureID: pkg.metadata.captureID)
        try FileManager.default.removeItem(at: pkg.directoryURL)
        let report = try r.reconciler.run()
        #expect(report.orphanedIndexRows == 1)
        #expect(try r.h.index.count() == 0)
        #expect(try r.jobs.jobs(captureID: pkg.metadata.captureID).isEmpty)
    }

    @Test func unassignedCapturesBindToActiveDestination() async throws {
        let r = try Rig(); defer { r.h.cleanup() }
        let early = try await r.h.add(note: "early")
        #expect(try r.reconciler.run().boundToActive == 0)
        _ = try r.destinations.connect(Destination(id: "d", providerKind: "filesystem", accountIdentifier: "a",
                                                    remoteRoot: "/H", displayName: "A", status: .active))
        _ = try r.h.db.execute("DELETE FROM jobs")
        #expect(try r.reconciler.run().boundToActive == 1)
        #expect(try r.jobs.jobs(captureID: early.metadata.captureID).count == 1)
        #expect(try r.reconciler.run().boundToActive == 0)
    }

    @Test func oneFailingPackageDoesNotStopTheRest() async throws {
        let r = try Rig(); defer { r.h.cleanup() }
        let dest = Destination(id: "d", providerKind: "filesystem", accountIdentifier: "a", remoteRoot: "/H",
                               displayName: "A", status: .active)
        // Captures from before any destination existed, so the bind step has work to do.
        let early = try await r.h.add(note: "early")
        _ = try r.destinations.connect(dest)
        try r.h.db.execute("DELETE FROM jobs")
        let bad = try await r.commitOnly(note: "bad")
        let good = try await r.commitOnly(note: "good")
        // Registering the first one fails inside the index.
        try r.h.db.execute("""
            CREATE TRIGGER boom BEFORE INSERT ON captures WHEN NEW.capture_id = '\(bad.metadata.captureID)'
            BEGIN SELECT RAISE(ABORT, 'boom'); END
            """)
        let staging = try r.staging(UUID().uuidString.lowercased())

        let report = try r.reconciler.run()

        #expect(report.failed == 1)
        #expect(report.registered == 1)
        #expect(report.removedStaging == 1 && !exists(staging))
        #expect(report.boundToActive == 1)
        #expect(try r.jobs.jobs(captureID: good.metadata.captureID).count == 1)
        #expect(try r.jobs.jobs(captureID: early.metadata.captureID).count == 1)
        #expect(try r.jobs.jobs(captureID: bad.metadata.captureID).isEmpty)
    }

    @Test func leftoverLockWithoutDirectoryIsNotAFailure() throws {
        let r = try Rig(); defer { r.h.cleanup() }
        try FileManager.default.createDirectory(at: r.h.layout.stagingDir, withIntermediateDirectories: true)
        // A lock file with no directory is the state a finished writer leaves behind.
        try Data().write(to: r.h.layout.stagingDir.appendingPathComponent("gone.lock"))
        let report = try r.reconciler.run()
        #expect(report.failed == 0 && report.removedStaging == 0)
    }

    // M7: a log upload snapshot (`staging/log-<uuid>.jsonl`) left by an app killed mid-upload is removed.
    // Other plain files in staging are left alone.
    @Test func strayLogSnapshotIsRemoved() throws {
        let r = try Rig(); defer { r.h.cleanup() }
        let staging = r.h.layout.stagingDir
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let snapshot = staging.appendingPathComponent("log-\(UUID().uuidString.lowercased()).jsonl")
        try Data(repeating: 0x41, count: 1_024).write(to: snapshot)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3_600)],
                                              ofItemAtPath: snapshot.path)
        let other = staging.appendingPathComponent("notes.jsonl")
        try Data().write(to: other)
        let report = try r.reconciler.run()
        #expect(!exists(snapshot))
        #expect(exists(other))
        #expect(report.removedStaging == 1 && report.failed == 0)
    }

    // Recovery runs alongside the first sync pass, so a fresh snapshot may belong to a live upload.
    @Test func freshLogSnapshotIsKept() throws {
        let r = try Rig(); defer { r.h.cleanup() }
        let staging = r.h.layout.stagingDir
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let snapshot = staging.appendingPathComponent("log-\(UUID().uuidString.lowercased()).jsonl")
        try Data(repeating: 0x41, count: 1_024).write(to: snapshot)
        let report = try r.reconciler.run()
        #expect(exists(snapshot))
        #expect(report.removedStaging == 0 && report.failed == 0)
    }

    @Test func failedIndexedListingIsCounted() async throws {
        let r = try Rig(); defer { r.h.cleanup() }
        _ = try await r.commitOnly()
        try r.h.db.execute("DROP TABLE captures")
        let report = try r.reconciler.run()
        #expect(report.failed == 3)
    }
}
