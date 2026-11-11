import Foundation
import CryptoKit
import CaptureCore

/// The files that let a synced folder describe itself (design §9): the format documents and JSON Schemas the
/// app ships, as they will sit in the destination. `docs/folder-readme.md` is stored twice, as
/// `format/README.md` and as the root `README.md`.
public struct FormatBundle: Sendable, Equatable {
    public struct File: Sendable, Equatable {
        public var relativePath: String
        public var localURL: URL

        public init(relativePath: String, localURL: URL) {
            self.relativePath = relativePath
            self.localURL = localURL
        }
    }

    public enum LoadError: Error, Equatable {
        case missingDocument(String)
        case noSchemas
        case readmeMarkerMissing
    }

    /// The first line of `docs/folder-readme.md`; the root `README.md` is only replaced while it carries this.
    public static let readmeMarker = "<!-- Hippo folder README. Written by the Hippo app and replaced when the app updates. -->"
    /// The most of a destination's `README.md` that is read to look for the marker.
    public static let readmeReadCap: Int64 = 64 * 1024

    /// `format/README.md`, the three documents and `format/schema/<name>`, sorted by path.
    public var formatFiles: [File]
    /// `README.md`: the same local file as `format/README.md`.
    public var readme: File
    /// SHA-256 hex over each (relative path, file SHA-256) in order, `README.md` last.
    public var digest: String

    /// Source file name in `docsDirectory` -> path under `format/`.
    private static let documents = [
        ("folder-readme.md", "format/README.md"),
        ("package-format.md", "format/package-format.md"),
        ("enrichment-format.md", "format/enrichment-format.md"),
        ("context-signals.md", "format/context-signals.md"),
    ]

    /// `docsDirectory` holds the four `.md` files; `schemaDirectory` holds `*.schema.json`. Throws when a
    /// document is missing, no schema is found, or `folder-readme.md` does not start with `readmeMarker`.
    public static func load(docsDirectory: URL, schemaDirectory: URL) throws -> FormatBundle {
        let fm = FileManager.default
        var files: [File] = []
        for (name, path) in documents {
            let url = docsDirectory.appendingPathComponent(name)
            guard fm.isReadableFile(atPath: url.path) else { throw LoadError.missingDocument(name) }
            files.append(File(relativePath: path, localURL: url))
        }
        let schemas = ((try? fm.contentsOfDirectory(atPath: schemaDirectory.path)) ?? [])
            .filter { $0.hasSuffix(".schema.json") }
        guard !schemas.isEmpty else { throw LoadError.noSchemas }
        files += schemas.map { File(relativePath: "format/schema/\($0)", localURL: schemaDirectory.appendingPathComponent($0)) }
        files.sort { $0.relativePath < $1.relativePath }

        let readmeURL = docsDirectory.appendingPathComponent("folder-readme.md")
        guard let head = try? FileHandle(forReadingFrom: readmeURL).read(upToCount: 1024),
              firstLine(of: head) == readmeMarker else { throw LoadError.readmeMarkerMissing }
        let readme = File(relativePath: "README.md", localURL: readmeURL)

        var hasher = SHA256()
        for file in files + [readme] {
            hasher.update(data: Data("\(file.relativePath)\n\(try StreamingHasher.digest(of: file.localURL).sha256)\n".utf8))
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return FormatBundle(formatFiles: files, readme: readme, digest: digest)
    }

    /// The text before the first newline (a trailing carriage return dropped), or nil if it is not UTF-8.
    static func firstLine(of data: Data) -> String? {
        let line = data.prefix { $0 != UInt8(ascii: "\n") }
        guard var text = String(data: line, encoding: .utf8) else { return nil }
        if text.hasSuffix("\r") { text.removeLast() }
        return text
    }
}
