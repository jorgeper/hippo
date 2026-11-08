import Foundation
import LocalRepository

/// One destination's sync state with a message the user can act on.
public struct SyncRow: Equatable, Sendable {
    public var destinationName: String?
    public var label: SyncLabel
    public var message: String?
    public var canRetry: Bool

    public init(destinationName: String?, label: SyncLabel, message: String?, canRetry: Bool) {
        self.destinationName = destinationName
        self.label = label
        self.message = message
        self.canRetry = canRetry
    }

    /// Shown when a capture has no upload job yet.
    static let unassigned = SyncRow(destinationName: nil, label: .onIPhone,
                                    message: "Not uploaded yet. Connect storage in Settings.", canRetry: false)

    static func make(job: UploadJob, destinationName: String?) -> SyncRow {
        let label: SyncLabel
        let message: String?
        switch job.state {
        case .pending:
            label = .onIPhone; message = "Waiting to upload"
        case .uploading:
            label = .onIPhone; message = "Uploading…"
        case .synced:
            label = .synced; message = nil
        case .retryableFailure:
            label = .onIPhone; message = "Couldn't upload yet. Hippo will retry automatically."
        case .needsAuthentication:
            label = .needsAttention; message = "Sign in again in Settings to resume uploads."
        case .paused:
            label = .needsAttention; message = "Uploads are paused because this account is signed out."
        case .blocked:
            label = .needsAttention
            switch job.lastErrorCode.map(Self.unprefixed) {
            case "quota_exceeded": message = "Your storage is full. Free up space, then tap Retry."
            case "remote_conflict":
                message = "A different file already exists in your storage at this capture's path. Hippo won't overwrite it."
            case "local_package_invalid": message = "This capture's files on iPhone are damaged or missing."
            case "provider_unavailable": message = "This storage provider isn't available in this version of Hippo."
            default: message = "Upload stopped. Tap Retry to try again."
            }
        }
        return SyncRow(destinationName: destinationName, label: label, message: message,
                       canRetry: job.state == .blocked || job.state == .retryableFailure)
    }

    /// The sync engine records adapter errors as `permanent:<code>` or `transient:<code>`.
    private static func unprefixed(_ code: String) -> String {
        for prefix in ["permanent:", "transient:"] where code.hasPrefix(prefix) {
            return String(code.dropFirst(prefix.count))
        }
        return code
    }
}
