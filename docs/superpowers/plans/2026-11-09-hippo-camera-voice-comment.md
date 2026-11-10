# Camera Button and Voice Comment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Camera button on the timeline that saves a photo or video as a capture, and a voice comment on the share sheet and the camera sheet that becomes a second attachment of the same capture.

**Architecture:** The share sheet's view and model become the one "capture sheet" used by the Share Extension, the in-app camera flow, and shares handed off to the app. The recorder's state machine is extracted into `RecordingSession` so the sheet can record without saving a separate capture. Because a Share Extension cannot record audio (design §3), the extension's mic writes a *pending draft* into the intake directory and the app presents the sheet for it. Packages stay immutable; one capture per share or shot.

**Tech Stack:** Swift 6, SwiftUI, UIKit (`UIImagePickerController`), AVFoundation, ImageIO, Photos (add-only), Swift Testing. HippoKit targets: CaptureCore, ShareIntake, HippoPresentation, LocalRepository. App targets: Hippo, HippoShare.

**Spec:** `docs/superpowers/specs/2026-11-09-hippo-camera-voice-comment-design.md` (the design; its "(my call)" items are decided).

## Global Constraints

- Swift 6 strict concurrency; HippoKit builds and tests on macOS (`make test`), so nothing UIKit-only goes into HippoKit. ImageIO/CoreGraphics are fine.
- New copy is exactly the design's copy (§4). Captions: "Record a comment", "Recording…", "Voice comment · 0:07", "Replace the recording?" (Replace / Keep), "Hippo needs the microphone to record a comment.", "Open Hippo to record your comment", "Hippo couldn't hand this off. Save without a comment, or try again.", "Discard this photo?" / "Discard this video?" (Discard / Keep editing), "Save without comment", "Hippo needs camera access to take pictures. Turn it on in Settings.", Settings toggle "Also save to Photos" with footer "Pictures and videos you take in Hippo stay only in Hippo unless this is on."
- New raw values: `CaptureMethod.camera = "camera"`; `representation_source` `"camera"` for camera files, `"recording"` for the voice comment; UTIs `public.heic` (`image/heic`), `com.apple.quicktime-movie` (`video/quicktime`), `com.apple.m4a-audio` (`audio/mp4`); settings key `camera_saves_to_photos`; URL scheme `hippo`, hand-off URL `hippo://pending`; pending file name `pending.json` inside `intake/<capture-id>/`; log event `camera.library_save`; `capture.save_failed` code `pending_missing`.
- `LogEventName` is a closed set; every new event name is added there and documented in `docs/log-format.md`.
- The package format does not change; `docs/package-format.md` only gains the two new known values.
- Log messages never contain content, filenames or paths.
- Commit after each task with the two trailers: `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_011TuXtyAQXAppU2rKDgDPjV`. Read `git diff --cached` before each commit for secrets.
- App build check after any App change: `xcodegen generate && xcodebuild -project Hippo.xcodeproj -scheme Hippo -configuration Debug -destination generic/platform=iOS -derivedDataPath build/DerivedData -allowProvisioningUpdates build` → `** BUILD SUCCEEDED **`.

## Plan-level calls

- `PendingCapture` has its own Codable shape in ShareIntake (file bodies as paths relative to the intake capture directory, data bodies base64); `CaptureDraft` itself does not become Codable.
- `CameraResult.photo` carries a `CGImage` plus the picker's metadata dictionary wrapped in `PhotoMetadata` (`@unchecked Sendable`, `[String: Any]`), so HippoPresentation never imports UIKit.
- The pending-share sheet in the app starts recording at once (design §4.3); the camera sheet does not (the user taps the mic).
- Hand-off opening is best effort: `extensionContext.open` then a responder-chain `openURL:`; the copy covers the case where neither works.

## Review Focus

1. A pending draft whose intake files vanished (sweep, reinstall) must be discarded with a log line, never presented with a broken preview or committed empty. Test in Task 2 (`pendingCapturesSkipsAndRemovesMissingFiles`).
2. Save on the camera sheet while a recording is still running must include the recording, not a 0-second file or the file of a previous recording. Test in Task 4 (`saveStopsRunningRecordingAndAttachesIt`).
3. A photo written as HEIC must keep its orientation and EXIF date so Detail and the desktop show it the right way up. Test in Task 5 (`photoKeepsOrientationAndExifDate`).
4. "Save without comment" on a pending share must commit the share exactly once even if the app is killed right after; the pending file is removed only after the commit. Test in Task 4 (`pendingSaveRemovesPendingFileAfterCommit`).
5. The intake sweep must skip pending drafts however old they are. Test in Task 2 (`sweepKeepsPendingCaptures`).

