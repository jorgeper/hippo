import Foundation
import Testing
import CaptureCore
@testable import LocalRepository

private func destination(_ id: String, account: String) -> Destination {
    Destination(id: id, providerKind: "filesystem", accountIdentifier: account, remoteRoot: "/Hippo",
                displayName: "Account \(account)", status: .active)
}

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// A harness with destination and job stores on the index harness's database.
private struct Stores {
    let h: IndexHarness
    let destinations: DestinationStore
    let jobs: JobStore

    init() throws {
        h = try IndexHarness()
        destinations = DestinationStore(db: h.db)
        jobs = JobStore(db: h.db)
    }

    /// Commits and registers a capture, then enqueues it as the app does. Returns its capture ID.
    func capture(_ note: String = "note") async throws -> String {
        let id = try await h.add(note: note).metadata.captureID
        try jobs.enqueueIfActive(captureID: id)
        return id
    }

    func status(_ destinationID: String) throws -> String? {
        try h.db.query("SELECT status FROM destinations WHERE destination_id = ?", [.text(destinationID)]).first?
            .string("status")
    }

    func lease(_ jobID: String) throws -> (owner: String?, expires: Int64?) {
        let r = try h.db.query("SELECT lease_owner, lease_expires_at_ms FROM jobs WHERE job_id = ?", [.text(jobID)])[0]
        return (r.string("lease_owner"), r.int("lease_expires_at_ms"))
    }
}

@Suite struct DestinationJobTests {
    @Test func captureBeforeAnyAccountIsUnassignedThenBoundOnConnect() async throws {
        let s = try Stores(); defer { s.h.cleanup() }
        let early = try await s.capture("before any account")
        #expect(try s.destinations.active() == nil)
        #expect(try s.jobs.jobs(captureID: early).isEmpty)

        let a = destination("dest-a", account: "a@example.com")
        #expect(try s.destinations.connect(a) == 1)
        #expect(try s.destinations.active() == a)
        let bound = try s.jobs.jobs(captureID: early)
        #expect(bound.count == 1)
        #expect(bound[0].destinationID == "dest-a")
        #expect(bound[0].state == .pending)
        #expect(bound[0].attemptCount == 0)
        #expect(bound[0].jobID == bound[0].jobID.lowercased())
        #expect(UUID(uuidString: bound[0].jobID) != nil)

        // A capture made while connected is enqueued directly; re-enqueueing is a no-op.
        let later = try await s.capture("after connect")
        try s.jobs.enqueueIfActive(captureID: later)
        #expect(try s.jobs.jobs(captureID: later).map(\.destinationID) == ["dest-a"])

        // Reconnecting creates nothing new.
        #expect(try s.destinations.connect(a) == 0)
        #expect(try s.jobs.jobs(captureID: early) == bound)
    }

    @Test func accountBNeverPicksUpAccountAJobs() async throws {
        let s = try Stores(); defer { s.h.cleanup() }
        let a = destination("dest-a", account: "a@example.com")
        let b = destination("dest-b", account: "b@example.com")

        // 1. Connect A, register a capture, and A gets a job.
        _ = try s.destinations.connect(a)
        let capture = try await s.capture()
        let aJob = try #require(try s.jobs.jobs(captureID: capture).first)
        #expect(aJob.destinationID == "dest-a")

        // 2. Sign out of A. A's job is paused.
        try s.destinations.signOut(destinationID: "dest-a")
        #expect(try s.status("dest-a") == "signed_out")
        #expect(try s.destinations.active() == nil)
        #expect(try s.jobs.jobs(captureID: capture).map(\.state) == [.paused])

        // A capture made while signed out is unassigned.
        let orphan = try await s.capture("while signed out")
        #expect(try s.jobs.jobs(captureID: orphan).isEmpty)

        // 3. Connect B. B has 0 jobs for that capture, and A's job is still paused.
        #expect(try s.destinations.connect(b) == 1)  // only the unassigned capture
        #expect(try s.destinations.active() == b)
        let afterB = try s.jobs.jobs(captureID: capture)
        #expect(afterB.count == 1)
        #expect(afterB[0].jobID == aJob.jobID)
        #expect(afterB[0].destinationID == "dest-a")
        #expect(afterB[0].state == .paused)
        #expect(try s.jobs.jobs(captureID: orphan).map(\.destinationID) == ["dest-b"])
        // B's worker can only ever claim B's job.
        let claimed = try #require(try s.jobs.claimNext(owner: "w", now: t0, lease: 60))
        #expect(claimed.destinationID == "dest-b")
        #expect(try s.jobs.claimNext(owner: "w", now: t0, lease: 60) == nil)

        // 4. Reconnect A. A's job is pending, and B is no longer active.
        #expect(try s.destinations.connect(a) == 0)
        #expect(try s.jobs.jobs(captureID: capture).map(\.state) == [.pending])
        #expect(try s.status("dest-b") == "disabled")
        #expect(try s.destinations.active() == a)
    }

