import Foundation

public struct RemoteEnrichmentPath: Sendable, Equatable {
    public enum File: Sendable, Equatable {
        case document
        case asset(String)
    }
    public var layer: EnrichmentLayer
    public var captureID: String
    /// `enrichments/<layer>/YYYY/MM/DD/<capture-id>`
    public var directory: String
    public var file: File
}

/// Remote (destination-relative) layout of enrichment files.
public enum EnrichmentPaths {
    public static let documentName = "enrichment.json"

    /// Maps `captures/YYYY/MM/DD/<uuid>` to `enrichments/<layer>/YYYY/MM/DD/<uuid>`.
    public static func remoteDirectory(_ layer: EnrichmentLayer, packageDirectory: String) throws -> String {
        let parts = packageDirectory.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5, parts[0] == "captures",
              isDigits(parts[1], 4), isDigits(parts[2], 2), isDigits(parts[3], 2),
              isLowercaseUUID(parts[4]) else { throw FormatError.unsafePath(packageDirectory) }
        return (["enrichments", layer.rawValue] + parts[1...]).joined(separator: "/")
    }

    /// Accepts only `enrichments/<layer>/YYYY/MM/DD/<uuid>/enrichment.json` or `…/assets/<valid name>`.
    public static func parseRemote(_ path: String) -> RemoteEnrichmentPath? {
        let p = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard p.count >= 7, p[0] == "enrichments", let layer = EnrichmentLayer(rawValue: p[1]),
              isDigits(p[2], 4), isDigits(p[3], 2), isDigits(p[4], 2), isLowercaseUUID(p[5]) else { return nil }
        let directory = p[0...5].joined(separator: "/")
        if p.count == 7, p[6] == documentName {
            return RemoteEnrichmentPath(layer: layer, captureID: p[5], directory: directory, file: .document)
        }
        if p.count == 8, p[6] == "assets", isValidAssetPath("assets/" + p[7]) {
            return RemoteEnrichmentPath(layer: layer, captureID: p[5], directory: directory, file: .asset(p[7]))
        }
        return nil
    }

    /// `assets/<64 lowercase hex>.<1–10 of [a-z0-9]>`
    public static func isValidAssetPath(_ p: String) -> Bool {
        let parts = p.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "assets" else { return false }
        let name = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        guard name.count == 2, isLowercaseHex(String(name[0]), 64) else { return false }
        let ext = name[1].utf8
        return (1...10).contains(ext.count) && ext.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) }
    }

    static func isDigits(_ s: String, _ n: Int) -> Bool {
        s.utf8.count == n && s.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }

    static func isLowercaseHex(_ s: String, _ n: Int) -> Bool {
        s.utf8.count == n && s.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    static func isLowercaseUUID(_ s: String) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        let sizes = [8, 4, 4, 4, 12]
        guard parts.count == 5 else { return false }
        return zip(parts, sizes).allSatisfy { isLowercaseHex(String($0), $1) }
    }
}
