import Foundation
import CaptureCore

/// How far back "Download from <destination>" reaches, by `captured_at` (design §4.5).
public struct DownloadWindow: Sendable, Equatable {
    /// Nil means everything.
    public var seconds: TimeInterval?

    public init(seconds: TimeInterval?) { self.seconds = seconds }

    /// 2 weeks, 1 month, 3 months, 6 months, 1 year, everything.
    public static let steps: [TimeInterval?] = ([14, 30, 90, 180, 365] as [TimeInterval]).map { Optional($0 * 86_400) }
        + [nil]
    public static let `default` = DownloadWindow(seconds: 30 * 86_400)
}

/// A complete remote capture that isn't on this phone.
public struct DownloadCandidate: Sendable, Equatable {
    public var captureID: String
    /// `captures/YYYY/MM/DD/<capture-id>`, the same locally and in the destination.
    public var relativeDirectory: String
    /// Every file the listing found under the capture's directory.
    public var files: [RemoteEntry]
    /// `metadata.json`, `complete.json` and the attachments at or under the light limit.
    public var lightBytes: Int64
    /// It was removed from this phone with "Delete from iPhone" (listed only when those are included).
    public var locallyDeleted: Bool

    public init(captureID: String, relativeDirectory: String, files: [RemoteEntry], lightBytes: Int64,
                locallyDeleted: Bool) {
        self.captureID = captureID
        self.relativeDirectory = relativeDirectory
        self.files = files
        self.lightBytes = lightBytes
        self.locallyDeleted = locallyDeleted
    }
}

public struct DownloadEstimate: Sendable, Equatable {
    public var candidates: [DownloadCandidate]
    /// Remote captures in the window that were removed from this phone, whether or not they are included.
    public var skippedLocallyDeleted: Int
    public var bytes: Int64
    public var count: Int

    public init(candidates: [DownloadCandidate], skippedLocallyDeleted: Int, bytes: Int64, count: Int) {
        self.candidates = candidates
        self.skippedLocallyDeleted = skippedLocallyDeleted
        self.bytes = bytes
        self.count = count
    }
}

/// The listing half of "Download from <destination>": which complete captures the destination holds in a
/// window's month folders, and how many light bytes each would download. Knows nothing of this phone.
struct RemoteListing: Sendable {
    /// Month folders are listed from this long before the window starts (and through this long after now),
    /// and a capture's folder may be dated this far before the window, because a folder is named by the
    /// capture's local date and UTC offsets span 26 hours.
    static let folderSlack: TimeInterval = 2 * 86_400

    let calendar: Calendar
    let lightAttachmentLimit: Int64

    /// Captures with both `complete.json` and `metadata.json` in the window's month folders (all of
    /// `captures/` when the window is everything) whose folder date is at most two days before the window.
    /// Newest folder first; none is flagged locally deleted.
    func completeCaptures(window: DownloadWindow, now: Date, adapter: any StorageAdapter) async throws
        -> [DownloadCandidate] {
        let start = window.seconds.map { now.addingTimeInterval(-$0 - Self.folderSlack) }
        var byDirectory: [String: [RemoteEntry]] = [:]
        for folder in monthFolders(from: start, through: now.addingTimeInterval(Self.folderSlack)) {
            for entry in try await listAll(folder, adapter: adapter) where !entry.isFolder {
                guard let directory = Self.captureDirectory(containing: entry.relativePath) else { continue }
                byDirectory[directory, default: []].append(entry)
            }
        }

        let firstDay = start.map(dayString)
        var captures: [DownloadCandidate] = []
        for directory in byDirectory.keys.sorted(by: >) {
            let files = byDirectory[directory, default: []].sorted { $0.relativePath < $1.relativePath }
            let names = Set(files.map { String($0.relativePath.dropFirst(directory.count + 1)) })
            guard names.contains("complete.json"), names.contains("metadata.json") else { continue }
            if let firstDay, Self.folderDay(directory) < firstDay { continue }
            captures.append(DownloadCandidate(captureID: String(directory.split(separator: "/").last ?? ""),
                                              relativeDirectory: directory, files: files,
                                              lightBytes: lightBytes(files, directory: directory),
                                              locallyDeleted: false))
        }
        return captures
    }

    /// `captures/YYYY/MM/DD/<lowercase uuid>`.
    static func isCaptureDirectory(_ directory: String) -> Bool {
        (try? EnrichmentPaths.remoteDirectory(.device, packageDirectory: directory)) != nil
    }

    /// `captures/YYYY/MM` for each month from `start`'s through `end`'s, in the calendar; `captures` for nil.
    private func monthFolders(from start: Date?, through end: Date) -> [String] {
        guard let start else { return ["captures"] }
        let first = calendar.dateComponents([.year, .month], from: start)
        let last = calendar.dateComponents([.year, .month], from: end)
        var (year, month) = (first.year ?? 0, first.month ?? 1)
        var folders: [String] = []
        while (year, month) <= (last.year ?? 0, last.month ?? 1) {
            folders.append(String(format: "captures/%04d/%02d", year, month))
            month += 1
            if month > 12 { (year, month) = (year + 1, 1) }
        }
        return folders
    }

    private func listAll(_ folder: String, adapter: any StorageAdapter) async throws -> [RemoteEntry] {
        var entries: [RemoteEntry] = []
        var cursor: String?
        while true {
            try Task.checkCancellation()
            let page = try await adapter.listFolder(relativePath: folder, recursive: true, cursor: cursor)
            entries += page.entries
            guard page.hasMore, let next = page.cursor else { return entries }
            cursor = next
        }
    }

    private func dayString(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// `YYYY-MM-DD` of a `captures/YYYY/MM/DD/<id>` directory.
    private static func folderDay(_ directory: String) -> String {
        directory.split(separator: "/").dropFirst().prefix(3).joined(separator: "-")
    }

    /// The capture directory a file path is inside, if any.
    private static func captureDirectory(containing path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 6 else { return nil }
        let directory = parts.prefix(5).joined(separator: "/")
        return isCaptureDirectory(directory) ? directory : nil
    }

    private func lightBytes(_ files: [RemoteEntry], directory: String) -> Int64 {
        files.reduce(0) { sum, file in
            let name = file.relativePath.dropFirst(directory.count + 1)
            let light = name == "metadata.json" || name == "complete.json"
                || (name.hasPrefix("content/") && file.byteCount <= lightAttachmentLimit)
            return light ? sum + file.byteCount : sum
        }
    }
}
