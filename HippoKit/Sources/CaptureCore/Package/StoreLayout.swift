import Foundation

/// The local store's on-disk layout. Committed packages live under `captures/` with the same relative
/// layout as the remote destination; `staging/` holds in-progress commits. Local enrichments live under
/// `enrichments/`.
public struct StoreLayout: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public var stagingDir: URL { root.appendingPathComponent("staging", isDirectory: true) }
    public var capturesDir: URL { root.appendingPathComponent("captures", isDirectory: true) }
    public var databaseURL: URL { root.appendingPathComponent("hippo.sqlite") }
    public var diagnosticsURL: URL { root.appendingPathComponent("diagnostics.json") }

    /// Local silver and gold, outside the packages: `enrichments/<layer>/<capture-id>/`.
    public var enrichmentsDir: URL { root.appendingPathComponent("enrichments", isDirectory: true) }
    /// Where enrichment directories are built before they are swapped into place.
    public var enrichmentStagingDir: URL { stagingDir.appendingPathComponent("enrichments", isDirectory: true) }

    /// `enrichments/<layer>/<capture-id>`: keyed by capture ID only, with no date shards.
    public func enrichmentDirectory(_ layer: EnrichmentLayer, captureID: String) -> URL {
        enrichmentsDir.appendingPathComponent(layer.rawValue, isDirectory: true)
            .appendingPathComponent(captureID, isDirectory: true)
    }

    /// `relativeDirectory` is a package path such as `captures/2026/11/07/<capture-id>`.
    public func packageURL(relativeDirectory: String) -> URL {
        root.appendingPathComponent(relativeDirectory, isDirectory: true)
    }
}
