import Foundation
import CaptureCore

/// The redacted `diagnostics.json` read from the Mac with `devicectl` (design §3.5): counts, safe error
/// codes and versions only. It never contains capture or job IDs, paths, file names, URLs, account
/// identifiers, display names, content or locations (spec §13).
public enum Diagnostics {
    private struct Report: Encodable {
        var generatedAt: Date
        var appVersion: String
        var schemaVersion: Int64
        var captureCount: Int64
        var jobsByState: [String: Int64]
        var recentErrorCodes: [String]
        var destinations: [DestinationSummary]

        enum CodingKeys: String, CodingKey {
            case generatedAt = "generated_at"
            case appVersion = "app_version"
            case schemaVersion = "schema_version"
            case captureCount = "capture_count"
            case jobsByState = "jobs_by_state"
            case recentErrorCodes = "recent_error_codes"
            case destinations
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

    /// The report as HippoJSON (sorted keys, RFC 3339 millisecond timestamps). `schema_version` is the
    /// local database schema version.
    public static func make(db: Database, appVersion: String, now: Date) throws -> Data {
        var byState = Dictionary(uniqueKeysWithValues: JobState.allCases.map { ($0.rawValue, Int64(0)) })
        for row in try db.query("SELECT state, count(*) AS n FROM jobs GROUP BY state") {
            byState[row.string("state") ?? "", default: 0] += row.int("n") ?? 0
        }
        // Error codes are the sync engine's fixed vocabulary (`offline`, `transient:<code>`, ...): safe as-is.
        let errors = try db.query("""
            SELECT last_error_code FROM jobs WHERE last_error_code IS NOT NULL
            ORDER BY updated_at_ms DESC, job_id LIMIT ?
            """, [.int(Int64(recentErrorLimit))]).compactMap { $0.string("last_error_code") }
        let destinations = try db.query("""
            SELECT provider_kind, status FROM destinations ORDER BY created_at_ms, destination_id
            """).map { DestinationSummary(providerKind: $0.string("provider_kind") ?? "", status: $0.string("status") ?? "") }

        return try HippoJSON.encode(Report(
            generatedAt: now,
            appVersion: appVersion,
            schemaVersion: try db.query("PRAGMA user_version")[0].int("user_version") ?? 0,
            captureCount: try db.query("SELECT count(*) AS n FROM captures")[0].int("n") ?? 0,
            jobsByState: byState,
            recentErrorCodes: errors,
            destinations: destinations))
    }

    /// Writes the report atomically to `url` (normally `StoreLayout.diagnosticsURL`).
    public static func write(db: Database, appVersion: String, now: Date, to url: URL) throws {
        try make(db: db, appVersion: appVersion, now: now).write(to: url, options: .atomic)
    }
}
