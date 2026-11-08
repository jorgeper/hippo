import Foundation
import os
import CaptureCore
import LocalRepository

public struct GoldPullResult: Sendable, Equatable {
    public var applied: Int
    public var removed: Int
    public var ignored: Int
    public var skipped: Int
    /// An adapter error that ended the pull, else the last per-document skip or mismatch code, else nil.
    public var code: String?

    public init(applied: Int = 0, removed: Int = 0, ignored: Int = 0, skipped: Int = 0, code: String? = nil) {
        self.applied = applied; self.removed = removed; self.ignored = ignored; self.skipped = skipped
        self.code = code
    }
}

/// Pulls server-produced (gold) enrichment from the active destination's `enrichments/server/` tree into
/// the local server layer (design §6.5). Documents are size-capped, decoded and checked against the path
/// they came from, and every referenced asset is verified by SHA-256 before anything is written, so the
/// local layer only ever holds complete, checked documents. A document that fails a check is skipped and
/// not retried: the cursor moves past it. Bronze and the device layer are never touched. Codes are fixed
/// strings; nothing here logs or records content, paths, URLs or IDs.
public final class GoldPuller: Sendable {
    public static let prefix = "enrichments/server/"
    public let maxDocumentBytes: Int64 = 1_048_576
    public let maxAssetBytes: Int64 = 5_242_880
    public let softChangeLimit = 200

    private static let log = Logger(subsystem: "com.jorgeper.hippo", category: "enrichment")

    private let layout: StoreLayout
    private let index: CaptureIndex
    private let destinations: DestinationStore
    private let enrichments: EnrichmentStore
    private let adapterFor: @Sendable (Destination) throws -> any StorageAdapter
    private let now: @Sendable () -> Date

    public init(layout: StoreLayout, index: CaptureIndex, destinations: DestinationStore, enrichments: EnrichmentStore,
                adapterFor: @escaping @Sendable (Destination) throws -> any StorageAdapter,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.layout = layout
        self.index = index
        self.destinations = destinations
        self.enrichments = enrichments
        self.adapterFor = adapterFor
        self.now = now
    }

