# Comments on any capture, one capture control — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the share-sheet voice hand-off; let the user add a typed or spoken comment to any capture from its detail screen, stored as append-only files in the package and uploaded like the rest; and give the Note, Camera and Record buttons one round icon-only look everywhere.

**Architecture:** A comment is `comments/<comment-id>.json` (plus `comments/<comment-id>.m4a` for audio) inside the package directory, written json-last; the manifest never changes. `HippoStore.addComment` writes it, bumps the index's `comment_count`, requeues synced upload jobs and forgets the transcript task for audio. `SyncWorker` uploads comment files add-only after the marker and only marks a job synced when the index's `comment_count` has not moved since it listed the files. `TranscriptEnricher` transcribes audio comments keyed by comment id. One `CaptureButton` SwiftUI view replaces the three bar buttons, the recorder button and the capture sheet's mic.

**Tech Stack:** Swift 6.2, SwiftUI, Swift Testing (`@Test`), SQLite via the existing `Database`, XcodeGen (`project.yml`).

**Spec:** `docs/superpowers/specs/2026-11-10-hippo-comments-design.md` (binding). It supersedes §3–§4.4 of `docs/superpowers/specs/2026-11-09-hippo-camera-voice-comment-design.md`.

## Global Constraints

- Never rewrite `metadata.json`, `complete.json` or anything under `content/` of a committed package. Comments are new files only.
- Comment json is written last, locally and remotely; an audio file is written before its json.
- Upload of comment files is add-only (`StorageAdapter.uploadFile`); `replaceFile` is never used for them.
- Copy, verbatim: bar accessibility labels "Note", "Camera", "Record" / "Stop"; identifiers `note-button`, `camera-button`, `record-button`; comment-mode titles "Add a comment" and "Record a comment"; placeholder "Write a comment"; Detail section title "Comments"; captions "Added today, 14:02" / "Added 3 Nov, 09:15" (locale-formatted); recorder failure copy "Hippo couldn't save this comment. It's still here. Try again."
- Log events carry no content: `comment.added` (`kind` = `text` | `audio`), `comment.save_failed` (`code`).
- Every new public type is `Sendable`; models stay `@MainActor` where their neighbours are.
- Commit after each task with the `Co-Authored-By` and `Claude-Session` trailers in use on this branch. Never commit `Hippo.xcodeproj`, `Config/Secrets.xcconfig` or `.env`.
- `make test` (all HippoKit suites) must be green at the end of every task; tasks 7 and 8 also build the app (`xcodegen generate && xcodebuild -project Hippo.xcodeproj -scheme Hippo -destination 'generic/platform=iOS Simulator' build`) and task 7 runs `make uitest`.

## Review Focus

1. A comment added while its capture's upload job is `uploading` (Task 4: `markSyncedIfCommentsUnchanged` test with the count bumped between listing and marking).
2. A comment json without its audio file, or with the wrong bytes, in a package: Detail and sync treat it as pending, never corrupt (Task 2 loader test; Task 4 worker skips it).
3. A capture whose only content is a recording (`voice_recording`) must not list that recording twice on Detail (Task 6 test `voiceRecordingIsNotAComment`).
4. The timeline excerpt after a typed comment on a capture that already had a capture-time comment: unchanged (Task 3 test `recordCommentKeepsExistingExcerpt`).
5. Delete everywhere with comments present: the remote folder delete removes them and nothing references them afterwards (Task 4 test `deleteEverywhereRemovesComments`).

---

### Task 1: Remove the share hand-off

**Files:**
- Delete: `HippoKit/Sources/ShareIntake/PendingCapture.swift`, `HippoKit/Tests/ShareIntakeTests/PendingCaptureTests.swift`, `App/Hippo/Capture/PendingShareView.swift`
- Modify: `HippoKit/Sources/ShareIntake/IntakeDirectory.swift` (sweep doc + the `pendingFileName` skip), `HippoKit/Sources/HippoPresentation/Share/ShareSessionModel.swift`, `HippoKit/Tests/HippoPresentationTests/ShareSessionTests.swift`, `App/Shared/CaptureSheetView.swift`, `App/Shared/VoiceCommentControl.swift`, `App/HippoShare/ShareViewController.swift`, `App/Hippo/RootView.swift`, `App/Hippo/Timeline/TimelineView.swift`, `App/Hippo/Capture/CameraCaptureView.swift`, `project.yml`, `README.md`, `docs/acceptance.md`, `docs/log-format.md`

**Interfaces:**
- Produces: `ShareSessionModel.init(store:intake:prepared:destinationName:voice:location:now:)` (no `isPendingShare`); `ShareSessionModel.State` without `.deferred`; `CaptureSheetView.voice: RecordingSession?` (nil hides the voice block); `VoiceCommentControl(session: RecordingSession, disabled: Bool)`.

