# Hippo: comments on any capture, and one capture control — design

Date: 2026-11-10. Follows the camera and voice-comment phase (`2026-11-09-hippo-camera-voice-comment-design.md`, whose §3–§4.4 share hand-off this document **supersedes**). Jorge asked for this in conversation after trying the hand-off on the phone and asked me to build without further questions; every call marked **(my call)** is mine.

## 1. Intent

Jorge's words: the share-sheet hand-off ("Open Hippo to record your comment") is too clunky. Undo it. Instead, let him add a comment to **any** capture after the fact: open a capture and either type a note or record a voice comment, and have it synchronised like everything else. And make the "take a note" and "record audio" controls look the same everywhere: on the main screen, on the camera sheet, and on a capture.

Three parts:

1. **Remove the hand-off.** The share sheet keeps its typed comment and loses the mic. No pending drafts, no URL scheme, no "Later".
2. **Comments after the fact.** A capture's detail screen gets two buttons, Note and Record. Each adds a comment to that capture (typed text, or an m4a recording) that is stored in the capture's package, shown on the capture, transcribed when it is audio, and uploaded to the destination. Comments can be added any number of times, to any capture, online or not.
3. **One capture control.** Round, icon-only buttons: Note, Camera, Record. The same component, in the same style, on the timeline (all three), on a capture (Note and Record) and on the camera sheet (Record). This also fixes the wrapped "Camera" label.

## 2. Goals, non-goals, anti-goals

Goals:
- From a capture, two taps to add a typed or spoken comment; it appears on the capture at once and in Dropbox after the next sync pass.
- An audio comment plays back on the capture and gets a transcript like a voice note.
- Nothing already uploaded is ever rewritten: adding a comment only adds files. Packages that are already in Dropbox stay valid for the desktop reader throughout.
- Offline works: a comment on a not-yet-uploaded capture travels with it; a comment on an uploaded capture is uploaded on its own.
- The bottom bar and the other capture controls are visibly the same control.

Non-goals:
- Editing or deleting a comment. A wrong comment is followed by another one. **(my call)**
- Replying, threading, or comments from a second phone on a capture it did not make.
- Changing how a capture-time comment is stored: `user_note` and the camera sheet's recording stay as they are.
- A mic in the share sheet (impossible in an extension; the hand-off that worked around it is what this removes).

Anti-goals (a failure even if it works):
- A comment that is lost, attached to the wrong capture, or saved as a separate capture.
- A comment that makes a package look corrupt or incomplete to the desktop reader, or that produces a Dropbox "conflicted copy".
- A capture control that looks different on one screen than on another.

## 3. Comment storage: append-only files in the package

Today a package (`captures/YYYY/MM/DD/<id>/`) is immutable once `complete.json` exists; the uploader adds files and never overwrites, and the reader verifies the manifest. Rewriting `metadata.json` and the marker to add a comment would need overwrite semantics in both adapters, conflict handling between phones, and a relaxation of every "immutable" promise. So comments are **new files only**:

```text
captures/YYYY/MM/DD/<capture-id>/
  metadata.json               (unchanged)
  content/...                 (unchanged)
  complete.json               (unchanged; the manifest never lists comments)
  comments/<comment-id>.json  (one per comment; written last)
  comments/<comment-id>.m4a   (only for an audio comment; written before its json)
```

`comments/<comment-id>.json`, schema version 1:

| Field | Required | Notes |
|---|---|---|
| `schema_version` | yes | `1` |
| `capture_id` | yes | Matches the package. |
| `comment_id` | yes | Lowercase UUID; equals the file's base name. |
| `added_at` | yes | RFC 3339 UTC with milliseconds, `Z`. |
| `local_datetime`, `timezone_identifier`, `utc_offset_seconds` | yes | Same rules as `metadata.json`. |
| `producer` | yes | Same object as `metadata.json`. |
| `text` | one of | The typed comment, trimmed, non-empty. |
| `audio` | one of | `{relative_path, uti, mime_type, byte_count, sha256, media: {duration_seconds}}`; `relative_path` is `comments/<comment-id>.<ext>`. |

