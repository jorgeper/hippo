import LocalRepository
import SyncEngine

/// Whether a provider can still reach the destination's account, as far as it knows without a network call.
public enum ProviderAccountStatus: Sendable, Equatable {
    case ok
    /// The sign-in expired or was revoked: Settings offers "Reconnect <name>".
    case needsSignIn
    /// This build can't sign in to the provider at all (no app key).
    case notConfigured
}

/// One kind of upload destination (Dropbox, or the debug developer folder): connects an account,
/// builds the adapter that uploads to it, and signs out. Kept provider-neutral (spec §8).
public protocol StorageProvider: Sendable {
    /// Matches `Destination.providerKind`.
    var kind: String { get }
    var displayName: String { get }
    /// Interactive sign-in. Main app only: the Share Extension never shows sign-in UI.
    @MainActor func connect() async throws -> Destination
    func makeAdapter(for d: Destination) throws -> any StorageAdapter
    /// Forgets the destination's credentials. Local captures and their jobs are handled by the caller.
    func signOut(_ d: Destination) async
    /// The account's sign-in state for `d`, read locally (no network).
    func accountStatus(_ d: Destination) async -> ProviderAccountStatus
}

extension StorageProvider {
    public func accountStatus(_ d: Destination) async -> ProviderAccountStatus { .ok }
}
