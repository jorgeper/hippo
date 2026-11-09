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

    /// `destinationName` names the copy that stays: the capture's bound destination (`HippoStore.boundDestinationID`),
    /// the one "Delete everywhere" would also delete from. Nil reads as "your storage".
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

    /// The confirmation before "Delete everywhere…": the capture goes from this iPhone and from `destinationName`.
    public static func everywhere(destinationName: String) -> DeletionPrompt {
        DeletionPrompt(title: "Delete everywhere?",
                       message: "Delete from this iPhone and from \(destinationName)? \(destinationName) keeps deleted files for a while, so you can restore them on dropbox.com.",
                       confirm: "Delete everywhere")
    }
}
