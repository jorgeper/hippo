import Foundation
import CaptureCore
import SyncEngine

/// Where a recording or typed note goes when saved: a new capture (the main screen), or a comment on an
/// existing capture (Detail's Note and Record).
public enum SaveTarget: Equatable, Sendable {
    case newCapture
    case comment(captureID: String)
}

/// The copy shown when `HippoStore.addComment` refuses or fails. Shared by the recorder and the note editor.
public enum CommentErrorCopy {
    public static let damagedMessage = "This capture is damaged. Hippo can't add a comment to it."
    public static let goneMessage = "This capture is gone."
    public static let insufficientSpaceMessage = "Not enough space on this iPhone. Nothing was saved."

    /// The message for an `addComment` error: the capture is gone, damaged, or the iPhone is full; otherwise
    /// `fallback` (the caller's "couldn't save this comment" copy).
    public static func message(for error: Error, fallback: String) -> String {
        switch error as? CaptureError {
        case .io(HippoStore.commentCaptureMissing)?: goneMessage
        case .io(HippoStore.commentPackageInvalid)?: damagedMessage
        case .insufficientSpace?: insufficientSpaceMessage
        default: fallback
        }
    }
}
