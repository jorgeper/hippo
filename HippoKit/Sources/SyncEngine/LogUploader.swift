import Foundation
import os
import CaptureCore
import LocalRepository

public struct LogUploadResult: Sendable, Equatable {
    public var uploaded: Int
    /// Nil when the pass went well or had nothing to do.
    public var code: String?

    public init(uploaded: Int, code: String? = nil) {
        self.uploaded = uploaded
        self.code = code
    }
}

/// Copies the event log's segment files to `logs/<install-id>/` on the active destination (design §7.4).
/// A segment is uploaded again whenever its size differs from the size recorded at its last upload. Each
/// file is snapshotted under its `flock` first, so a writer appending during the upload cannot make the
/// remote copy fail verification; the lines it appended go up on the next pass. Uploads are not logged
/// as events, and error codes never carry content.
public final class LogUploader: Sendable {
    private static let osLog = Logger(subsystem: "com.jorgeper.hippo", category: "log")
    static let stateFileName = "upload-state.json"

    private struct State: Codable {
        var files: [String: Int64] = [:]
        var lastAt: Date?
        var lastCode: String?

        enum CodingKeys: String, CodingKey { case files, lastAt = "last_at", lastCode = "last_code" }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(files, forKey: .files)
            try c.encodeIfPresent(lastAt, forKey: .lastAt)
            // `last_code` is always present, null when the pass was fine.
            try c.encode(lastCode, forKey: .lastCode)
        }
    }

    private let layout: StoreLayout
    private let log: ActivityLog
    private let destinations: DestinationStore
    private let installID: String
    private let adapterFor: @Sendable (Destination) throws -> any StorageAdapter
    private let maxFilesPerPass: Int

    public init(layout: StoreLayout, log: ActivityLog, destinations: DestinationStore, installID: String,
                adapterFor: @escaping @Sendable (Destination) throws -> any StorageAdapter, maxFilesPerPass: Int = 5) {
        self.layout = layout
        self.log = log
        self.destinations = destinations
        self.installID = installID
        self.adapterFor = adapterFor
        self.maxFilesPerPass = maxFilesPerPass
    }

    // MARK: State

    private static func stateURL(_ layout: StoreLayout) -> URL {
        layout.logsDir.appendingPathComponent(stateFileName)
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private static func readState(_ layout: StoreLayout) -> State {
        guard let data = try? Data(contentsOf: stateURL(layout)),
              let state = try? decoder().decode(State.self, from: data) else { return State() }
        return state
    }

    private static func writeState(_ state: State, _ layout: StoreLayout) {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        do {
            try FileManager.default.createDirectory(at: layout.logsDir, withIntermediateDirectories: true)
            try e.encode(state).write(to: stateURL(layout), options: .atomic)
        } catch {
            osLog.error("\("upload_state_write_failed", privacy: .public)")
        }
    }

    /// When the last pass that had a destination finished, and its code (nil = ok). Nil if none ran.
    public static func lastResult(layout: StoreLayout) -> (at: Date, code: String?)? {
        let state = readState(layout)
        guard let at = state.lastAt else { return nil }
        return (at, state.lastCode)
    }

    // MARK: Upload

    /// Uploads up to `maxFilesPerPass` changed segment files, oldest name first.
    public func upload() async -> LogUploadResult {
        guard !Task.isCancelled else { return LogUploadResult(uploaded: 0) }
        guard let destination = try? destinations.active(), destination.status == .active else {
            return LogUploadResult(uploaded: 0, code: "no_destination")
        }
        var state = Self.readState(layout)
        let fm = FileManager.default
        let present = log.segmentFiles()
        let names = Set(present.map(\.lastPathComponent))
        state.files = state.files.filter { names.contains($0.key) }

        let candidates = present.filter { url in
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            return size != nil && size != state.files[url.lastPathComponent]
        }.prefix(maxFilesPerPass)
        guard !candidates.isEmpty else {
            // Nothing changed, but the pass ran: refresh the time the UI shows.
            state.lastAt = Date()
            state.lastCode = nil
            Self.writeState(state, layout)
            return LogUploadResult(uploaded: 0)
        }

        var uploaded = 0
        var code: String?
        do {
            let adapter = try adapterFor(destination)
            let directory = "logs/\(installID)"
            try await adapter.ensureContainer(relativePath: directory)
            for url in candidates {
                if Task.isCancelled { break }
                let name = url.lastPathComponent
                do {
                    let copy = layout.stagingDir.appendingPathComponent("log-\(UUID().uuidString.lowercased()).jsonl")
                    defer { try? fm.removeItem(at: copy) }
                    guard let size = Self.snapshot(url, to: copy, fm: fm, staging: layout.stagingDir) else {
                        code = "snapshot_failed"
                        continue
                    }
                    let digest = try StreamingHasher.digest(of: copy)
                    _ = try await adapter.replaceFile(
                        localURL: copy, relativePath: "\(directory)/\(name)",
                        expected: FileIntegrity(byteCount: digest.byteCount, sha256: digest.sha256))
                    state.files[name] = size
                    uploaded += 1
                } catch is CancellationError {
                    break
                } catch let error as StorageError {
                    if case .needsAuthentication = error { code = "needs_authentication"; break }
                    code = Self.code(for: error)
                } catch {
                    code = "upload_failed"
                }
            }
        } catch let error as StorageError {
            code = Self.code(for: error)
        } catch {
            code = "upload_failed"
        }
        if !Task.isCancelled || uploaded > 0 {
            state.lastAt = Date()
            state.lastCode = code
            Self.writeState(state, layout)
        }
        return LogUploadResult(uploaded: uploaded, code: code.map(Diagnostics.safeCode))
    }

    /// Copies `url` to `copy` while holding its `flock` and returns the copy's size, or nil on failure.
    private static func snapshot(_ url: URL, to copy: URL, fm: FileManager, staging: URL) -> Int64? {
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var locked = false
        for _ in 0..<50 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { locked = true; break }
            usleep(20_000)
        }
        guard locked else { return nil }
        defer { flock(fd, LOCK_UN) }
        guard (try? fm.copyItem(at: url, to: copy)) != nil else { return nil }
        return (try? fm.attributesOfItem(atPath: copy.path)[.size] as? NSNumber)?.int64Value
    }

    private static func code(for error: StorageError) -> String {
        switch error {
        case .permanent(let code), .transient(let code): Diagnostics.safeCode(code)
        case .needsAuthentication: "needs_authentication"
        case .offline: "offline"
        case .rateLimited: "rate_limited"
        case .quotaExceeded: "quota_exceeded"
        default: "upload_failed"
        }
    }
}