- [ ] **Step 1: Delete the pending machinery in HippoKit.** Remove the three files above. In `ShareSessionModel.swift` remove `PreparedCapture.init(_ pending:)`, `case deferred`, `handoffMessage`, `handoffFailedMessage`, `isPendingShare`, `handoffFailed`, the `isPendingShare:` init parameter, the guard in `cancel()` and the whole `// MARK: - Hand-off` block. Remove the doc comments that mention pending shares.
- [ ] **Step 2: Trim the tests.** In `ShareSessionTests.swift` drop `deferWritesPendingWithCommentAndLocation`, `deferFailureKeepsReadyAndFlags`, `pendingSaveRemovesPendingFileAfterCommit`, `cancelKeepsPendingShare`, the `isPendingShare` argument of `Rig` and the assertion on line ~281. Keep every voice-save test.
- [ ] **Step 3: Run `make test`.** Expected: green; `ShareIntakeTests` no longer has pending tests.
- [ ] **Step 4: App side.** `CaptureSheetView`: replace `enum Voice` with `let voice: RecordingSession?`; remove the `.deferred` case, `isClosing` becomes `model.state == .saved`, remove the pending header branch and the `handoffFailed` block; show `VoiceCommentControl` only when `voice != nil`. `VoiceCommentControl`: drop the `.handoff` case; its stored property is `let session: RecordingSession`. `ShareViewController`: pass `voice: nil`; delete `openHippo()` and `openThroughResponderChain`. `CameraCaptureView`: drop `isPendingShare: false`, pass `voice: session`. `RootView`: remove `presentationClosed`, all pending state, the cover, `onAppear`, the scene-phase handler, `onOpenURL`, the notification receiver, `checkPending`, `finishPending`, `putOffPending`, `PendingShareItem`, and `import ShareIntake`. `TimelineView`: remove `presentationClosed()` and its four call sites (keep the `model.reload()` calls in `onDismiss`). `project.yml`: delete the `hippo` URL scheme entry and its comment (keep the `db-` scheme).
- [ ] **Step 5: Docs.** `README.md`: delete the hand-off paragraph (line ~60) and the "A pending share waits…" bullet (~78); the "Camera and voice comments" subsection keeps the camera and in-sheet voice comment text. `docs/acceptance.md`: delete rows C4, C5, C6; in C7 remove the share clause from the Steps and Expected cells (Task 8 adds the new rows). `docs/log-format.md`: the `capture.save_failed` row (both occurrences) loses the `pending_missing` / `pending_already_committed` text.
- [ ] **Step 6: Build the app and run `make test`.** Expected: `** BUILD SUCCEEDED **`, tests green. `grep -rn "pending" App HippoKit/Sources --include=*.swift -i | grep -iv "pendingLine\|PendingLineView\|pending:\|\.pending\b\|pendingRecording\|hasPendingRecording\|status.*pending\|\"pending\"\|nextAttempt\|JobState\|retry"` shows no pending-share leftovers (judge the remaining hits by eye).
- [ ] **Step 7: Commit** `refactor: remove the share-sheet voice hand-off`.

---

### Task 2: CaptureCore comment model, writer, loader, schema, fixtures

**Files:**
- Create: `HippoKit/Sources/CaptureCore/Model/CaptureComment.swift`, `HippoKit/Sources/CaptureCore/Package/CommentWriter.swift`, `HippoKit/Sources/CaptureCore/Package/PackageComments.swift`, `schema/capture-comment-v1.schema.json`, `HippoKit/Tests/CaptureCoreTests/CommentWriterTests.swift`
- Modify: `HippoKit/Sources/CaptureCore/Package/PackageWriter.swift` (`CommittedPackage.comments`), `HippoKit/Sources/CaptureCore/Package/PackageValidator.swift` (`load` fills comments), `HippoKit/Sources/CaptureCore/Model/HippoJSON.swift` (`decodeComment`), `HippoKit/Sources/hippo-fixtures/main.swift`, `fixtures/README.md`, `scripts/validate-fixtures.sh`, `HippoKit/Tests/CaptureCoreTests/FixtureTests.swift`, `docs/package-format.md`

