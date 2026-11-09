import Foundation
import CryptoKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
import CaptureCore
import LocalRepository
@testable import SyncEngine
import FilesystemAdapter

private let day: TimeInterval = 86_400
private let utcCalendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

private func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

/// A PNG of random pixels, so it doesn't compress below `side * side * 4` bytes or so.
private func noisyPNG(side: Int) throws -> Data {
    let ctx = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let pixels = try #require(ctx.data).bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * side)
    var seed: UInt32 = 12_345
    for i in 0..<(ctx.bytesPerRow * side) {
        seed = seed &* 1_103_515_245 &+ 12_345
        pixels[i] = i % 4 == 3 ? 255 : UInt8(truncatingIfNeeded: seed >> 16)
    }
    let image = try #require(ctx.makeImage())
    let data = NSMutableData()
    let dest = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(dest, image, nil)
    #expect(CGImageDestinationFinalize(dest))
    return data as Data
}

/// Two phones sharing one remote folder: phone A captures and uploads with its worker; phone B lists and
/// downloads with its own store and destination row, through an adapter rooted at A's remote.
private struct Phones {
    let a: SyncHarness
    let b: SyncHarness
    let aEnrichments: EnrichmentStore
    let bEnrichments: EnrichmentStore
    let bTasks: EnrichmentTaskStore

    init() throws {
        a = try SyncHarness()
        b = try SyncHarness()
        aEnrichments = EnrichmentStore(db: a.db, layout: a.layout)
        bEnrichments = EnrichmentStore(db: b.db, layout: b.layout)
        bTasks = EnrichmentTaskStore(db: b.db)
    }

    func cleanup() { a.cleanup(); b.cleanup() }

    /// B's view of the shared remote, recording B's operations.
    var bAdapter: FilesystemAdapter { FilesystemAdapter(root: a.remote, faults: b.faults) }

    func downloader(_ adapter: (any StorageAdapter)? = nil,
                    limit: Int64 = RemoteDownloader.defaultLightAttachmentLimit) -> RemoteDownloader {
        let adapter: any StorageAdapter = adapter ?? bAdapter
        let clock = b.clock
        return RemoteDownloader(layout: b.layout, index: b.index, jobs: b.jobs, destinations: b.destinations,
                                remoteState: b.remoteState, trims: b.trims, enrichments: bEnrichments,
                                enrichmentTasks: bTasks, adapterFor: { _ in adapter }, lightAttachmentLimit: limit,
                                calendar: utcCalendar, now: { clock.now }, log: b.log)
    }

    /// A capture on phone A `daysAgo` days before the shared clock's now.
    func capture(daysAgo: Double, attachmentBytes: Int? = 1_000, timeZone: TimeZone? = nil,
                 image: Data? = nil) async throws -> CommittedPackage {
        try await a.capture(attachmentBytes: attachmentBytes, startedAt: t0.addingTimeInterval(-daysAgo * day),
                            timeZone: timeZone ?? TimeZone(identifier: "America/Los_Angeles")!, image: image)
    }

    func uploadFromA() async {
        let r = await a.worker().runOnce()
        #expect(r.failed == 0)
    }

    func estimate(_ seconds: TimeInterval?, include: Bool = false,
                  _ d: RemoteDownloader? = nil) async throws -> DownloadEstimate {
        try await (d ?? downloader()).estimate(window: DownloadWindow(seconds: seconds), includeLocallyDeleted: include)
    }

    /// Estimates and downloads everything in the window.
    func download(_ seconds: TimeInterval? = 30 * day, include: Bool = false,
                  _ d: RemoteDownloader? = nil) async throws -> DownloadResult {
        let d = d ?? downloader()
        let e = try await estimate(seconds, include: include, d)
        return await d.run(e.candidates, window: DownloadWindow(seconds: seconds), progress: { _, _ in })
    }

