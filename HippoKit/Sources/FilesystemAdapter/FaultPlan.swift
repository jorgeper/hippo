import Foundation
import SyncEngine

/// Scripted, one-shot faults keyed by exact relative path, plus a log of adapter operations.
public final class FaultPlan: @unchecked Sendable {
    public static var none: FaultPlan { FaultPlan() }

    private let lock = NSLock()
    private var beforeWrite: [String: StorageError] = [:]
    private var afterBytes: [String: (Int64, StorageError)] = [:]
    private var writeThrow: [String: StorageError] = [:]
    private var log: [String] = []

    public init() {}

    public func failBeforeWrite(_ path: String, _ e: StorageError) {
        lock.lock(); defer { lock.unlock() }
        beforeWrite[path] = e
    }

    /// Fires once the upload has copied at least `n` bytes (and saved the checkpoint for them).
    public func failAfterBytes(_ path: String, _ n: Int64, _ e: StorageError) {
        lock.lock(); defer { lock.unlock() }
        afterBytes[path] = (n, e)
    }

    /// Completes the write, then throws: "request succeeded but the response was lost".
    public func writeButThrow(_ path: String, _ e: StorageError) {
        lock.lock(); defer { lock.unlock() }
        writeThrow[path] = e
    }

    public var operations: [String] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    func record(_ op: String) {
        lock.lock(); defer { lock.unlock() }
        log.append(op)
    }

    func takeBeforeWrite(_ path: String) -> StorageError? {
        lock.lock(); defer { lock.unlock() }
        return beforeWrite.removeValue(forKey: path)
    }

    func takeAfterBytes(_ path: String, copied: Int64) -> StorageError? {
        lock.lock(); defer { lock.unlock() }
        guard let (n, e) = afterBytes[path], copied >= n else { return nil }
        afterBytes.removeValue(forKey: path)
        return e
    }

    func takeWriteButThrow(_ path: String) -> StorageError? {
        lock.lock(); defer { lock.unlock() }
        return writeThrow.removeValue(forKey: path)
    }
}