**Interfaces:**
- Produces:
  ```swift
  public struct CommentAudio: Codable, Sendable, Equatable {
      public var relativePath: String   // "comments/<comment-id>.<ext>"
      public var uti: String
      public var mimeType: String?
      public var byteCount: Int64
      public var sha256: String
      public var media: MediaFacts?     // duration_seconds only, in practice
  }
  public struct CaptureComment: Codable, Sendable, Equatable, Identifiable {
      public var schemaVersion: Int, captureID: String, commentID: String
      public var addedAt: Date, localDatetime: String, timezoneIdentifier: String, utcOffsetSeconds: Int
      public var producer: Producer
      public var text: String?          // exactly one of text / audio
      public var audio: CommentAudio?
      public var id: String { commentID }
      public var relativePath: String { "comments/\(commentID).json" }
      /// The json path, preceded by the audio path when present (upload order).
      public var filePaths: [String]
  }
  public enum CommentDraft: Sendable, Equatable {
      case text(String)
      case audio(fileURL: URL, uti: String, mimeType: String?, durationSeconds: Double?)
  }
  public struct CommentWriter: Sendable {
      public init(layout: StoreLayout, producer: Producer, space: any SpaceChecking = VolumeSpaceChecker(),
                  makeID: @escaping @Sendable () -> UUID = { UUID() })
      /// Writes the comment into `package.directoryURL/comments/`, audio first, json last. Throws
      /// `CaptureError.emptyCapture` for whitespace text, `.insufficientSpace` as PackageWriter does,
      /// `.io` otherwise; on any failure no json exists.
      public func add(_ draft: CommentDraft, to package: CommittedPackage, now: Date, timeZone: TimeZone) throws -> CaptureComment
  }
  public enum PackageComments {
      public static let directoryName = "comments"
      public struct Listing: Sendable, Equatable { public var comments: [CaptureComment]; public var pendingCount: Int }
      /// Every decodable json under comments/ whose audio (if any) exists and matches byte_count + sha256,
      /// sorted by addedAt then commentID. Others count as pending. A json with another schema_version
      /// or no decodable body counts as pending too (never throws).
      public static func load(directory: URL) -> Listing
  }
  extension CommittedPackage { public var comments: [CaptureComment] }   // stored, default []; filled by load(directory:)
  extension HippoJSON { public static func decodeComment(_ data: Data) throws -> CaptureComment }  // FormatError.unsupportedSchemaVersion as decodeMetadata
  ```

- [ ] **Step 1: Failing tests** in `CommentWriterTests.swift` (use `HippoTestSupport` to commit a package first, as `PackageWriterTests` does):
  - `textCommentRoundTrips`: `add(.text("  hello  "))` → file `comments/<id>.json` exists, decoded `text == "hello"`, `audio == nil`, `captureID` matches, `localDatetime` ends with the zone offset, `PackageComments.load` returns it with `pendingCount == 0`.
  - `audioCommentWritesAudioThenJson`: `add(.audio(fileURL: tmp m4a, uti: "com.apple.m4a-audio", mimeType: "audio/mp4", durationSeconds: 1.5))` → `comments/<id>.m4a` bytes equal the source, `audio.byteCount`/`sha256` match `StreamingHasher`, `media.durationSeconds == 1.5`, `filePaths == ["comments/<id>.m4a", "comments/<id>.json"]`; the source file is untouched.
  - `whitespaceTextIsRejected`: `.text("  \n")` throws `CaptureError.emptyCapture`; the `comments/` directory does not exist afterwards.
  - `failureLeavesNoJson`: a `SpaceChecking` fake reporting 0 bytes → `.insufficientSpace`; no `comments/` entries; nothing left under `staging/`.
  - `loaderTreatsMissingAudioAsPending`: write a valid audio comment, delete its m4a → `load` returns `comments == []`, `pendingCount == 1`; replace the m4a with other bytes → same.
  - `loaderIgnoresUnsupportedSchema`: a json with `schema_version: 2` → pending.
  - `loaderOrdersByAddedAt`: two text comments with `now` 1 s apart written in reverse → sorted ascending.
  - `committedPackageLoadIncludesComments`: `CommittedPackage.load(directory:layout:)` after one comment → `comments.count == 1`; `PackageValidator.validate` still `.complete` with the same digest as before the comment.
