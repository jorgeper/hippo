import Foundation
import CaptureCore

public enum SyncBucket: String, Sendable, CaseIterable {
    case notSynced, synced, needsAttention
}

public enum SortOrder: Sendable {
    case newestFirst, oldestFirst
}

/// Empty sets mean "any". Content types match any of the selected types.
public struct CaptureFilter: Sendable {
    public var dateRange: Range<Date>?
    public var contentTypes: Set<ContentType> = []
    public var methods: Set<CaptureMethod> = []
    public var hasComment: Bool?
    public var hasLocation: Bool?
    public var syncBuckets: Set<SyncBucket> = []
    public var searchText: String?
    public var sort: SortOrder = .newestFirst

    public init(dateRange: Range<Date>? = nil, contentTypes: Set<ContentType> = [], methods: Set<CaptureMethod> = [],
                hasComment: Bool? = nil, hasLocation: Bool? = nil, syncBuckets: Set<SyncBucket> = [],
                searchText: String? = nil, sort: SortOrder = .newestFirst) {
        self.dateRange = dateRange; self.contentTypes = contentTypes; self.methods = methods
        self.hasComment = hasComment; self.hasLocation = hasLocation; self.syncBuckets = syncBuckets
        self.searchText = searchText; self.sort = sort
    }
}

public struct PageCursor: Sendable, Equatable {
    public var capturedAt: Date
    public var captureID: String
    public init(capturedAt: Date, captureID: String) { self.capturedAt = capturedAt; self.captureID = captureID }
}

public struct CaptureSummary: Sendable, Equatable, Identifiable {
    public var id: String
    public var capturedAt: Date
    public var localDay: String
    public var title: String
    public var noteExcerpt: String?
    public var contentTypes: [ContentType]
    public var method: CaptureMethod
    public var attachmentCount: Int
    public var primaryAttachmentPath: String?
    public var relativeDirectory: String
    public var syncBucket: SyncBucket
    /// The capture's UTC offset when it was taken. Nil for rows indexed before schema v2.
    public var utcOffsetSeconds: Int?

    public init(id: String, capturedAt: Date, localDay: String, title: String, noteExcerpt: String?,
                contentTypes: [ContentType], method: CaptureMethod, attachmentCount: Int,
                primaryAttachmentPath: String?, relativeDirectory: String, syncBucket: SyncBucket, utcOffsetSeconds: Int? = nil) {
        self.id = id; self.capturedAt = capturedAt; self.localDay = localDay; self.title = title
        self.noteExcerpt = noteExcerpt; self.contentTypes = contentTypes; self.method = method
        self.attachmentCount = attachmentCount; self.primaryAttachmentPath = primaryAttachmentPath
        self.relativeDirectory = relativeDirectory; self.syncBucket = syncBucket
        self.utcOffsetSeconds = utcOffsetSeconds
    }
}
