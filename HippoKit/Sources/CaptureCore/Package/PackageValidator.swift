import Foundation
import CryptoKit

public enum ValidationResult: Equatable, Sendable {
    case complete(metadata: CaptureMetadata, packageDigest: String)
    case incomplete(String)
    case corrupt(String)
    case unsupportedSchema(Int)
}

/// The desktop-reader contract (spec §12): a package is usable only when its completion marker is present,
/// supported, safe, and every manifest file is available with the right size and hash.
public enum PackageValidator {
    public static func validate(directory: URL) -> ValidationResult {
        let markerURL = directory.appendingPathComponent("complete.json")
        guard let markerBytes = try? Data(contentsOf: markerURL) else { return .incomplete("no completion marker") }

        let marker: CompletionMarker
        do { marker = try HippoJSON.decodeMarker(markerBytes) }
        catch FormatError.unsupportedSchemaVersion(let v) { return .unsupportedSchema(v) }
        catch { return .corrupt("undecodable completion marker") }

        for entry in marker.files {
            do { try PackagePath.validateRelative(entry.relativePath) }
            catch { return .corrupt("unsafe manifest path") }
        }
        guard marker.files.contains(where: { $0.relativePath == "metadata.json" }) else {
            return .corrupt("manifest lacks metadata.json")
        }

        let fm = FileManager.default
        for entry in marker.files {
            let url = directory.appendingPathComponent(entry.relativePath)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return .incomplete("missing \(entry.relativePath)")
            }
            guard let digest = try? StreamingHasher.digest(of: url) else {
                return .incomplete("missing \(entry.relativePath)")
            }
            guard digest.byteCount == entry.byteCount, digest.sha256 == entry.sha256 else {
                return .incomplete("mismatch \(entry.relativePath)")
            }
        }

        let metadata: CaptureMetadata
        do { metadata = try HippoJSON.decodeMetadata(Data(contentsOf: directory.appendingPathComponent("metadata.json"))) }
        catch FormatError.unsupportedSchemaVersion(let v) { return .unsupportedSchema(v) }
        catch { return .corrupt("undecodable metadata") }

        guard metadata.captureID == marker.captureID else { return .corrupt("capture id differs from marker") }
        guard metadata.captureID == directory.lastPathComponent else { return .corrupt("capture id differs from directory") }
        let listed = Set(marker.files.map(\.relativePath))
        for attachment in metadata.attachments where !listed.contains(attachment.relativePath) {
            return .corrupt("attachment not in manifest")
        }

        let digest = SHA256.hash(data: markerBytes).map { String(format: "%02x", $0) }.joined()
        return .complete(metadata: metadata, packageDigest: digest)
    }
}

extension CommittedPackage {
    /// Non-nil only when `directory` (under `layout.root`) validates `.complete`.
    public static func load(directory: URL, layout: StoreLayout) -> CommittedPackage? {
        let rootPath = layout.root.resolvingSymlinksInPath().standardizedFileURL.path
        let dirPath = directory.resolvingSymlinksInPath().standardizedFileURL.path
        guard dirPath.hasPrefix(rootPath + "/") else { return nil }
        let relative = String(dirPath.dropFirst(rootPath.count + 1))
        guard case .complete(let metadata, _) = PackageValidator.validate(directory: directory),
              let marker = try? HippoJSON.decodeMarker(Data(contentsOf: directory.appendingPathComponent("complete.json")))
        else { return nil }
        let expected = PackagePath.captureDirectory(
            captureID: metadata.captureID,
            localDate: PackagePath.localDateComponents(of: metadata.capturedAt,
                                                       in: TimeZone(identifier: metadata.timezoneIdentifier) ?? .gmt))
        guard relative == expected else { return nil }
        return CommittedPackage(metadata: metadata, marker: marker, relativeDirectory: relative, directoryURL: directory)
    }
}