- [ ] **Step 2: Run** `swift test --package-path HippoKit --filter CommentWriterTests`. Expected: compile failure (types missing).
- [ ] **Step 3: Implement.** `CaptureComment` coding keys snake_case like `CaptureMetadata` (`schema_version`, `capture_id`, `comment_id`, `added_at`, `local_datetime`, `timezone_identifier`, `utc_offset_seconds`, `relative_path`, `mime_type`, `byte_count`); dates through `HippoJSON.encode`. `CommentWriter.add`: stage in `layout.stagingDir/comment-<commentID>/` under a `StagingLock` named like a package lock (the reconciler skips a locked entry; name it so `Reconciler` treats it like `gold-`/`download-` entries, read `Reconciler.sweepStaging` first); audio: copy, hash (`StreamingHasher.digest`), extension from `UTType(uti)?.preferredFilenameExtension ?? "m4a"`; json via `HippoJSON.encode`, `PackageWriter.writeDurably`-style fsync (reuse the private helpers by making them `static` internal); create `package.directoryURL/comments/` (intermediate dirs ok); move audio, then json; `fullSync` the directory; release the lock; on error remove the staging dir and any moved audio. Space check: audio byte count + `PackageWriter.headroomBytes`.
- [ ] **Step 4: Run** the filter again. Expected: PASS.
- [ ] **Step 5: Schema and fixtures.** Write `schema/capture-comment-v1.schema.json` (required fields per the spec §3, `oneOf` text / audio, `additionalProperties: true`). In `hippo-fixtures/main.swift`, after committing package 4 (`mixed`), add one text comment ("Bought this one.") and one audio comment (1 s AAC via `MediaMaker.writeAudio`) with `CommentWriter` using fixed ids `00000000-0000-4000-8000-00000000c001`/`c002` and `now` = base + 4 min + 1 h / + 2 h. Update `fixtures/README.md` (table row note for `mixed`, a "Comments" paragraph). Extend `scripts/validate-fixtures.sh` with `comments=(fixtures/packages/captures/*/*/*/*/comments/*.json)` validated against the new schema. Regenerate: `swift run --package-path HippoKit hippo-fixtures fixtures/packages && swift run --package-path HippoKit hippo-fixtures enrichments fixtures/packages && scripts/validate-fixtures.sh`. Add to `FixtureTests`: `mixedFixtureHasTwoComments` (load → 2 comments, one text, one audio with duration). Expected: validator passes, tests green.
- [ ] **Step 6: `docs/package-format.md`.** Layout block gets the two `comments/` lines; the "immutable" bullet becomes "The manifested files are immutable once `complete.json` exists; `comments/` is append-only (below)."; new section "Comments" with the field table from spec §3 and the json-last/pending rules; reader algorithm step 7: "List `comments/*.json`; index each new comment id; a comment whose audio is missing or mismatched is pending."; the "Index by capture_id plus digest" sentence adds "plus the set of comment ids".
- [ ] **Step 7: `make test`** green, then commit `feat(core): append-only comments in a package`.

---

### Task 3: Index and task-store support

**Files:**
- Modify: `HippoKit/Sources/LocalRepository/SQLite/Migrations.swift` (v5), `HippoKit/Sources/LocalRepository/CaptureIndex.swift`, `HippoKit/Sources/LocalRepository/CaptureFilter.swift` (`CaptureSummary.commentCount`), `HippoKit/Sources/LocalRepository/Enrichment/EnrichmentTaskStore.swift`, `HippoKit/Sources/LocalRepository/JobStore.swift`
- Test: `HippoKit/Tests/LocalRepositoryTests/CaptureIndexTests.swift`, `EnrichmentTaskStoreTests.swift`, `DestinationJobTests.swift`

**Interfaces:**
- Produces:
  ```swift
  // Migrations: v5 = "ALTER TABLE captures ADD COLUMN comment_count INTEGER NOT NULL DEFAULT 0;" (target becomes 5)
  extension CaptureIndex {
      /// has_comment = 1, comment_count += 1, FTS user_note gets " " + text appended (text comments),
      /// note_excerpt = first 120 chars of text when `replacesExcerpt` (the capture has no user_note).
      public func recordComment(captureID: String, _ c: CaptureComment, replacesExcerpt: Bool) throws
      public func commentCount(captureID: String) throws -> Int
  }
  // register(): comment_count = p.comments.count; has_comment also true when p.comments is non-empty;
  // note_excerpt falls back to the newest text comment; FTS user_note includes every comment text.
  public struct CaptureSummary { public var commentCount: Int }   // init param, default 0; page() reads it
  extension EnrichmentTaskStore { public func forget(captureID: String, kind: FacetKind) throws }   // DELETE the row
  extension JobStore {
      /// Marks synced only if captures.comment_count still equals `commentCount`; otherwise requeues (pending) and returns false.
      public func markSyncedIfCommentsUnchanged(jobID: String, owner: String, captureID: String, commentCount: Int) throws -> Bool
      /// Requeues every job of the capture whose state is synced; returns how many.
      public func requeueSynced(captureID: String) throws -> Int
  }
  ```

