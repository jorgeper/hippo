import Foundation
import SyncEngine

public enum DropboxPaths {
    /// Validated like `FilesystemAdapter.resolve`; builds `/<root>/<rel>` (root may be empty).
    public static func remote(_ relativePath: String, root: String) throws -> String {
        let invalid = StorageError.permanent(code: "invalid_path")
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"), !relativePath.contains("\0") else { throw invalid }
        for seg in relativePath.split(separator: "/", omittingEmptySubsequences: false) {
            if seg.isEmpty || seg == "." || seg == ".." { throw invalid }
        }
        return "/" + [root, relativePath].filter { !$0.isEmpty }.joined(separator: "/")
    }

    /// The path under the root, matching case-insensitively (Dropbox paths are case-insensitive), else nil.
    public static func relative(_ display: String, root: String) -> String? {
        let prefix = root.isEmpty ? "/" : "/\(root)/"
        guard display.count > prefix.count,
              display.lowercased().hasPrefix(prefix.lowercased()) else { return nil }
        return String(display.dropFirst(prefix.count))
    }
}
