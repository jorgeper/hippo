import Foundation
import CaptureCore

/// The redacted `diagnostics.json` read from the Mac with `devicectl` (design §3.5): counts, safe error
/// codes and versions only. It never contains capture or job IDs, paths, file names, URLs, account
/// identifiers, display names, content or locations (spec §13).
public enum Diagnostics {
    private struct Report: Encodable {
        var generatedAt: Date
        var appVersion: String
        /// The local database schema version (`PRAGMA user_version`), not the package format version.
        var schemaVersion: Int64
        var captureCount: Int64
        var jobsByState: [String: Int64]
        var recentErrorCodes: [String]
        var destinations: [DestinationSummary]
        var enrichmentTasks: [String: [String: Int]]
        var enrichmentUploadsPending: Int
        var gold: GoldSummary

        enum CodingKeys: String, CodingKey {
            case generatedAt = "generated_at"
            case appVersion = "app_version"
            case schemaVersion = "schema_version"
            case captureCount = "capture_count"
            case jobsByState = "jobs_by_state"
            case recentErrorCodes = "recent_error_codes"
            case destinations
            case enrichmentTasks = "enrichment_tasks"
            case enrichmentUploadsPending = "enrichment_uploads_pending"
            case gold
        }
    }

    private struct GoldSummary: Encodable {
        var lastResultCode: String?
        var lastPullAgeSeconds: Int?

        enum CodingKeys: String, CodingKey {
            case lastResultCode = "last_result_code"
            case lastPullAgeSeconds = "last_pull_age_seconds"
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(lastResultCode, forKey: .lastResultCode)
            try c.encodeIfPresent(lastPullAgeSeconds, forKey: .lastPullAgeSeconds)
        }
    }

    private struct DestinationSummary: Encodable {
        var providerKind: String
        var status: String

        enum CodingKeys: String, CodingKey {
            case providerKind = "provider_kind"
            case status
        }
    }

    static let recentErrorLimit = 20
    static let unrecognizedCode = "unrecognized"

    /// The report as HippoJSON (sorted keys, RFC 3339 millisecond timestamps). `schema_version` is the
    /// local database schema version.
    public static func make(db: Database, appVersion: String, now: Date) throws -> Data {
        var byState = Dictionary(uniqueKeysWithValues: JobState.allCases.map { ($0.rawValue, Int64(0)) })
        for row in try db.query("SELECT state, count(*) AS n FROM jobs GROUP BY state") {
            byState[row.string("state") ?? "", default: 0] += row.int("n") ?? 0
        }
        // Error codes are the sync engine's vocabulary (`offline`, `transient:<code>`, ...); anything outside
        // its character set, which could carry a path, URL or message, is replaced.
        let errors = try db.query("""
            SELECT last_error_code FROM jobs WHERE last_error_code IS NOT NULL
            ORDER BY updated_at_ms DESC, job_id LIMIT ?
            """, [.int(Int64(recentErrorLimit))]).compactMap { $0.string("last_error_code") }.map(safeCode)
        let destinations = try db.query("""
            SELECT provider_kind, status FROM destinations ORDER BY created_at_ms, destination_id
            """).map { DestinationSummary(providerKind: $0.string("provider_kind") ?? "", status: $0.string("status") ?? "") }

        // Gold and upload figures describe the active destination, if there is one.
        var pending = 0
        var gold = GoldSummary()
        if let active = try db.query("SELECT destination_id FROM destinations WHERE status = 'active' ORDER BY destination_id LIMIT 1")
            .first?.string("destination_id") {
            pending = try EnrichmentStore.uploadCandidateCount(db: db, destinationID: active, now: now)
            if let row = try db.query("SELECT last_result_code, last_pull_at_ms FROM gold_cursors WHERE destination_id = ?",
                                      [.text(active)]).first {
                gold.lastResultCode = row.string("last_result_code").map(safeCode)
                gold.lastPullAgeSeconds = row.int("last_pull_at_ms").map {
                    max(0, Int((now.timeIntervalSince1970 - Double($0) / 1000).rounded()))
                }
            }
        }

        return try HippoJSON.encode(Report(
            generatedAt: now,
            appVersion: appVersion,
            schemaVersion: try db.query("PRAGMA user_version")[0].int("user_version") ?? 0,
            captureCount: try db.query("SELECT count(*) AS n FROM captures")[0].int("n") ?? 0,
            jobsByState: byState,
            recentErrorCodes: errors,
            destinations: destinations,
            enrichmentTasks: try EnrichmentTaskStore(db: db).counts(),
            enrichmentUploadsPending: pending,
            gold: gold))
    }

    /// `code` if it matches `^[a-z0-9_:.-]{1,64}$`, otherwise "unrecognized".
    static func safeCode(_ code: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_:.-".utf8)
        let bytes = code.utf8
        return (1...64).contains(bytes.count) && bytes.allSatisfy(allowed.contains) ? code : unrecognizedCode
    }

    /// Writes the report atomically to `url` (normally `StoreLayout.diagnosticsURL`).
    public static func write(db: Database, appVersion: String, now: Date, to url: URL) throws {
        try make(db: db, appVersion: appVersion, now: now).write(to: url, options: .atomic)
    }
}
