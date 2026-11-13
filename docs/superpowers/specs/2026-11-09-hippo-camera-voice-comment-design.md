# Hippo: camera button and voice comment — design

> Superseded on 2026-11-10 by `2026-11-10-hippo-comments-design.md` for §3–§4.4 (the share-sheet hand-off was removed). The camera button and the in-sheet voice comment stand.

Date: 2026-11-09. Follows Plan 3 (Dropbox). Roadmap: `docs/roadmap.md`. Jorge approved the behaviour in conversation and asked to build without further questions; the calls marked **(my call)** are mine.

## 1. Intent

Two shortcuts that make capturing faster, both producing ordinary captures:

- **Camera button.** From the main screen, take a picture or record a video and have it saved exactly as if that image or video had been shared to Hippo from Photos.
- **Voice comment.** When sharing something to Hippo, or after taking a photo or video, add a spoken comment instead of, or as well as, typing one. The recording becomes part of that capture, like a voice note does, so the desktop reader and the transcript enrichment treat it as audio in the package.

## 2. Goals, non-goals, anti-goals

Goals:
- One tap from the timeline to the camera; after the shot, the same note sheet a shared image gets, then one capture with the photo or video as its attachment.
- A mic button on that note sheet, and on the Share Extension sheet, that looks like the main Record button. Type, record, or both. Discard and re-record before saving.
- The recording is a second attachment of the same capture (`representation_source: recording`), so Detail shows it, it plays back, and `transcript` enrichment runs on it.
- Camera photos and videos live only in Hippo unless a Settings toggle "Also save to Photos" is on (off by default).

Non-goals:
- No mic on the plain typed-note sheet (Note button).
- No custom viewfinder, filters or editing. The system camera UI is enough.
- No length limits on the voice comment or the video beyond what the system camera imposes.
- Nothing changes in the package format: the capture is still immutable once committed.

Anti-goals (a failure even if it works):
- Losing a capture because the user tapped the mic in the share sheet and never finished the comment.
- A voice comment that lands as a separate capture, or that changes a package after it was committed and possibly uploaded.
- Camera shots silently landing in the Photos library when the toggle is off.

## 3. Constraint that shapes the share-sheet design

**A Share Extension cannot record audio.** Apple's App Extension guidance says extensions cannot use the microphone (iMessage extensions excepted) and Technical Q&A QA1872 documents the resulting `AVAudioSessionErrorCodeCannotStartRecording`; a developer thread shows the symptom (a recorder that "succeeds" with a 0:00 file). Verified by web lookup on 2026-11-09, not on a device: the ADR-style watch item is in §9.

So the share sheet's mic cannot record in place. The design keeps the capture safe and the comment tied to it by **deferring the commit to the Hippo app**:

1. In the share sheet, tapping the mic saves everything gathered so far (the prepared draft, the typed comment, the location fix at share time, the intake files) as a **pending draft** in the App Group store, closes the share sheet with "Open Hippo to record your comment", and attempts to open Hippo (best effort, §5.3).
2. When Hippo becomes active, it finds the pending draft and presents the same capture sheet with the preview, the typed comment prefilled, and a working mic. Save commits one capture (method `share_extension`, `captured_at` = the share time) with the recording as a second attachment.
3. The capture can never be lost: Cancel on that sheet saves the capture **without** the comment (there is no "discard the share" path from the app), and the intake sweep ignores pending drafts.

The in-app camera sheet records in place; it is the same view and model, with the mic in record mode instead of hand-off mode.

Device confirmation of the hand-off (whether Hippo opens by itself) is acceptance row C4/C7.

## 4. User-visible behaviour

### 4.1 Main screen
Bottom bar: **Note** (left, bordered), **Camera** (middle, bordered, `camera` symbol), **Record** (right, prominent red) **(my call on placement)**.

