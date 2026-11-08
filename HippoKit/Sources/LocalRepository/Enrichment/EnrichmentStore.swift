import Foundation
import CryptoKit
import CaptureCore
import Darwin
import os

public enum EnrichmentStoreError: Error, Equatable {
    /// The document's capture is not in the index.
    case notIndexed
    /// A referenced asset is neither in `newAssets` nor already stored in the layer with a matching SHA-256.
    case missingAsset
    /// The stored document belongs to another capture or layer than the directory it was read from.
    case mismatchedDocument
}

/// Local silver (`device`) and gold (`server`) enrichments (design §6.2), their search text, the silver
/// upload rows and the gold cursors. Files live at `enrichments/<layer>/<capture-id>/` (`enrichment.json`
/// plus `assets/`); each write builds a new directory in `staging/enrichments/` and swaps it into place,
/// so a reader or a crash sees either the old or the new directory, never a mix.
public final class EnrichmentStore: Sendable {
    /// Fixed category strings only: never IDs, paths or error text.
    private static let log = Logger(subsystem: "com.jorgeper.hippo", category: "enrichment")

    private let db: Database
    private let layout: StoreLayout
    /// Serializes this instance's file changes, so `sweep()` never removes a write's staging while it runs.
    private let lock = NSLock()

    public init(db: Database, layout: StoreLayout) {
        self.db = db
        self.layout = layout
    }

    // MARK: Documents

    /// The layer's document for the capture. Nil if absent; throws if it can't be read or decoded.
    public func document(_ layer: EnrichmentLayer, captureID: String) throws -> EnrichmentDocument? {
        let url = layout.enrichmentDirectory(layer, captureID: captureID)
            .appendingPathComponent(EnrichmentPaths.documentName)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
        return try Self.decode(data, layer, captureID: captureID)
    }

    private static func decode(_ data: Data, _ layer: EnrichmentLayer, captureID: String) throws -> EnrichmentDocument {
        let doc = try EnrichmentJSON.decode(data)
        guard doc.captureID == captureID, doc.layer == layer else { throw EnrichmentStoreError.mismatchedDocument }
        return doc
    }

    /// Where the layer keeps `asset` for the capture. The file exists only if a stored document references it.
    public func assetURL(_ layer: EnrichmentLayer, captureID: String, asset: AssetRef) -> URL {
        layout.enrichmentDirectory(layer, captureID: captureID).appendingPathComponent(asset.relativePath)
    }

    /// Replaces the layer's directory for `d.captureID` with `d` and its assets. Every referenced asset
    /// comes from `newAssets` (keyed by relative path; the files are copied, not moved) or is already in
    /// the layer's directory with a matching SHA-256. Unreferenced old assets are dropped. Then the
    /// capture's search text is refreshed and, for `device`, `device_revision` becomes the SHA-256 of
    /// the written `enrichment.json`.
    public func write(_ d: EnrichmentDocument, newAssets: [String: URL]) throws {
        let bytes = try EnrichmentJSON.encode(d)
        // The same checks every reader applies, so what is written can always be read back.
        _ = try EnrichmentJSON.decode(bytes)
        let fm = FileManager.default
        try lock.withLock {
            guard try isIndexed(d.captureID) else { throw EnrichmentStoreError.notIndexed }
            let target = layout.enrichmentDirectory(d.layer, captureID: d.captureID)

            // Resolve every asset before touching the disk.
            var sources: [(path: String, url: URL)] = []
            for asset in d.referencedAssets() {
                let candidates = [newAssets[asset.relativePath], target.appendingPathComponent(asset.relativePath)]
                guard let source = candidates.compactMap({ $0 }).first(where: { Self.matches($0, asset) }) else {
                    throw EnrichmentStoreError.missingAsset
                }
                sources.append((asset.relativePath, source))
            }

            let staging = try newStagingDirectory()
            do {
                if !sources.isEmpty {
                    try fm.createDirectory(at: staging.appendingPathComponent("assets", isDirectory: true),
                                           withIntermediateDirectories: false)
                }
                for source in sources {
                    let destination = staging.appendingPathComponent(source.path)
                    try fm.copyItem(at: source.url, to: destination)
                    try Self.fullSync(destination)
                }
                let json = staging.appendingPathComponent(EnrichmentPaths.documentName)
                try bytes.write(to: json, options: .withoutOverwriting)
                try Self.fullSync(json)
                if !sources.isEmpty { try Self.fullSync(staging.appendingPathComponent("assets", isDirectory: true)) }
                try Self.fullSync(staging)
                try swapIntoPlace(staging, target)
            } catch {
                try? fm.removeItem(at: staging)
                throw error
            }

            let device = d.layer == .device ? d : try? document(.device, captureID: d.captureID)
            let server = d.layer == .server ? d : try? document(.server, captureID: d.captureID)
            try updateIndex(captureID: d.captureID, text: EnrichmentSearchText.make(device: device, server: server),
                            deviceRevision: d.layer == .device ? .some(Self.hex(SHA256.hash(data: bytes))) : nil)
        }
    }