Exactly one of `text` or `audio` is present. The json is the comment's own marker: it is written after the audio file, locally (staging then rename) and on the destination (audio uploaded first). A reader that finds a json whose audio file is missing or does not match `byte_count`/`sha256` treats that comment as pending, exactly like a package whose manifest entry is not yet there. Unknown keys are ignored; a `schema_version` other than 1 is rejected as unsupported.

Reader rule change (`docs/package-format.md`): the manifest remains the authority for the core files, and "same `capture_id` + same digest means nothing to do" still holds for them; a rescan additionally lists `comments/` and indexes any json it has not seen. A capture's comments are the union of `user_note`, the audio attachments with `representation_source: recording`, and the files in `comments/`, in time order. Deleting a package (from the phone or on Dropbox) deletes its comments with it; nothing outside the package references them.

Why inside the package and not `enrichments/`-style: a comment is the user's content, not derived data; it must be deleted with the capture, be found by a reader that only knows the package, and survive an enrichment cursor reset.

## 4. User-visible behaviour

### 4.1 The capture control
One SwiftUI component, `CaptureButton(kind:size:)` **(name is my call)**, kinds `note` (`square.and.pencil`), `camera` (`camera`), `record` (`mic`), and a `recording` state for the record kind (red rounded square, "Stop"). A filled circle with a white symbol: Note and Camera in the accent colour, Record in red; 56 pt in bars, 88 pt on the recorder sheet **(my call: same drawing, larger on the sheet where it is the only control)**. No text label. Accessibility labels "Note", "Camera", "Record"/"Stop"; identifiers `note-button`, `camera-button`, `record-button` (the existing UI tests keep working: they find Record and Stop by label and Note/Camera by id).

### 4.2 Main screen
Bottom bar: the three buttons, evenly spaced, no text. Behaviour unchanged (Note sheet, camera, recorder).