---

### Task 1: `CaptureMethod.camera`, Detail "How" row, package-format doc

**Files:**
- Modify: `HippoKit/Sources/CaptureCore/Model/OpenEnums.swift`
- Modify: `HippoKit/Sources/HippoPresentation/Detail/CaptureDetail.swift` (the `how` switch near line 248)
- Modify: `docs/package-format.md` (`capture_method` known values; `representation_source` sentence)
- Modify: `schema/capture-metadata-v1.schema.json` (`examples` arrays only)
- Test: `HippoKit/Tests/HippoPresentationTests/DetailTests.swift`

**Interfaces:**
- Produces: `CaptureMethod.camera` (`"camera"`).

- [ ] **Step 1: Write the failing test** in `DetailTests.swift`, following the existing "How" row test shape (search for `"Typed note"` in that file):

```swift
@Test func cameraCaptureHowRow() throws {
    // metadata with captureMethod: .camera, one HEIC attachment
    // expect rows contain DetailRow(label: "How", value: "Camera")
}
```

- [ ] **Step 2: Run it** — `swift test --package-path HippoKit --filter DetailTests` → FAIL (no `camera` member).
- [ ] **Step 3: Implement**: add `public static let camera = CaptureMethod(rawValue: "camera")`; add `case "camera": "Camera"` to the `how` switch; document `camera` in `docs/package-format.md` ("Known: … `voice_recording`, `camera`") and `camera` in the `representation_source` list ("… `recording`, `camera` (taken with Hippo's camera button)"); add both to the schema `examples`.
- [ ] **Step 4: Run** the HippoPresentation tests and `scripts/validate-fixtures.sh` → PASS.
- [ ] **Step 5: Commit** `feat(core): camera capture method`.

---

### Task 2: Pending captures in the intake directory

**Files:**
- Create: `HippoKit/Sources/ShareIntake/PendingCapture.swift`
- Modify: `HippoKit/Sources/ShareIntake/IntakeDirectory.swift`
- Test: `HippoKit/Tests/ShareIntakeTests/PendingCaptureTests.swift`

**Interfaces:**
- Consumes: `CaptureDraft`, `AttachmentSource` (CaptureCore).
- Produces:

```swift
/// A capture gathered by the Share Extension, waiting for the app to add a voice comment and commit it.
public struct PendingCapture: Sendable, Equatable {
    public var draft: CaptureDraft          // userNote = the typed comment so far; location already set
    public var previewImageURL: URL?
    public var totalBytes: Int64
    public var savedAt: Date
    public init(draft: CaptureDraft, previewImageURL: URL?, totalBytes: Int64, savedAt: Date)
}

extension IntakeDirectory {
    /// Writes `intake/<capture-id>/pending.json`. File bodies must already live inside that directory.
    public func savePending(_ pending: PendingCapture) throws
    /// Oldest first. A pending capture whose files are missing is removed and reported in `dropped`.
    public func pendingCaptures() -> (captures: [PendingCapture], dropped: Int)
    /// True when `intake/<capture-id>/pending.json` exists.
    public func isPending(captureID: UUID) -> Bool
}
```

- `sweep(olderThan:now:)` skips any directory that contains `pending.json`.
- `CaptureDraft.Equatable` is not available; compare fields in tests.

- [ ] **Step 1: Write failing tests**:

```swift
@Test func pendingRoundTrip()            // draft with one file attachment (MediaMaker.imageData written into the capture dir), one .data attachment, a URL, userNote "hi", location, observations → savePending → pendingCaptures() returns one with equal fields, file URL pointing at the same file, previewImageURL and totalBytes preserved
@Test func pendingCapturesSkipsAndRemovesMissingFiles()  // save, delete the attachment file → pendingCaptures() returns [] with dropped == 1 and the directory is gone
@Test func sweepKeepsPendingCaptures()   // a pending dir and a plain dir, both older than the cutoff → sweep removes only the plain one
@Test func pendingOrderIsOldestFirst()   // two pendings with savedAt t0 and t0+10 saved in reverse order → returned t0 first
```

