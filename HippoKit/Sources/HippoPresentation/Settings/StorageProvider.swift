import LocalRepository
import SyncEngine

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
}
