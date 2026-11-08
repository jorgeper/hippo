import Foundation
import Testing
@testable import LocalRepository

private func prepared() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("hippo-db-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("hippo.sqlite")
}

@Suite struct DatabaseTests {
    @Test func migratesOnceAndIsIdempotent() throws {
        let url = try prepared()
        let first = try Database(url: url)
        #expect(try first.query("PRAGMA user_version")[0].int("user_version") == 2)
        let second = try Database(url: url)
        #expect(try second.query("PRAGMA user_version")[0].int("user_version") == 2)
        #expect(try second.query("SELECT count(*) AS n FROM sqlite_master WHERE name = 'captures'")[0].int("n") == 1)
    }

    @Test func fts5Available() throws {
        let db = try Database(url: try prepared())
        try db.execute("INSERT INTO captures_fts(capture_id, title, user_note, shared_text, urls, filenames) VALUES (?, ?, '', '', '', '')",
                       [.text("a"), .text("Café résumé")])
        let rows = try db.query("SELECT capture_id FROM captures_fts WHERE captures_fts MATCH ?", [.text("cafe")])
        #expect(rows.count == 1)
        #expect(rows[0].string("capture_id") == "a")
    }

    @Test func transactionRollsBackOnThrow() throws {
        let db = try Database(url: try prepared())
        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try db.transaction { tx in
                try tx.execute("INSERT INTO destinations VALUES ('d','fs','a','/','n','active',1)")
                throw Boom()
            }
        }
        #expect(try db.query("SELECT * FROM destinations").isEmpty)
        let n = try db.transaction { tx in
            try tx.execute("INSERT INTO destinations VALUES ('d','fs','a','/','n','active',1)")
            return try tx.query("SELECT * FROM destinations").count
        }
        #expect(n == 1)
    }

    @Test func nestedTransactionFailsLoudly() throws {
        let db = try Database(url: try prepared())
        #expect(throws: DatabaseError.self) {
            try db.transaction { tx in
                try tx.transaction { _ in () }
            }
        }
        // The outer transaction rolled back and the instance is usable afterwards.
        try db.transaction { try $0.execute("SELECT 1") }
    }

    @Test func rowAccessors() throws {
        let db = try Database(url: try prepared())
        let r = try db.query("SELECT 'x' AS s, 7 AS i, 1.5 AS d, NULL AS n, 1700000000123 AS ms")[0]
        #expect(r.string("s") == "x")
        #expect(r.int("i") == 7)
        #expect(r.double("d") == 1.5)
        #expect(r.string("n") == nil)
        #expect(r.int("s") == nil)
        #expect(r.date("ms") == Date(timeIntervalSince1970: 1_700_000_000.123))
        #expect(r["missing"] == .null)
    }

    @Test func errorMessagesOmitBoundValues() throws {
        let db = try Database(url: try prepared())
        do {
            try db.execute("INSERT INTO destinations(destination_id) VALUES (?)", [.text("SECRET-VALUE")])
            Issue.record("expected failure")
        } catch let DatabaseError.sqlite(_, message) {
            #expect(!message.contains("SECRET-VALUE"))
        }
    }

    @Test func concurrentWritersDoNotFail() async throws {
        let url = try prepared()
        let a = try Database(url: url)
        let b = try Database(url: url)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (idx, db) in [a, b].enumerated() {
                group.addTask {
                    for i in 0..<200 {
                        try db.execute("INSERT INTO destinations VALUES (?, 'fs', 'a', '/', 'n', 'active', 1)",
                                       [.text("\(idx)-\(i)")])
                        if i % 20 == 0 { await Task.yield() }
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(try a.query("SELECT count(*) AS n FROM destinations")[0].int("n") == 400)
    }

    @Test func concurrentFreshOpenMigratesOnce() async throws {
        let url = try prepared()
        let versions = try await withThrowingTaskGroup(of: Int64?.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    let db = try Database(url: url)
                    return try db.query("PRAGMA user_version")[0].int("user_version")
                }
            }
            var out: [Int64?] = []
            for try await v in group { out.append(v) }
            return out
        }
        #expect(versions == [2, 2])
    }

    @Test func fileDatabaseUsesWAL() throws {
        let db = try Database(url: try prepared())
        #expect(try db.query("PRAGMA journal_mode")[0].string("journal_mode") == "wal")
    }

    @Test func migrationFromV1AddsOffsetColumn() async throws {
        let url = try prepared()
        let v1 = try Database(url: url, migratingUpTo: 1)
        try v1.execute("""
            INSERT INTO captures(capture_id, captured_at_ms, local_day, method, content_types, title, note_excerpt,
              has_comment, has_location, attachment_count, primary_attachment_path, relative_directory,
              package_digest, registered_at_ms) VALUES ('old',1,'2026-11-07','typed_note',',text,','t',NULL,0,0,0,NULL,'captures/x','d',1)
            """)
        #expect(try v1.query("PRAGMA user_version")[0].int("user_version") == 1)

        let upgraded = try Database(url: url)
        #expect(try upgraded.query("PRAGMA user_version")[0].int("user_version") == 2)
        let index = CaptureIndex(db: upgraded)
        let old = try #require(try index.page(CaptureFilter(), after: nil, limit: 10).first)
        #expect(old.id == "old")
        #expect(old.utcOffsetSeconds == nil)
    }
}
