import Foundation
import Darwin
import UniformTypeIdentifiers

/// Appends a comment to a committed package: audio first, json last, so the json is the comment's marker.
///
/// Protocol: an exclusive `flock` on `staging/comment-<comment-id>.lock` is held while
/// `staging/comment-<comment-id>/` exists, so the reconciler (which only deletes staging directories it can
/// lock) never removes a live write.
public struct CommentWriter: Sendable {
    private let layout: StoreLayout
    private let producer: Producer
    private let space: any SpaceChecking
    private let makeID: @Sendable () -> UUID

    public init(layout: StoreLayout, producer: Producer, space: any SpaceChecking = VolumeSpaceChecker(),
                makeID: @escaping @Sendable () -> UUID = { UUID() }) {
        self.layout = layout; self.producer = producer; self.space = space; self.makeID = makeID
    }

    /// Writes the comment into `package.directoryURL/comments/`, audio first, json last. Throws
    /// `CaptureError.emptyCapture` for whitespace text, `.insufficientSpace` as PackageWriter does,
    /// `.io` otherwise; on any failure no json exists.
    public func add(_ draft: CommentDraft, to package: CommittedPackage, now: Date, timeZone: TimeZone) throws -> CaptureComment {
        let text: String?
        var source: (url: URL, uti: String, mimeType: String?, duration: Double?)?
        switch draft {
        case .text(let raw):
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw CaptureError.emptyCapture }
            text = trimmed
        case .audio(let url, let uti, let mimeType, let duration):
            text = nil
            source = (url.resolvingSymlinksInPath(), uti, mimeType.flatMap { $0.isEmpty ? nil : $0 }, duration)
        }

        let required = PackageWriter.headroomBytes + (source.map(Self.size) ?? 0)
        let available: Int64
        do { available = try space.availableBytes(at: layout.root) } catch { throw CaptureError.io("space check failed") }
        guard required <= available else {
            throw CaptureError.insufficientSpace(requiredBytes: required, availableBytes: available)
        }

        let fm = FileManager.default
        let commentID = makeID().uuidString.lowercased()
        let addedAt = HippoJSON.wholeMilliseconds(now)
        let stagingName = "comment-\(commentID)"
        try PackageWriter.io("create staging root") { try fm.createDirectory(at: layout.stagingDir, withIntermediateDirectories: true) }
        let lock = try StagingLock.acquire(at: layout.stagingDir.appendingPathComponent("\(stagingName).lock"))
        let staging = layout.stagingDir.appendingPathComponent(stagingName, isDirectory: true)
        let commentsDir = package.directoryURL.appendingPathComponent(PackageComments.directoryName, isDirectory: true)
        // True only once this call itself created comments/: cleanup may then remove it (if still empty).
        var createdCommentsDir = false
        var movedAudio: URL?

        do {
            if fm.fileExists(atPath: staging.path) {
                try PackageWriter.io("clear stale staging") { try fm.removeItem(at: staging) }
            }
            try PackageWriter.io("create staging") { try fm.createDirectory(at: staging, withIntermediateDirectories: false) }

            var audio: CommentAudio?
            var stagedAudio: URL?
            if let source {
                var ext = UTType(source.uti)?.preferredFilenameExtension?.lowercased() ?? "m4a"
                if !PackageComments.isSafeAudioPath("comments/\(commentID).\(ext)", commentID: commentID) { ext = "m4a" }
                let relativePath = "\(PackageComments.directoryName)/\(commentID).\(ext)"
                let staged = staging.appendingPathComponent("\(commentID).\(ext)")
                try PackageWriter.io("copy comment audio") {
                    guard try source.url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                        throw CaptureError.io("not a regular file")
                    }
                    try fm.copyItem(at: source.url, to: staged)
                }
                try PackageWriter.io("sync comment audio") { try PackageWriter.fullSync(staged) }
                let digest = try PackageWriter.io("hash comment audio") { try StreamingHasher.digest(of: staged) }
                audio = CommentAudio(relativePath: relativePath, uti: source.uti, mimeType: source.mimeType,
                                     byteCount: digest.byteCount, sha256: digest.sha256,
                                     media: source.duration.map { MediaFacts(durationSeconds: $0) })
                stagedAudio = staged
            }

            let comment = CaptureComment(
                captureID: package.metadata.captureID, commentID: commentID, addedAt: addedAt,
                localDatetime: PackagePath.localDatetimeString(addedAt, tz: timeZone),
                timezoneIdentifier: timeZone.identifier, utcOffsetSeconds: timeZone.secondsFromGMT(for: addedAt),
                producer: producer, text: text, audio: audio, schemaMinor: FormatVersion.minor)
            let stagedJSON = staging.appendingPathComponent("\(commentID).json")
            try PackageWriter.writeDurably(try PackageWriter.io("encode comment") { try HippoJSON.encode(comment) },
                                           to: stagedJSON, step: "comment")
            try PackageWriter.io("sync staging") { try PackageWriter.fullSync(staging) }

            // Never resurrect a package deleted mid-write: the parent must exist, so create only comments/ itself.
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: package.directoryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw CaptureError.io("package is gone")
            }
            // Another writer (or an earlier comment) may have created it first: "already exists" is success.
            if mkdir(commentsDir.path, 0o755) == 0 {
                createdCommentsDir = true
            } else if errno != EEXIST {
                throw CaptureError.io("create comments failed: errno \(errno)")
            }
            isDirectory = false
            guard fm.fileExists(atPath: commentsDir.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw CaptureError.io("comments is not a directory")
            }
            if let stagedAudio, let audio {
                let destination = package.directoryURL.appendingPathComponent(audio.relativePath)
                try Self.move(stagedAudio, to: destination)
                movedAudio = destination
            }
            try PackageWriter.io("sync comments") { try PackageWriter.fullSync(commentsDir) }
            try Self.move(stagedJSON, to: package.directoryURL.appendingPathComponent(comment.relativePath))

            // The json is in place: the comment is committed. Nothing below may fail the call or remove files.
            try? PackageWriter.fullSync(commentsDir)
            if createdCommentsDir { try? PackageWriter.fullSync(package.directoryURL) }
            try? fm.removeItem(at: staging)
            try? PackageWriter.fullSync(layout.stagingDir)
            lock.release()
            return comment
        } catch {
            try? fm.removeItem(at: staging)
            if let movedAudio { try? fm.removeItem(at: movedAudio) }
            if createdCommentsDir { rmdir(commentsDir.path) }  // rmdir only removes an empty directory
            lock.release()
            throw error as? CaptureError ?? CaptureError.io("comment failed")
        }
    }

    private static func size(_ source: (url: URL, uti: String, mimeType: String?, duration: Double?)) -> Int64 {
        Int64((try? source.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// Rename that refuses to replace an existing file.
    private static func move(_ from: URL, to: URL) throws {
        if renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) != 0 {
            throw CaptureError.io("rename failed: errno \(errno)")
        }
    }
}