    /// Removes the layer's files for the capture, refreshes its search text and, for `device`, clears
    /// `device_revision`. Removing an absent layer only refreshes the index.
    public func removeLayer(_ layer: EnrichmentLayer, captureID: String) throws {
        try lock.withLock {
            try removeDirectory(layout.enrichmentDirectory(layer, captureID: captureID))
            let device = layer == .device ? nil : try? document(.device, captureID: captureID)
            let server = layer == .server ? nil : try? document(.server, captureID: captureID)
            try updateIndex(captureID: captureID, text: EnrichmentSearchText.make(device: device, server: server),
                            deviceRevision: layer == .device ? .some(nil) : nil)
        }
    }

    /// Removes both layers' files for the capture. Its rows go with the capture (cascade on `index.remove`).
    public func removeAll(captureID: String) throws {
        try lock.withLock {
            var firstError: Error?
            for layer in [EnrichmentLayer.device, .server] {
                do { try removeDirectory(layout.enrichmentDirectory(layer, captureID: captureID)) } catch {
                    firstError = firstError ?? error
                }
            }
            if let firstError { throw firstError }
        }
    }

    /// Removes everything in `staging/enrichments/` and, when `removingOrphans` is true, every
    /// `enrichments/<layer>/<id>` whose capture isn't indexed. Pass false when recovery could not register
    /// every package: an unindexed capture may then still exist, and its gold could not be pulled again.
    /// Returns how many entries were removed. An entry that can't be removed is skipped (and logged);
    /// the next sweep tries again.
    public func sweep(removingOrphans: Bool = true) throws -> Int {
        try lock.withLock {
            var removed = 0
            func remove(_ url: URL) {
                do {
                    try FileManager.default.removeItem(at: url)
                    removed += 1
                } catch let error as CocoaError where error.code == .fileNoSuchFile {
                    // Already gone.
                } catch {
                    Self.log.error("\("enrichment_sweep_item_failed", privacy: .public)")
                }
            }
            for name in Self.contents(of: layout.enrichmentStagingDir) {
                remove(layout.enrichmentStagingDir.appendingPathComponent(name))
            }
            guard removingOrphans else { return removed }
            let indexed = Set(try db.query("SELECT capture_id FROM captures").compactMap { $0.string("capture_id") })
            for layer in [EnrichmentLayer.device, .server] {
                let dir = layout.enrichmentsDir.appendingPathComponent(layer.rawValue, isDirectory: true)
                for name in Self.contents(of: dir) where !indexed.contains(name) {
                    remove(dir.appendingPathComponent(name))
                }
            }
            return removed
        }
    }

    /// Brings each indexed capture's search text and `device_revision` back in line with the files on
    /// disk. `write` and `removeLayer` change the files before the database, so a crash or a failed
    /// transaction in between leaves the index describing the old files; re-registering a capture also
    /// resets its text. A capture is repaired when its device `enrichment.json` hashes to something other
    /// than `device_revision` (including a file that is gone), when its text is empty but documents
    /// exist, or when it has text but no documents. Returns how many captures were changed. A capture
    /// that can't be repaired is skipped (and logged).
    ///
    /// Known limit: a gold-only change whose index update was lost, on a capture whose text is not
    /// empty, is not detected; the next write for that capture repairs it.
    public func reconcileIndex() throws -> Int {
        try lock.withLock {
            var texts: [String: String] = [:]
            for row in try db.query("SELECT capture_id, enrichment FROM captures_fts") {
                if let id = row.string("capture_id") { texts[id] = row.string("enrichment") ?? "" }
            }
            let onDevice = Set(Self.contents(of: layout.enrichmentsDir.appendingPathComponent(EnrichmentLayer.device.rawValue)))
            let onServer = Set(Self.contents(of: layout.enrichmentsDir.appendingPathComponent(EnrichmentLayer.server.rawValue)))
            var repaired = 0
            for row in try db.query("SELECT capture_id, device_revision FROM captures") {
                guard let id = row.string("capture_id") else { continue }
                let storedRevision = row.string("device_revision")
                let storedText = texts[id] ?? ""
                let hasFiles = onDevice.contains(id) || onServer.contains(id)
                guard hasFiles || storedRevision != nil || !storedText.isEmpty else { continue }

                let deviceURL = layout.enrichmentDirectory(.device, captureID: id)
                    .appendingPathComponent(EnrichmentPaths.documentName)
                let deviceBytes = onDevice.contains(id) ? try? Data(contentsOf: deviceURL) : nil
                let deviceHash = deviceBytes.map { Self.hex(SHA256.hash(data: $0)) }
                // `device_revision` is only ever set from bytes that decoded, so a matching hash means
                // the device file is the one the index describes.
                if deviceHash == storedRevision, storedText.isEmpty != hasFiles { continue }

                let device = deviceBytes.flatMap { try? Self.decode($0, .device, captureID: id) }
                let server = onServer.contains(id) ? try? document(.server, captureID: id) : nil
                let revision = device == nil ? nil : deviceHash
                let text = EnrichmentSearchText.make(device: device, server: server)
                guard revision != storedRevision || text != storedText else { continue }
                do {
                    try updateIndex(captureID: id, text: text, deviceRevision: .some(revision))
                    repaired += 1
                } catch {
                    Self.log.error("\("enrichment_reconcile_item_failed", privacy: .public)")
                }
            }
            return repaired
        }
    }

