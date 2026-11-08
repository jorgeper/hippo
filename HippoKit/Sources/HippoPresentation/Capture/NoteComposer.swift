import Foundation
import CaptureCore

/// Builds the draft for a typed note.
public enum NoteComposer {
    /// Nil when `text` is only whitespace. Otherwise the text is stored verbatim (untrimmed) as one
    /// plain-text attachment.
    public static func draft(text: String, captureID: UUID, startedAt: Date, timeZone: TimeZone,
                             location: CaptureLocation?) -> CaptureDraft? {
        guard !text.allSatisfy(\.isWhitespace) else { return nil }
        return CaptureDraft(
            captureID: captureID, startedAt: startedAt, timeZone: timeZone, method: .typedNote,
            attachments: [AttachmentSource(body: .data(Data(text.utf8)), originalFilename: nil,
                                           uti: "public.utf8-plain-text", mimeType: "text/plain",
                                           representationSource: "typed_note")],
            location: location)
    }
}