- [ ] **Step 2: Run** `swift test --package-path HippoKit --filter PendingCaptureTests` → FAIL.
- [ ] **Step 3: Implement** `PendingCapture` with a private `Codable` file struct: `schemaVersion: 1`, `captureID`, `startedAt`, `timeZone` (identifier), `method` (raw), `userNote`, `sharedTitle`, `sharedText`, `urls`, `attachments` (`{file: "0.heic"} | {data: base64}`, `originalFilename`, `uti`, `mimeType`, `representationSource`), `location`, `observations`, `previewImage` (relative name or nil), `totalBytes`, `savedAt`. Relative paths are the file's last path component; anything not inside the capture directory throws `CocoaError(.fileWriteInvalidFileName)`. `pendingCaptures()` decodes each `pending.json`, checks every file body exists, removes the directory otherwise.
- [ ] **Step 4: Run** the ShareIntake tests → PASS.
- [ ] **Step 5: Commit** `feat(intake): pending captures for the voice-comment hand-off`.

---

### Task 3: Extract `RecordingSession` from `RecorderModel`

**Files:**
- Create: `HippoKit/Sources/HippoPresentation/Capture/RecordingSession.swift`
- Modify: `HippoKit/Sources/HippoPresentation/Capture/RecorderModel.swift`
- Test: `HippoKit/Tests/HippoPresentationTests/RecordingSessionTests.swift` (new); `CaptureModelTests.swift` unchanged and still green

**Interfaces:**
- Produces:

```swift
@MainActor @Observable
public final class RecordingSession {
    public enum State: Equatable {
        case idle, denied
        case recording(startedAt: Date)
        case stopped(duration: TimeInterval, interrupted: Bool)
        case failed(String)
    }
    public static let startFailedMessage = "Hippo couldn't start recording. Try again."
    public private(set) var state: State
    /// The recording on disk after stop/interruption, until `discard()` or `takePending()`.
    public var pending: (url: URL, duration: TimeInterval)? { get }
    public init(intake: IntakeDirectory, recorder: AudioRecording,
                permission: @escaping () async -> MicPermission, now: @escaping () -> Date = Date.init)
    public func start() async          // same rules as RecorderModel.start today
    public func stop()
    public func interruptionBegan()
    public func discard()              // stops if recording, deletes the file, state .idle
    /// Hands the file to the caller (who commits it) and returns to idle without deleting it.
    public func takePending() -> (url: URL, duration: TimeInterval, startedAt: Date, timeZone: TimeZone)?
}
```

- `RecorderModel` keeps its public API (`State` incl. `.saving/.saved`, `start/stop/interruptionBegan/save/discard/hasPendingRecording/elapsedText`) and delegates to a `RecordingSession`. `RecorderModel.State` is derived: the session's state mapped 1:1, plus `.saving/.saved` while committing. `save()` calls `takePending()`, builds the draft as today, commits, deletes the file; on failure it must keep the file and allow retry, so the session needs `restorePending(_:)` or `save()` must not call `takePending()` until the commit succeeded — builder's choice, but the existing test `failedSaveKeepsFileAndCanRetry` must stay green.

- [ ] **Step 1: Write failing tests** in `RecordingSessionTests.swift` (copy the `FakeRecorder` and rig shape from `CaptureModelTests.swift`):

```swift
@Test func deniedPermission()                 // permission .denied → state .denied, recorder never started
@Test func startStopLeavesPendingFile()       // start → .recording; stop → .stopped(7.4, false); pending?.url exists
@Test func interruptionKeepsRecording()       // interruptionBegan → .stopped(_, true), pending set
@Test func discardDeletesFile()               // start, stop, discard → .idle, file gone
@Test func takePendingReturnsToIdleAndKeepsFile()
@Test func startWhileRecordingIsIgnored()     // startCount stays 1
```