    // MARK: Silver uploads

    /// Captures whose current silver should be uploaded to the destination, newest first: the capture has
    /// a `device_revision` and a `synced` package job for the destination; the revision isn't the one
    /// already uploaded, nor one that was blocked; and any scheduled retry is due.
    public func uploadCandidates(destinationID: String, now: Date, limit: Int) throws
        -> [(captureID: String, relativeDirectory: String, revision: String)] {
        try db.query("""
            SELECT c.capture_id, c.relative_directory, c.device_revision \(Self.candidateClause)
            ORDER BY c.captured_at_ms DESC, c.capture_id DESC LIMIT ?
            """, [.text(destinationID), .text(destinationID), .int(Self.ms(now)), .int(Int64(max(limit, 0)))]).map {
            ($0.string("capture_id") ?? "", $0.string("relative_directory") ?? "", $0.string("device_revision") ?? "")
        }
    }

    /// How many captures `uploadCandidates` would return without a limit.
    public static func uploadCandidateCount(db: Database, destinationID: String, now: Date) throws -> Int {
        Int(try db.query("SELECT count(*) AS n \(candidateClause)",
                         [.text(destinationID), .text(destinationID), .int(ms(now))])[0].int("n") ?? 0)
    }

    private static let candidateClause = """
        FROM captures c
        JOIN jobs j ON j.capture_id = c.capture_id AND j.destination_id = ? AND j.state = 'synced'
        LEFT JOIN enrichment_uploads u ON u.capture_id = c.capture_id AND u.destination_id = ?
        WHERE c.device_revision IS NOT NULL
          AND (u.capture_id IS NULL OR u.uploaded_revision IS NOT c.device_revision)
          AND NOT (COALESCE(u.blocked, 0) = 1 AND u.attempted_revision IS c.device_revision)
          AND (u.next_attempt_at_ms IS NULL OR u.next_attempt_at_ms <= ?)
        """

    /// Records that `revision` reached the destination, clearing any failure state.
    public func markUploaded(captureID: String, destinationID: String, revision: String, now: Date) throws {
        try db.execute("""
            INSERT INTO enrichment_uploads(capture_id, destination_id, uploaded_revision, attempted_revision,
              updated_at_ms) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(capture_id, destination_id) DO UPDATE SET uploaded_revision = excluded.uploaded_revision,
              attempted_revision = excluded.attempted_revision, blocked = 0, attempt_count = 0,
              next_attempt_at_ms = NULL, last_error_code = NULL, updated_at_ms = excluded.updated_at_ms
            """, [.text(captureID), .text(destinationID), .text(revision), .text(revision), .int(Self.ms(now))])
    }

    /// Records a failed upload of `revision`. `attempt_count` counts attempts at that revision: it
    /// restarts at 1 when the attempted revision changes.
    public func markUploadFailed(captureID: String, destinationID: String, revision: String, code: String,
                                 blocked: Bool, nextAttemptAt: Date?, now: Date) throws {
        try db.execute("""
            INSERT INTO enrichment_uploads(capture_id, destination_id, attempted_revision, blocked, attempt_count,
              next_attempt_at_ms, last_error_code, updated_at_ms) VALUES (?, ?, ?, ?, 1, ?, ?, ?)
            ON CONFLICT(capture_id, destination_id) DO UPDATE SET
              attempt_count = CASE WHEN attempted_revision IS excluded.attempted_revision
                                   THEN attempt_count + 1 ELSE 1 END,
              attempted_revision = excluded.attempted_revision, blocked = excluded.blocked,
              next_attempt_at_ms = excluded.next_attempt_at_ms, last_error_code = excluded.last_error_code,
              updated_at_ms = excluded.updated_at_ms
            """, [.text(captureID), .text(destinationID), .text(revision), .int(blocked ? 1 : 0),
                  nextAttemptAt.map { .int(Self.ms($0)) } ?? .null, .text(code), .int(Self.ms(now))])
    }

