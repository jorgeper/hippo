import Foundation
import Testing
import CaptureCore
import HippoTestSupport
@testable import LocalRepository

@Suite struct CaptureIndexTests {
    private func png() throws -> Data { try MediaMaker.imageData(width: 40, height: 30, type: .png) }
    private func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))! }
    private func date(_ s: Double) -> Date { Date(timeIntervalSince1970: 1_794_070_800 + s) }
    private func ids(_ page: [CaptureSummary]) -> [String] { page.map(\.id) }

    @Test func registerIsIdempotent() async throws {
        let h = try IndexHarness(); defer { h.cleanup() }
        let pkg = try await h.add(note: "hello world")
        #expect(try h.index.register(pkg, noteBody: nil) == false)
        #expect(try h.index.count() == 1)
        #expect(try h.db.query("SELECT count(*) AS n FROM captures_fts")[0].int("n") == 1)
        let row = try h.db.query("SELECT * FROM captures")[0]
        #expect(row.string("local_day") == "2026-11-07")
        #expect(row.string("package_digest")?.count == 64)
        #expect(try h.index.metadata(captureID: pkg.metadata.captureID, layout: h.layout) == pkg.metadata)
        #expect(try h.index.metadata(captureID: "nope", layout: h.layout) == nil)
        try h.index.remove(captureID: pkg.metadata.captureID)
        #expect(try h.index.count() == 0)
        #expect(try h.db.query("SELECT count(*) AS n FROM captures_fts")[0].int("n") == 0)
    }

    @Test func relativeDirectoryLookup() async throws {
        let h = try IndexHarness(); defer { h.cleanup() }
        let pkg = try await h.add(note: "where am I")
        #expect(try h.index.relativeDirectory(captureID: pkg.metadata.captureID) == pkg.relativeDirectory)
        #expect(try h.index.relativeDirectory(captureID: "nope") == nil)
    }

    @Test func newestFirstWithStableTieBreak() async throws {
        let h = try IndexHarness(); defer { h.cleanup() }
        for n in [2, 1, 3] { try await h.add(id: id(n), note: "x") }
        let all = ids(try h.index.page(CaptureFilter(), after: nil, limit: 10))
        #expect(all == [id(3), id(2), id(1)].map { $0.uuidString.lowercased() })
        let old = ids(try h.index.page(CaptureFilter(sort: .oldestFirst), after: nil, limit: 10))
        #expect(old == all.reversed())
    }

    @Test func paginationCoversAllWithoutDuplicates() async throws {
        let h = try IndexHarness(); defer { h.cleanup() }
        for n in 1...25 { try await h.add(id: id(n), at: date(Double(n % 7)), note: "n\(n)") }
        for sort in [SortOrder.newestFirst, .oldestFirst] {
            var seen: [String] = []
            var cursor: PageCursor?
            while true {
                let page = try h.index.page(CaptureFilter(sort: sort), after: cursor, limit: 10)
                if page.isEmpty { break }
                seen += ids(page)
                cursor = PageCursor(capturedAt: page.last!.capturedAt, captureID: page.last!.id)
            }
            #expect(seen.count == 25)
            #expect(Set(seen).count == 25)
        }
    }

    @Test func mixedCaptureMatchesAnyType() async throws {
        let h = try IndexHarness(); defer { h.cleanup() }
        let mixed = try await h.add(id: id(1), urls: ["https://example.com/a"], attachments: [imageAttachment(data: try png())])
        try await h.add(id: id(2), urls: ["https://example.com/b"])
        try await h.add(id: id(3), note: "just a note", attachments: [textAttachment("body")])
        #expect(Set(mixed.metadata.contentTypes) == [.image, .url])
        func hits(_ t: Set<ContentType>) throws -> Int { try h.index.page(CaptureFilter(contentTypes: t), after: nil, limit: 50).count }
        #expect(try hits([.image]) == 1)
        #expect(try hits([.url]) == 2)
        #expect(try hits([.image, .url]) == 2)
        #expect(try hits([.image, .text]) == 2)
        #expect(try hits([.pdf]) == 0)
        let s = try h.index.page(CaptureFilter(contentTypes: [.image]), after: nil, limit: 5)[0]
        #expect(Set(s.contentTypes) == [.image, .url])
        #expect(s.primaryAttachmentPath == mixed.metadata.attachments[0].relativePath)
    }

    @Test func filtersByMethodCommentLocationDate() async throws {
        let h = try IndexHarness(); defer { h.cleanup() }
        let loc = CaptureLocation(latitude: 1, longitude: 2, horizontalAccuracyMeters: 5, observedAt: date(0), provenance: "core_location")
        try await h.add(id: id(1), at: date(0), method: .typedNote, note: "has comment", attachments: [textAttachment("b")])
        try await h.add(id: id(2), at: date(100), method: .shareExtension, urls: ["https://x.example"], location: loc)
        try await h.add(id: id(3), at: date(200), method: .shareExtension, urls: ["https://y.example"])
        func run(_ f: CaptureFilter) throws -> Set<String> {
            Set(ids(try h.index.page(f, after: nil, limit: 50)))
        }
        func s(_ n: Int) -> String { id(n).uuidString.lowercased() }
        #expect(try run(CaptureFilter(methods: [.typedNote])) == [s(1)])
        #expect(try run(CaptureFilter(methods: [.typedNote, .shareExtension])).count == 3)
        #expect(try run(CaptureFilter(hasComment: true)) == [s(1)])
        #expect(try run(CaptureFilter(hasComment: false)) == [s(2), s(3)])
        #expect(try run(CaptureFilter(hasLocation: true)) == [s(2)])
        #expect(try run(CaptureFilter(hasLocation: false)) == [s(1), s(3)])
        // lower bound inclusive, upper exclusive
        #expect(try run(CaptureFilter(dateRange: date(0)..<date(200))) == [s(1), s(2)])
        #expect(try run(CaptureFilter(dateRange: date(100)..<date(201))) == [s(2), s(3)])
        #expect(try run(CaptureFilter(methods: [.shareExtension], hasLocation: false)) == [s(3)])
    }

    @Test func searchMatchesTitleNoteSharedTextURLFilename() async throws {
        let h = try IndexHarness(); defer { h.cleanup() }
        try await h.add(id: id(1), title: "Zebramovie", urls: ["https://plain.example"])
        try await h.add(id: id(2), note: "pineapple reminder")
        try await h.add(id: id(3), sharedText: "quokka quote")
        try await h.add(id: id(4), urls: ["https://marmot.example/path"])
        try await h.add(id: id(5), attachments: [imageAttachment(name: "narwhal.png", data: try png())])
        try await h.add(id: id(6), method: .typedNote, attachments: [textAttachment("axolotl body text")])
        func hit(_ q: String) throws -> [String] { ids(try h.index.page(CaptureFilter(searchText: q), after: nil, limit: 50)) }
        func s(_ n: Int) -> String { id(n).uuidString.lowercased() }
        #expect(try hit("zebra") == [s(1)])
        #expect(try hit("pineapple") == [s(2)])
        #expect(try hit("quokka") == [s(3)])
        #expect(try hit("marmot") == [s(4)])
        #expect(try hit("narwhal") == [s(5)])
        #expect(try hit("axolotl") == [s(6)])
        #expect(try hit("ocr-only-word").isEmpty)
        #expect(try hit("pineapple remin") == [s(2)])
        #expect(try hit("pineapple quokka").isEmpty)
        #expect(try hit("   ").count == 6)
        // AND-combined with other filters
        let f = CaptureFilter(methods: [.typedNote], searchText: "pineapple")
        #expect(try h.index.page(f, after: nil, limit: 50).isEmpty)
    }

    @Test func searchWithFTSOperatorsNeverThrows() async throws {
        let h = try IndexHarness(); defer { h.cleanup() }
        try await h.add(note: "some text AND more")
        for q in ["\"", "*", "-", "NEAR(", "a:b", "((", "😀", "AND OR NOT"] {
            _ = try h.index.page(CaptureFilter(searchText: q), after: nil, limit: 10)
        }
    }

    @Test func syncBucketRules() async throws {
        let h = try IndexHarness(); defer { h.cleanup() }
        try h.db.execute("INSERT INTO destinations VALUES('d1','fs','a','/r','D','active',0)")
        try h.db.execute("INSERT INTO destinations VALUES('d2','fs','b','/r','E','active',0)")
        var jobN = 0
        func job(_ capture: Int, _ dest: String, _ state: String) throws {
            jobN += 1
            try h.db.execute("INSERT INTO jobs(job_id, capture_id, destination_id, state, updated_at_ms) VALUES(?,?,?,?,0)",
                             [.text("j\(jobN)"), .text(id(capture).uuidString.lowercased()), .text(dest), .text(state)])
        }
        for n in 1...8 { try await h.add(id: id(n), note: "n") }
        // 1: no job
        try job(2, "d1", "synced")
        try job(3, "d1", "pending")
        try job(4, "d1", "retryable_failure")
        try job(5, "d1", "uploading")
        try job(6, "d1", "needs_authentication")
        try job(7, "d1", "blocked"); 
        try job(8, "d1", "synced"); try job(8, "d2", "paused")
        func bucket(_ n: Int) throws -> SyncBucket {
            try h.index.page(CaptureFilter(), after: nil, limit: 50).first { $0.id == id(n).uuidString.lowercased() }!.syncBucket
        }
        #expect(try bucket(1) == .notSynced)
        #expect(try bucket(2) == .synced)
        #expect(try bucket(3) == .notSynced)
        #expect(try bucket(4) == .notSynced)
        #expect(try bucket(5) == .notSynced)
        #expect(try bucket(6) == .needsAttention)
        #expect(try bucket(7) == .needsAttention)
        #expect(try bucket(8) == .needsAttention)
        func count(_ b: Set<SyncBucket>) throws -> Int { try h.index.page(CaptureFilter(syncBuckets: b), after: nil, limit: 50).count }
        #expect(try count([.synced]) == 1)
        #expect(try count([.needsAttention]) == 3)
        #expect(try count([.notSynced]) == 4)
        #expect(try count([.synced, .needsAttention]) == 4)
    }

    @Test func tenThousandCapturesStayResponsive() throws {
        let h = try IndexHarness(); defer { h.cleanup() }
        let types = [",image,", ",url,", ",text,", ",video,", ",pdf,", ",image,url,"]
        let words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel"]
        try h.db.transaction { tx in
            for i in 0..<10_000 {
                let cid = String(format: "00000000-0000-4000-8000-%012d", i)
                let ms = Int64(1_794_070_800_000 + i * 60_000)
                let title = "\(words[i % 8]) \(words[(i / 8) % 8]) item \(i)"
                try tx.execute("""
                    INSERT INTO captures VALUES(?,?,?,?,?,?,NULL,0,0,1,NULL,?,?,0)
                    """, [.text(cid), .int(ms), .text("2026-11-07"), .text("share_extension"),
                          .text(types[i % types.count]), .text(title), .text("captures/\(cid)"), .text("d")])
                try tx.execute("INSERT INTO captures_fts VALUES(?,?,?,?,?,?)",
                               [.text(cid), .text(title), .text(""), .text("shared \(words[i % 5])"), .text(""), .text("file\(i).png")])
            }
        }
        let clock = ContinuousClock()
        var typed = CaptureFilter(); typed.contentTypes = [.image]
        var found = [CaptureSummary]()
        let t1 = try clock.measure { found = try h.index.page(typed, after: nil, limit: 50) }
        #expect(found.count == 50)
        #expect(t1 < .milliseconds(200))
        var search = CaptureFilter(); search.searchText = "golf hotel"
        let t2 = try clock.measure { found = try h.index.page(search, after: nil, limit: 50) }
        #expect(!found.isEmpty)
        #expect(t2 < .milliseconds(200))
    }
}
