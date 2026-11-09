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
    /// `trimmed` lists manifest paths whose files may be absent (their originals live only in the
    /// destination). A listed file that is present is still hashed and must match.
    public static func validate(directory: URL, trimmed: Set<String> = []) -> ValidationResult {
        validateReturningMarker(directory: directory, trimmed: trimmed).result
    }

    /// Like `validate`, also returning the marker decoded from the very bytes that were validated.
    static func validateReturningMarker(directory: URL, trimmed: Set<String> = [])
        -> (result: ValidationResult, marker: CompletionMarker?) {
        var marker: CompletionMarker?
        let result = check(directory: directory, trimmed: trimmed, marker: &marker)
        return (result, marker)
    }

    private static func check(directory: URL, trimmed: Set<String>, marker decodedMarker: inout CompletionMarker?) -> ValidationResult {
        let markerURL = directory.appendingPathComponent("complete.json")
        guard let markerBytes = try? Data(contentsOf: markerURL) else { return .incomplete("no completion marker") }

        let marker: CompletionMarker
        do { marker = try HippoJSON.decodeMarker(markerBytes) }
        catch FormatError.unsupportedSchemaVersion(let v) { return .unsupportedSchema(v) }
        catch { return .corrupt("undecodable completion marker") }
        decodedMarker = marker

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
            if trimmed.contains(entry.relativePath), !fm.fileExists(atPath: url.path) { continue }
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
    public static func load(directory: URL, layout: StoreLayout, trimmed: Set<String> = []) -> CommittedPackage? {
        let rootPath = layout.root.resolvingSymlinksInPath().standardizedFileURL.path
        let dirPath = directory.resolvingSymlinksInPath().standardizedFileURL.path
        guard dirPath.hasPrefix(rootPath + "/") else { return nil }
        let relative = String(dirPath.dropFirst(rootPath.count + 1))
        let (result, marker) = PackageValidator.validateReturningMarker(directory: directory, trimmed: trimmed)
        guard case .complete(let metadata, _) = result, let marker else { return nil }
        // Structural check from the recorded local date (spec §6), never from time-zone math.
        let date = metadata.localDatetime.prefix(10)
        let parts = date.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2 else { return nil }
        guard relative == "captures/\(parts[0])/\(parts[1])/\(parts[2])/\(metadata.captureID)" else { return nil }
        return CommittedPackage(metadata: metadata, marker: marker, relativeDirectory: relative, directoryURL: directory)
    }
}
