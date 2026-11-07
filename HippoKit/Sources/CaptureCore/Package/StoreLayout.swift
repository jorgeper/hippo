import Foundation

/// The local store's on-disk layout. Committed packages live under `captures/` with the same relative
/// layout as the remote destination; `staging/` holds in-progress commits.
public struct StoreLayout: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public var stagingDir: URL { root.appendingPathComponent("staging", isDirectory: true) }
    public var capturesDir: URL { root.appendingPathComponent("captures", isDirectory: true) }
    public var databaseURL: URL { root.appendingPathComponent("hippo.sqlite") }
    public var diagnosticsURL: URL { root.appendingPathComponent("diagnostics.json") }

    /// `relativeDirectory` is a package path such as `captures/2026/11/07/<capture-id>`.
    public func packageURL(relativeDirectory: String) -> URL {
        root.appendingPathComponent(relativeDirectory, isDirectory: true)
    }
}