    /// The light bytes of one of A's local packages: metadata, marker and attachments up to `limit`.
    func lightBytes(_ p: CommittedPackage, limit: Int64 = RemoteDownloader.defaultLightAttachmentLimit) throws -> Int64 {
        let dir = a.layout.packageURL(relativeDirectory: p.relativeDirectory)
        func size(_ name: String) throws -> Int64 {
            try #require(try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)[.size]
                as? Int64)
        }
        return try size("metadata.json") + size("complete.json")
            + p.metadata.attachments.filter { $0.byteCount <= limit }.reduce(0) { $0 + $1.byteCount }
    }

    var bStagingLeftovers: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: b.layout.stagingDir.path)) ?? [])
            .filter { $0.hasPrefix("download-") }
    }

    /// Every file under B's `captures/`.
    var bCaptureFiles: [String] {
        let walker = FileManager.default.enumerator(atPath: b.layout.capturesDir.path)
        return (walker?.allObjects as? [String] ?? []).filter {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: b.layout.capturesDir.appendingPathComponent($0).path, isDirectory: &isDir)
            return !isDir.boolValue
        }
    }

    func bEvents(_ id: String) -> [LogEvent] { b.log.events(captureID: id, from: Date(timeIntervalSince1970: 0)) }

    /// Asserts the capture failed and left nothing behind on phone B.
    func expectNotDownloaded(_ r: DownloadResult, _ p: CommittedPackage, code: String) throws {
        #expect(r.failed == 1)
        #expect(r.downloaded == 0)
        #expect(r.code == code)
        #expect(bCaptureFiles.isEmpty)
        #expect(try b.index.relativeDirectory(captureID: p.metadata.captureID) == nil)
        #expect(try b.index.count() == 0)
        #expect(bStagingLeftovers.isEmpty)
        let event = try #require(bEvents(p.metadata.captureID).last { $0.event == .downloadCapture })
        #expect(event.outcome == .failed)
        #expect(event.code == code)
    }
}

@Suite struct RemoteDownloaderTests {
    @Test func estimateListsCompleteRemoteCapturesInWindow() async throws {
        let s = try Phones(); defer { s.cleanup() }
        let recent = try await s.capture(daysAgo: 10)
        let older = try await s.capture(daysAgo: 40)
        let oldest = try await s.capture(daysAgo: 400)
        await s.uploadFromA()

        let month = try await s.estimate(30 * day)
        #expect(month.candidates.map(\.captureID) == [recent.metadata.captureID])
        #expect(month.count == 1)
        #expect(try month.bytes == s.lightBytes(recent))
        let candidate = month.candidates[0]
        #expect(candidate.relativeDirectory == recent.relativeDirectory)
        #expect(try candidate.lightBytes == s.lightBytes(recent))
        #expect(!candidate.locallyDeleted)
        #expect(Set(candidate.files.map(\.relativePath))
                == Set(["metadata.json", "complete.json", recent.metadata.attachments[0].relativePath]
                    .map { recent.relativeDirectory + "/" + $0 }))

        let quarter = try await s.estimate(90 * day)
        #expect(Set(quarter.candidates.map(\.captureID)) == [recent.metadata.captureID, older.metadata.captureID])
        #expect(try quarter.bytes == s.lightBytes(recent) + s.lightBytes(older))

