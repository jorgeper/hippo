#if DEBUG
import Foundation
import LocalRepository
import SyncEngine
import FilesystemAdapter
import CaptureCore
import HippoPresentation

/// Debug-only destination that "uploads" into a folder in the App Group container, so the whole sync
/// path can be exercised without an account. Nothing leaves the iPhone.
struct DevFolderProvider: StorageProvider {
    enum Failure: Error { case appGroupUnavailable }

    let kind = "filesystem"
    let displayName = "Developer folder"

    /// Recomputed on every use: App Group container paths can change across reinstalls.
    static func remoteRoot() throws -> URL {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppEnvironment.appGroupID) else { throw Failure.appGroupUnavailable }
        return container
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("HippoDevRemote", isDirectory: true)
    }

    @MainActor func connect() async throws -> Destination {
        let root = try Self.remoteRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Destination(id: "dev-folder", providerKind: kind, accountIdentifier: "this-iphone",
                           remoteRoot: root.path, displayName: displayName, status: .active)
    }

    func makeAdapter(for d: Destination) throws -> any StorageAdapter {
        FilesystemAdapter(root: try Self.remoteRoot())
    }

    func signOut(_ d: Destination) async {}
}

extension DevFolderProvider {
    /// Writes `GoldSample` for the newest capture to `<HippoDevRemote>/enrichments/server/…/enrichment.json`.
    /// Returns false when there is no capture or it has no synced job to the developer folder.
    static func writeSampleGold(store: HippoStore) async -> Bool {
        await Task.detached { () -> Bool in
            do {
                guard let newest = try store.index.page(CaptureFilter(), after: nil, limit: 1).first,
                      try store.jobs.jobs(captureID: newest.id).contains(where: {
                          $0.destinationID == "dev-folder" && $0.state == .synced }),
                      let metadata = try store.index.metadata(captureID: newest.id, layout: store.layout),
                      let digest = try store.index.packageDigest(captureID: newest.id) else { return false }
                let doc = GoldSample.make(metadata: metadata, packageDigest: digest, now: Date())
                let directory = try remoteRoot().appendingPathComponent(
                    try EnrichmentPaths.remoteDirectory(.server, packageDirectory: newest.relativeDirectory), isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try EnrichmentJSON.encode(doc).write(to: directory.appendingPathComponent(EnrichmentPaths.documentName),
                                                     options: .atomic)
                return true
            } catch {
                return false
            }
        }.value
    }
}
#endif
