import Foundation
import CaptureCore
import LocalRepository

public enum FormatUploadResult: Sendable, Equatable {
    case noBundle, noDestination, unchanged
    /// `files` counts the files written in this pass; `readmeSkipped` is true when the destination's own root
    /// `README.md` was left alone.
    case uploaded(files: Int, readmeSkipped: Bool)
    case failed(code: String)
}

/// Copies the format documents and schemas to `format/` on the active destination, and Hippo's folder README
/// to its root, so the synced folder describes itself (design §9). A destination receives the bundle again
/// only when the bundle's digest differs from the one recorded after its last finished pass. The root
/// `README.md` is replaced only when it is Hippo's own (first line is the marker); anyone else's is left alone
/// and not retried until the bundle changes. Never throws, and logs carry counts and fixed codes only.
public final class FormatUploader: Sendable {
    static let stateFileName = "format-upload-state.json"
    private static let readmePath = "README.md"

    private struct DestinationState: Codable { var digest: String }

    private let layout: StoreLayout
    private let log: ActivityLog
    private let destinations: DestinationStore
    private let bundle: FormatBundle?
    private let adapterFor: @Sendable (Destination) throws -> any StorageAdapter

    /// A nil `bundle` (the app shipped without the files) makes every `upload()` a no-op.
    public init(layout: StoreLayout, log: ActivityLog, destinations: DestinationStore, bundle: FormatBundle?,
                adapterFor: @escaping @Sendable (Destination) throws -> any StorageAdapter) {
        self.layout = layout
        self.log = log
        self.destinations = destinations
        self.bundle = bundle
        self.adapterFor = adapterFor
    }

    // MARK: State

    private var stateURL: URL { layout.root.appendingPathComponent(Self.stateFileName) }

    private func readState() -> [String: DestinationState] {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode([String: DestinationState].self, from: data) else { return [:] }
        return state
    }

    private func record(digest: String, destinationID: String) {
        var state = readState()
        state[destinationID] = DestinationState(digest: digest)
        writeState(state)
    }

    private func writeState(_ state: [String: DestinationState]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // A failed write only means the next pass uploads again.
        try? encoder.encode(state).write(to: stateURL, options: .atomic)
    }

    /// Forgets what was recorded for `destinationID`, so the next `upload()` writes the files again. Called when
    /// a destination is connected: the person may have deleted `format/` or `README.md` while it was away.
    public func forgetUpload(destinationID: String) {
        var state = readState()
        guard state.removeValue(forKey: destinationID) != nil else { return }
        writeState(state)
    }

    // MARK: Upload

    public func upload() async -> FormatUploadResult {
        guard let bundle else { return .noBundle }
        guard !Task.isCancelled else { return .failed(code: "cancelled") }
        guard let destination = try? destinations.active(), destination.status == .active else { return .noDestination }
        if readState()[destination.id]?.digest == bundle.digest { return .unchanged }

        var written = 0
        var readmeSkipped = false
        do {
            let adapter = try adapterFor(destination)
            try await adapter.ensureContainer(relativePath: "format")
            try await adapter.ensureContainer(relativePath: "format/schema")
            for file in bundle.formatFiles {
                try Task.checkCancellation()
                try await replace(file, adapter: adapter)
                written += 1
            }
            try Task.checkCancellation()
            if try await mayReplaceRootReadme(adapter) {
                try await replace(bundle.readme, adapter: adapter)
                written += 1
            } else {
                readmeSkipped = true
            }
        } catch {
            let code = Self.code(for: error)
            log.append(LogEvent(event: .formatUploadFailed, code: code, dest: destination.providerKind))
            return .failed(code: code)
        }
        record(digest: bundle.digest, destinationID: destination.id)
        log.append(LogEvent(event: .formatUploaded, count: written, dest: destination.providerKind))
        if readmeSkipped {
            log.append(LogEvent(event: .formatReadmeSkipped, code: "readme_foreign", dest: destination.providerKind))
        }
        return .uploaded(files: written, readmeSkipped: readmeSkipped)
    }

    private func replace(_ file: FormatBundle.File, adapter: any StorageAdapter) async throws {
        let digest = try StreamingHasher.digest(of: file.localURL)
        _ = try await adapter.replaceFile(localURL: file.localURL, relativePath: file.relativePath,
                                          expected: FileIntegrity(byteCount: digest.byteCount, sha256: digest.sha256))
    }

    /// True when the destination has no `README.md` or its `README.md` is Hippo's own. False when it is anyone
    /// else's, including one over the read cap or a folder. Any other error (an outage, say) propagates: it is not "foreign".
    private func mayReplaceRootReadme(_ adapter: any StorageAdapter) async throws -> Bool {
        let found: RemoteFileInfo?
        do {
            found = try await adapter.inspectFile(relativePath: Self.readmePath)
        } catch StorageError.permanent(code: "path_is_directory") {
            return false  // A folder named README.md is not ours to replace.
        }
        guard let info = found else { return true }
        guard info.byteCount <= FormatBundle.readmeReadCap else { return false }
        let fm = FileManager.default
        try? fm.createDirectory(at: layout.stagingDir, withIntermediateDirectories: true)
        let copy = layout.stagingDir.appendingPathComponent("format-readme-\(UUID().uuidString.lowercased())")
        defer { try? fm.removeItem(at: copy) }
        do {
            _ = try await adapter.downloadFile(relativePath: Self.readmePath, to: copy,
                                               maxBytes: FormatBundle.readmeReadCap)
        } catch StorageError.permanent(code: "too_large") {
            return false
        }
        let head = try FileHandle(forReadingFrom: copy).read(upToCount: Int(FormatBundle.readmeReadCap)) ?? Data()
        return FormatBundle.firstLine(of: head) == FormatBundle.readmeMarker
    }

    private static func code(for error: Error) -> String {
        switch error {
        case let e as StorageError:
            switch e {
            case .permanent(let code), .transient(let code): Diagnostics.safeCode(code)
            case .needsAuthentication: "needs_authentication"
            case .offline: "offline"
            case .rateLimited: "rate_limited"
            case .quotaExceeded: "quota_exceeded"
            default: "upload_failed"
            }
        case is CancellationError: "cancelled"
        default: "upload_failed"
        }
    }
}