- [ ] **Step 1: Failing tests.** `CaptureIndexTests`: `recordCommentSetsFlagsAndExcerpt` (register a capture without a note; record a text comment with `replacesExcerpt: true` → `page` summary has `noteExcerpt == text`, `commentCount == 1`; `CaptureFilter(hasComment: true)` returns it; a search for a word of the text finds it); `recordCommentKeepsExistingExcerpt` (capture with `userNote`; `replacesExcerpt: false` → excerpt unchanged, `commentCount == 1`); `recordAudioCommentCountsWithoutExcerpt`; `registerCountsPackageComments` (package loaded with two comments → `commentCount == 2`, `has_comment`, excerpt = newest text). `EnrichmentTaskStoreTests`: `forgetRemovesRow` (set then forget → `task(...) == nil`, `capturesNeeding` lists it again). `DestinationJobTests`: `markSyncedIfCommentsUnchanged` true path (state synced) and false path (count bumped → state pending, lease cleared); `requeueSyncedOnlyTouchesSyncedJobs`.
- [ ] **Step 2: Run** `swift test --package-path HippoKit --filter "CaptureIndexTests|EnrichmentTaskStoreTests|DestinationJobTests"`. Expected: compile failure.
- [ ] **Step 3: Implement** per the Interfaces block. The `markSyncedIfCommentsUnchanged` UPDATE is one statement: `UPDATE jobs SET state='synced', last_error_code=NULL, next_attempt_at_ms=NULL, lease_owner=NULL, lease_expires_at_ms=NULL, updated_at_ms=? WHERE job_id=? AND lease_owner=? AND (SELECT comment_count FROM captures WHERE capture_id=?) = ?`; when it changes no row and the job is still owned, call `requeue`.
- [ ] **Step 4: Run** the filter. Expected: PASS. Then `make test` green.
- [ ] **Step 5: Commit** `feat(repo): comment count, comment indexing, forget task, synced-if-unchanged`.

---

### Task 4: Store and sync

**Files:**
- Modify: `HippoKit/Sources/SyncEngine/HippoStore.swift`, `HippoKit/Sources/SyncEngine/SyncWorker.swift`, `HippoKit/Sources/LocalRepository/Log/LogEvent.swift` (`commentAdded = "comment.added"`, `commentSaveFailed = "comment.save_failed"`)
- Test: `HippoKit/Tests/SyncEngineTests/HippoStoreTests.swift`, `HippoKit/Tests/SyncEngineTests/SyncWorkerTests.swift`

**Interfaces:**
- Consumes: Task 2 writer/loader, Task 3 index and job store methods.
- Produces:
  ```swift
  extension HippoStore {
      /// Loads the package (CaptureError.io("capture missing") / ("package invalid") when it can't),
      /// writes the comment, records it in the index, requeues synced jobs, forgets the transcript
      /// task for audio, logs comment.added. Logs comment.save_failed with saveFailureCode on throw.
      public func addComment(captureID: String, _ draft: CommentDraft, now: Date = Date(),
                             timeZone: TimeZone = .current) async throws -> CaptureComment
  }
  ```
  `SyncWorker.upload`: after the marker step, `PackageComments.load(directory:)` → for each comment, `ensureContainer(directory + "/comments")` once, then `syncFile` for every path in `comment.filePaths` without a receipt (audio integrity from `CommentAudio`, json integrity from `StreamingHasher.digest`). Pending comments (not in `comments`) are skipped. `upload` returns the `index.commentCount(captureID:)` it read **before** listing comment files; `process` calls `jobs.markSyncedIfCommentsUnchanged(..., commentCount:)` and, when it returns false, logs nothing and returns `.abandoned` (the job is pending again and is claimed on the next loop iteration).

- [ ] **Step 1: Failing tests.** `HippoStoreTests`: `addTextCommentIndexesAndRequeues` (capture, `insertSynced` job, add → job state pending, `commentCount == 1`, log has `comment.added` with kind text, index excerpt set); `addAudioCommentForgetsTranscript` (set transcript task `ok`; add audio → `enrichmentTasks.task(...) == nil`; text comment leaves it); `addCommentToPendingJobDoesNotRequeue`; `addCommentMissingCaptureThrowsAndLogs` (`comment.save_failed`); `deleteEverywhereRemovesComments` (filesystem adapter: comment files present remotely after a worker pass; delete everywhere → the remote package directory is gone). `SyncWorkerTests`: `uploadsCommentFilesAfterMarkerAudioFirst` (filesystem adapter; receipts contain the four package paths plus `comments/<id>.m4a` then `comments/<id>.json` in that order of the adapter's upload log); `commentAddedDuringUploadKeepsJobPending` (bump `comment_count` via `recordComment` between `upload`'s listing and `markSynced`, using a fake adapter whose `uploadFile` hook adds the comment on the first call → after the pass the job is `pending` with the first files receipted; a second pass uploads the comment and marks synced); `pendingCommentIsSkipped` (json without audio → not uploaded, job synced).
- [ ] **Step 2: Run** `swift test --package-path HippoKit --filter "HippoStoreTests|SyncWorkerTests"`. Expected: compile failure.
- [ ] **Step 3: Implement.** `HippoStore` keeps a `CommentWriter` built with the same `layout`, `producer` and space checker as `writer`. `addComment` order: load package (`CommittedPackage.load(directory:layout:trimmed:)`), `commentWriter.add`, `index.recordComment(..., replacesExcerpt: (package.metadata.userNote ?? "").isEmpty && draft is text)`, `jobs.requeueSynced`, `enrichmentTasks.forget(kind: .transcript)` for audio, log. Index/requeue/forget failures after the write are logged with `osLog` and not thrown (the comment is on disk; `recover()` registers package comments through `register`).
- [ ] **Step 4: Run** the filter. Expected: PASS. `make test` green (the Dropbox contract tests are untouched).
- [ ] **Step 5: Commit** `feat(sync): add comments to a capture and upload them`.