        let everything = try await s.estimate(nil)
        #expect(everything.count == 3)
        #expect(Set(everything.candidates.map(\.captureID))
                == Set([recent, older, oldest].map(\.metadata.captureID)))
        #expect(try everything.bytes == s.lightBytes(recent) + s.lightBytes(older) + s.lightBytes(oldest))

        // Only the window's month folders are listed, from the month one day before its start.
        let lists = s.b.faults.operations.filter { $0.hasPrefix("listFolder ") }
        #expect(lists.prefix(2) == ["listFolder captures/2026/12", "listFolder captures/2027/01"])
        #expect(lists.last == "listFolder captures")
    }

    @Test func estimateIgnoresIncompleteRemoteCaptures() async throws {
        let s = try Phones(); defer { s.cleanup() }
        let p = try await s.capture(daysAgo: 10)
        await s.uploadFromA()
        try FileManager.default.removeItem(at: s.a.remoteURL(p).appendingPathComponent("complete.json"))
        #expect(try await s.estimate(30 * day).candidates.isEmpty)
    }

    @Test func estimateExcludesIndexedTombstonedAndLocallyDeleted() async throws {
        let s = try Phones(); defer { s.cleanup() }
        let indexed = try await s.capture(daysAgo: 10)
        let tombstoned = try await s.capture(daysAgo: 11)
        let deleted = try await s.capture(daysAgo: 12)
        await s.uploadFromA()

        _ = try s.b.index.register(indexed, noteBody: nil)
        try s.b.remoteState.addTombstone(captureID: tombstoned.metadata.captureID,
                                         relativeDirectory: tombstoned.relativeDirectory, destinationID: "dest-fs",
                                         accountIdentifier: "local", now: t0)
        try s.b.remoteState.recordLocalDelete(captureID: deleted.metadata.captureID,
                                              relativeDirectory: deleted.relativeDirectory, accountIdentifier: "local",
                                              now: t0)

        let without = try await s.estimate(30 * day)
        #expect(without.candidates.isEmpty)
        #expect(without.count == 0)
        #expect(without.bytes == 0)
        #expect(without.skippedLocallyDeleted == 1)

        let with = try await s.estimate(30 * day, include: true)
        #expect(with.candidates.map(\.captureID) == [deleted.metadata.captureID])
        #expect(with.candidates.map(\.locallyDeleted) == [true])
        #expect(with.count == 1)
        #expect(try with.bytes == s.lightBytes(deleted))
    }

    @Test func runRegistersSyncedNeverReuploads() async throws {
        let s = try Phones(); defer { s.cleanup() }
        let p = try await s.capture(daysAgo: 10)
        await s.uploadFromA()
        let id = p.metadata.captureID

        let r = try await s.download()
        #expect(r == DownloadResult(downloaded: 1, skipped: 0, failed: 0, code: nil))

        #expect(try s.b.index.relativeDirectory(captureID: id) == p.relativeDirectory)
        let local = s.b.layout.packageURL(relativeDirectory: p.relativeDirectory)
        guard case .complete = PackageValidator.validate(directory: local) else {
            Issue.record("downloaded package is not complete")
            return
        }
        let jobs = try s.b.jobs.jobs(captureID: id)
        #expect(jobs.map(\.state) == [.synced])
        #expect(jobs.map(\.destinationID) == ["dest-fs"])
        #expect(s.bStagingLeftovers.isEmpty)

        // The same row the timeline orders and shows as on phone A.
        let aRow = try #require(try s.a.index.page(CaptureFilter(), after: nil, limit: 10).first)
        let bRow = try #require(try s.b.index.page(CaptureFilter(), after: nil, limit: 10).first)
        #expect(bRow == aRow)

        // B's sync pass uploads nothing.
        let before = s.b.faults.operations.count
        _ = await s.b.worker(s.bAdapter).runOnce()
        #expect(s.b.faults.operations.dropFirst(before).filter { $0.hasPrefix("upload ") }.isEmpty)

        let events = s.bEvents(id)
        #expect(!events.contains { $0.event == .captureSaved })
        let event = try #require(events.first { $0.event == .downloadCapture })
        #expect(event.outcome == .ok)
        #expect(event.dest == "filesystem")
        let run = try #require(s.b.log.globalEvents(limit: 20, before: nil).first { $0.event == .downloadRun })
        #expect(run.count == 1)
        #expect(run.code == nil)
        #expect(run.dest == "filesystem")
    }

    @Test func largeAttachmentArrivesRemoteOnly() async throws {
        let s = try Phones(); defer { s.cleanup() }
        let png = try noisyPNG(side: 64)
        try #require(png.count >= 10_240)
        let p = try await s.capture(daysAgo: 10, image: png)
        await s.uploadFromA()
        let attachment = p.metadata.attachments[0]
        let d = s.downloader(limit: 4096)

        let e = try await s.estimate(30 * day, d)
        #expect(try e.bytes == s.lightBytes(p, limit: 4096))
        let r = await d.run(e.candidates, window: DownloadWindow(seconds: 30 * day), progress: { _, _ in })
        #expect(r.downloaded == 1)

        let local = s.b.layout.packageURL(relativeDirectory: p.relativeDirectory)
        #expect(!FileManager.default.fileExists(atPath: local.appendingPathComponent(attachment.relativePath).path))
        #expect(!s.b.faults.operations.contains("download \(p.attachmentPath)"))
        let trimmed = try s.b.trims.trimmed(captureID: p.metadata.captureID)
        #expect(trimmed.count == 1)
        #expect(trimmed.first?.relativePath == attachment.relativePath)
        #expect(trimmed.first?.attachmentID == attachment.attachmentID)
        #expect(trimmed.first?.sha256 == attachment.sha256)
        #expect(trimmed.first?.byteCount == attachment.byteCount)
        #expect(trimmed.first?.state == .trimmed)
        #expect(trimmed.first?.destinationID == "dest-fs")
        #expect(trimmed.first?.trimmedAt == t0)
        let thumb = try Data(contentsOf: s.b.layout.thumbnailURL(attachmentID: attachment.attachmentID))
        #expect(thumb.starts(with: [0xFF, 0xD8]))
        #expect(try s.b.index.relativeDirectory(captureID: p.metadata.captureID) == p.relativeDirectory)
    }

    @Test func incompleteRemotePackageIsSkippedAndNotIndexed() async throws {
        let s = try Phones(); defer { s.cleanup() }
        let p = try await s.capture(daysAgo: 10)
        await s.uploadFromA()
        try FileManager.default.removeItem(at: s.a.remote.appendingPathComponent(p.attachmentPath))

        try s.expectNotDownloaded(try await s.download(), p, code: "incomplete_package")
    }

    @Test func badHashIsSkippedNeverHalfIndexed() async throws {
        let s = try Phones(); defer { s.cleanup() }
        let p = try await s.capture(daysAgo: 10)
        await s.uploadFromA()
        // Same size, different bytes.
        try Data(repeating: 0x41, count: Int(p.metadata.attachments[0].byteCount))
            .write(to: s.a.remote.appendingPathComponent(p.attachmentPath))

        try s.expectNotDownloaded(try await s.download(), p, code: "incomplete_package")
    }

    @Test func packageInAnotherDatesFolderIsInvalid() async throws {
        let s = try Phones(); defer { s.cleanup() }
        let p = try await s.capture(daysAgo: 10)
        await s.uploadFromA()
        let moved = p.relativeDirectory.replacingOccurrences(of: "/01/05/", with: "/01/06/")
        try #require(moved != p.relativeDirectory)
        let to = s.a.remote.appendingPathComponent(moved)
        try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: s.a.remoteURL(p), to: to)

        try s.expectNotDownloaded(try await s.download(), p, code: "invalid_package")
    }

    @Test func enrichmentDocumentsAreImported() async throws {
        let s = try Phones(); defer { s.cleanup() }
        let p = try await s.capture(daysAgo: 10)
        let id = p.metadata.captureID
        let digest = try #require(try s.a.index.packageDigest(captureID: id))
        let producer = EnrichmentProducer(name: "t", version: "1", build: "1")

        // Phone A's silver, with an asset, uploaded by its enrichment uploader.
        let deviceAsset = Data("device-asset".utf8)
        let deviceAssetPath = "assets/\(hex(deviceAsset)).jpg"
        let deviceRef: JSONValue = .object(["relative_path": .string(deviceAssetPath), "sha256": .string(hex(deviceAsset)),
                                            "byte_count": .number(Double(deviceAsset.count))])
        let tmp = s.a.root.appendingPathComponent("device-asset.jpg")
        try deviceAsset.write(to: tmp)
        let device = EnrichmentDocument(
            schemaVersion: 1, captureID: id, layer: .device, packageDigest: digest, producer: producer, generatedAt: t0,
            facets: [FacetKind.textRecognition.rawValue: Facet(version: 3, status: .ok, generatedAt: t0, provenance: "ocr",
                                                                data: .object(["text": .string("walrus"), "thumb": deviceRef])),
                     FacetKind.linkPreview.rawValue: Facet(version: 2, status: .empty, generatedAt: t0, provenance: "lp",
                                                           data: nil)])
        try s.aEnrichments.write(device, newAssets: [deviceAssetPath: tmp])
        await s.uploadFromA()
        let clock = s.a.clock
        let aUpload = await EnrichmentUploader(layout: s.a.layout, destinations: s.a.destinations,
                                               enrichments: s.aEnrichments, adapterFor: { [a = s.a] _ in a.adapter },
                                               now: { clock.now }, random: { 1 }).runOnce()
        #expect(aUpload.synced == 1)

        // A server's gold, placed in the destination directly.
        let goldAsset = Data("gold-asset".utf8)
        let goldAssetPath = "assets/\(hex(goldAsset)).png"
        let goldRef: JSONValue = .object(["relative_path": .string(goldAssetPath), "sha256": .string(hex(goldAsset)),
                                          "byte_count": .number(Double(goldAsset.count))])
        let server = EnrichmentDocument(
            schemaVersion: 1, captureID: id, layer: .server, packageDigest: digest,
            producer: EnrichmentProducer(name: "server", version: "1", build: "1"), generatedAt: t0,
            facets: [FacetKind.summary.rawValue: Facet(version: 1, status: .ok, generatedAt: t0, provenance: "gold",
                                                       data: .object(["text": .string("seal"), "thumb": goldRef]))])
        let goldDir = s.a.remote.appendingPathComponent(
            try EnrichmentPaths.remoteDirectory(.server, packageDirectory: p.relativeDirectory))
        try FileManager.default.createDirectory(at: goldDir.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try EnrichmentJSON.encode(server).write(to: goldDir.appendingPathComponent("enrichment.json"))
        try goldAsset.write(to: goldDir.appendingPathComponent(goldAssetPath))

        let r = try await s.download()
        #expect(r.downloaded == 1)

        #expect(try s.bEnrichments.document(.device, captureID: id) == device)
        #expect(try s.bEnrichments.document(.server, captureID: id) == server)
        #expect(try Data(contentsOf: s.bEnrichments.assetURL(.device, captureID: id,
                                                            asset: device.referencedAssets()[0])) == deviceAsset)
        #expect(try Data(contentsOf: s.bEnrichments.assetURL(.server, captureID: id,
                                                            asset: server.referencedAssets()[0])) == goldAsset)

        let ocr = try #require(try s.bTasks.task(captureID: id, kind: .textRecognition))
        #expect(ocr.version == 3)
        #expect(ocr.status == "ok")
        let preview = try #require(try s.bTasks.task(captureID: id, kind: .linkPreview))
        #expect(preview.version == 2)
        #expect(preview.status == "empty")
        #expect(try s.bTasks.task(captureID: id, kind: .summary) == nil)   // gold makes no silver task

        // The imported silver counts as already uploaded to B's destination.
        let bClock = s.b.clock
        let bUpload = await EnrichmentUploader(layout: s.b.layout, destinations: s.b.destinations,
                                               enrichments: s.bEnrichments, adapterFor: { [a = s.bAdapter] _ in a },
                                               now: { bClock.now }, random: { 1 }).runOnce()
        #expect(bUpload.synced == 0)
        #expect(bUpload.failed == 0)
        #expect(s.b.faults.operations.filter { $0.hasPrefix("upload ") || $0.hasPrefix("replace ") }.isEmpty)
        #expect(s.bStagingLeftovers.isEmpty)
    }

    @Test func badEnrichmentLeavesTheCaptureDownloaded() async throws {
        let s = try Phones(); defer { s.cleanup() }
        let p = try await s.capture(daysAgo: 10)
        await s.uploadFromA()
        let goldDir = s.a.remote.appendingPathComponent(
            try EnrichmentPaths.remoteDirectory(.server, packageDirectory: p.relativeDirectory))
        try FileManager.default.createDirectory(at: goldDir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: goldDir.appendingPathComponent("enrichment.json"))

        let r = try await s.download()
        #expect(r == DownloadResult(downloaded: 1, skipped: 0, failed: 0, code: nil))
        #expect(try s.b.index.relativeDirectory(captureID: p.metadata.captureID) == p.relativeDirectory)
        #expect(try s.bEnrichments.document(.server, captureID: p.metadata.captureID) == nil)
        #expect(s.bStagingLeftovers.isEmpty)
    }

    @Test func includeThemRemovesLocalDeleteRecord() async throws {
        let s = try Phones(); defer { s.cleanup() }
        let p = try await s.capture(daysAgo: 10)
        await s.uploadFromA()
        try s.b.remoteState.recordLocalDelete(captureID: p.metadata.captureID, relativeDirectory: p.relativeDirectory,
                                              accountIdentifier: "local", now: t0)

        let r = try await s.download(include: true)
        #expect(r.downloaded == 1)
        #expect(try s.b.remoteState.localDeletedCaptureIDs().isEmpty)
        #expect(try s.b.index.relativeDirectory(captureID: p.metadata.captureID) == p.relativeDirectory)
    }

    @Test func outsideWindowByCapturedAtIsSkipped() async throws {
        let s = try Phones(); defer { s.cleanup() }
        // 4 hours before the 14-day window starts, but at UTC+14 its folder is a day inside the window.
        let p = try await s.capture(daysAgo: 14 + 4.0 / 24, timeZone: TimeZone(identifier: "Pacific/Kiritimati")!)
        await s.uploadFromA()
        #expect(p.relativeDirectory.hasPrefix("captures/2027/01/01/"))

        let e = try await s.estimate(14 * day)
        #expect(e.candidates.map(\.captureID) == [p.metadata.captureID])
        let r = await s.downloader().run(e.candidates, window: DownloadWindow(seconds: 14 * day), progress: { _, _ in })

        #expect(r == DownloadResult(downloaded: 0, skipped: 1, failed: 0, code: nil))
        #expect(s.bCaptureFiles.isEmpty)
        #expect(try s.b.index.count() == 0)
        #expect(s.bStagingLeftovers.isEmpty)
        let event = try #require(s.bEvents(p.metadata.captureID).first { $0.event == .downloadCapture })
        #expect(event.outcome == .skipped)
        #expect(event.code == "outside_window")
        // Only the marker's sibling metadata was fetched.
        #expect(s.b.faults.operations.filter { $0.hasPrefix("download ") } == ["download \(p.metadataPath)"])
    }

    @Test func cancellationIsResumable() async throws {
        let s = try Phones(); defer { s.cleanup() }
        for n in 0..<3 { _ = try await s.capture(daysAgo: 10 + Double(n)) }
        await s.uploadFromA()
        let d = s.downloader()

        let first = try await s.estimate(30 * day, d)
        #expect(first.count == 3)
        let r1 = await Task {
            await d.run(first.candidates, window: DownloadWindow(seconds: 30 * day), progress: { done, _ in
                if done == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }.value
        #expect(r1.downloaded == 1)
        #expect(r1.code == "cancelled")
        #expect(try s.b.index.count() == 1)
        #expect(s.bStagingLeftovers.isEmpty)

        let second = try await s.estimate(30 * day, d)
        #expect(second.count == 2)
        let r2 = await d.run(second.candidates, window: DownloadWindow(seconds: 30 * day), progress: { _, _ in })
        #expect(r2.downloaded == 2)
        #expect(try s.b.index.count() == 3)
    }

    @Test func progressCountsEveryCandidate() async throws {
        let s = try Phones(); defer { s.cleanup() }
        for n in 0..<2 { _ = try await s.capture(daysAgo: 10 + Double(n)) }
        await s.uploadFromA()
        let d = s.downloader()
        let e = try await s.estimate(30 * day, d)
        let seen = Seen()
        _ = await d.run(e.candidates, window: DownloadWindow(seconds: 30 * day), progress: { seen.add([$0, $1]) })
        #expect(seen.all == [[0, 2], [1, 2], [2, 2]])
    }

    @Test func launchRecoveryDuringADownloadKeepsItsStaging() async throws {
        let s = try Phones(); defer { s.cleanup() }
        _ = try await s.capture(daysAgo: 10)
        await s.uploadFromA()
        let reconciler = Reconciler(layout: s.b.layout, index: s.b.index, jobs: s.b.jobs, destinations: s.b.destinations)
        let swept = Seen()
        // Recovery runs mid-download, as it can at launch alongside a foreground download.
        let adapter = HookedAdapter(inner: s.bAdapter, beforeDownload: { _ in
            if let report = try? reconciler.run(), report.removedStaging > 0 { swept.add([report.removedStaging]) }
        })

        let r = try await s.download(30 * day, s.downloader(adapter))

        #expect(swept.all.isEmpty)
        #expect(r.downloaded == 1)
        #expect(s.bStagingLeftovers.isEmpty)
    }

    @Test func abandonedDownloadStagingIsSwept() throws {
        let s = try Phones(); defer { s.cleanup() }
        let leftover = s.b.layout.stagingDir.appendingPathComponent("download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: leftover.appendingPathComponent("x"), withIntermediateDirectories: true)
        let reconciler = Reconciler(layout: s.b.layout, index: s.b.index, jobs: s.b.jobs, destinations: s.b.destinations)
        #expect(try reconciler.run().removedStaging == 1)
        #expect(s.bStagingLeftovers.isEmpty)
    }

    @Test func windowSteps() {
        #expect(DownloadWindow.steps == [14 * day, 30 * day, 90 * day, 180 * day, 365 * day, nil])
        #expect(DownloadWindow.default == DownloadWindow(seconds: 30 * day))
        #expect(RemoteDownloader.defaultLightAttachmentLimit == 10 * 1024 * 1024)
    }
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[Int]] = []
    func add(_ v: [Int]) { lock.lock(); values.append(v); lock.unlock() }
    var all: [[Int]] { lock.lock(); defer { lock.unlock() }; return values }
}