- [ ] **Step 2: Run** → FAIL (type missing).
- [ ] **Step 3: Implement** `RecordingSession` by moving the state machine out of `RecorderModel`; rewrite `RecorderModel` on top of it.
- [ ] **Step 4: Run** `swift test --package-path HippoKit --filter "RecordingSessionTests|CaptureModelTests"` → PASS, all existing recorder tests unchanged.
- [ ] **Step 5: Commit** `refactor(presentation): RecordingSession behind RecorderModel`.

---

### Task 4: `ShareSessionModel` as the capture-sheet model

**Files:**
- Modify: `HippoKit/Sources/HippoPresentation/Share/ShareSessionModel.swift`
- Test: `HippoKit/Tests/HippoPresentationTests/ShareSessionTests.swift`

**Interfaces:**
- Consumes: `PendingCapture`, `IntakeDirectory.savePending/isPending` (Task 2); `RecordingSession` (Task 3).
- Produces:

```swift
/// A draft already on disk: from the camera or a pending share.
public struct PreparedCapture: Sendable {
    public var draft: CaptureDraft
    public var previewImageURL: URL?
    public var totalBytes: Int64
    public init(draft: CaptureDraft, previewImageURL: URL?, totalBytes: Int64)
    public init(_ pending: PendingCapture)     // comment = pending.draft.userNote
}

extension ShareSessionModel {
    public enum State { …existing…; case deferred }      // after a successful hand-off write
    public static let handoffFailedMessage = "Hippo couldn't hand this off. Save without a comment, or try again."
    public static let handoffMessage = "Open Hippo to record your comment"

    /// Camera or pending share. State starts `.ready`; `prepare()` is a no-op. `isPendingShare` is true
    /// when the draft came from a pending share (the sheet then offers "Save without comment").
    public init(store: HippoStore, intake: IntakeDirectory, prepared: PreparedCapture, isPendingShare: Bool,
                destinationName: String?, voice: RecordingSession?,
                location: @escaping (Date) -> CaptureLocation?, now: @escaping () -> Date = Date.init)
    public let voice: RecordingSession?          // nil in the extension
    public let isPendingShare: Bool
    public private(set) var handoffFailed: Bool  // shows handoffFailedMessage under the mic
    /// Extension only: writes the pending draft (comment + location now) and sets `.deferred`.
    public func deferForVoiceComment() async
}
```