    @Test func signOutPausesInFlightJobsAndRevokesLease() async throws {
        let s = try Stores(); defer { s.h.cleanup() }
        _ = try s.destinations.connect(destination("dest-a", account: "a"))
        let ids = [try await s.capture("1"), try await s.capture("2"), try await s.capture("3")]
        let uploading = try #require(try s.jobs.claimNext(owner: "w", now: t0, lease: 60))
        let failing = try #require(try s.jobs.claimNext(owner: "w", now: t0, lease: 60))
        try s.jobs.markFailed(jobID: failing.jobID, owner: "w", state: .needsAuthentication, errorCode: "auth",
                              nextAttemptAt: nil)

        try s.destinations.signOut(destinationID: "dest-a")
        for id in ids { #expect(try s.jobs.jobs(captureID: id).map(\.state) == [.paused]) }
        #expect(try s.lease(uploading.jobID).owner == nil)
        #expect(throws: JobError.leaseLost) { try s.jobs.markSynced(jobID: uploading.jobID, owner: "w") }
        #expect(try s.jobs.claimNext(owner: "w", now: t0, lease: 60) == nil)
    }

    @Test func reusedDestinationIDForAnotherAccountIsRejected() async throws {
        let s = try Stores(); defer { s.h.cleanup() }
        _ = try s.destinations.connect(destination("x", account: "a"))
        let id = try await s.capture()
        try s.destinations.signOut(destinationID: "x")

        #expect(throws: DestinationError.accountMismatch) {
            try s.destinations.connect(destination("x", account: "b"))
        }
        let otherProvider = Destination(id: "x", providerKind: "other", accountIdentifier: "a", remoteRoot: "/Hippo",
                                        displayName: "Account a", status: .active)
        #expect(throws: DestinationError.accountMismatch) { try s.destinations.connect(otherProvider) }
        #expect(try s.jobs.jobs(captureID: id).map(\.state) == [.paused])
        #expect(try s.status("x") == "signed_out")
        let row = try s.h.db.query("SELECT account_identifier, provider_kind FROM destinations WHERE destination_id = 'x'")[0]
        #expect(row.string("account_identifier") == "a")
        #expect(row.string("provider_kind") == "filesystem")

        // The same account may update its root and display name.
        let renamed = Destination(id: "x", providerKind: "filesystem", accountIdentifier: "a", remoteRoot: "/Hippo2",
                                  displayName: "Renamed", status: .active)
        #expect(try s.destinations.connect(renamed) == 0)
        #expect(try s.destinations.active() == renamed)
        #expect(try s.jobs.jobs(captureID: id).map(\.state) == [.pending])
    }

    @Test func connectResumesNeedsAuthenticationJobs() async throws {
        let s = try Stores(); defer { s.h.cleanup() }
        let a = destination("dest-a", account: "a")
        _ = try s.destinations.connect(a)
        let id = try await s.capture()
        let job = try #require(try s.jobs.claimNext(owner: "w", now: t0, lease: 60))
        try s.jobs.markFailed(jobID: job.jobID, owner: "w", state: .needsAuthentication, errorCode: "auth",
                              nextAttemptAt: t0.addingTimeInterval(3600))

        _ = try s.destinations.connect(a)
        let resumed = try s.jobs.jobs(captureID: id)[0]
        #expect(resumed.state == .pending)
        #expect(resumed.nextAttemptAt == nil)
        #expect(try s.jobs.claimNext(owner: "w", now: t0, lease: 60)?.jobID == job.jobID)
    }