    /// How many failed uploads of `revision` are recorded for the capture and destination (0 if none).
    public func uploadAttemptCount(captureID: String, destinationID: String, revision: String) throws -> Int {
        let row = try db.query("""
            SELECT attempt_count FROM enrichment_uploads
            WHERE capture_id = ? AND destination_id = ? AND attempted_revision IS ?
            """, [.text(captureID), .text(destinationID), .text(revision)]).first
        return Int(row?.int("attempt_count") ?? 0)
    }

    // MARK: Gold cursors

    /// The destination's saved gold `listChanges` cursor, or nil to start from the beginning.
    public func goldCursor(destinationID: String) throws -> String? {
        try db.query("SELECT cursor FROM gold_cursors WHERE destination_id = ?", [.text(destinationID)]).first?
            .string("cursor")
    }

    /// Saves (or, with nil, clears) the destination's gold cursor.
    public func saveGoldCursor(destinationID: String, cursor: String?, now: Date) throws {
        try db.execute("""
            INSERT INTO gold_cursors(destination_id, cursor, last_pull_at_ms) VALUES (?, ?, ?)
            ON CONFLICT(destination_id) DO UPDATE SET cursor = excluded.cursor, last_pull_at_ms = excluded.last_pull_at_ms
            """, [.text(destinationID), cursor.map { .text($0) } ?? .null, .int(Self.ms(now))])
    }

    /// Records how the destination's last gold pass ended (a fixed result code).
    public func recordGoldResult(destinationID: String, code: String, now: Date) throws {
        try db.execute("""
            INSERT INTO gold_cursors(destination_id, last_result_code, last_pull_at_ms) VALUES (?, ?, ?)
            ON CONFLICT(destination_id) DO UPDATE SET last_result_code = excluded.last_result_code,
              last_pull_at_ms = excluded.last_pull_at_ms
            """, [.text(destinationID), .text(code), .int(Self.ms(now))])
    }

    // MARK: Helpers

    private func isIndexed(_ captureID: String) throws -> Bool {
        try !db.query("SELECT 1 FROM captures WHERE capture_id = ?", [.text(captureID)]).isEmpty
    }

    /// Sets the capture's enrichment search text and, when `deviceRevision` is non-nil, its
    /// `device_revision` (`.some(nil)` clears it), in one transaction.
    private func updateIndex(captureID: String, text: String, deviceRevision: String??) throws {
        try db.transaction { tx in
            try tx.execute("UPDATE captures_fts SET enrichment = ? WHERE capture_id = ?", [.text(text), .text(captureID)])
            if let revision = deviceRevision {
                try tx.execute("UPDATE captures SET device_revision = ? WHERE capture_id = ?",
                               [revision.map { .text($0) } ?? .null, .text(captureID)])
            }
        }
    }

    private func newStagingDirectory() throws -> URL {
        let dir = layout.enrichmentStagingDir.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Puts `staging` at `target` atomically. When `target` exists the two are exchanged with
    /// `RENAME_SWAP`, so the path always names a complete directory; the old one, now at `staging`, is
    /// then removed (a leftover is swept later).
    private func swapIntoPlace(_ staging: URL, _ target: URL) throws {
        let parent = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        if renamex_np(staging.path, target.path, UInt32(RENAME_SWAP)) == 0 {
            try? FileManager.default.removeItem(at: staging)
        } else if errno == ENOENT, rename(staging.path, target.path) == 0 {
            // No previous directory.
        } else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try? Self.fullSync(parent)
    }

    /// Moves `dir` aside into staging, then deletes it, so the layer is either whole or absent.
    private func removeDirectory(_ dir: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return }
        try fm.createDirectory(at: layout.enrichmentStagingDir, withIntermediateDirectories: true)
        let aside = layout.enrichmentStagingDir.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        do {
            try fm.moveItem(at: dir, to: aside)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
        do { try fm.removeItem(at: aside) } catch { Self.log.error("\("enrichment_cleanup_failed", privacy: .public)") }
    }

    private static func matches(_ url: URL, _ asset: AssetRef) -> Bool {
        guard let digest = try? StreamingHasher.digest(of: url) else { return false }
        return digest.sha256 == asset.sha256 && digest.byteCount == asset.byteCount
    }

    private static func contents(of dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    /// Flushes a file or directory to stable storage; falls back to `fsync` where `F_FULLFSYNC` isn't supported.
    private static func fullSync(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        if fcntl(fd, F_FULLFSYNC) == 0 { return }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    private static func ms(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }
}