### 4.2 Camera
- Tap Camera → the system camera (`UIImagePickerController`, source `.camera`, media types image and movie, high video quality, default capture mode photo). The user flips to video with the system control. First use shows the iOS camera permission prompt (usage string: "Hippo uses the camera to take pictures and record videos as captures."). Denied → an alert "Hippo needs camera access to take pictures. Turn it on in Settings." with Open Settings / Cancel.
- Cancel in the camera → back to the timeline, nothing saved.
- After the shot → the **capture sheet** (§4.4) with a thumbnail of the photo or video, the summary ("1 photo · 2.1 MB" / "1 video · 38 MB"), the comment field, the mic, and the destination line. `captured_at` is the moment the sheet appears **(my call: the end of the shot, not the tap on Camera)**; the location fix uses the same rule as the recorder (session fix started when the camera opens).
- Save → one capture, method `camera`, attachment `representation_source: camera`, HEIC photo (`public.heic`) with its EXIF carried over from the camera, or QuickTime movie (`com.apple.quicktime-movie`). After the save, sync and enrichment run as after a recording.
- Cancel on the sheet asks "Discard this photo?" / "Discard this video?" (Discard / Keep editing) and discards; the file was never in Photos.
- If "Also save to Photos" is on, after a successful commit the file is added to the Photos library (add-only permission, usage string: "Hippo can also keep the pictures and videos you take in your Photos library. This is off unless you turn it on in Settings."). A failure or a denied permission never affects the capture; it is logged (`camera.library_save` with `outcome: failed` and a code) and nothing is shown.

### 4.3 Share sheet (extension)
Same layout as today plus, under the comment field, the **mic button**: the main Record button's look (red disc in a ring, 56 pt **(my call on size)**) with the caption "Record a comment". Tapping it:
- disables Save, writes the pending draft (§5.2), shows "Open Hippo to record your comment" in place of the content for about a second, tries to open Hippo, then completes the share request. If Hippo opens, the capture sheet is already up with the mic recording started **(my call: start at once, like the recorder)**.
- If the draft can't be written, the sheet stays as it was and shows "Hippo couldn't hand this off. Save without a comment, or try again." under the mic.

### 4.4 Capture sheet (app; camera and pending-share)
One view, `CaptureSheetView`, used by the extension (mic in hand-off mode) and the app (mic in record mode). Content: header Cancel / Hippo / Save, preview row, partial notice if any, comment field, **voice comment block**, destination line.

Voice comment block states (app):
- idle: the mic button with the caption "Record a comment".
- recording: the stop button (red square in the ring), elapsed time ("0:07") updating, caption "Recording…".
- stopped: a row "Voice comment · 0:07" with a trash button (discards and returns to idle). No playback before saving **(my call)**. Tapping the mic again replaces the recording after "Replace the recording?" (Replace / Keep).
- denied: "Hippo needs the microphone to record a comment." with Open Settings.
- interrupted (a call or Siri took the mic): behaves like stopped with the recorded part kept, plus the recorder's existing one-line notice.
- Save with a recording in progress stops it first and includes it **(my call)**.

Save → one capture: the draft plus, when present, the recording as the last attachment (`com.apple.m4a-audio`, `audio/mp4`, `representation_source: recording`). The capture's content types then include `audio`, and the transcript enricher picks it up. Detail shows the recording as an audio attachment under the main attachment (it already renders every attachment); the first attachment stays the preview.

For a **pending share** presented in the app: title "Hippo", the preview and summary of the share, comment prefilled, mic recording started at once. **Cancel saves the capture without a comment** (button reads "Save without comment" **(my call)**); there is no discard. If the app is killed with the sheet open, the pending draft is presented again next time. If Save fails in a way the sheet can't retry (no space, a disk error), the only button is **"Later"** (ruled in the final review): it closes the sheet and keeps the pending draft for the next activation. A pending draft whose capture is already saved (the app was killed between the commit and clearing the intake) is removed instead of presented (`capture.save_failed`, code `pending_already_committed`).