---

### Task 5: Transcripts for audio comments

**Files:**
- Modify: `HippoKit/Sources/Enrichment/Enricher.swift`, `HippoKit/Sources/Enrichment/TranscriptEnricher.swift`, `HippoKit/Sources/Enrichment/EnrichmentRunner.swift`, `docs/enrichment-format.md`
- Test: `HippoKit/Tests/EnrichmentTests/TranscriptEnricherTests.swift`, `EnrichmentRunnerTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct EnricherInput { public var comments: [CaptureComment] }   // init param, default []
  public protocol Enricher { func applies(to m: CaptureMetadata, comments: [CaptureComment]) -> Bool }
  extension Enricher { public func applies(to m: CaptureMetadata, comments: [CaptureComment]) -> Bool { applies(to: m) } }
  ```
  `TranscriptEnricher.applies(to:comments:)` is true for any audio attachment or any `audio` comment; `run` transcribes comments after attachments, `TranscriptItem(attachmentID: comment.commentID, …)`, same 3600 s cap from `audio.media?.durationSeconds`. `EnrichmentRunner.scheduleOne` and `process` load `PackageComments.load(directory:).comments` (the directory from `index.relativeDirectory`) and pass them.

- [ ] **Step 1: Failing tests.** `TranscriptEnricherTests`: `audioCommentIsTranscribedByCommentID` (metadata without audio, one audio comment → `applies` true, one item with `attachmentID == commentID`); `textCommentOnlyIsNotApplicable`. `EnrichmentRunnerTests`: `audioCommentSchedulesAndTranscribes` (capture with no audio: task `not_applicable`; add an audio comment through `HippoStore.addComment`; `schedule()` then `runPending` → task `ok`, document transcript item keyed by the comment id).
- [ ] **Step 2: Run** `swift test --package-path HippoKit --filter "TranscriptEnricherTests|EnrichmentRunnerTests"`. Expected: failure.
- [ ] **Step 3: Implement.** Other enrichers are untouched (the default extension covers them).
- [ ] **Step 4: Docs.** `docs/enrichment-format.md` line 5: "It never changes a capture package's manifested files." The `transcript` facet paragraph: "`attachment_id` names an attachment or, for a comment's audio, the `comment_id` of a `comments/` file."
- [ ] **Step 5: Run** the filter, then `make test`. Commit `feat(enrichment): transcribe audio comments`.

---

### Task 6: Presentation: save targets, Detail comments, log lines

