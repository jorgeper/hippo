#if DEBUG
import Foundation
import LocalRepository
import SyncEngine
import FilesystemAdapter
import HippoPresentation

/// Debug-only destination that "uploads" into a folder in the App Group container, so the whole sync
/// path can be exercised without an account. Nothing leaves the iPhone.
struct DevFolderProvider: StorageProvider {
    enum Failure: Error { case appGroupUnavailable }

    let kind = "filesystem"
    let displayName = "Developer folder"

    @MainActor func connect() async throws -> Destination {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppEnvironment.appGroupID) else { throw Failure.appGroupUnavailable }
        let root = container
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("HippoDevRemote", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Destination(id: "dev-folder", providerKind: kind, accountIdentifier: "this-iphone",
                           remoteRoot: root.path, displayName: displayName, status: .active)
    }

    func makeAdapter(for d: Destination) throws -> any StorageAdapter {
        FilesystemAdapter(root: URL(fileURLWithPath: d.remoteRoot, isDirectory: true))
    }

    func signOut(_ d: Destination) async {}
}
#endif
