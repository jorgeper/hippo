import Foundation

/// Temporary files gathered before a capture is committed. They live under the store root so the
/// package writer's copy is a same-volume clone.
public struct IntakeDirectory: Sendable {
    private let root: URL

    /// `<storeRoot>/intake`
    public init(storeRoot: URL) {
        root = storeRoot.appendingPathComponent("intake", isDirectory: true)
    }

    /// `<storeRoot>/intake/<lowercased capture id>/`
    public func directory(for captureID: UUID) -> URL {
        root.appendingPathComponent(captureID.uuidString.lowercased(), isDirectory: true)
    }

    /// `<storeRoot>/intake/recording-<lowercased id>.m4a`
    public func recordingURL(id: UUID) -> URL {
        root.appendingPathComponent("recording-\(id.uuidString.lowercased()).m4a", isDirectory: false)
    }

    public func discard(captureID: UUID) {
        try? FileManager.default.removeItem(at: directory(for: captureID))
    }

    /// Removes every intake entry last modified more than `olderThan` seconds before `now`.
    public func sweep(olderThan: TimeInterval, now: Date) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let cutoff = now.addingTimeInterval(-olderThan)
        for entry in entries {
            guard let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified < cutoff else { continue }
            try? fm.removeItem(at: entry)
        }
    }
}