Behaviour changes to `save()`:
- If `voice` is recording, `stop()` it first. If `voice.pending` exists, `takePending()` and append `AttachmentSource(body: .file(url), uti: "com.apple.m4a-audio", mimeType: "audio/mp4", representationSource: "recording")` as the last attachment.
- For a prepared capture the location is **not** re-read: a pending share already carries the share-time fix; a camera draft carries the fix taken at staging time (Task 5 sets it). Only the `input:` path keeps `draft.location = location(startedAt)`.
- After a successful commit: `intake.discard(captureID:)` (removes the pending file and the files) and delete the recording file. On failure the recording file stays (`voice.restorePending`-equivalent, builder's choice) so Save can be retried.
- `cancel()` for a pending share must not discard the intake (the sheet's "Save without comment" calls `save()` instead; the view never calls `cancel()` for a pending share).

- [ ] **Step 1: Write failing tests** (rig: add a `prepared` initializer; `FakeRecorder` from Task 3's tests, moved to the tests `Support/` folder if both suites need it):

```swift
@Test func preparedStartsReadyWithSummary()                 // camera photo draft → .ready, summary "1 photo · <size>", previewSymbol "photo"
@Test func saveAppendsVoiceComment()                        // voice started+stopped → save → committed metadata has 2 attachments, last uti com.apple.m4a-audio, representation_source "recording"; recording file gone; intake dir gone
@Test func saveStopsRunningRecordingAndAttachesIt()         // voice still .recording at save → recorder.stopCount == 1 and the attachment is present
@Test func saveWithoutVoiceHasOneAttachment()
@Test func deferWritesPendingWithCommentAndLocation()       // input-based model, comment "  hello ", location fix → deferForVoiceComment → state .deferred; intake.pendingCaptures() has one with userNote "hello", location set, same captureID, files present
@Test func deferFailureKeepsReadyAndFlags()                 // make the intake dir read-only or point intake at an unwritable path → handoffFailed true, state .ready
@Test func pendingSaveRemovesPendingFileAfterCommit()       // prepared(pending) → save → committed once, isPending false, no second commit on a repeated save()
@Test func rejectedCommitKeepsRecordingForRetry()           // prepared draft whose first attachment file is missing → save → CaptureError.attachmentsFailed → state .confirmPartial; the recording file is still on disk and `voice.pending` is restored; save(acceptPartial: true) commits with the recording as an attachment
```

- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `swift test --package-path HippoKit --filter ShareSessionTests` → PASS.
- [ ] **Step 5: Commit** `feat(presentation): capture-sheet model with voice comment and hand-off`.

---

### Task 5: `CameraCapture.stage` and the Photos setting

**Files:**
- Create: `HippoKit/Sources/HippoPresentation/Capture/CameraCapture.swift`
- Modify: `HippoKit/Sources/HippoPresentation/Settings/AppSettings.swift`, `SettingsModel.swift`
- Test: `HippoKit/Tests/HippoPresentationTests/CameraCaptureTests.swift`, `SettingsTests.swift`

**Interfaces:**
- Consumes: `IntakeDirectory.directory(for:)`, `PreparedCapture` (Task 4), `CaptureMethod.camera` (Task 1).
- Produces:

```swift
/// The picker's metadata dictionary (CGImageProperties keys), passed through untouched.
public struct PhotoMetadata: @unchecked Sendable { public let properties: [String: Any]; public init(_ p: [String: Any]) }

public enum CameraResult: Sendable {
    case photo(CGImage, orientation: Int32 /* CGImagePropertyOrientation raw */, metadata: PhotoMetadata)
    case video(URL)        // the picker's temporary .mov
}

public enum CameraCapture {
    /// Writes the shot into `intake/<captureID>/0.heic` (ImageIO, quality 0.9, metadata merged with
    /// the orientation) or moves the video to `intake/<captureID>/0.mov`, and returns the draft
    /// (method .camera, representationSource "camera", location as given).
    public static func stage(_ result: CameraResult, intake: IntakeDirectory, captureID: UUID,
                             startedAt: Date, timeZone: TimeZone, location: CaptureLocation?) throws -> PreparedCapture
}

extension AppSettings { public var cameraSavesToPhotos: Bool { get nonmutating set } }   // key camera_saves_to_photos, default false
extension SettingsModel {
    public private(set) var cameraSavesToPhotos: Bool
    public func setCameraSavesToPhotos(_ on: Bool)   // logs settings.changed kind "camera_saves_to_photos"
    public static let cameraFooter = "Pictures and videos you take in Hippo stay only in Hippo unless this is on."
}
```

- [ ] **Step 1: Write failing tests**:

```swift
@Test func photoKeepsOrientationAndExifDate()   // CGImage 64×48 from MediaMaker, orientation 6, metadata {Exif: {DateTimeOriginal: "2026:11:09 10:00:00"}} → file 0.heic exists; CGImageSource properties: Orientation 6, Exif DateTimeOriginal preserved; draft.method == .camera; attachment uti "public.heic", mimeType "image/heic", representationSource "camera"; previewImageURL == the file; totalBytes == file size
@Test func videoIsMovedIntoIntake()             // MediaMaker.writeVideo to a temp URL → stage(.video) → file at intake/<id>/0.mov, temp gone, uti "com.apple.quicktime-movie", mimeType "video/quicktime", previewImageURL nil
@Test func cameraSavesToPhotosDefaultsOff()     // AppSettings on a fresh suite → false; set true → true; SettingsModel.setCameraSavesToPhotos logs settings.changed kind camera_saves_to_photos
```

- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.** HEIC: `CGImageDestinationCreateWithURL(url, UTType.heic.identifier, 1, nil)`; properties = metadata merged with `kCGImagePropertyOrientation: orientation` and `kCGImageDestinationLossyCompressionQuality: 0.9`. If HEIC encoding is unavailable on the test host, fall back to JPEG (`public.jpeg`, `image/jpeg`, `0.jpg`) and let the test accept either; on device it is HEIC.
- [ ] **Step 4: Run** `swift test --package-path HippoKit --filter "CameraCaptureTests|SettingsTests"` → PASS.
- [ ] **Step 5: Commit** `feat(presentation): camera staging and the Photos setting`.

---

### Task 6: Shared `CaptureSheetView` and the extension hand-off

**Files:**
- Move: `App/HippoShare/ShareSheetView.swift` → `App/Shared/CaptureSheetView.swift` (rename the type `ShareSheetView` → `CaptureSheetView`; keep `SharePreviewThumbnail` and `ShareStartupFailureView` with it or in `App/HippoShare/`)
- Create: `App/Shared/VoiceCommentControl.swift`
- Modify: `App/HippoShare/ShareViewController.swift`, `project.yml` (URL scheme `hippo` on the app target; `NSCameraUsageDescription`, `NSPhotoLibraryAddUsageDescription`; reword `NSMicrophoneUsageDescription` to "Hippo records voice notes and voice comments when you tap Record.")

**Interfaces:**
- Consumes: `ShareSessionModel` (Task 4), `RecordingSession` (Task 3), `SystemAudioRecorder` (app only).
- Produces:

```swift
struct CaptureSheetView: View {
    enum Voice { case handoff(() -> Void), record(RecordingSession) }
    let model: ShareSessionModel
    let voice: Voice
    let save: (_ acceptPartial: Bool) async -> Void
    let cancel: () -> Void          // for a pending share the view calls `save(false)` instead and labels the button "Save without comment"
    let finish: () -> Void
}
struct VoiceCommentControl: View { let voice: CaptureSheetView.Voice; let disabled: Bool }
```

- The mic button is a 56 pt version of `RecorderView.recordButton` (red disc in a secondary ring; red square while recording) with the captions from Global Constraints; the stopped row shows "Voice comment · <elapsedText>" with a trash button (`discard()`), and tapping the mic in the stopped state asks "Replace the recording?" (Replace → `discard()` then `start()`; Keep → nothing). Denied shows the design copy with Open Settings (the Open Settings button only in the app build; guarded with `#if !HIPPO_SHARE_EXTENSION`).
- In `.handoff` mode, the button has the same look, caption "Record a comment"; tapping calls the closure. `model.handoffFailed` shows `handoffFailedMessage` under it. `model.state == .deferred` shows `handoffMessage` in place of the content, then `finish()` after one second (reuse the `.saved` timer).
- `ShareViewController`: `voice: .handoff { Task { await model.deferForVoiceComment(); if model.state == .deferred { self.openHippo() } } }`; `openHippo()` tries `extensionContext?.open(URL(string: "hippo://pending")!)` and, if its completion reports false, walks `self.next` responders for one that responds to `#selector(UIApplication.openURL(_:))` via `perform`. Never blocks `finish()`.
- `canSave` is false while `.deferred`.

- [ ] **Step 1: Move the file and rename**; build the extension and app (App build check) → `** BUILD SUCCEEDED **`.
- [ ] **Step 2: Add `VoiceCommentControl`** and wire the hand-off; build again.
- [ ] **Step 3: UI tests**: `make uitest` must still pass (`CaptureFlowUITests` share path, if it drives the share sheet, uses the same accessibility identifiers; keep `note-save`, add `voice-comment-button`).
- [ ] **Step 4: Commit** `feat(app): shared capture sheet with voice comment; share hand-off to the app`.

---

### Task 7: Camera flow, pending-share presentation, Settings, logging

**Files:**
- Create: `App/Hippo/Capture/CameraPicker.swift`, `App/Hippo/Capture/CameraCaptureView.swift`, `App/Hippo/Capture/PhotoLibrarySaver.swift`, `App/Hippo/Capture/PendingShareView.swift`
- Modify: `App/Hippo/Timeline/TimelineView.swift` (bottom bar: Note, Camera, Record; `Compose.camera`), `App/Hippo/RootView.swift` (pending presentation on `.active` and `onOpenURL` for `hippo://pending`), `App/Hippo/Settings/SettingsView.swift` (Camera section after Location), `HippoKit/Sources/LocalRepository/Log/LogEvent.swift` (`cameraLibrarySave = "camera.library_save"`), `HippoKit/Sources/HippoPresentation/Log/LogLine.swift` (a line for it: "Saved to Photos" / "Couldn't save to Photos"), `docs/log-format.md`
- Test: `HippoKit/Tests/HippoPresentationTests/LogLineTests.swift` (the new line)

**Interfaces:**
- Consumes: `CameraCapture.stage`, `PreparedCapture`, `ShareSessionModel(prepared:)`, `CaptureSheetView(.record)`, `AppSettings.cameraSavesToPhotos`, `IntakeDirectory.pendingCaptures()`.
- Produces:

```swift
struct CameraPicker: UIViewControllerRepresentable {   // UIImagePickerController, .camera, [image, movie], .typeHigh
    let onResult: (CameraResult) -> Void               // converts originalImage.cgImage + imageOrientation + mediaMetadata, or mediaURL
    let onCancel: () -> Void
}
struct CameraCaptureView: View { let environment: AppEnvironment; let location: LocationService }
    // full-screen cover: picker → stage (captureID UUID(), startedAt now, location(startedAt:)) → CaptureSheetView(.record(session)) with SystemAudioRecorder;
    // Save → BackgroundActivity "camera-save" → on .saved: optional PhotoLibrarySaver.save(fileURL:isVideo:) when settings.cameraSavesToPhotos, then sync pass "camera-sync"/"after_save" and EnrichmentScheduling.run(reason: "camera"); Cancel → confirmation ("Discard this photo?"/"Discard this video?") → intake.discard
    // camera permission: AVCaptureDevice.authorizationStatus(for: .video); .denied/.restricted → alert with Open Settings
enum PhotoLibrarySaver { static func save(fileURL: URL, isVideo: Bool, log: ActivityLog) async }   // PHPhotoLibrary add-only; logs camera.library_save outcome ok, or failed with code "denied" / "failed"; `log` is `environment.store.log`
struct PendingShareView: View { let environment: AppEnvironment; let pending: PendingCapture; let done: () -> Void }
    // CaptureSheetView(.record(session)) with the session started on appear; header button "Save without comment" → save; Save → save; on .saved → done(), sync pass "pending-sync"/"after_save", enrichment reason "pending_share"
```

- `RootView`: `@State private var pending: PendingCapture?`; on `scenePhase == .active` and on `onOpenURL` (`hippo` scheme), if `pending == nil` call `environment.intake.pendingCaptures()`; take the first; log `capture.save_failed` code `pending_missing` × `dropped`; present with `.fullScreenCover(item:)`. `done` re-checks for the next.
- `TimelineView.bottomBar`: Note (bordered) · Camera (bordered, `Label("Camera", systemImage: "camera")`, identifier `camera-button`) · Record (prominent). `.fullScreenCover` for `.camera` (the camera needs full screen; the sheet inside it is the cover's content after the picker finishes).
- `SettingsView`: `cameraSection` between `locationSection` and `enrichmentSection`: `Section("Camera") { Toggle("Also save to Photos", …) } footer: SettingsModel.cameraFooter`.
- The Photos save uses the committed package file (`CommittedPackage` from `store.capture` gives the package directory; the attachment's `relative_path`), not the intake file, which is gone after discard.

- [ ] **Step 1: Write the failing `LogLineTests` case** for `camera.library_save` (ok → "Saved to Photos"; failed/denied → "Couldn't save to Photos (denied)") and run → FAIL.
- [ ] **Step 2: Add the event, the line and the doc row**; run the HippoPresentation tests → PASS.
- [ ] **Step 3: Build the App pieces**; App build check → `** BUILD SUCCEEDED **`; `make uitest` green.
- [ ] **Step 4: Commit** `feat(app): camera button, pending-share sheet, Photos setting`.

---

### Task 8: Docs, acceptance rows, roadmap

**Files:**
- Modify: `README.md` ("The iPhone app" section: Camera button; voice comment on the share sheet and camera sheet; the hand-off; the Photos toggle), `docs/acceptance.md` (rows C1–C7 from design §9, "not run"), `docs/roadmap.md` (mark the two items done, pointing at the design), `docs/superpowers/specs/2026-11-09-hippo-camera-voice-comment-design.md` §3 (add a line: hand-off behaviour on the device to be confirmed in C4/C7)

- [ ] **Step 1: Write the docs.**
- [ ] **Step 2: Run** `make test` (all green), the App build check, `scripts/validate-fixtures.sh`.
- [ ] **Step 3: Commit** `docs: camera and voice comment; acceptance rows C1–C7`.
