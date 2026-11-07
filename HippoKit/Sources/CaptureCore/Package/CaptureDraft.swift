import Foundation

/// One piece of content to store as an attachment.
public struct AttachmentSource: Sendable {
    public enum Body: Sendable {
        case file(URL)
        case data(Data)
    }

    public var body: Body
    public var originalFilename: String?
    public var uti: String
    public var mimeType: String?
    /// `item_provider_file`, `item_provider_data`, `typed_note` or `recording`.
    public var representationSource: String

    public init(body: Body, originalFilename: String? = nil, uti: String, mimeType: String? = nil,
                representationSource: String) {
        self.body = body; self.originalFilename = originalFilename; self.uti = uti
        self.mimeType = mimeType; self.representationSource = representationSource
    }
}

/// Everything gathered for a capture before it is committed. The capture ID and start time are
/// fixed by the caller when the capture begins.
public struct CaptureDraft: Sendable {
    public var captureID: UUID
    public var startedAt: Date
    public var timeZone: TimeZone
    public var method: CaptureMethod
    public var userNote: String?
    public var sharedTitle: String?
    public var sharedText: String?
    public var urls: [CapturedURL]
    public var attachments: [AttachmentSource]
    public var location: CaptureLocation?
    public var observations: [MetadataObservation]

    public init(captureID: UUID, startedAt: Date, timeZone: TimeZone, method: CaptureMethod,
                userNote: String? = nil, sharedTitle: String? = nil, sharedText: String? = nil,
                urls: [CapturedURL] = [], attachments: [AttachmentSource] = [],
                location: CaptureLocation? = nil, observations: [MetadataObservation] = []) {
        self.captureID = captureID; self.startedAt = startedAt; self.timeZone = timeZone; self.method = method
        self.userNote = userNote; self.sharedTitle = sharedTitle; self.sharedText = sharedText
        self.urls = urls; self.attachments = attachments; self.location = location
        self.observations = observations
    }
}

public enum PartialPolicy: Sendable {
    case rejectPartial
    case acceptPartial
}

public struct AttachmentFailure: Sendable, Equatable {
    public var index: Int
    public var reason: String
    public init(index: Int, reason: String) { self.index = index; self.reason = reason }
}

/// Messages never contain capture content, filenames or paths.
public enum CaptureError: Error, Equatable, Sendable {
    case insufficientSpace(requiredBytes: Int64, availableBytes: Int64)
    case attachmentsFailed([AttachmentFailure])
    case emptyCapture
    case io(String)
}