### 4.3 A capture (Detail)
- Under the preview and above everything else, the comments **(my call on placement: comments are the user's own words, they go first)**: the capture-time comment (`user_note`, when present), then the capture-time recording(s) if any, then each after-the-fact comment, oldest first. A typed comment shows its text; an audio comment shows the existing audio player row with its duration and, when the transcript exists, the transcript text under it. Each after-the-fact comment carries a small caption with when it was added, formatted in the phone's locale ("Added today, 2:02 PM" / "Added Nov 3, 9:15 AM" in en_US; "Added 3 Nov, 9:15" in en_GB). The section is titled "Comments" ("Your comment" today).
- At the bottom of the screen, a bar with **Note** and **Record** (the same control as the main screen, 56 pt), under the content, above the safe area **(my call: a bar, not toolbar items, so it is the same look as the main screen)**.
- **Note** opens the typed-note sheet in comment mode: title "Add a comment", placeholder "Write a comment", Cancel and Save; Save adds a text comment to this capture and closes.
- **Record** opens the recorder sheet in comment mode: title "Record a comment"; it starts recording at once, like the main recorder; Stop, then Discard / Save. Save adds an audio comment. An interruption keeps the recorded part, as today.
- After either save: the capture reloads and shows the comment (an audio comment's transcript arrives after the enrichment pass, usually within seconds), the timeline reloads, and a sync pass and an enrichment pass run (`comment-sync` / `comment`).
- Captures that are "remote only" (local originals removed by Save space) can still take comments: the comment files are small and are kept locally like any package file.

### 4.4 Camera sheet
Unchanged, except the mic is the `CaptureButton` record kind at 56 pt with the same caption text as today. The share sheet shows the typed comment field only; the voice block and the hand-off are gone.

### 4.5 Timeline rows
- A row's comment excerpt is `user_note`; when that is empty, the newest typed comment **(my call)**. The "has a comment" filter is true when the capture has any comment, typed or audio, capture-time or later.
- A row's kind never changes because of a comment: comments are not attachments, so the voice-note rule, the thumbnail and the "+N" count are untouched.

### 4.6 Search
Typed comments are searchable (FTS `user_note` column gets the comments' text appended) **(my call: same column, no schema migration for FTS)**.

## 5. Architecture

### 5.1 CaptureCore
- `CaptureComment` (Codable model of the json above; `body: .text(String) | .audio(CommentAudio)`), `CommentDraft` (`.text(String)` or `.audio(fileURL, duration)`), `CommentWriter.add(_ draft: CommentDraft, to packageDirectory: URL, captureID:, now:, timeZone:, producer:) throws -> CaptureComment` (writes under `staging/`, then moves the audio, then the json; a failure leaves no json), `PackageComments.load(directory:) -> [CaptureComment]` (ignores json it cannot decode or whose audio is missing or mismatched, reporting them as pending), `CommittedPackage.comments`.
- `PackageValidator` unchanged for the core; a separate `validateComments` reports pending/corrupt comments.
- Schema: `schema/capture-comment-v1.schema.json`; a fixture package with a text and an audio comment under `fixtures/packages/`.

### 5.2 LocalRepository
- `CaptureIndex.recordComment(captureID:, comment:)`: `has_comment = 1`, `comment_count + 1` (new column, migration), `note_excerpt` set from the text when it is empty, FTS `user_note` appended. `CaptureSummary.commentCount`.
- `EnrichmentTaskStore.forget(captureID:, kind:)` deletes the row so the next `schedule()` re-evaluates the capture.

### 5.3 SyncEngine
- `SyncWorker.upload`: after the manifest files and the marker, upload each comment (audio before json) that has no receipt, add-only, with `ensureContainer(.../comments)`. A job becomes `synced` only when every manifest file, the marker and every local comment file have receipts; otherwise it stays `pending`, which closes the race between a comment landing during an upload and the worker finishing.
- `HippoStore.addComment(captureID:, _ draft: CommentDraft) async throws -> CaptureComment`: under the store lock, `CommentWriter.add`, `index.recordComment`, `jobs.requeue` for every destination whose job is `synced`, `tasks.forget(captureID:kind: transcript)` when the comment is audio, log `comment.added` (`kind: text|audio`, no content). Space check as for a capture.
- `RemoteChangeDetector` sees comment files through receipts (nothing to do); `SpaceSaver` never removes comment files; `AttachmentRestorer` is unaffected; delete-everywhere deletes the whole package directory and so the comments.

### 5.4 Enrichment
- `EnrichmentInput.comments: [CaptureComment]`. `TranscriptEnricher.applies` is true when any attachment or any comment is audio; it transcribes both; a comment's `TranscriptItem` uses the `comment_id` in the existing `attachment_id` field **(my call: no facet schema change; `docs/enrichment-format.md` says the id may name a comment)**.
- The runner loads comments from the package when it loads metadata.

### 5.5 HippoPresentation
- `RecorderModel` and `NoteComposer`/the note editor gain a target: `SaveTarget.newCapture` (today) or `.comment(captureID:)`. Save for `.comment` calls `store.addComment`.
- `CaptureDetail` gains `comments: [CommentRow]` (kind, text or audio URL + duration, added caption, transcript id) built from `user_note`, recording attachments and `package.comments`; `CaptureDetailModel.load` reads comments; `addNote`/`addRecording` are done by the sheets.
- `TimelineRow`: unchanged rules; the excerpt now comes from the index.
- Log events: `comment.added`; `comment.save_failed` with the store error code.

### 5.6 App
- `App/Shared/CaptureButton.swift` (compiled into the extension target too, unused there). Timeline bar, Detail bar, `VoiceCommentControl`, `RecorderView` use it.
- `CaptureDetailView`: comments section, bottom bar, sheets for Note and Record in comment mode.
- Removal: `PendingCapture.swift`, `PendingShareView.swift`, the pending branches in `ShareSessionModel`, `CaptureSheetView` (`Voice` becomes optional; `.handoff` gone), `VoiceCommentControl`, `ShareViewController` (`openHippo`), `RootView` (`checkPending`, `presentationClosed`, `onOpenURL`), `TimelineView` (`presentationClosed` posts), the `hippo` URL scheme in `project.yml`, their tests, and the doc lines listed in §7.

## 6. Edge cases
- Comment while the capture's upload is in progress: the worker finishes the core files, finds the comment files without receipts on the same run or the next, uploads them, and only then marks the job synced.
- Comment on a capture whose job is blocked or needs authentication: the comment waits with the job; nothing special.
- Comment on a capture that was deleted everywhere from another device: the job's remote-change handling applies as for any upload to a missing directory (today's behaviour).
- Kill during an audio comment save after the m4a is in place but before the json: no json means no comment; the orphan m4a is removed by the sweep of `staging/` **(my call: the writer stages both files and moves the json last, so an orphan can only be in staging)**.
- Two comments in the same second: distinct ids, ordered by `added_at` then id.
- A comment on a package that `PackageValidator` reports incomplete: refused with the store's existing error ("This capture is damaged…", code `local_package_invalid`).
- Not enough space: the existing insufficient-space error; nothing written.
- Microphone denied on the comment recorder: the recorder's existing denied state.

## 7. Docs
- `docs/package-format.md`: §Layout gets `comments/`; a new "Comments" section with the table in §3; the reader algorithm gets the comments step; "immutable" becomes "the manifested files are immutable; comments are append-only".
- `docs/enrichment-format.md`: transcript items may name a comment.
- `docs/log-format.md`: `comment.added`, `comment.save_failed`; remove `pending_missing`, `pending_already_committed`.
- `README.md`: the hand-off paragraph and the "pending share waits" bullet go; a "Comments" paragraph comes; Known limits updated.
- `docs/acceptance.md`: C4–C6 replaced (§9); C7 loses its share clause; new rows C8–C10.
- `docs/roadmap.md`: "Audio comment on share" becomes "Comments on any capture (done 2026-11-10)"; the share-sheet mic is recorded as tried and removed.
- The 2026-11-09 design gets a one-line "superseded by" note at the top; it is otherwise left as history.

## 8. Testing
- CaptureCore: writer round-trips text and audio comments; json is written last; a failure leaves no json; loader skips a json with a missing or mismatched audio file; fixture validates against the schema.
- LocalRepository: `recordComment` updates `has_comment`, `comment_count`, excerpt fallback and FTS; `forget`.
- SyncEngine: worker uploads comment files add-only after the marker and in audio-then-json order; a job with an unreceipted comment is not synced; `addComment` requeues a synced job, leaves a pending one, forgets the transcript task for audio only; filesystem adapter contract unchanged.
- Enrichment: transcript runs on an audio comment; the item id is the comment id; a capture with only a text comment is not applicable.
- HippoPresentation: recorder and note save with `.comment` target call `addComment`; Detail comment rows and captions; timeline excerpt fallback; the kept voice tests still pass.
- App: build with and without `Config/Secrets.xcconfig`; `make uitest` with the new ids.
- Device rows below.

## 9. Device acceptance (replaces C4–C6, extends C7)
- C4 Open a shared link, tap Note, type, Save → the comment shows under "Comments" with "Added…"; the timeline row shows it as the excerpt (when the share had no comment); after a sync pass, `comments/<id>.json` is in Dropbox.
- C5 Open a photo capture, tap Record, speak, Stop, Save → the audio comment plays on the capture; a transcript appears under it within the next enrichment pass; `comments/<id>.m4a` and `.json` are in Dropbox; the row is still a photo row.
- C6 Airplane mode, add a comment, leave airplane mode → the comment uploads on the next pass; the capture's status stays "Saved everywhere" afterwards.
- C7 Camera permission denied → the alert with Open Settings; nothing saved. (Share clause removed.)
- C8 Main screen: three round icon buttons, no text, no wrapping, in portrait and landscape.
- C9 Share from Safari: the sheet has the comment field and no mic; Save → one capture.
- C10 Two comments on the same capture, one typed, one audio → both shown in order; both in Dropbox; delete everywhere → the whole folder, comments included, is gone.
