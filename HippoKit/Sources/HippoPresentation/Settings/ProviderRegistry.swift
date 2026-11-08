import LocalRepository
import SyncEngine

/// The providers this build implements. The Settings picker lists only these (spec §11).
public struct ProviderRegistry: Sendable {
    public let providers: [any StorageProvider]

    public init(_ providers: [any StorageProvider]) { self.providers = providers }

    public func provider(kind: String) -> (any StorageProvider)? {
        providers.first { $0.kind == kind }
    }

    /// Throws `StorageError.permanent(code: "provider_unavailable")` when this build has no provider
    /// of the destination's kind, so its jobs are surfaced as needing attention rather than retried.
    public func adapter(for d: Destination) throws -> any StorageAdapter {
        guard let provider = provider(kind: d.providerKind) else {
            throw StorageError.permanent(code: "provider_unavailable")
        }
        return try provider.makeAdapter(for: d)
    }
}