    /// One pass over the changes since the saved cursor. Cancellation ends it at once and records nothing.
    public func pull() async -> GoldPullResult {
        var result = GoldPullResult()
        guard !Task.isCancelled, let destination = try? destinations.active() else { return result }

        let staging = layout.stagingDir.appendingPathComponent("gold-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        var itemCode: String?
        var endCode: String?
        do {
            let adapter = try adapterFor(destination)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            var cursor = try enrichments.goldCursor(destinationID: destination.id)
            var resetUsed = false
            var processed = 0
            while true {
                try Task.checkCancellation()
                let page: ChangePage
                do {
                    page = try await adapter.listChanges(under: Self.prefix, cursor: cursor)
                } catch StorageError.cursorReset {
                    if resetUsed { endCode = "cursor_reset"; break }
                    resetUsed = true
                    cursor = nil
                    continue
                }
                for change in page.changes {
                    try Task.checkCancellation()
                    processed += 1
                    if let code = try await handle(change, adapter: adapter, staging: staging, result: &result) {
                        itemCode = code
                    }
                }
                try enrichments.saveGoldCursor(destinationID: destination.id, cursor: page.cursor, now: now())
                cursor = page.cursor
                if !page.hasMore || processed >= softChangeLimit { break }
            }
        } catch is CancellationError {
            return result
        } catch let error as StorageError {
            if Task.isCancelled { return result }
            endCode = Self.code(for: error)
        } catch {
            if Task.isCancelled { return result }
            Self.log.error("\("gold_pull_failed", privacy: .public)")
            endCode = "transient:internal"
        }

        result.code = endCode ?? itemCode
        do {
            try enrichments.recordGoldResult(destinationID: destination.id, code: result.code ?? "ok", now: now())
        } catch {
            Self.log.error("\("gold_record_failed", privacy: .public)")
        }
        return result
    }

    /// A per-document failure: the document is skipped and the pull goes on.
    private struct Skip: Error { var code: String }
    /// A local write failed: the pull ends with the cursor at the last saved page, so the document is retried.
    private struct WriteFailed: Error {}

    /// Applies one change. Returns a code when the change was skipped or applied with a mismatch.
    private func handle(_ change: RemoteChange, adapter: any StorageAdapter, staging: URL,
                        result: inout GoldPullResult) async throws -> String? {
        switch change {
        case .deleted(let path):
            guard let parsed = EnrichmentPaths.parseRemote(path), parsed.layer == .server,
                  parsed.file == .document, try isIndexed(parsed.captureID) else {
                result.ignored += 1
                return nil
            }
            let dir = layout.enrichmentDirectory(.server, captureID: parsed.captureID)
            let existed = FileManager.default.fileExists(atPath: dir.path)
            try enrichments.removeLayer(.server, captureID: parsed.captureID)
            if existed { result.removed += 1 } else { result.ignored += 1 }
            return nil
        case .upserted(let info):
            guard let parsed = EnrichmentPaths.parseRemote(info.relativePath), parsed.layer == .server,
                  parsed.file == .document, try isIndexed(parsed.captureID) else {
                result.ignored += 1
                return nil
            }
            let work = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: work) }
            do {
                let code = try await apply(info, parsed: parsed, adapter: adapter, work: work)
                result.applied += 1
                return code
            } catch let skip as Skip {
                result.skipped += 1
                return skip.code
            } catch EnrichmentStoreError.notIndexed {
                result.ignored += 1
                return nil
            } catch is WriteFailed {
                throw StorageError.transient(code: "gold_write_failed")
            }
        }
    }

    private func apply(_ info: RemoteFileInfo, parsed: RemoteEnrichmentPath, adapter: any StorageAdapter,
                       work: URL) async throws -> String? {
        guard info.byteCount <= maxDocumentBytes else { throw Skip(code: "gold_too_large") }
        let fm = FileManager.default
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let documentURL = work.appendingPathComponent(EnrichmentPaths.documentName)
        do {
            _ = try await adapter.downloadFile(relativePath: info.relativePath, to: documentURL, maxBytes: maxDocumentBytes)
        } catch StorageError.permanent(let code) {
            throw Skip(code: code == "too_large" ? "gold_too_large" : "gold_missing")
        }
        let document: EnrichmentDocument
        do {
            document = try EnrichmentJSON.decode(try Data(contentsOf: documentURL))
        } catch FormatError.unsupportedSchemaVersion {
            throw Skip(code: "gold_unsupported_version")
        } catch {
            throw Skip(code: "gold_invalid")
        }
        guard document.captureID == parsed.captureID, document.layer == .server else { throw Skip(code: "gold_mismatch") }

        var newAssets: [String: URL] = [:]
        for asset in document.referencedAssets() {
            try Task.checkCancellation()
            guard EnrichmentPaths.isValidAssetPath(asset.relativePath), asset.byteCount >= 0,
                  asset.byteCount <= maxAssetBytes else { throw Skip(code: "gold_asset_invalid") }
            if localAssetMatches(asset, captureID: document.captureID) { continue }
            let local = work.appendingPathComponent(asset.relativePath)
            try fm.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                _ = try await adapter.downloadFile(relativePath: parsed.directory + "/" + asset.relativePath, to: local,
                                                   maxBytes: maxAssetBytes)
            } catch StorageError.permanent {
                throw Skip(code: "gold_asset_invalid")
            }
            guard let digest = try? StreamingHasher.digest(of: local), digest.sha256 == asset.sha256,
                  digest.byteCount == asset.byteCount else { throw Skip(code: "gold_asset_invalid") }
            newAssets[asset.relativePath] = local
        }

        try Task.checkCancellation()
        do {
            try enrichments.write(document, newAssets: newAssets)
        } catch EnrichmentStoreError.notIndexed {
            throw EnrichmentStoreError.notIndexed
        } catch {
            Self.log.error("\("gold_write_failed", privacy: .public)")
            throw WriteFailed()
        }
        // The document was made for another version of the package; it is applied all the same.
        return document.packageDigest == (try? index.packageDigest(captureID: document.captureID)) ? nil
            : "gold_digest_mismatch"
    }

    private func localAssetMatches(_ asset: AssetRef, captureID: String) -> Bool {
        let url = enrichments.assetURL(.server, captureID: captureID, asset: asset)
        guard let digest = try? StreamingHasher.digest(of: url) else { return false }
        return digest.sha256 == asset.sha256 && digest.byteCount == asset.byteCount
    }

    private func isIndexed(_ captureID: String) throws -> Bool {
        try index.packageDigest(captureID: captureID) != nil
    }

    private static func code(for error: StorageError) -> String {
        switch error {
        case .offline: "offline"
        case .transient(let code): "transient:\(code)"
        case .rateLimited: "rate_limited"
        case .checkpointExpired: "checkpoint_expired"
        case .cursorReset: "cursor_reset"
        case .needsAuthentication: "needs_authentication"
        case .quotaExceeded: "quota_exceeded"
        case .conflict: "remote_conflict"
        case .permanent(let code): "permanent:\(code)"
        }
    }
}
