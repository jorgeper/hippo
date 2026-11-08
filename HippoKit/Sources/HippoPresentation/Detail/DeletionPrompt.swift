import LocalRepository

/// The confirmation shown before "Delete from iPhone…" removes a capture.
public struct DeletionPrompt: Equatable, Sendable {
    public var title: String
    public var message: String
    public var confirm: String

    public init(title: String, message: String, confirm: String) {
        self.title = title
        self.message = message
        self.confirm = confirm
    }

    /// `destinationName` names the copy that stays; nil reads as "your storage".
    public static func make(jobs: [UploadJob], destinationName: String?) -> DeletionPrompt {
        var message: String
        if !jobs.isEmpty, jobs.allSatisfy({ $0.state == .synced }) {
            message = "This removes the capture from this iPhone. The copy in \(destinationName ?? "your storage") stays."
        } else {
            message = "This capture hasn't finished uploading. Deleting it removes the only copy."
        }
        if jobs.contains(where: { $0.state == .uploading }) {
            message += " The upload in progress will be stopped."
        }
        return DeletionPrompt(title: "Delete from iPhone?", message: message, confirm: "Delete")
    }
}
