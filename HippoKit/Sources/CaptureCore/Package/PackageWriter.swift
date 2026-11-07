import Foundation
import Darwin
import UniformTypeIdentifiers

/// A package that has been atomically moved into `captures/`.
public struct CommittedPackage: Sendable {
    public var metadata: CaptureMetadata
    public var marker: CompletionMarker
    public var relativeDirectory: String
    public var directoryURL: URL

    public init(metadata: CaptureMetadata, marker: CompletionMarker, relativeDirectory: String, directoryURL: URL) {
        self.metadata = metadata; self.marker = marker
        self.relativeDirectory = relativeDirectory; self.directoryURL = directoryURL
    }

    private static let noteBodyLimit = 4096
    private static let plainTextUTIs: Set<String> = ["public.utf8-plain-text", "public.plain-text"]

    /// For `typed_note` captures, the first 4 KiB of the first plain-text attachment (cut back to a whole
    /// UTF-8 character). Nil for every other capture, or if the body can't be read as UTF-8.
    public func noteBody() -> String? {
        guard metadata.captureMethod == .typedNote,
              let note = metadata.attachments.first(where: { Self.plainTextUTIs.contains($0.uti) }),
              (try? PackagePath.validateRelative(note.relativePath)) != nil,
              let handle = try? FileHandle(forReadingFrom: directoryURL.appendingPathComponent(note.relativePath))
        else { return nil }
        defer { try? handle.close() }
        guard var bytes = try? handle.read(upToCount: Self.noteBodyLimit) ?? Data() else { return nil }
        let wasCapped = bytes.count == Self.noteBodyLimit
        // A UTF-8 character is at most 4 bytes, so at most 3 trailing bytes can belong to a cut character.
        for _ in 0...3 {
            if let text = String(data: bytes, encoding: .utf8) { return text }
            guard wasCapped, !bytes.isEmpty else { break }
            bytes.removeLast()
        }
        return nil
    }
}

/// Commits a `CaptureDraft` as an immutable package: either the complete package appears under
/// `captures/YYYY/MM/DD/<capture-id>/` or nothing does.
///
/// Protocol: an exclusive `flock` on the sibling `staging/<capture-id>.lock` is held from before
/// `staging/<capture-id>/` exists until after it has been renamed into place, so the startup
/// reconciler never deletes a staging directory that a live writer owns.
public final class PackageWriter: Sendable {
    private let layout: StoreLayout
    private let producer: Producer
    private let space: any SpaceChecking
    private let makeID: @Sendable () -> UUID

    static let headroomBytes: Int64 = 1 << 20

    public init(layout: StoreLayout, producer: Producer, space: any SpaceChecking = VolumeSpaceChecker(),
                makeID: @escaping @Sendable () -> UUID = { UUID() }) {
        self.layout = layout; self.producer = producer; self.space = space; self.makeID = makeID
    }