    @Test func backfillCreatesNewJobsOnly() async throws {
        let s = try Stores(); defer { s.h.cleanup() }
        _ = try s.destinations.connect(destination("dest-a", account: "a"))
        let c1 = try await s.capture("1")
        let c2 = try await s.capture("2")
        let first = try #require(try s.jobs.claimNext(owner: "w", now: t0, lease: 60))
        try s.jobs.markSynced(jobID: first.jobID, owner: "w")
        try s.destinations.signOut(destinationID: "dest-a")
        let aBefore = try [c1, c2].flatMap { try s.jobs.jobs(captureID: $0) }

        _ = try s.destinations.connect(destination("dest-b", account: "b"))
        let c3 = try await s.capture("3")  // enqueued for B directly
        #expect(try s.destinations.backfill(destinationID: "dest-b") == 2)
        #expect(try s.destinations.backfill(destinationID: "dest-b") == 0)

        for id in [c1, c2] {
            let jobs = try s.jobs.jobs(captureID: id)
            #expect(jobs.map(\.destinationID) == ["dest-a", "dest-b"])
            #expect(jobs[1].state == .pending)
        }
        #expect(try s.jobs.jobs(captureID: c3).map(\.destinationID) == ["dest-b"])
        // A's jobs are untouched: one synced, one paused.
        let aAfter = try [c1, c2].compactMap { try s.jobs.jobs(captureID: $0).first }
        #expect(aAfter == aBefore)
        #expect(Set(aAfter.map(\.state)) == [.synced, .paused])
    }

    @Test func onlyOneClaimerWins() async throws {
        let s = try Stores(); defer { s.h.cleanup() }
        _ = try s.destinations.connect(destination("dest-a", account: "a"))
        for n in 0..<50 { _ = try await s.capture("n\(n)") }

        let one = JobStore(db: try Database(url: s.h.layout.databaseURL))
        let two = JobStore(db: try Database(url: s.h.layout.databaseURL))
        @Sendable func drain(_ store: JobStore, _ owner: String) throws -> [UploadJob] {
            var claimed: [UploadJob] = []
            while let job = try store.claimNext(owner: owner, now: t0, lease: 300) {
                claimed.append(job)
                Thread.sleep(forTimeInterval: 0.002)  // the worker uploads; lets the other connection in
            }
            return claimed
        }
        async let a = Task.detached { try drain(one, "app") }.value
        async let b = Task.detached { try drain(two, "extension") }.value
        let (appJobs, extensionJobs) = try await (a, b)

        // Assert only after the join, so failures are attributed to this test.
        #expect((appJobs + extensionJobs).allSatisfy { $0.state == .uploading })
        let fromApp = appJobs.map(\.jobID)
        let fromExtension = extensionJobs.map(\.jobID)
        #expect(Set(fromApp).isDisjoint(with: fromExtension))
        #expect(Set(fromApp + fromExtension).count == 50)
        #expect(fromApp.count + fromExtension.count == 50)
        let owners = try s.h.db.query("SELECT lease_owner, count(*) AS n FROM jobs GROUP BY lease_owner")
        let byOwner = Dictionary(uniqueKeysWithValues: owners.map { ($0.string("lease_owner") ?? "", $0.int("n") ?? 0) })
        #expect(byOwner["app", default: 0] == Int64(fromApp.count))
        #expect(byOwner["extension", default: 0] == Int64(fromExtension.count))
    }

    @Test func expiredLeaseIsReclaimable() async throws {
        let s = try Stores(); defer { s.h.cleanup() }
        _ = try s.destinations.connect(destination("dest-a", account: "a"))
        _ = try await s.capture()

        let job = try #require(try s.jobs.claimNext(owner: "w1", now: t0, lease: 30))
        #expect(try s.lease(job.jobID) == ("w1", 1_800_000_030_000))
        #expect(try s.jobs.claimNext(owner: "w2", now: t0.addingTimeInterval(29), lease: 30) == nil)
        #expect(try s.jobs.renewLease(jobID: job.jobID, owner: "w1", now: t0.addingTimeInterval(10), lease: 30))
        #expect(try s.jobs.claimNext(owner: "w2", now: t0.addingTimeInterval(39), lease: 30) == nil)

        let reclaimed = try #require(try s.jobs.claimNext(owner: "w2", now: t0.addingTimeInterval(41), lease: 30))
        #expect(reclaimed.jobID == job.jobID)
        #expect(reclaimed.attemptCount == 1)  // the expired lease counts as a crashed attempt
        #expect(try s.lease(job.jobID) == ("w2", 1_800_000_071_000))
        #expect(try s.jobs.renewLease(jobID: job.jobID, owner: "w1", now: t0.addingTimeInterval(42), lease: 30) == false)
        #expect(throws: JobError.leaseLost) { try s.jobs.markSynced(jobID: job.jobID, owner: "w1") }
        try s.jobs.markSynced(jobID: job.jobID, owner: "w2")
    }