### 4.5 Settings
New section **Camera** under the Location section: Toggle "Also save to Photos", footer "Pictures and videos you take in Hippo stay only in Hippo unless this is on." Turning it on does not prompt for Photos permission; the prompt comes with the first save.

### 4.6 Detail
"How" row: `camera` → "Camera". Everything else is unchanged.

Timeline row (ruled in the final review): the voice-note row is for method `voice_recording` and for a capture whose attachments are all audio and that has no URL (a shared Voice Memo or voice message). Otherwise a voice comment never changes a row's kind and is left out of the "+N" count, so a photo with a comment shows the photo and a link with a comment shows the link.

## 5. Architecture

### 5.1 HippoPresentation
- `RecordingSession` (new, extracted from `RecorderModel`): the start / stop / interruption / discard state machine over `AudioRecording` and `IntakeDirectory.recordingURL(id:)`, with `state` (idle, denied, recording(startedAt), stopped(duration, interrupted), failed(message)), `pending: (url, duration)?`, `start()`, `stop()`, `interruptionBegan()`, `discard()`. `RecorderModel` keeps its public API and tests and delegates to it; its `save()` reads the session's pending file.
- `ShareSessionModel` becomes the capture-sheet model for every source:
  - existing `init(... input: ShareInput ...)` for the extension;
  - new `init(store:intake:prepared: PreparedCapture, destinationName:location:now:timeZone:)` for the camera and for a pending draft, where `PreparedCapture` = draft + preview image URL + total bytes (+ a comment prefill); `prepare()` is a no-op in this case and the state starts `.ready`;
  - optional `voice: RecordingSession?` (nil in the extension); `save()` stops a running recording, appends the recording attachment, commits, and deletes the recording file;
  - `deferForVoiceComment() -> Bool` (extension only): writes the pending draft with the current comment and location, state `.deferred`; the sheet shows the hand-off copy. Returns false and sets a message when the write fails.
