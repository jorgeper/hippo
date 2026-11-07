import Foundation

public protocol SpaceChecking: Sendable {
    func availableBytes(at url: URL) throws -> Int64
}

/// Reports the volume's capacity available for important (user-initiated) writes.
public struct VolumeSpaceChecker: SpaceChecking {
    public init() {}

    /// `url` may not exist yet; the nearest existing ancestor is queried (same volume).
    public func availableBytes(at url: URL) throws -> Int64 {
        var probe = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" {
            probe = probe.deletingLastPathComponent()
        }
        let values = try probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let bytes = values.volumeAvailableCapacityForImportantUsage else {
            throw CocoaError(.fileReadUnknown)
        }
        return bytes
    }
}
