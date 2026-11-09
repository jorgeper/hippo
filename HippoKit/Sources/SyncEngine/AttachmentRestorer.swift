import Foundation
import CaptureCore
import LocalRepository

public enum RestoreError: Error, Equatable {
    /// The file's destination isn't the connected one (or nothing is connected).
    case notConnected(destinationName: String?)
    case offline
    /// The destination's copy no longer matches the recorded hash.
    case mismatch
    case notFound
    case failed(code: String)
}

/// Downloads a trimmed attachment back into its package (design §6.4), after checking its SHA-256 and size
/// against what was recorded when it was trimmed.
public final class AttachmentRestorer: Sendable {
    private let layout: StoreLayout
    private let index: CaptureIndex
    private let trims: TrimStore
    private let destinations: DestinationStore
    private let adapterFor: @Sendable (Destination) throws -> any StorageAdapter
    private let log: ActivityLog?

    public init(layout: StoreLayout, index: CaptureIndex, trims: TrimStore, destinations: DestinationStore,
                adapterFor: @escaping @Sendable (Destination) throws -> any StorageAdapter, log: ActivityLog? = nil) {
        self.layout = layout
        self.index = index
        self.trims = trims
        self.destinations = destinations
        self.adapterFor = adapterFor
        self.log = log
    }

    public func restore(captureID: String, attachmentID: String,
                        progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        guard let row = try trimmedRow(captureID: captureID, attachmentID: attachmentID),
              let directory = try index.relativeDirectory(captureID: captureID) else { throw RestoreError.notFound }
        let rowDestination = try? destinations.destination(id: row.destinationID)
        guard let active = try? destinations.active() else {
            throw RestoreError.notConnected(destinationName: rowDestination?.displayName)
        }
        guard active.id == row.destinationID else {
            throw RestoreError.notConnected(destinationName: rowDestination?.displayName)
        }

        let fm = FileManager.default
        let temp = layout.transfersDir.appendingPathComponent("restore-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temp) }
        do {
            try fm.createDirectory(at: layout.transfersDir, withIntermediateDirectories: true)
            let adapter = try adapterFor(active)
            let size = row.byteCount
            _ = try await adapter.downloadFile(relativePath: directory + "/" + row.relativePath, to: temp,
                                               maxBytes: size, progress: { progress($0, size) })
            let digest = try StreamingHasher.digest(of: temp)
            guard digest.sha256 == row.sha256, digest.byteCount == row.byteCount else {
                try? fm.removeItem(at: temp)
                try? trims.setState(captureID: captureID, attachmentID: attachmentID, state: .mismatch)
                fail("mismatch", captureID, active)
                throw RestoreError.mismatch
            }
            let destination = layout.packageURL(relativeDirectory: directory).appendingPathComponent(row.relativePath)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: temp, to: destination)
            try trims.remove(captureID: captureID, attachmentID: attachmentID)
            log?.append(LogEvent(event: .attachmentRestored, captureID: captureID, outcome: .ok, dest: active.providerKind))
        } catch let e as RestoreError {
            throw e
        } catch StorageError.permanent(code: "not_found") {
            try? trims.setState(captureID: captureID, attachmentID: attachmentID, state: .mismatch)
            fail("not_found", captureID, active)
            throw RestoreError.notFound
        } catch StorageError.offline {
            fail("offline", captureID, active)
            throw RestoreError.offline
        } catch StorageError.needsAuthentication {
            fail("needs_authentication", captureID, active)
            throw RestoreError.notConnected(destinationName: active.displayName)
        } catch {
            let code = (error as? StorageError).map(GoldPuller.code(for:)) ?? "restore_failed"
            fail(code, captureID, active)
            throw RestoreError.failed(code: Diagnostics.safeCode(code))
        }
    }

    private func trimmedRow(captureID: String, attachmentID: String) throws -> TrimmedAttachment? {
        try trims.trimmed(captureID: captureID).first { $0.attachmentID == attachmentID }
    }

    private func fail(_ code: String, _ captureID: String, _ destination: Destination) {
        log?.append(LogEvent(event: .attachmentRestored, captureID: captureID, outcome: .failed, code: code,
                             dest: destination.providerKind))
    }
}