    @Test func expiredLeaseReclaimCountsAttempt() async throws {
        let s = try Stores(); defer { s.h.cleanup() }
        _ = try s.destinations.connect(destination("dest-a", account: "a"))
        let id = try await s.capture()

        let job = try #require(try s.jobs.claimNext(owner: "w1", now: t0, lease: 30))
        #expect(job.attemptCount == 0)
        let reclaimed = try #require(try s.jobs.claimNext(owner: "w2", now: t0.addingTimeInterval(31), lease: 30))
        #expect(reclaimed.jobID == job.jobID)
        #expect(reclaimed.state == .uploading)
        #expect(reclaimed.attemptCount == 1)
        #expect(reclaimed.lastErrorCode == "lease_expired")
        #expect(try s.jobs.jobs(captureID: id)[0] == reclaimed)
        #expect(try s.lease(job.jobID) == ("w2", 1_800_000_061_000))
    }

    @Test func thirdExpiredReclaimBacksOff() async throws {
        let s = try Stores(); defer { s.h.cleanup() }
        _ = try s.destinations.connect(destination("dest-a", account: "a"))
        let id = try await s.capture("crashes")
        let backoff: @Sendable (Int) -> TimeInterval = { _ in 600 }

        let job = try #require(try s.jobs.claimNext(owner: "w", now: t0, lease: 30, reclaimDelay: backoff))
        var now = t0
        for expected in 1...2 {
            now = now.addingTimeInterval(31)
            let again = try #require(try s.jobs.claimNext(owner: "w", now: now, lease: 30, reclaimDelay: backoff))
            #expect(again.jobID == job.jobID)
            #expect(again.attemptCount == expected)
        }
        // Another job, due but ordered after the crashing one, is claimed in the same call.
        let other = try await s.capture("healthy")
        let otherJobID = try s.jobs.jobs(captureID: other)[0].jobID
        try s.h.db.execute("UPDATE jobs SET state = 'retryable_failure', next_attempt_at_ms = ? WHERE job_id = ?",
                           [.int(1_800_000_000_000), .text(otherJobID)])

        now = now.addingTimeInterval(31)
        #expect(try s.jobs.claimNext(owner: "w", now: now, lease: 30, reclaimDelay: backoff)?.jobID == otherJobID)
        try s.jobs.markSynced(jobID: otherJobID, owner: "w")
        let parked = try s.jobs.jobs(captureID: id)[0]
        #expect(parked.state == .retryableFailure)
        #expect(parked.attemptCount == 3)
        #expect(parked.lastErrorCode == "lease_expired")
        #expect(parked.nextAttemptAt == now.addingTimeInterval(600))
        #expect(try s.lease(job.jobID) == (nil, nil))

        #expect(try s.jobs.claimNext(owner: "w", now: now, lease: 30, reclaimDelay: backoff) == nil)
        let retried = try #require(try s.jobs.claimNext(owner: "w", now: now.addingTimeInterval(600), lease: 30,
                                                        reclaimDelay: backoff))
        #expect(retried.jobID == job.jobID)
        #expect(retried.attemptCount == 3)
    }

    @Test func defaultReclaimDelayDoublesUpToSixHours() {
        #expect(JobStore.defaultReclaimDelay(1) == 30)
        #expect(JobStore.defaultReclaimDelay(3) == 120)
        #expect(JobStore.defaultReclaimDelay(10) == 15_360)
        #expect(JobStore.defaultReclaimDelay(11) == 21_600)
        #expect(JobStore.defaultReclaimDelay(40) == 21_600)
    }

    @Test func clearCancelRevivesJobPausedByCancel() async throws {
        let s = try Stores(); defer { s.h.cleanup() }
        _ = try s.destinations.connect(destination("dest-a", account: "a"))
        let id = try await s.capture()
        let job = try #require(try s.jobs.claimNext(owner: "w", now: t0, lease: 60))
        try s.jobs.requestCancel(captureID: id)
        try s.jobs.markFailed(jobID: job.jobID, owner: "w", state: .paused, errorCode: "cancelled", nextAttemptAt: nil)
        #expect(try s.jobs.claimNext(owner: "w", now: t0, lease: 60) == nil)

        try s.jobs.clearCancel(captureID: id)
        let revived = try s.jobs.jobs(captureID: id)[0]
        #expect(revived.state == .pending)
        #expect(revived.nextAttemptAt == nil)
        #expect(revived.cancelRequested == false)
        #expect(try s.jobs.claimNext(owner: "w", now: t0, lease: 60)?.jobID == job.jobID)
    }

    @Test func clearCancelLeavesOtherPausedJobsPaused() async throws {
        let s = try Stores(); defer { s.h.cleanup() }
        _ = try s.destinations.connect(destination("dest-a", account: "a"))
        let id = try await s.capture()
        let job = try #require(try s.jobs.claimNext(owner: "w", now: t0, lease: 60))
        try s.jobs.markFailed(jobID: job.jobID, owner: "w", state: .paused, errorCode: "destination_inactive",
                              nextAttemptAt: nil)
        try s.jobs.requestCancel(captureID: id)

        try s.jobs.clearCancel(captureID: id)
        let kept = try s.jobs.jobs(captureID: id)[0]
        #expect(kept.state == .paused)
        #expect(kept.cancelRequested == false)
    }

    @Test func destinationByID() throws {
        let s = try Stores(); defer { s.h.cleanup() }
        let a = destination("dest-a", account: "a")
        _ = try s.destinations.connect(a)
        #expect(try s.destinations.destination(id: "dest-a") == a)
        #expect(try s.destinations.destination(id: "unknown") == nil)
    }

    @Test func activeLeaseExistsOnlyWhileUploadingUnderAnUnexpiredLease() async throws {
        let s = try Stores(); defer { s.h.cleanup() }
        _ = try s.destinations.connect(destination("dest-a", account: "a"))
        let id = try await s.capture()
        #expect(try s.jobs.activeLeaseExists(captureID: id, now: t0) == false)

        let job = try #require(try s.jobs.claimNext(owner: "w1", now: t0, lease: 30))
        #expect(try s.jobs.activeLeaseExists(captureID: id, now: t0.addingTimeInterval(29)))
        #expect(try s.jobs.activeLeaseExists(captureID: id, now: t0.addingTimeInterval(30)) == false)
        #expect(try s.jobs.activeLeaseExists(captureID: "other", now: t0) == false)

        try s.jobs.markSynced(jobID: job.jobID, owner: "w1")
        #expect(try s.jobs.activeLeaseExists(captureID: id, now: t0) == false)
    }

    @Test func leaseLostRejectsStaleOwner() async throws {
        let s = try Stores(); defer { s.h.cleanup() }
        _ = try s.destinations.connect(destination("dest-a", account: "a"))
        let id = try await s.capture()
        let job = try #require(try s.jobs.claimNext(owner: "w1", now: t0, lease: 60))

        #expect(throws: JobError.leaseLost) { try s.jobs.markSynced(jobID: job.jobID, owner: "w2") }
        #expect(throws: JobError.leaseLost) {
            try s.jobs.markFailed(jobID: job.jobID, owner: "w2", state: .blocked, errorCode: "x", nextAttemptAt: nil)
        }
        #expect(throws: JobError.notFound) { try s.jobs.markSynced(jobID: "missing", owner: "w1") }
        #expect(try s.jobs.jobs(captureID: id)[0].state == .uploading)

        let retryAt = t0.addingTimeInterval(120)
        try s.jobs.markFailed(jobID: job.jobID, owner: "w1", state: .retryableFailure, errorCode: "network",
                              nextAttemptAt: retryAt)
        let failed = try s.jobs.jobs(captureID: id)[0]
        #expect(failed.state == .retryableFailure)
        #expect(failed.attemptCount == 1)
        #expect(failed.lastErrorCode == "network")
        #expect(failed.nextAttemptAt == retryAt)
        #expect(try s.lease(job.jobID) == (nil, nil))
        // The lease is gone, so the former owner can no longer write.
        #expect(throws: JobError.leaseLost) { try s.jobs.markSynced(jobID: job.jobID, owner: "w1") }

        // Not eligible until its retry time.
        #expect(try s.jobs.claimNext(owner: "w2", now: retryAt.addingTimeInterval(-1), lease: 60) == nil)
        let again = try #require(try s.jobs.claimNext(owner: "w2", now: retryAt, lease: 60))
        #expect(again.attemptCount == 1)
        try s.jobs.markSynced(jobID: job.jobID, owner: "w2")
        let synced = try s.jobs.jobs(captureID: id)[0]
        #expect(synced.state == .synced)
        #expect(synced.lastErrorCode == nil)
        #expect(synced.nextAttemptAt == nil)
        #expect(try s.lease(job.jobID) == (nil, nil))
        #expect(try s.jobs.claimNext(owner: "w2", now: retryAt.addingTimeInterval(3600), lease: 60) == nil)
    }

    @Test func markFailedRejectsNonFailureStates() async throws {
        let s = try Stores(); defer { s.h.cleanup() }
        _ = try s.destinations.connect(destination("dest-a", account: "a"))
        let id = try await s.capture()
        let job = try #require(try s.jobs.claimNext(owner: "w", now: t0, lease: 60))
        for state in [JobState.pending, .uploading, .synced] {
            #expect(throws: JobError.invalidState) {
                try s.jobs.markFailed(jobID: job.jobID, owner: "w", state: state, errorCode: "x", nextAttemptAt: nil)
            }
        }
        let unchanged = try s.jobs.jobs(captureID: id)[0]
        #expect(unchanged.state == .uploading)
        #expect(unchanged.attemptCount == 0)
        #expect(try s.lease(job.jobID).owner == "w")
        for state in [JobState.retryableFailure, .needsAuthentication, .blocked, .paused] {
            try s.h.db.execute("UPDATE jobs SET state = 'uploading', lease_owner = 'w' WHERE job_id = ?", [.text(job.jobID)])
            try s.jobs.markFailed(jobID: job.jobID, owner: "w", state: state, errorCode: "x", nextAttemptAt: nil)
            #expect(try s.jobs.jobs(captureID: id)[0].state == state)
        }
    }

    @Test func claimOrderFollowsDocumentedSelection() async throws {
        let s = try Stores(); defer { s.h.cleanup() }
        _ = try s.destinations.connect(destination("dest-a", account: "a"))
        var jobIDs: [String] = []
        for n in 0..<5 { jobIDs.append(try s.jobs.jobs(captureID: try await s.capture("n\(n)"))[0].jobID) }
        let (expiredUploading, pending, dueLater, dueEarlier, notDue) = (jobIDs[0], jobIDs[1], jobIDs[2], jobIDs[3], jobIDs[4])
        let nowMS: Int64 = 1_800_000_000_000
        func set(_ jobID: String, _ state: String, next: Int64?, updated: Int64, leaseExpires: Int64? = nil) throws {
            try s.h.db.execute("""
                UPDATE jobs SET state = ?, next_attempt_at_ms = ?, updated_at_ms = ?, lease_owner = ?,
                  lease_expires_at_ms = ? WHERE job_id = ?
                """, [.text(state), next.map { .int($0) } ?? .null, .int(updated),
                      leaseExpires == nil ? .null : .text("dead-worker"), leaseExpires.map { .int($0) } ?? .null,
                      .text(jobID)])
        }
        // Null next attempt first (by updated_at), then by next attempt time; not-yet-due jobs never.
        try set(pending, "pending", next: nil, updated: 200)
        try set(expiredUploading, "uploading", next: nil, updated: 100, leaseExpires: nowMS - 1)
        try set(dueLater, "retryable_failure", next: nowMS - 60_000, updated: 50)
        try set(dueEarlier, "retryable_failure", next: nowMS - 120_000, updated: 300)
        try set(notDue, "retryable_failure", next: nowMS + 60_000, updated: 10)

        var order: [String] = []
        while let job = try s.jobs.claimNext(owner: "w", now: t0, lease: 60) { order.append(job.jobID) }
        #expect(order == [expiredUploading, pending, dueEarlier, dueLater])
    }

    @Test func cancelRequestedJobsAreNotClaimed() async throws {
        let s = try Stores(); defer { s.h.cleanup() }
        _ = try s.destinations.connect(destination("dest-a", account: "a"))
        let cancelled = try await s.capture("cancel me")
        let kept = try await s.capture("keep me")

        try s.jobs.requestCancel(captureID: cancelled)
        #expect(try s.jobs.jobs(captureID: cancelled).map(\.cancelRequested) == [true])
        #expect(try s.jobs.jobs(captureID: kept).map(\.cancelRequested) == [false])
        let claimed = try #require(try s.jobs.claimNext(owner: "w", now: t0, lease: 60))
        #expect(claimed.captureID == kept)
        #expect(try s.jobs.claimNext(owner: "w", now: t0, lease: 60) == nil)
    }

    @Test func jobLookupByIDSeesCancelRequests() async throws {
        let s = try Stores(); defer { s.h.cleanup() }
        _ = try s.destinations.connect(destination("dest-a", account: "a"))
        let capture = try await s.capture()
        let job = try #require(try s.jobs.jobs(captureID: capture).first)
        #expect(try s.jobs.job(jobID: job.jobID) == job)
        try s.jobs.requestCancel(captureID: capture)
        #expect(try s.jobs.job(jobID: job.jobID)?.cancelRequested == true)
        #expect(try s.jobs.job(jobID: "missing") == nil)
    }

    @Test func checkpointsRoundTrip() async throws {
        let s = try Stores(); defer { s.h.cleanup() }
        _ = try s.destinations.connect(destination("dest-a", account: "a"))
        _ = try await s.capture()
        let job = try #require(try s.jobs.claimNext(owner: "w", now: t0, lease: 60))
        let path = "content/a.png"

        #expect(try s.jobs.checkpoint(jobID: job.jobID, relativePath: path) == nil)
        try s.jobs.saveCheckpoint(jobID: job.jobID, relativePath: path, data: Data([1, 2, 3]))
        try s.jobs.saveCheckpoint(jobID: job.jobID, relativePath: path, data: Data([4, 5]))
        try s.jobs.saveCheckpoint(jobID: job.jobID, relativePath: "metadata.json", data: Data())
        #expect(try s.jobs.checkpoint(jobID: job.jobID, relativePath: path) == Data([4, 5]))
        #expect(try s.jobs.checkpoint(jobID: job.jobID, relativePath: "metadata.json") == Data())
        try s.jobs.clearCheckpoint(jobID: job.jobID, relativePath: path)
        #expect(try s.jobs.checkpoint(jobID: job.jobID, relativePath: path) == nil)
        #expect(try s.jobs.checkpoint(jobID: job.jobID, relativePath: "metadata.json") == Data())

        let first = StoredReceipt(relativePath: path, byteCount: 10, evidenceKind: "content_hash", evidenceValue: "aa")
        let replaced = StoredReceipt(relativePath: path, byteCount: 12, evidenceKind: "content_hash", evidenceValue: "bb")
        let meta = StoredReceipt(relativePath: "metadata.json", byteCount: 0, evidenceKind: "size", evidenceValue: "0")
        #expect(try s.jobs.receipts(jobID: job.jobID).isEmpty)
        try s.jobs.saveReceipt(jobID: job.jobID, first)
        try s.jobs.saveReceipt(jobID: job.jobID, replaced)
        try s.jobs.saveReceipt(jobID: job.jobID, meta)
        #expect(try s.jobs.receipts(jobID: job.jobID) == [replaced, meta])
    }

    @Test func nextAttemptAtIsEarliestRetryable() async throws {
        let s = try Stores(); defer { s.h.cleanup() }
        _ = try s.destinations.connect(destination("dest-a", account: "a"))
        #expect(try s.jobs.nextAttemptAt(destinationID: "dest-a") == nil)
        let ids = [try await s.capture("a"), try await s.capture("b"), try await s.capture("c")]
        func set(_ id: String, _ state: String, _ next: Int64) throws {
            try s.h.db.execute("UPDATE jobs SET state = ?, next_attempt_at_ms = ? WHERE capture_id = ?",
                               [.text(state), .int(next), .text(id)])
        }
        try set(ids[0], "retryable_failure", 1_800_000_200_000)
        try set(ids[1], "retryable_failure", 1_800_000_100_000)
        try set(ids[2], "blocked", 1_800_000_000_000)
        #expect(try s.jobs.nextAttemptAt(destinationID: "dest-a") == Date(timeIntervalSince1970: 1_800_000_100))
        #expect(try s.jobs.nextAttemptAt(destinationID: "other") == nil)
        // A due job being cancelled is never claimed, so it must not drive the retry timer.
        let cancelled = try await s.capture("d")
        try set(cancelled, "retryable_failure", 1_700_000_000_000)
        try s.jobs.requestCancel(captureID: cancelled)
        #expect(try s.jobs.nextAttemptAt(destinationID: "dest-a") == Date(timeIntervalSince1970: 1_800_000_100))
        try s.h.db.execute("UPDATE jobs SET state = 'synced' WHERE state = 'retryable_failure'")
        #expect(try s.jobs.nextAttemptAt(destinationID: "dest-a") == nil)
    }

    @Test func retryNowResetsBlockedAndRetryableButNotCancelled() async throws {
        let s = try Stores(); defer { s.h.cleanup() }
        _ = try s.destinations.connect(destination("d1", account: "a"))
        let blocked = try await s.capture("b"), waiting = try await s.capture("w")
        let cancelled = try await s.capture("c"), synced = try await s.capture("s")
        for (id, state) in [(blocked, "blocked"), (waiting, "retryable_failure"), (cancelled, "blocked"), (synced, "synced")] {
            try s.h.db.execute("""
                UPDATE jobs SET state = ?, attempt_count = 2, last_error_code = 'quota_exceeded',
                  next_attempt_at_ms = 9999999999999 WHERE capture_id = ?
                """, [.text(state), .text(id)])
        }
        try s.jobs.requestCancel(captureID: cancelled)

        #expect(try s.jobs.retryNow(captureID: blocked) == 1)
        let job = try #require(try s.jobs.jobs(captureID: blocked).first)
        #expect(job.state == .pending && job.nextAttemptAt == nil)
        #expect(job.attemptCount == 2 && job.lastErrorCode == "quota_exceeded")

        #expect(try s.jobs.retryNow(captureID: cancelled) == 0)
        #expect(try s.jobs.jobs(captureID: cancelled).first?.state == .blocked)

        #expect(try s.jobs.retryAll(destinationID: "d1") == 1)  // only `waiting`
        #expect(try s.jobs.jobs(captureID: waiting).first?.state == .pending)
        #expect(try s.jobs.jobs(captureID: synced).first?.state == .synced)
        #expect(try s.jobs.retryAll(destinationID: "other") == 0)
    }

    @Test func clearCancelMakesJobsClaimableAgain() async throws {
        let s = try Stores(); defer { s.h.cleanup() }
        _ = try s.destinations.connect(destination("d1", account: "a"))
        let id = try await s.capture()
        try s.jobs.requestCancel(captureID: id)
        #expect(try s.jobs.claimNext(owner: "w", now: t0, lease: 60) == nil)
        try s.jobs.clearCancel(captureID: id)
        #expect(try s.jobs.claimNext(owner: "w", now: t0, lease: 60)?.captureID == id)
    }

    @Test func insertSyncedAndClearReceipts() async throws {
        let s = try Stores(); defer { s.h.cleanup() }
        _ = try s.destinations.connect(destination("d", account: "a"))
        let id = try await s.capture()
        let other = try await s.h.add(note: "second").metadata.captureID
        try s.jobs.insertSynced(captureID: other, destinationID: "d")
        let synced = try #require(try s.jobs.jobs(captureID: other).first)
        #expect(synced.state == .synced)
        #expect(try s.jobs.receipts(jobID: synced.jobID).isEmpty)
        // An existing pair is left alone.
        try s.jobs.insertSynced(captureID: id, destinationID: "d")
        #expect(try s.jobs.jobs(captureID: id).map(\.state) == [.pending])

        let job = try #require(try s.jobs.jobs(captureID: id).first)
        for path in ["a", "b", "c"] {
            try s.jobs.saveReceipt(jobID: job.jobID, StoredReceipt(relativePath: path, byteCount: 1, evidenceKind: "k", evidenceValue: "v"))
        }
        try s.jobs.clearReceipts(jobID: job.jobID, paths: ["a", "c"])
        #expect(try s.jobs.receipts(jobID: job.jobID).map(\.relativePath) == ["b"])
        try s.jobs.clearReceipts(jobID: job.jobID, paths: nil)
        #expect(try s.jobs.receipts(jobID: job.jobID).isEmpty)

        // requeue: any state back to pending, lease and retry time cleared, cancel flag kept.
        let claimed = try #require(try s.jobs.claimNext(owner: "w", now: t0, lease: 60))
        try s.jobs.requestCancel(captureID: claimed.captureID)
        try s.jobs.requeue(jobID: claimed.jobID)
        let after = try #require(try s.jobs.job(jobID: claimed.jobID))
        #expect(after.state == .pending)
        #expect(after.nextAttemptAt == nil)
        #expect(after.cancelRequested)
        #expect(try s.lease(claimed.jobID).owner == nil)
        #expect(try s.lease(claimed.jobID).expires == nil)
    }

    @Test func capturesFullySynced() async throws {
        let s = try Stores(); defer { s.h.cleanup() }
        _ = try s.destinations.connect(destination("d", account: "a"))
        let done = try await s.capture("done")
        let partial = try await s.capture("partial")
        let unbound = try await s.h.add(note: "unbound").metadata.captureID
        try s.h.db.execute("UPDATE jobs SET state = 'synced' WHERE capture_id = ?", [.text(done)])
        // A second destination's unfinished job doesn't count against `d`.
        _ = try s.destinations.connect(destination("e", account: "b"))
        try s.h.db.execute("UPDATE jobs SET state = 'pending' WHERE capture_id = ? AND destination_id = 'e'", [.text(done)])
        _ = unbound
        #expect(try s.jobs.capturesFullySynced(destinationID: "d") == [done])
        try s.jobs.insertSynced(captureID: unbound, destinationID: "d")
        #expect(try s.jobs.capturesFullySynced(destinationID: "d") == [done, unbound])
        _ = partial
    }
}
