import Foundation
import CaptureCore

/// Builds the draft for a typed note.
public enum NoteComposer {
    /// Nil when `text` is only whitespace. Otherwise the text is stored verbatim (untrimmed) as one
    /// plain-text attachment.
    public static func draft(text: String, captureID: UUID, startedAt: Date, timeZone: TimeZone,
                             location: CaptureLocation?, context: [MetadataObservation] = []) -> CaptureDraft? {
        guard !text.allSatisfy(\.isWhitespace) else { return nil }
        return CaptureDraft(
            captureID: captureID, startedAt: startedAt, timeZone: timeZone, method: .typedNote,
            attachments: [AttachmentSource(body: .data(Data(text.utf8)), originalFilename: nil,
                                           uti: "public.utf8-plain-text", mimeType: "text/plain",
                                           representationSource: "typed_note")],
            location: location, observations: context)
    }

    /// The draft for a typed comment on an existing capture: the text trimmed of surrounding whitespace, or nil
    /// when nothing is left.
    public static func comment(text: String) -> CommentDraft? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : .text(trimmed)
    }
}