    public func commit(_ draft: CaptureDraft, partialPolicy: PartialPolicy = .rejectPartial) async throws -> CommittedPackage {
        // Optional text that is blank is unknown, and unknown is omitted (never "").
        let userNote = Self.nonBlank(draft.userNote)
        let sharedTitle = Self.nonBlank(draft.sharedTitle)
        let sharedText = Self.nonBlank(draft.sharedText)

        // 1. Reject a capture with nothing in it.
        guard !draft.attachments.isEmpty || !draft.urls.isEmpty || sharedText != nil || userNote != nil else {
            throw CaptureError.emptyCapture
        }

        // 2. Check free space before writing anything.
        let required = draft.attachments.reduce(Self.headroomBytes) { $0 + Self.sourceSize($1.body) }
        let available: Int64
        do { available = try space.availableBytes(at: layout.root) } catch { throw CaptureError.io("space check failed") }
        guard required <= available else {
            throw CaptureError.insufficientSpace(requiredBytes: required, availableBytes: available)
        }

        // R9: dates are stored at millisecond precision; keep exactly what will read back.
        let capturedAt = HippoJSON.wholeMilliseconds(draft.startedAt)
        let captureID = draft.captureID.uuidString.lowercased()
        let relativeDirectory = PackagePath.captureDirectory(
            captureID: captureID, localDate: PackagePath.localDateComponents(of: capturedAt, in: draft.timeZone))
        let fm = FileManager.default

        // 3. Lock, then create the staging directory.
        try Self.io("create staging root") { try fm.createDirectory(at: layout.stagingDir, withIntermediateDirectories: true) }
        let lock = try StagingLock.acquire(at: layout.stagingDir.appendingPathComponent("\(captureID).lock"))
        let staging = layout.stagingDir.appendingPathComponent(captureID, isDirectory: true)
        let finalURL = layout.packageURL(relativeDirectory: relativeDirectory)

        let package: CommittedPackage
        do {
            // A leftover from an interrupted attempt with this ID is ours to discard: we hold its lock.
            if fm.fileExists(atPath: staging.path) {
                try Self.io("clear stale staging") { try fm.removeItem(at: staging) }
            }
            try Self.io("create staging") { try fm.createDirectory(at: staging, withIntermediateDirectories: false) }
            let contentDir = staging.appendingPathComponent("content", isDirectory: true)
            if !draft.attachments.isEmpty {
                try Self.io("create content") { try fm.createDirectory(at: contentDir, withIntermediateDirectories: false) }
            }

            // 4. Copy every source; collect failures instead of stopping at the first.
            var copied: [(source: AttachmentSource, id: String, relativePath: String, url: URL)] = []
            var failures: [AttachmentFailure] = []
            for (index, source) in draft.attachments.enumerated() {
                let id = makeID().uuidString.lowercased()
                let relativePath = PackagePath.attachmentPath(attachmentID: id, originalFilename: source.originalFilename,
                                                              uti: source.uti)
                do { try PackagePath.validateRelative(relativePath) } catch { throw CaptureError.io("unsafe attachment path") }
                let destination = staging.appendingPathComponent(relativePath)
                if let reason = Self.copy(source.body, to: destination) {
                    failures.append(AttachmentFailure(index: index, reason: reason))
                    try? fm.removeItem(at: destination)
                } else {
                    copied.append((source, id, relativePath, destination))
                }
            }
            var observations = draft.observations
            if !failures.isEmpty {
                let nothingLeft = copied.isEmpty && draft.urls.isEmpty && sharedText == nil && userNote == nil
                guard partialPolicy == .acceptPartial, !nothingLeft else { throw CaptureError.attachmentsFailed(failures) }
                observations += failures.map {
                    MetadataObservation(key: "attachment_copy_failed",
                                        value: .object(["index": .number(Double($0.index)), "reason": .string($0.reason)]),
                                        provenance: "package_writer")
                }
                // The package holds only spec files: no empty content/ when every attachment was dropped.
                if copied.isEmpty { try Self.io("remove empty content") { try fm.removeItem(at: contentDir) } }
            }

            // 5. Make each copy durable, hash it and gather media facts.
            var attachments: [Attachment] = []
            for c in copied {
                try Self.io("sync attachment") { try Self.fullSync(c.url) }
                let digest = try Self.io("hash attachment") { try StreamingHasher.digest(of: c.url) }
                let media = await MediaInspector.facts(for: c.url, uti: c.source.uti)
                attachments.append(Attachment(
                    attachmentID: c.id, relativePath: c.relativePath,
                    originalFilename: c.source.originalFilename.flatMap { $0.isEmpty ? nil : $0 },
                    uti: c.source.uti, mimeType: c.source.mimeType.flatMap { $0.isEmpty ? nil : $0 },
                    byteCount: digest.byteCount, sha256: digest.sha256,
                    representationSource: c.source.representationSource, media: media))
            }

            // 6. Metadata.
            var contentTypes: [ContentType] = []
            func add(_ t: ContentType) { if !contentTypes.contains(t) { contentTypes.append(t) } }
            attachments.forEach { add(Self.contentType(uti: $0.uti)) }
            if !draft.urls.isEmpty { add(.url) }
            if sharedText != nil { add(.text) }

            var location = draft.location
            if let observedAt = location?.observedAt { location?.observedAt = HippoJSON.wholeMilliseconds(observedAt) }

            let metadata = CaptureMetadata(
                schemaVersion: 1, captureID: captureID, capturedAt: capturedAt,
                localDatetime: PackagePath.localDatetimeString(capturedAt, tz: draft.timeZone),
                timezoneIdentifier: draft.timeZone.identifier,
                utcOffsetSeconds: draft.timeZone.secondsFromGMT(for: capturedAt),
                captureMethod: draft.method, contentTypes: contentTypes,
                userNote: userNote, sharedTitle: sharedTitle, sharedText: sharedText, urls: draft.urls,
                sourceApplication: nil, captureLocation: location, producer: producer,
                attachments: attachments, metadataObservations: observations, extensions: [:])
            let metadataURL = staging.appendingPathComponent("metadata.json")
            try Self.writeDurably(Self.io("encode metadata") { try HippoJSON.encode(metadata) }, to: metadataURL, step: "metadata")

            // 7. Completion marker: metadata first, then attachments in order. Then sync the directories.
            let metadataDigest = try Self.io("hash metadata") { try StreamingHasher.digest(of: metadataURL) }
            let marker = CompletionMarker(
                schemaVersion: 1, captureID: captureID,
                files: [ManifestEntry(relativePath: "metadata.json", byteCount: metadataDigest.byteCount, sha256: metadataDigest.sha256)]
                    + attachments.map { ManifestEntry(relativePath: $0.relativePath, byteCount: $0.byteCount, sha256: $0.sha256) })
            try Self.writeDurably(Self.io("encode marker") { try HippoJSON.encode(marker) },
                                  to: staging.appendingPathComponent("complete.json"), step: "marker")
            if !copied.isEmpty { try Self.io("sync content") { try Self.fullSync(contentDir) } }
            try Self.io("sync staging") { try Self.fullSync(staging) }

            // 8. Atomic move into place. RENAME_EXCL refuses to replace an existing package.
            try Self.io("create partition") {
                try fm.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            if renamex_np(staging.path, finalURL.path, UInt32(RENAME_EXCL)) != 0 {
                let code = errno
                throw CaptureError.io(code == EEXIST || code == ENOTEMPTY ? "already committed" : "rename failed: errno \(code)")
            }
            package = CommittedPackage(metadata: metadata, marker: marker,
                                       relativeDirectory: relativeDirectory, directoryURL: finalURL)
        } catch {
            try? fm.removeItem(at: staging)
            lock.release()
            throw error as? CaptureError ?? CaptureError.io("commit failed")
        }

        // Deliberately non-fatal: the package is already in place, so throwing would report a failed save
        // for a capture that recovery will later register.
        let day = finalURL.deletingLastPathComponent()
        let month = day.deletingLastPathComponent()
        let year = month.deletingLastPathComponent()
        for dir in [day, month, year, layout.capturesDir, layout.root, layout.stagingDir] {
            try? Self.fullSync(dir)
        }
        lock.release()
        return package
    }

    // MARK: Helpers

    private static func nonBlank(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    /// Unknown sizes count as zero; an unreadable source fails at copy time.
    private static func sourceSize(_ body: AttachmentSource.Body) -> Int64 {
        switch body {
        case .data(let data): Int64(data.count)
        case .file(let url): Int64((try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    static func contentType(uti: String) -> ContentType {
        guard let type = UTType(uti) else { return .file }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .plainText) { return .text }
        return .file
    }

    /// Returns a failure reason (no paths or names), or nil on success. Only regular files are accepted;
    /// symlinks are resolved so the package never contains a link.
    private static func copy(_ body: AttachmentSource.Body, to destination: URL) -> String? {
        do {
            switch body {
            case .data(let data):
                try data.write(to: destination, options: .withoutOverwriting)
            case .file(let source):
                let resolved = source.resolvingSymlinksInPath()
                guard try resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    return "not a regular file"
                }
                try FileManager.default.copyItem(at: resolved, to: destination)
            }
            return nil
        } catch {
            let ns = error as NSError
            return "copy failed: \(ns.domain) \(ns.code)"
        }
    }

    /// Runs `body`, mapping any error to `CaptureError.io` with a message free of paths and content.
    private static func io<T>(_ step: String, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as CaptureError {
            throw error
        } catch {
            let ns = error as NSError
            throw CaptureError.io("\(step) failed: \(ns.domain) \(ns.code)")
        }
    }

    private static func writeDurably(_ data: Data, to url: URL, step: String) throws {
        try io("write \(step)") { try data.write(to: url, options: .withoutOverwriting) }
        try io("sync \(step)") { try fullSync(url) }
    }

    /// Flushes a file or directory to stable storage (R14). `F_FULLFSYNC` also flushes the drive cache;
    /// filesystems that don't support it fall back to `fsync`. Read-only open, so 0444 copies sync too.
    private static func fullSync(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        if fcntl(fd, F_FULLFSYNC) == 0 { return }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
