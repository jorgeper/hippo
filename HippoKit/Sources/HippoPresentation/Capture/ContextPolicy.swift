import Foundation
import CaptureCore

/// Chooses which capture-time context entries are recorded with a capture.
public enum ContextPolicy {
    /// A snapshot taken further than this from the capture start is treated as absent.
    public static let maxSnapshotAge: TimeInterval = 120

    /// [] when `enabled` is false. The snapshot is used when |takenAt - captureStartedAt| <= `maxSnapshotAge`;
    /// otherwise it is treated as absent. A missing network entry is filled from `networkAtSave`.
    public static func observations(enabled: Bool, snapshot: ContextSnapshot?, captureStartedAt: Date,
                                    networkAtSave: ContextSnapshot.Network?) -> [MetadataObservation] {
        guard enabled else { return [] }
        var used = snapshot.flatMap { abs($0.takenAt.timeIntervalSince(captureStartedAt)) <= maxSnapshotAge ? $0 : nil }
        if used?.network == nil, let networkAtSave {
            used = used ?? ContextSnapshot(takenAt: captureStartedAt)
            used?.network = networkAtSave
        }
        return used.map(ContextObservations.observations(from:)) ?? []
    }
}