- `CameraCapture` (new): `static func stage(_ result: CameraResult, intake:, captureID:, startedAt:, timeZone:) throws -> PreparedCapture`: writes the photo (HEIC, EXIF preserved via ImageIO using the picker's media metadata dictionary) or moves the video into `intake/<captureID>/0.<ext>`, and builds the draft with method `.camera`. `CameraResult` is `.photo(CGImage, orientation, metadata: [String: Any])` or `.video(URL)`; conversion from the UIKit picker happens in the app.
- `AppSettings.cameraSavesToPhotos` (`camera_saves_to_photos`, default false).
- `CaptureMethod.camera = "camera"`; `CaptureDetail` maps it to "Camera".

### 5.2 ShareIntake: pending drafts
- `CaptureDraft` and `AttachmentSource` become `Codable` (file bodies as paths relative to the store root; data bodies as base64).
- `IntakeDirectory.savePending(_ draft: CaptureDraft, comment: String?, preview: URL?, totalBytes: Int64)` writes `intake/<captureID>/pending.json` next to the files; `pendingCaptures() -> [PendingCapture]` lists them oldest first; `sweep` skips directories containing `pending.json`; `discard(captureID:)` unchanged (used after the commit).
- A pending draft whose files are missing (corrupt) is discarded with a log event (`capture.save_failed`, code `pending_missing`) rather than presented.

### 5.3 App
- `CameraPicker` (`UIViewControllerRepresentable` over `UIImagePickerController`) in `App/Hippo/Capture/`.
- `CaptureSheetView` moves from `App/HippoShare/ShareSheetView.swift` to `App/Shared/CaptureSheetView.swift` with a `VoiceCommentControl` subview; in the extension the mic calls the hand-off closure, in the app it drives `RecordingSession` with `SystemAudioRecorder`.
- `CameraCaptureView` (app) owns the picker → stage → sheet flow and the Photos save (`PhotoLibrarySaver`, add-only).
- Pending shares: `RootView` watches `scenePhase == .active` and the `hippo://pending` URL (new `CFBundleURLSchemes` entry `hippo`), asks `intake.pendingCaptures()`, and presents `CaptureSheetView` for the first one; on finish, the next. Hand-off from the extension: try `extensionContext.open(URL("hippo://pending"))`, then walk the responder chain for `openURL:` (best effort, personal app); either way the copy tells the user to open Hippo.
- Share extension Info.plist does not need the microphone string (it never records). The app's `NSMicrophoneUsageDescription` is reworded: "Hippo records voice notes and voice comments when you tap Record."
- Usage strings added to the app: `NSCameraUsageDescription`, `NSPhotoLibraryAddUsageDescription`.

### 5.4 Docs and logging
- `docs/package-format.md`: `capture_method` known values add `camera`; `representation_source` add `camera`.
- `docs/log-format.md`: `camera.library_save` (app; `outcome` ok/failed, `code` denied/failed), and `capture.save_failed` code `pending_missing`.
- `README.md`: a paragraph on the camera button, the voice comment, the hand-off and the Photos toggle.
- `docs/acceptance.md`: rows C1–C7 (§9).

## 6. Edge cases
- Share hand-off then the app is opened days later: the sheet appears then; `captured_at` is still the share time (the package date folder follows it).
- Two pending drafts: presented one after another, oldest first.
- Pending draft and the app's launch recovery: recovery and the sweep run first; the sweep skips pending drafts.
- Voice recording interrupted by a call on the camera sheet: the recorded part is kept (stopped state with the notice), Save includes it.
- Camera video larger than the free-space margin: the store's existing insufficient-space error path applies ("Not enough space on this iPhone. Nothing was saved."); the temp file is discarded on Cancel.
- Photos save when the library permission is denied: logged, nothing shown, capture unaffected.
- The user turns "Also save to Photos" on after taking shots: earlier shots are not back-filled.

## 7. Left to the builder
- Exact SwiftUI layout of the voice comment block and the replace confirmation.
- HEIC encoding details (quality) and the EXIF keys carried; orientation must be right in Detail and on the desktop.
- Whether `UIImagePickerController` returns the still as `originalImage` + `mediaMetadata` (expected) and how to write them through ImageIO.
- How the responder-chain open is attempted without private API warnings (plain `perform(_:with:)` on `openURL:`).

## 8. Testing
- HippoKit: `RecordingSession` state machine (moved recorder tests keep passing); `ShareSessionModel` with `prepared:` and with a voice recording (attachment appended, file removed after commit, running recording stopped on save, discard removes the file); `deferForVoiceComment` writes a pending draft that round-trips through `pendingCaptures()` with the comment, location and files; sweep skips pending; `CameraCapture.stage` for a photo (HEIC with EXIF orientation and date) and a video (moved, draft method `camera`, UTI and MIME right); `CaptureDetail` "How" row; `AppSettings.cameraSavesToPhotos` default.
- App build check with and without `Config/Secrets.xcconfig`.
- Device rows C1–C7.

## 9. Device acceptance (to add to `docs/acceptance.md`)
- C1 Camera photo → capture with the photo, "Camera" in Detail, right orientation, not in Photos.
- C2 Camera video with a voice comment → one capture, video plays, the comment plays and gets a transcript.
- C3 "Also save to Photos" on → the next photo is also in Photos; off → not.
- C4 Share from Safari, tap the mic → hand-off copy; open Hippo → the sheet with the page preview and the mic recording; Save → one capture dated at the share time with the recording.
- C5 Same as C4 but "Save without comment" → the capture without audio.
- C6 Share, tap the mic, kill Hippo before saving, reopen → the sheet comes back; nothing lost or duplicated.
- C7 Camera permission denied → the alert with Open Settings; nothing saved. Also note whether `extensionContext.open` or the responder-chain fallback actually opened Hippo (watch item from §3).