**Files:**
- Modify: `HippoKit/Sources/HippoPresentation/Capture/RecorderModel.swift`, `HippoKit/Sources/HippoPresentation/Capture/NoteComposer.swift`, `HippoKit/Sources/HippoPresentation/Detail/CaptureDetail.swift`, `HippoKit/Sources/HippoPresentation/Detail/CaptureDetailModel.swift`, `HippoKit/Sources/HippoPresentation/Log/LogLine.swift`
- Create: `HippoKit/Sources/HippoPresentation/Capture/SaveTarget.swift`
- Test: `HippoKit/Tests/HippoPresentationTests/CaptureModelTests.swift`, `DetailTests.swift`, `LogLineTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum SaveTarget: Equatable, Sendable { case newCapture; case comment(captureID: String) }
  // RecorderModel.init(store:intake:recorder:permission:location:now:target: SaveTarget = .newCapture)
  // save(): .comment → store.addComment(captureID:, .audio(fileURL: taken.url, uti: "com.apple.m4a-audio",
  //         mimeType: "audio/mp4", durationSeconds: taken.duration)); failure copy
  //         RecorderModel.commentSaveFailedMessage = "Hippo couldn't save this comment. It's still here. Try again."
  extension NoteComposer { public static func comment(text: String) -> CommentDraft? }   // nil when whitespace; trimmed
  public struct CommentRow: Equatable, Sendable, Identifiable {
      public enum Body: Equatable, Sendable { case text(String); case audio(URL, durationText: String?) }
      public var id: String
      public var body: Body
      public var caption: String?        // nil for capture-time comments; "Added today, 14:02" / "Added 3 Nov, 09:15"
      public var transcript: String?
      public var transcriptLayer: Layer?
  }
  public struct CaptureDetail { public var comments: [CommentRow] }   // replaces `comment: String?`
  // CaptureDetail.make(..., comments: [CaptureComment] = [], ...)
  ```
  Row order: `user_note` (text, no caption), then attachments with `representation_source == "recording"` **unless** `captureMethod == .voiceRecording` (audio, no caption, duration from `media`, transcript from `enrichment.transcripts[attachmentID]`), then `comments` in order (caption from `addedAt` in the capture's `calendar`/`locale`: "Added today, " + short time when `calendar.isDateInToday`, else "Added " + abbreviated day-month + ", " + short time; transcript from `enrichment.transcripts[commentID]`). `transcripts` (the Transcripts section) excludes attachments shown as comment rows. `CaptureDetailModel.load` passes `PackageComments.load(directory: url).comments`.
  `LogLine`: `.commentAdded` → "Comment added" (kind appended: "Comment added · audio"), `.commentSaveFailed` → "Couldn't save comment · <code>".

- [ ] **Step 1: Failing tests.** `CaptureModelTests`: `recorderSavesCommentToTarget` (fake recorder; `target: .comment(captureID:)` → `store.addComment` effect: the capture's `commentCount == 1`, the index has no new capture, the intake file is gone); `recorderCommentFailureKeepsRecording` (missing capture id → state failed with the comment copy, `hasPendingRecording`); `noteComposerCommentTrims`. `DetailTests`: `commentsOrderAndCaptions` (user note + two package comments, one text one audio with a transcript → three rows; captions per the exact copy using a fixed `now`, `Locale(identifier: "en_US")`, `TimeZone` fixed); `voiceRecordingIsNotAComment` (method voice_recording with its recording → `comments == []`, preview `.audio`); `cameraVoiceCommentIsAComment` (method camera, HEIC + recording attachment → one audio row, no caption, `transcripts` empty). `LogLineTests`: the two new lines.
- [ ] **Step 2: Run** `swift test --package-path HippoKit --filter "CaptureModelTests|DetailTests|LogLineTests"`. Expected: compile failure.
- [ ] **Step 3: Implement.** Keep `RecorderModel.save()`'s restore-on-failure path for both targets.
- [ ] **Step 4: Run** the filter, then `make test`. Commit `feat(presentation): comment save target, Detail comment rows`.

---

### Task 7: App: CaptureButton, bars, Detail comments, comment-mode sheets

**Files:**
- Create: `App/Shared/CaptureButton.swift`
- Modify: `App/Hippo/Timeline/TimelineView.swift`, `App/Hippo/Detail/CaptureDetailView.swift`, `App/Hippo/Detail/AttachmentPreview.swift` (`AudioPreview` becomes internal `AudioPlayerRow`), `App/Hippo/Capture/RecorderView.swift`, `App/Hippo/Capture/NoteEditorView.swift`, `App/Shared/VoiceCommentControl.swift`, `App/HippoUITests/CaptureFlowUITests.swift`

**Interfaces:**
- Consumes: Task 6 `SaveTarget`, `CommentRow`, `CaptureDetail.comments`.
- Produces:
  ```swift
  struct CaptureButton: View {
      enum Kind: Equatable { case note, camera, record(recording: Bool) }
      let kind: Kind
      var size: CGFloat = 56
      var identifier: String? = nil      // overrides the default id below
      let action: () -> Void
  }
  ```
  Drawing: a filled `Circle` (`.tint` for note and camera, `.red` for record) with a white SF Symbol (`square.and.pencil`, `camera`, `mic`) at `size * 0.42` weight `.semibold`; recording → a white `RoundedRectangle(cornerRadius: size * 0.09)` of `size * 0.32`. `.buttonStyle(.plain)`, opacity 0.4 when disabled, `.contentShape(Circle())`. Accessibility labels "Note" / "Camera" / "Record" or "Stop"; identifiers `note-button` / `camera-button` / `record-button`.

- [ ] **Step 1: `CaptureButton`** as above (compiles in both targets; no UIKit).
- [ ] **Step 2: Timeline bar.** `bottomBar` = `HStack { Spacer(); CaptureButton(kind: .note) {…}; Spacer(); CaptureButton(kind: .camera) {…}; Spacer(); CaptureButton(kind: .record(recording: false)) {…}; Spacer() }.padding(.vertical, 8).background(.bar)`. Remove the Label buttons, `.labelStyle`, `.controlSize`.
- [ ] **Step 3: RecorderView.** `init(environment:location:target: SaveTarget = .newCapture)`; pass `target` to the model; title "Record" / "Record a comment"; replace `recordButton` with `CaptureButton(kind: .record(recording: recording), size: 88)`; after a `.comment` save run `SyncScheduling.runPass(... name: "comment-sync", trigger: "after_save")` and `EnrichmentScheduling.run(environment, reason: "comment")`.
- [ ] **Step 4: NoteEditorView.** `init(environment:location:target: SaveTarget = .newCapture)`; for `.comment`: title "Add a comment", placeholder "Write a comment", `save()` uses `NoteComposer.comment(text:)` and `environment.store.addComment(captureID:_:)` inside the same `BackgroundActivity.run(name: "comment-save")`, then "comment-sync" / "comment" as above. Keep `note-save`.
- [ ] **Step 5: VoiceCommentControl.** `MicButton` is replaced by `CaptureButton(kind: .record(recording:), identifier: "voice-comment-button")`; the "Record a comment" caption and the rest stay.
- [ ] **Step 6: Detail.** Replace the "Your comment" section with `Section("Comments")` listing `detail.comments`: text rows as before (italic, selectable); audio rows `AudioPlayerRow(url:)` plus the duration; caption in `.caption` secondary under the body; transcript in `.callout` secondary under that, with the layer stripe. `.safeAreaInset(edge: .bottom)` bar: `HStack { Spacer(); CaptureButton(kind: .note) { compose = .note }; Spacer(); CaptureButton(kind: .record(recording: false)) { compose = .record }; Spacer() }.padding(.vertical, 8).background(.bar)`, shown only when `model.detail != nil`. `.sheet(item: $compose, onDismiss: { Task { await model.load() }; NotificationCenter.default.post(name: TimelineModel.enrichmentChanged, object: nil) })` presenting `NoteEditorView(..., target: .comment(captureID: captureID))` or `RecorderView(..., target: …).presentationDetents([.medium])`. `compose` is a private `enum Compose: String, Identifiable { case note, record }`.
- [ ] **Step 7: UI tests.** In the first flow test assert `app.buttons["record-button"].exists` next to the existing `camera-button` assertion. Add `testDetailHasCommentButtons`: open a row's Detail (the existing test creates a note then opens it; reuse) and assert `note-button` and `record-button` exist there too.
- [ ] **Step 8: Build and run.** `xcodegen generate && xcodebuild -project Hippo.xcodeproj -scheme Hippo -destination 'generic/platform=iOS Simulator' build` → `** BUILD SUCCEEDED **` (also with `Config/Secrets.xcconfig` temporarily out of the way: `HIPPO_DROPBOX_APP_KEY` empty must still build); `make uitest` → `** TEST SUCCEEDED **`; `make test` green.
- [ ] **Step 9: Commit** `feat(app): round capture buttons; comments on a capture`.

---

### Task 8: Docs, acceptance rows, roadmap

**Files:**
- Modify: `README.md`, `docs/acceptance.md`, `docs/log-format.md`, `docs/roadmap.md`, `docs/superpowers/specs/2026-11-09-hippo-camera-voice-comment-design.md` (one line at the top)

- [ ] **Step 1: README.** Rename "Camera and voice comments" to "Camera, voice comments and comments on a capture": keep the camera and camera-sheet mic text; add a paragraph: the share sheet takes a typed comment only; any capture's screen has Note and Record buttons that add a comment after the fact; comments live in `comments/` inside the package, are uploaded with it, searchable when typed, transcribed when audio, and cannot be edited or deleted (add another). Known limits: "Comments can't be edited or deleted." The "Local storage layout" / package section mentions `comments/`.
- [ ] **Step 2: Acceptance.** Replace the C-rows block with C1–C3 as they are, then C4–C10 exactly as spec §9 (Steps / Expected cells; status "not run").
- [ ] **Step 3: Log format.** Add rows `comment.added` ("A comment was added to the capture; `kind` is `text` or `audio`") and `comment.save_failed` ("Adding a comment failed; `code` names the failure") in the per-capture table.
- [ ] **Step 4: Roadmap.** The "Done: Audio comment on share" bullet becomes "**Done: Comments on any capture (2026-11-10, [design](superpowers/specs/2026-11-10-hippo-comments-design.md)).** Note or Record on a capture adds a typed or spoken comment after the fact, stored in `comments/` inside the package and synced. The share-sheet mic (hand-off to the app) was built on 2026-11-09, tried, found too clunky and removed." Add under Parked: "Editing or deleting a comment." and "A desktop reader must list `comments/` on rescan (the package digest does not change)."
- [ ] **Step 5: Old design.** First line after the title: "> Superseded on 2026-11-10 by `2026-11-10-hippo-comments-design.md` for §3–§4.4 (the share-sheet hand-off was removed). The camera button and the in-sheet voice comment stand."
- [ ] **Step 6: Build the app, `make test`, `scripts/validate-fixtures.sh`.** All green. Commit `docs: comments on any capture; acceptance C4–C10`.
