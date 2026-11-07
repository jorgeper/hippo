import Foundation

public enum DestinationError: Error, Equatable {
    /// The destination ID is already bound to a different provider or account.
    case accountMismatch
}

public enum DestinationStatus: String, Sendable {
    case active
    case signedOut = "signed_out"
    case disabled
}

/// An upload destination: one account on one provider (spec §8). Secrets are stored elsewhere.
public struct Destination: Sendable, Equatable {
    public let id: String
    public let providerKind: String
    public let accountIdentifier: String
    public let remoteRoot: String
    public let displayName: String
    public let status: DestinationStatus

    public init(id: String, providerKind: String, accountIdentifier: String, remoteRoot: String,
                displayName: String, status: DestinationStatus) {
        self.id = id
        self.providerKind = providerKind
        self.accountIdentifier = accountIdentifier
        self.remoteRoot = remoteRoot
        self.displayName = displayName
        self.status = status
    }
}

/// Destination records and the rules binding captures to them (spec §8 "Provider switching",
/// design §3.6). A job stays bound to its destination; connecting another account never moves it.
public final class DestinationStore: Sendable {
    private let db: Database

    public init(db: Database) { self.db = db }

    /// Makes `d` the active destination, disabling any other active one, resumes its `paused` and
    /// `needs_authentication` jobs, and binds every unassigned capture (one with no job) to it.
    /// Returns the number of jobs created. Throws `DestinationError.accountMismatch`, changing
    /// nothing, if the ID is already stored with a different provider kind or account.
    public func connect(_ d: Destination) throws -> Int {
        let now = JobStore.ms(Date())
        return try db.transaction { tx in
            // Provider and account are fixed for an ID: reusing it for another account would resume
            // that account's paused jobs into a different account.
            let stored = try tx.query("SELECT provider_kind, account_identifier FROM destinations WHERE destination_id = ?",
                                      [.text(d.id)])
            if let row = stored.first,
               row.string("provider_kind") != d.providerKind || row.string("account_identifier") != d.accountIdentifier {
                throw DestinationError.accountMismatch
            }
            try tx.execute("""
                INSERT INTO destinations(destination_id, provider_kind, account_identifier, remote_root, display_name,
                  status, created_at_ms) VALUES (?, ?, ?, ?, ?, 'active', ?)
                ON CONFLICT(destination_id) DO UPDATE SET remote_root = excluded.remote_root,
                  display_name = excluded.display_name, status = 'active'
                """, [.text(d.id), .text(d.providerKind), .text(d.accountIdentifier), .text(d.remoteRoot),
                      .text(d.displayName), .int(now)])
            try tx.execute("UPDATE destinations SET status = 'disabled' WHERE status = 'active' AND destination_id <> ?",
                           [.text(d.id)])
            try tx.execute("""
                UPDATE jobs SET state = 'pending', next_attempt_at_ms = NULL, updated_at_ms = ?
                WHERE destination_id = ? AND state IN ('paused', 'needs_authentication')
                """, [.int(now), .text(d.id)])
            let unassigned = try tx.query("""
                SELECT capture_id FROM captures c WHERE NOT EXISTS (SELECT 1 FROM jobs j WHERE j.capture_id = c.capture_id)
                ORDER BY captured_at_ms, capture_id
                """).compactMap { $0.string("capture_id") }
            return try JobStore.insertPending(captureIDs: unassigned, destinationID: d.id, in: tx)
        }
    }

    /// Marks the destination signed out and pauses its unfinished jobs. Paused jobs lose their
    /// lease, so a worker still uploading one can no longer record a result for it.
    public func signOut(destinationID: String) throws {
        let now = JobStore.ms(Date())
        try db.transaction { tx in
            try tx.execute("UPDATE destinations SET status = 'signed_out' WHERE destination_id = ?",
                           [.text(destinationID)])
            try tx.execute("""
                UPDATE jobs SET state = 'paused', lease_owner = NULL, lease_expires_at_ms = NULL, updated_at_ms = ?
                WHERE destination_id = ? AND state IN ('pending', 'retryable_failure', 'uploading', 'needs_authentication')
                """, [.int(now), .text(destinationID)])
        }
    }

    public func active() throws -> Destination? {
        try db.query("SELECT * FROM destinations WHERE status = 'active' ORDER BY destination_id LIMIT 1").first.map { r in
            Destination(id: r.string("destination_id") ?? "", providerKind: r.string("provider_kind") ?? "",
                        accountIdentifier: r.string("account_identifier") ?? "", remoteRoot: r.string("remote_root") ?? "",
                        displayName: r.string("display_name") ?? "",
                        status: DestinationStatus(rawValue: r.string("status") ?? "") ?? .disabled)
        }
    }

    /// The explicit "Upload existing local captures to this destination" action: creates jobs for
    /// captures that have none for this destination. Never alters existing jobs.
    public func backfill(destinationID: String) throws -> Int {
        try db.transaction { tx in
            let missing = try tx.query("""
                SELECT capture_id FROM captures c WHERE NOT EXISTS
                  (SELECT 1 FROM jobs j WHERE j.capture_id = c.capture_id AND j.destination_id = ?)
                ORDER BY captured_at_ms, capture_id
                """, [.text(destinationID)]).compactMap { $0.string("capture_id") }
            return try JobStore.insertPending(captureIDs: missing, destinationID: destinationID, in: tx)
        }
    }
}
