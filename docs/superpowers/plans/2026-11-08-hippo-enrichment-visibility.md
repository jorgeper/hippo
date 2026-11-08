# Hippo Enrichment Visibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make enrichment visible. Detail gets layer stripes, progress indicators and a Status section, and Settings gets a status summary. An always-recorded event log is stored in its own folder, uploaded to the destination, and shown in Developer mode as per-capture Activity and a global log. Relative dates resolve against the capture.

**Architecture:**
- **Event log:** lives in `LocalRepository/Log/`, owned by `HippoStore` so the app and the share extension write the same JSONL files under `logs/`. It sits outside `hippo.sqlite`.
- **Instrumentation:** the existing components (`HippoStore`, `EnrichmentRunner`, `SyncWorker`, `EnrichmentUploader`, `GoldPuller`, `SyncCoordinator`, `SettingsModel`) emit events.
- **Log upload:** a new `SyncEngine` step, `LogUploader`, that `SyncCoordinator` runs last in each pass.
- **Presentation:** `HippoPresentation` derives stripes, progress and Status as pure functions of task rows, documents, jobs, switches and connectivity, never from the log. A separate set of view models renders log events as plain-words lines.
- **App:** the SwiftUI views.

**Tech Stack:** Swift 6 language mode, Swift Testing, SQLite, Foundation (`FileHandle`, `flock` via Darwin), `NSDataDetector` (HippoKit); SwiftUI, Network (App). XcodeGen, Xcode 27.2.

**Spec:** `docs/superpowers/specs/2026-11-08-hippo-enrichment-visibility-design.md` (wins on conflict; §n below refers to it), on top of `2026-11-07-hippo-enrichment-design.md`. Executors read the visibility design in full.

**Branch:** `feat/enrichment-visibility` (checked out, from `main` after PR #4).

## Plan-level calls (decisions the design left open)
- **No new target.** The log lives in `LocalRepository/Log/`. Every module that needs it already depends on `LocalRepository`, and `project.yml` needs no change.
- **`proc` is `app` or `share` only.** Background tasks run in the app process; `bg.task` events bracket them. (§7.3 listed `bg`; dropped.)
- **`settings.changed` carries `on` (Bool).** This is one field beyond §7.3's list; `kind` names the switch.
- **`enrich.scheduled` (global) replaces `enrich.backfill`:** `EnrichmentRunner.schedule` logs one event per kind that queued at least one capture, with `count`. That covers backfills and new captures alike.
- **No `not_applicable` events.** Scheduling a kind that doesn't apply is not logged. It would add one useless line per capture per kind.
- **Write failures:** go to os `Logger` (category `log`), not `diagnostics.json`. Counting them across two processes isn't worth a shared counter.
- **"Working" = pending and due.** `claimNext` doesn't mark a row running, so "currently running" isn't tracked separately. A running task is pending and due.
- **Last sync:** the time and whether anything failed are stored in App Group defaults through `AppSettings`, written by `SyncCoordinator`. This is "in the store, not the log" in spirit; no migration needed.
- **Live updates:** the runner posts a new `EnrichmentRunner.taskFinished` notification after every task. The timeline debounces reloads by 500 ms.
- **Network kinds for presentation:** `[.linkPreview, .place]` is a constant in HippoPresentation (`EnrichmentProgress.networkKinds`), since HippoPresentation doesn't link `Enrichment`.

## Global Constraints
- iOS 27.0 / macOS 27.0, Swift 6 language mode, no third-party dependencies. HippoKit targets import no UIKit/SwiftUI and stay `swift test`-able on macOS.
- **The UI never reads the log to decide what to show.** Stripes, spinners, pending lines and Status come from task rows, enrichment documents and jobs (§2 anti-goal).
- **The log holds no content.** No transcript, note, shared text, OCR text, titles, URLs, hostnames, file names, place names, coordinates or account/destination IDs. Every `code` passes `Diagnostics.safeCode` (`^[a-z0-9_:.-]{1,64}$`, else `unrecognized`). `dest` is the destination's `providerKind` (`filesystem` today, `dropbox` later).
- **Logging never fails or delays capture, enrichment or sync.** Every log call swallows its errors. A lock wait is bounded at 100 ms, then the event is dropped.
- Log layout: `<store root>/logs/YYYY-MM-DD.jsonl` (UTC day), then `YYYY-MM-DD.1.jsonl`, `.2`… after a Clear. `logs/upload-state.json` sits beside them. Remote: `logs/<install-id>/<same file name>`.
- Retention: 30 days by file date; 2,097,152 bytes per segment file, then one `log.truncated` event and drops for that segment. Remote copies are never deleted by the phone.
- `replaceFile` is allowed under `enrichments/` and `logs/` only; `captures/` stays write-once.
- Stripe colours (light / dark): bronze `#b0763c` / `#c98a4b`, silver `#a2a9b0` / `#b8bfc6`, gold `#d4ab2a` / `#e0b83a`, sync `#5ac8fa` / `#64d2ff`.
- Settings copy, exact:
  - stripes toggle "Show where details came from" in the Enrichment section, footer appended to the existing one: "Bronze: what you captured. Silver: added on this iPhone. Gold: added by your server.";
  - Developer section header "Developer", switch "Developer mode", rows "Log", "Clear log".
- Defaults: stripes **on**, Developer mode **off**.
- Missing values are omitted, never "Unknown". The V0 design §3.4 visual bar applies (quiet native iOS, Dark Mode, Dynamic Type).
- App build check (App tasks): `xcodegen generate && xcodebuild -project Hippo.xcodeproj -scheme Hippo -configuration Debug -destination generic/platform=iOS -derivedDataPath build/DerivedData -allowProvisioningUpdates build`. Expected: `** BUILD SUCCEEDED **`.
- Commit after every task. Before each commit, run `git diff --cached` and read all of it for secrets (Jorge's global rule). End commit messages with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus
1. **App and extension appending at the same moment.** Lines must never interleave or tear, and the extension's `capture.saved` must be on disk before it exits. Owned by Task 1 (`concurrentWritersNeverInterleave`, `appendIsDurableBeforeReturn`).
2. **A log folder that is missing, unreadable or holds garbage.** Detail, Timeline and Settings must still show correct Status and progress, and log screens must show what parses. Owned by Task 6 (`statusIgnoresLog`) and Task 7 (`readerSkipsGarbageLines`).
3. **A day file growing while it uploads.** The upload must verify, and the next pass must upload the rest. Owned by Task 3 (`growingFileUploadsSnapshotThenRest`).
4. **Offline for hours.** No row spins; the link preview says it is waiting for a connection; reconnecting turns it back to working. Owned by Task 6 (`offlineNetworkKindIsWaiting`).
5. **A capture saved near midnight, enriched days later.** "tomorrow" must be the day after the capture's local date in the capture's zone, not in UTC. Owned by Task 4 (`tomorrowNearMidnightUsesCaptureZone`).

---

### Task 1: Event log core (§7.1–7.3) + capture events + format doc

**Files:**
- Create: `HippoKit/Sources/LocalRepository/Log/LogEvent.swift`, `HippoKit/Sources/LocalRepository/Log/ActivityLog.swift`, `docs/log-format.md`
- Modify: `HippoKit/Sources/CaptureCore/Package/StoreLayout.swift`, `HippoKit/Sources/SyncEngine/HippoStore.swift`, `HippoKit/Sources/LocalRepository/Diagnostics.swift` (make `safeCode` `public`), `docs/package-format.md` (one sentence pointing to `docs/log-format.md`)
- Test: `HippoKit/Tests/LocalRepositoryTests/ActivityLogTests.swift`, `HippoKit/Tests/SyncEngineTests/HippoStoreTests.swift`

**Interfaces:**
- Produces (all `public`, `Sendable`):
  - `StoreLayout.logsDir: URL` = `root/logs`.
  - `enum LogProcess: String, Codable { case app, share }`
  - `enum LogOutcome: String, Codable { case ok, empty, notApplicable = "not_applicable", deferred, retrying, failed, skipped, cancelled }`
  - `enum LogEventName: String, Codable, CaseIterable` (closed set). Case names are the raw value in camelCase (`capture.saved` → `captureSaved`, `enrich.failed` → `enrichFailed`). Raw values:
    `capture.saved`, `capture.deleted`, `capture.save_failed`, `enrich.queued`, `enrich.started`, `enrich.finished`, `enrich.deferred`, `enrich.retrying`, `enrich.failed`, `enrich.scheduled`, `enrich.pass`, `silver.uploaded`, `silver.upload_failed`, `package.uploaded`, `package.upload_failed`, `gold.applied`, `gold.removed`, `gold.skipped`, `gold.pull`, `sync.pass`, `bg.task`, `app.launch`, `settings.changed`, `log.truncated`, `log.cleared`.
  - `struct LogEvent: Codable, Equatable`. Fields:
    - `t: Date`, `v: Int` (always 1), `proc: LogProcess`, `event: LogEventName`;
    - optionals: `captureID: String?` (key `capture_id`), `kind: String?`, `outcome: LogOutcome?`, `code: String?`, `attempt: Int?`, `count: Int?`, `ms: Int?`, `trigger: String?`, `dest: String?`, `on: Bool?`, `phase: String?` (`start` | `end` | `expired`, for `sync.pass`/`enrich.pass`/`bg.task`), `retryAt: Date?` (key `retry_at`).
    - Init takes everything except `t`, `v` and `proc`, which the log stamps.
    - `code`, `kind`, `trigger`, `dest` and `phase` pass through `Diagnostics.safeCode` in the init.
    - JSON: snake_case keys, nil omitted, dates RFC 3339 UTC with milliseconds (`HippoJSON` style).
  - `final class ActivityLog: Sendable`:
    - `init(layout: StoreLayout, process: LogProcess, now: @escaping @Sendable () -> Date = Date.init, lockTimeout: Duration = .milliseconds(100), segmentCap: Int = 2_097_152)`
    - `func append(_ e: LogEvent)`: never throws.
    - `func events(captureID: String, from day: Date) -> [LogEvent]`: oldest first, all segments of each day from `day`'s UTC day onward.
    - `func globalEvents(limit: Int, before: Date?) -> [LogEvent]`: events with no `captureID`, newest first.
    - `func prune(keepingDays: Int = 30)`
    - `func clear()`
    - `func segmentFiles() -> [URL]`: every `*.jsonl`, sorted by name.
    - `static func fileName(day: Date, segment: Int) -> String`: `2026-11-08.jsonl` for 0, `2026-11-08.1.jsonl` for 1.
  - `HippoStore.open(root:producer:process: LogProcess = .app)` and `HippoStore.log: ActivityLog`.
- Write algorithm (not determined by tests alone):
  - Find today's (UTC) highest existing segment: cache the URL, `stat` it on each append, relist on a miss or a new day.
  - Open with `O_WRONLY|O_APPEND|O_CREAT`, take `flock(LOCK_EX|LOCK_NB)` retrying every 5 ms up to `lockTimeout`, `write` one encoded line plus `\n` in one call, unlock, close.
  - If the file is already ≥ `segmentCap`, write a `log.truncated` line once (when the last line isn't already one) and drop the event.
  - `clear()` takes the lock on today's current segment, notes its number `n`, deletes every `*.jsonl`, and writes `log.cleared` into segment `n+1` of today. `upload-state.json` is kept.

- [ ] **Step 1: Write failing tests** in `ActivityLogTests` (temp root per test, injected `now`):
  - `appendWritesOneJSONLinePerEvent`: two appends → `logs/2026-11-08.jsonl` has 2 lines; line 1 decodes to the event with `proc == .app`, `v == 1`; a nil `captureID` key is absent from the raw JSON.
  - `codesAreSanitized`: `LogEvent(event: .enrichFailed, code: "Hello World https://x")` → `code == "unrecognized"`.
  - `concurrentWritersNeverInterleave`: two `ActivityLog`s (`.app`, `.share`) on the same root, 500 appends each from concurrent tasks → 1000 lines, every line decodes.
  - `appendIsDurableBeforeReturn`: after `append` returns, a fresh `ActivityLog` on the same root reads the event back.
  - `lockTimeoutDropsEvent`: hold `flock` on today's file from a test handle; `append` returns within 300 ms and the line count is unchanged.
  - `segmentCapWritesOneTruncatedMarker`: `segmentCap: 400`; append until over → exactly one `log.truncated` line, no events after it.
  - `eventsForCaptureStartAtItsDay`: events on 2026-11-06 and 2026-11-08 for capture A and one for B; `events(captureID: A, from: 2026-11-07)` returns only the 11-08 one, oldest first.
  - `globalEventsNewestFirstWithLimit`: 5 global + 3 capture events → `globalEvents(limit: 3, before: nil)` returns the 3 newest global ones; `before:` pages.
  - `readerSkipsTornLine`: append a valid line, then raw-write `{"t":` with no newline → `events` returns the valid one only.
  - `pruneKeeps30Days`: files dated 31 and 29 days before `now` → only the 29-day one remains.
  - `clearStartsNextSegment`: append 2 → `clear()` → no `2026-11-08.jsonl`, `2026-11-08.1.jsonl` holds one `log.cleared` line, the next append goes to `.1`; a second clear → `.2`; `upload-state.json` (pre-created) survives.
- [ ] **Step 2:** Run `swift test --package-path HippoKit --filter ActivityLogTests`. Expected: FAIL (types not defined).
- [ ] **Step 3:** Implement `LogEvent.swift` and `ActivityLog.swift` per the interfaces. Add `StoreLayout.logsDir`. Make `Diagnostics.safeCode` public.
- [ ] **Step 4:** Run the filter. Expected: PASS.
- [ ] **Step 5: Failing tests** in `HippoStoreTests`:
  - `captureLogsSaved`: `store.capture(draft)` → `store.log.events(captureID:from:)` has one `capture.saved` with `trigger` = the capture method's raw value and `proc == .app`; a store opened with `process: .share` logs `proc == .share`.
  - `deleteLogsDeleted`: after `delete`, the capture has a `capture.deleted` event.
  - `failedCommitLogsGlobalSaveFailed`: a draft the writer rejects → `globalEvents` has `capture.save_failed` with a non-nil code, and the error still propagates.
- [ ] **Step 6:** Implement in `HippoStore`:
  - `open` gains `process`; `log` is created in `init`.
  - `capture` wraps `writer.commit` to log `save_failed` (code = a fixed name for the error's case) and logs `saved` after the commit succeeds, before indexing.
  - `delete` logs `deleted` after the index row is removed.

  Run `make test`. Expected: all pass.
- [ ] **Step 7:** Write `docs/log-format.md` for a desktop reader. Cover:
  - the layout and segments;
  - every field;
  - the event list with meanings;
  - the no-content rule;
  - that the phone never deletes remote copies.

  Add the pointer sentence to `docs/package-format.md`.
- [ ] **Step 8:** Commit `feat(log): content-free event log in its own folder, capture saved/deleted events`.

### Task 2: Instrument enrichment, sync, silver, gold and settings (§7.3)

**Files:**
- Modify: `HippoKit/Sources/Enrichment/EnrichmentRunner.swift`, `HippoKit/Sources/SyncEngine/SyncWorker.swift`, `HippoKit/Sources/SyncEngine/EnrichmentUploader.swift`, `HippoKit/Sources/SyncEngine/GoldPuller.swift`, `HippoKit/Sources/SyncEngine/HippoStore.swift` (factories pass `log`), `HippoKit/Sources/HippoPresentation/Settings/SyncCoordinator.swift`, `HippoKit/Sources/HippoPresentation/Settings/SettingsModel.swift`, `App/Hippo/Enrichment/EnrichmentScheduling.swift` (pass `env.store.log` to the runner)
- Test: `HippoKit/Tests/EnrichmentTests/EnrichmentRunnerTests.swift`, `HippoKit/Tests/SyncEngineTests/SyncWorkerTests.swift`, `EnrichmentUploaderTests.swift`, `GoldPullerTests.swift`, `HippoKit/Tests/HippoPresentationTests/SettingsTests.swift`

**Interfaces:**
- Consumes: `ActivityLog`, `LogEvent`, `LogEventName` (Task 1).
- Produces:
  - `EnrichmentRunner.init(…, log: ActivityLog? = nil)` (new trailing parameter).
  - `static let taskFinished = Notification.Name("HippoEnrichmentTaskFinished")`, posted on the main actor after every processed task (any outcome), object = runner.
  - `SyncWorker`, `EnrichmentUploader`, `GoldPuller` each take `log: ActivityLog?`; `HippoStore.make…` pass `store.log`.
  - `SyncCoordinator.syncNow(trigger: String = "manual")`: the `trigger` lands on the `sync.pass` events. The App's call sites are wired in Task 9.
- Event mapping (fields not listed are nil):
  - Runner `schedule`: per row made pending, `enrich.queued` (capture, kind). Then per kind with ≥1 queued, a global `enrich.scheduled` (kind, count).
  - Runner `process`:
    - before `e.run`: `enrich.started` (capture, kind, attempt = attemptCount + 1);
    - saved: `enrich.finished` (outcome ok/empty, `count` = items in the facet data if it has an `items` array, `ms`);
    - deferred: `enrich.deferred` (code, `retry_at`);
    - transient with attempts left: `enrich.retrying` (code, attempt);
    - `fail`: `enrich.failed` (code, attempt);
    - cancelled: nothing.
  - Runner `runPending`: global `enrich.pass` phase `start`, then `end` with `count` = ran, `code` = `idle` | `max_tasks` | `cancelled` | `nothing_due`.
  - `SyncWorker`: on `markSynced`, `package.uploaded` (capture, dest); on `markFailed`, `package.upload_failed` (capture, dest, code).
  - `EnrichmentUploader`: per capture uploaded, `silver.uploaded` (capture, dest); on failure, `silver.upload_failed` (capture, dest, code).
  - `GoldPuller`:
    - per applied document `gold.applied`; per deleted document `gold.removed`; per skipped document `gold.skipped` (code). All with the capture ID when the path maps to an indexed capture, else global.
    - At the end, global `gold.pull` (count = documents applied, code = result code or `ok`, `on` = true if a cursor reset happened this pull).
  - `SyncCoordinator.run`: global `sync.pass` phase `start` (trigger) and `end` (trigger, `count` = synced, `code` = `ok` | `failed` (when failed > 0) | `cancelled`).
  - `SettingsModel.setEnrichment` / `setLocationEnabled`: global `settings.changed` (kind = facet kind raw value or `location`, on).

- [ ] **Step 1: Write failing tests** (each reads `store.log`, or a temp-root `ActivityLog` passed in):
  - `EnrichmentRunnerTests.logsQueuedStartedFinished`: a fake enricher returning `.ok` with 2 items → the capture's events in order: `enrich.queued`, `enrich.started` (attempt 1), `enrich.finished` (ok, count 2, ms ≥ 0); global has `enrich.scheduled` (count 1) and an `enrich.pass` start/end pair.
  - `logsDeferredThenRetryingThenFailed`: deferring fake → `enrich.deferred` with `code` and `retry_at`. Transient fake run to `maxAttempts` → `enrich.retrying` ×4, then `enrich.failed`.
  - `postsTaskFinishedPerTask`: two tasks → two `taskFinished` notifications.
  - `notApplicableIsNotLogged`: an enricher that doesn't apply → no `enrich.queued`.
  - `SyncWorkerTests.logsPackageUploadedWithProviderKind`: `dest == "filesystem"`; a fault-injected failure logs `package.upload_failed` with the job's error code.
  - `EnrichmentUploaderTests.logsSilverUploaded`, and `GoldPullerTests.logsAppliedRemovedSkippedAndPull` (an oversize document → `gold.skipped` code; the end-of-pull `gold.pull`).
  - `SettingsTests.switchChangeIsLogged`: `setEnrichment(.transcript, on: false)` → `settings.changed` kind `transcript`, on false.
  - `noEventCarriesContent`: run the capture → enrich → sync → gold flow with a note containing `SECRET-NOTE-TEXT` and a link `https://example.com/private`. Assert no log file's bytes contain `SECRET`, `example.com` or the capture's relative directory.
- [ ] **Step 2:** Run `make test`. Expected: the new tests FAIL.
- [ ] **Step 3:** Implement the mapping. Every log call is fire-and-forget. Nothing in an existing control flow changes.
- [ ] **Step 4:** Run `make test`. Expected: all pass. Run the App build check. Expected: `** BUILD SUCCEEDED **`.
- [ ] **Step 5:** Commit `feat(log): instrument enrichment, uploads, gold pull, sync passes and settings`.

### Task 3: Upload logs to the destination (§7.4)

**Files:**
- Create: `HippoKit/Sources/SyncEngine/LogUploader.swift`
- Modify: `HippoKit/Sources/FilesystemAdapter/FilesystemAdapter.swift:145`, `HippoKit/Tests/AdapterContractTests/AdapterContract.swift`, `HippoKit/Sources/SyncEngine/StorageAdapter.swift` (doc comment on `replaceFile`), `HippoKit/Sources/SyncEngine/HippoStore.swift`, `HippoKit/Sources/HippoPresentation/Settings/SyncCoordinator.swift`, `HippoKit/Sources/HippoPresentation/Settings/AppSettings.swift`, `App/Shared/AppEnvironment.swift`
- Test: `HippoKit/Tests/SyncEngineTests/LogUploaderTests.swift`, `HippoKit/Tests/HippoPresentationTests/SettingsTests.swift`

**Interfaces:**
- Consumes: `ActivityLog.segmentFiles()`, `StoreLayout.logsDir` (Task 1).
- Produces:
  - `struct LogUploadResult: Sendable, Equatable { var uploaded: Int; var code: String? }` (nil code = ok or nothing to do).
  - `final class LogUploader: Sendable`:
    - `init(layout: StoreLayout, log: ActivityLog, destinations: DestinationStore, installID: String, adapterFor: @escaping @Sendable (Destination) throws -> any StorageAdapter, maxFilesPerPass: Int = 5)`
    - `func upload() async -> LogUploadResult`
    - `static func lastResult(layout: StoreLayout) -> (at: Date, code: String?)?`, read from `upload-state.json` (static, so the UI can read it without an uploader).
  - `logs/upload-state.json`: `{"files": {"<name>": <uploaded byte count>}, "last_at": "<RFC 3339>", "last_code": "<code>"|null}`.
  - `HippoStore.makeLogUploader(installID:adapterFor:) -> LogUploader`.
  - `AppSettings`:
    - `installID: String`, a lowercase UUID created on first read and stored under `install_id`;
    - `developerMode: Bool` (key `developer_mode`, default false);
    - `showsLayerStripes: Bool` (key `layer_stripes`, default true);
    - `lastSync: (at: Date, failed: Bool)?` (keys `last_sync_at`, `last_sync_failed`), with `recordSync(at:failed:)`.
  - `SyncCoordinator.init(…, settings: AppSettings)` (new parameter). After the gold pull, `runPass` calls `logUploader.upload()` and then `store.log.prune()`. `run` calls `settings.recordSync(at: now, failed: total.failed > 0)` when the chain ends un-cancelled.
- Upload rules:
  - No active destination, or not `.active` status → `code = "no_destination"`, nothing uploaded.
  - Candidates: segment files whose size ≠ the recorded size, oldest name first, at most `maxFilesPerPass`.
  - Per file: copy it to `staging/log-<uuid>.jsonl` while holding its `flock`, hash the copy, then `ensureContainer("logs/<installID>")` once per pass, then `replaceFile(copy, "logs/<installID>/<name>", expected)`, record the copy's size, and delete the copy.
  - `needsAuthentication` stops the pass; other errors skip the file and record `last_code`.
  - Uploads are not logged as events.

- [ ] **Step 1: Failing tests:**
  - `AdapterContract`: replace under `logs/abc/2026-11-08.jsonl` succeeds and the second content wins. Replace under `captures/…` is still refused with `replace_not_allowed`.
  - `LogUploaderTests.uploadsChangedFilesOnly`: two day files → first `upload()` uploads 2, second uploads 0; after one more append, the third uploads 1. Remote bytes equal local bytes.
  - `growingFileUploadsSnapshotThenRest`: a fault plan appends a line to the local file during `replaceFile` → the upload verifies (the remote equals the snapshot), and the next pass uploads again and the remote equals the full file.
  - `respectsMaxFilesPerPass`: 7 files, max 5 → 5, then 2.
  - `noDestinationKeepsLocal`: `code == "no_destination"`, nothing remote, state unchanged.
  - `segmentsUploadSeparately`: after `clear()`, `2026-11-08.1.jsonl` uploads beside the earlier `2026-11-08.jsonl`, which stays remote untouched.
  - `SettingsTests.installIDIsStable` (same value on two reads, a lowercase UUID) and `defaultsForNewSettings` (stripes true, developer mode false, `lastSync` nil).
  - `SyncCoordinator` (in `SettingsTests` or the existing coordinator tests): after `syncNow()`, `logs/<installID>/` exists in the dev remote and `settings.lastSync` is set.
- [ ] **Step 2:** Run `make test`. Expected: the new tests FAIL.
- [ ] **Step 3:** Implement. In `FilesystemAdapter.replaceFile`, allow the `enrichments/` or `logs/` prefixes. Update the `replaceFile` doc comment in `StorageAdapter.swift` to name both, and say that Plan 3's Dropbox `files/upload` overwrite must allow both. `AppEnvironment` passes `AppSettings(defaults: UserDefaults(suiteName: appGroupID)!)` (the same suite the app already uses), plus `process: .share` for the extension's `HippoStore.open`.
- [ ] **Step 4:** Run `make test`. Expected: all pass. Run the App build check. Expected: `** BUILD SUCCEEDED **`.
- [ ] **Step 5:** Commit `feat(sync): upload log files to logs/<install-id>/ after each sync pass`.

### Task 4: Relative dates resolve against the capture (§9)

**Files:**
- Modify: `HippoKit/Sources/Enrichment/DataDetectionEnricher.swift`
- Test: `HippoKit/Tests/EnrichmentTests/DataDetectionEnricherTests.swift`

**Interfaces:**
- Produces:
  - `DataDetectionEnricher.version` = 3.
  - `static func detect(in text: String, source: String, ignoresClockLine: Bool = false, anchor: DateAnchor?) -> [Detection]`. There is no injectable clock: `NSDataDetector` always resolves against the real now, so the run day `R` is the real today too, and tests build captures relative to it.
  - `struct DateAnchor: Sendable { var day: DateComponents /* y-m-d of the capture in its zone */ }`, built in `run` from `metadata.localDatetime` and `timezoneIdentifier` (falling back to `utcOffsetSeconds`).
- Algorithm. `NSDataDetector` resolves against the real now, in the system zone. For each date match, take the wall-clock components it produced (in `.current`) and the run day `R` (today in `.current`, from `now`). Then classify the matched text, case-insensitive:
  - **Full:** a 4-digit year, or a numeric date with a year part (`11/12/26`). Leave it unchanged.
  - **Month-day, no year** (a month name, or numeric `d/m` / `m/d`, with a day number). Keep month, day and time. Pick the year so the date is the first occurrence on or after the anchor day.
  - **Weekday name** (with or without "next"): keep the time. The result is the first such weekday on or after the anchor day. Let `k` = the days from `R` to the detected day; if `k` ≥ 7 ("next Friday"), add 7 days.
  - **Anything else** (today, tonight, tomorrow, "in 3 days", bare times with AM/PM): keep the time and shift the day by (anchor day − `R`) in whole calendar days.
  - With no anchor, or anchor day == `R`, return the detector's value unchanged.

  The output format is unchanged: wall-clock `yyyy-MM-dd'T'HH:mm:ss`, or RFC 3339 when the detector reported a zone.

- [ ] **Step 1: Write failing tests.** Captures are built relative to the real now, so `NSDataDetector`'s own "now" agrees. `cap` = a capture at 12:00 local, 6 days before today, in `.current`. Assert on the `value`'s date part:
  - `tomorrowResolvesAgainstCapture`: "tomorrow at 3pm" → cap + 1 day, 15:00.
  - `tonightResolvesAgainstCapture`: "tonight at 7pm" → cap day, 19:00.
  - `weekdayResolvesAgainstCapture`: "Friday" → the first Friday on or after cap's day.
  - `monthDayWithoutYearUsesCaptureYear`: call `detect` directly with `anchor` = 30 December of last year; "Jan 3" → 3 January of this year (anchor year + 1), whatever today is.
  - `fullDateUnchanged`: "12 Nov 2027" → 2027-11-12.
  - `sameDayUnchanged`: the capture is today → value equals `NSDataDetector`'s.
  - `tomorrowNearMidnightUsesCaptureZone`: run through the enricher, with metadata whose `local_datetime` is 23:30 `-08:00` in `America/Los_Angeles` on a day 3 days ago. "tomorrow at 9am" → the capture's LA date + 1, 09:00. On a Mac in UTC this fails if the anchor uses the UTC date.
  - `bareAtTwoStillNotDetected`: "at 2" → no date detection.
  - `versionIsThree`.
- [ ] **Step 2:** Run `swift test --package-path HippoKit --filter DataDetectionEnricherTests`. Expected: the new tests FAIL.
- [ ] **Step 3:** Implement per the algorithm.
- [ ] **Step 4:** Run the filter, then `make test`. Expected: PASS.
- [ ] **Step 5:** Commit `fix(enrichment): relative dates resolve against the capture's day (data detection v3)`.

### Task 5: Layer per element on Detail (§4)

**Files:**
- Create: `HippoKit/Sources/HippoPresentation/Detail/Layer.swift`
- Modify: `HippoKit/Sources/HippoPresentation/Enrichment/ResolvedEnrichment.swift`, `HippoKit/Sources/HippoPresentation/Detail/DetailRow.swift`, `HippoKit/Sources/HippoPresentation/Detail/CaptureDetail.swift`
- Test: `HippoKit/Tests/HippoPresentationTests/ResolvedEnrichmentTests.swift`, `DetailTests.swift`

**Interfaces:**
- Produces:
  - `enum Layer: String, Sendable { case bronze, silver, gold, sync }`.
  - `ResolvedEnrichment.fromServer: ServerOrigin`, with `struct ServerOrigin: Equatable, Sendable { var places: Set<String>; var transcripts: Set<String>; var recognizedText: Set<String>; var detections: Bool; var sourceApp: Bool; var summary: Bool; var tags: Bool }`, filled where `make` already picks gold. `usesServer` stays.
  - `DetailRow.layer: Layer` (init default `.bronze`); `TitledText.layer: Layer` (default `.silver`).
  - `CaptureDetail` gains `foundLayer: Layer`, `summaryLayer: Layer` and `tagsLayer: Layer`, and loses `fromServerNote`. A link card's layer = `ResolvedLink.fromServer ? .gold : .silver`, computed in the view from the existing field.
- Mapping: §4 "Which layer each element gets". Source, Where (place line) and Taken in use silver or gold from `ServerOrigin`. Coordinates, When and How are bronze.

- [ ] **Step 1: Write failing tests:**
  - `ResolvedEnrichmentTests.serverOriginPerItem`: gold transcript for attachment A only → `fromServer.transcripts == [A]`. Gold place for `capture` → `places == ["capture"]`. An empty gold summary → `summary == false`.
  - `DetailTests.layersPerRow`:
    - a link share with a silver source-app guess and a gold place → When/How/Coordinates `.bronze`, Source `.silver`, Where `.gold`;
    - transcript items: `.gold` for A, `.silver` for B;
    - `foundLayer` `.silver` without gold detections, `.gold` with them;
    - `summaryLayer` `.gold`.
  - `DetailTests.noFromServerNote`: the property is gone. Delete or adapt existing assertions on it.
- [ ] **Step 2:** Run `swift test --package-path HippoKit --filter "ResolvedEnrichmentTests|DetailTests"`. Expected: FAIL.
- [ ] **Step 3:** Implement. Remove the `fromServerNote` footnote use from `App/Hippo/Detail/CaptureDetailView.swift`, so the App still builds; Task 8 adds the stripes.
- [ ] **Step 4:** Run `make test` and the App build check. Expected: pass, `** BUILD SUCCEEDED **`.
- [ ] **Step 5:** Commit `feat(presentation): layer per detail element for stripes`.

### Task 6: Progress, pending lines, Status and the Settings summary (§5, §6)

**Files:**
- Create: `HippoKit/Sources/HippoPresentation/Enrichment/EnrichmentProgress.swift`, `HippoKit/Sources/HippoPresentation/Detail/StatusLine.swift`
- Modify: `HippoKit/Sources/LocalRepository/Enrichment/EnrichmentTaskStore.swift`, `HippoKit/Sources/HippoPresentation/Detail/CaptureDetail.swift`, `CaptureDetailModel.swift`, `HippoKit/Sources/HippoPresentation/Timeline/TimelineRow.swift`, `TimelineModel.swift`, `HippoKit/Sources/HippoPresentation/Settings/SettingsModel.swift`
- Test: `HippoKit/Tests/LocalRepositoryTests/EnrichmentTaskStoreTests.swift`, `HippoKit/Tests/HippoPresentationTests/ProgressTests.swift` (new), `DetailTests.swift`, `TimelineTests.swift`, `SettingsTests.swift`

**Interfaces:**
- Consumes: `Layer` (Task 5), `AppSettings.lastSync` (Task 3).
- Produces:
  - `EnrichmentTaskStore.tasks(captureIDs: [String]) -> [EnrichmentTask]` (one `IN` query) and `unfinished() -> [EnrichmentTask]` (status `pending` or `failed`).
  - `enum StepState: Equatable, Sendable { case working, waiting(code: String?), waitingForInput(FacetKind), done, nothingFound, failed(code: String?), off }`.
  - `enum RowProgress: Equatable, Sendable { case none, working, waiting }`.
  - `enum EnrichmentProgress`:
    - `static let networkKinds: Set<FacetKind> = [.linkPreview, .place]`
    - `static func steps(_ tasks: [EnrichmentTask], isEnabled: (FacetKind) -> Bool, isOnline: Bool, now: Date) -> [FacetKind: StepState]`
    - `static func row(_ steps: [FacetKind: StepState]) -> RowProgress`
  - Step rules:
    - `not_applicable` → absent.
    - `ok` → done; `empty` → nothingFound; `failed` → failed(code).
    - `pending` and the kind is switched off → off.
    - `pending` with `next_attempt_at` in the future → waiting(code). A network kind that is pending while offline → waiting(`offline`). Otherwise → working.
    - Data detection done or nothingFound while transcript or text recognition is working or waiting → waitingForInput(that kind).
  - Row rules: any working (counting waitingForInput whose input is working) → working; otherwise any waiting/waitingForInput → waiting; otherwise none.
  - `struct PendingLine: Equatable, Sendable { var text: String; var working: Bool }` and `static func pendingLine(_ kind: FacetKind, _ state: StepState) -> PendingLine?`. Copy is exactly §5.2's table. Code → waiting text:
    - `offline` → "waiting for a connection";
    - `throttled` → "Apple Maps is busy, will retry" (place only);
    - `model_missing` → "waiting for the speech model to download";
    - transient or unknown → "<Kind>: couldn't finish yet. Hippo will retry.";
    - waitingForInput → "Dates, phone numbers and addresses: will check again after the transcript" / "… after the image text".
  - `struct StatusLine: Equatable, Sendable { var layer: Layer; var text: String; var state: StatusState }`, with `enum StatusState { case done, working, waiting, failed }`. `static func lines(saved: Date, steps: [FacetKind: StepState], goldKinds: Set<FacetKind>, goldArrivedAt: Date?, locale: Locale, zone: TimeZone) -> [StatusLine]`:
    - first "Saved on this iPhone · <time>" (bronze, done);
    - then one line per step in the order link preview, place, transcript, text in image, data detection, app guess, using the kind names and wording in §6.1. A failed line's reason comes from: `http_4xx`/`http_5xx` → "the page didn't respond", `too_large` → "the file is too large", `bad_url` → "the link isn't valid"; anything else has no reason;
    - the layer is gold when the kind is in `goldKinds`, else silver;
    - last "From your server · <time>" (gold, done) only when `goldArrivedAt` is non-nil.
    - Sync rows stay `CaptureDetail.sync: [SyncRow]` (the view renders them in Status with the sync layer).
  - `CaptureDetail` gains `status: [StatusLine]` and `pending: [FacetKind: PendingLine]`. `CaptureDetail.make` gains `tasks: [EnrichmentTask]`, `isEnabled`, `isOnline` and `goldArrivedAt: Date?` (the server document's `generatedAt`).
  - `CaptureDetailModel.init` gains `isEnabled: @escaping @Sendable (FacetKind) -> Bool` and `isOnline: @escaping @Sendable () -> Bool`.
  - `TimelineRow.progress: RowProgress`. `TimelineModel` loads `tasks(captureIDs:)` once per page and gains the same two closures.
  - `SettingsModel.statusSummary: String?`, built from `settings.lastSync` and `unfinished()` grouped by capture:
    - "Last sync <relative> · N being processed · N waiting for a connection · N couldn't be processed";
    - zero counts are omitted; "Last sync never" before the first sync;
    - a failed last sync reads "Last sync <relative> didn't finish";
    - relative time uses `RelativeDateTimeFormatter` (`.named`).

- [ ] **Step 1: Write failing tests** in `ProgressTests` (fixed `now`):
  - `pendingDueIsWorking`, `pendingFutureIsWaitingWithCode`, `offlineNetworkKindIsWaiting` (link preview pending, no retry time, offline → `.waiting(code: "offline")`; the same row online → working; on-device text recognition offline → working), `switchedOffIsOff`, `notApplicableAbsent`.
  - `dataDetectionWaitsForTranscript`: data detection `empty` + transcript pending (model_missing) → `.waitingForInput(.transcript)`, and the row is `.waiting`.
  - `rowProgressPrecedence`: working + waiting → working; waiting only → waiting; all done → none.
  - `pendingLineCopy`: every row of §5.2's table, plus an unknown code → the generic line.
  - `statusLinesForTypedNoteNothingFound`: data detection `empty` → "Dates, phone numbers and addresses: nothing found". There is no gold line when `goldArrivedAt` is nil.
  - `statusFailedReason`: link preview failed `http_4xx` → "Link preview: couldn't fetch the page — the page didn't respond" (the verb per kind is the implementer's, but the reason text is exact).
  - `statusIgnoresLog`: write garbage into `logs/` and delete it; `CaptureDetailModel.load()` produces identical `status` both times.
  - `EnrichmentTaskStoreTests.tasksForCaptureIDsAndUnfinished`.
  - `TimelineTests.rowProgressFromTasks`: one capture pending-due → `.working`; one deferred → `.waiting`.
  - `SettingsTests.statusSummaryCounts`: 2 working, 1 offline-waiting, 1 failed, last sync 2 min ago → "Last sync 2 minutes ago · 2 being processed · 1 waiting for a connection · 1 couldn't be processed" (match the formatter's exact output in the test locale `en_US`).
- [ ] **Step 2:** Run `make test`. Expected: the new tests FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `make test`. Expected: all pass.
- [ ] **Step 5:** Commit `feat(presentation): enrichment progress, pending lines, detail status and settings summary`.

### Task 7: Log view models (§8.2, §8.3)

**Files:**
- Create: `HippoKit/Sources/HippoPresentation/Log/LogLine.swift`, `HippoKit/Sources/HippoPresentation/Log/ActivityModel.swift`, `HippoKit/Sources/HippoPresentation/Log/GlobalLogModel.swift`
- Test: `HippoKit/Tests/HippoPresentationTests/LogLineTests.swift`

**Interfaces:**
- Consumes: `ActivityLog`, `LogEvent` (Task 1), `Layer` (Task 5).
- Produces:
  - `struct LogLine: Equatable, Sendable, Identifiable { var id: Int; var time: String /* local, HH:mm:ss, plus "MMM d" when not today */; var layer: Layer; var text: String }`.
  - `static func make(_ e: LogEvent, id: Int, now: Date, zone: TimeZone, locale: Locale) -> LogLine`.
  - Layer: `capture.*` bronze; `enrich.*` silver; `gold.*` gold; `package.*`, `silver.*`, `sync.*`, `bg.task` sync; the rest bronze.
  - Text examples, which the tests pin:
    - `enrich.finished` empty transcript, 2100 ms → "Transcript · nothing found · 2.1 s";
    - `enrich.deferred` link preview offline, `retry_at` 14:32 → "Link preview · waiting: offline · retry 14:32";
    - `package.uploaded` dest `dropbox` → "Uploaded to Dropbox", dest `filesystem` → "Uploaded to the Developer folder";
    - `capture.saved` proc share → "Saved from the share sheet";
    - `sync.pass` end → "Sync finished (activation) · 3 uploaded".
    - An unknown combination falls back to "<event> · <outcome> · <code>".
  - `@MainActor @Observable final class ActivityModel`:
    - `init(store: HippoStore, captureID: String, capturedAt: Date)`;
    - `lines: [LogLine]` (oldest first);
    - `mayBePruned: Bool` (true when `capturedAt` is more than 30 days ago);
    - `func load() async`;
    - `func copyText(appVersion: String) -> String`: header "Hippo activity · capture <id> · app <version>", then "time  text" lines.
  - `@MainActor @Observable final class GlobalLogModel`:
    - `init(store: HippoStore, pageSize: Int = 500)`;
    - `lines` (newest first), `canLoadMore`;
    - `load()`, `loadMore()`, `clear()` (calls `store.log.clear()`, then reloads);
    - `copyText(appVersion:)` with the header "Hippo log · app <version>";
    - `lastUpload: String?`, from `LogUploader.lastResult(layout: store.layout)`: "Last log upload 14:02" or "Last log upload failed: no_destination"; nil before the first attempt.

- [ ] **Step 1: Write failing tests** in `LogLineTests`:
  - each pinned text above;
  - layer per event family;
  - `activityModelOldestFirstAndCopy` (the header line and line count);
  - `globalModelPagesAndClear`;
  - `readerSkipsGarbageLines` (a garbage line in a day file → lines from the valid ones only, no crash);
  - `mayBePrunedAfter30Days`.
- [ ] **Step 2:** Run `swift test --package-path HippoKit --filter LogLineTests`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `make test`. Expected: PASS.
- [ ] **Step 5:** Commit `feat(presentation): activity and global log view models with copy`.

### Task 8: App — stripes, pending lines, Status, timeline progress, Settings summary (§4–§6)

**Files:**
- Create: `App/Hippo/Detail/LayerStripe.swift`, `App/Hippo/Detail/StatusSection.swift`
- Modify: `App/Hippo/Detail/CaptureDetailView.swift`, `App/Hippo/Detail/EnrichmentSections.swift`, `App/Hippo/Timeline/TimelineRowView.swift`, `App/Hippo/Timeline/TimelineView.swift`, `App/Hippo/Settings/SettingsView.swift`, `App/Hippo/Enrichment/EnrichmentScheduling.swift` (expose the shared connectivity monitor as `EnrichmentScheduling.isOnline`), the view-model construction sites (pass `isEnabled` / `isOnline`), the asset catalog (four colour sets with light and dark variants, values from Global Constraints)

**Interfaces:**
- Consumes: Tasks 5 and 6 outputs, `AppSettings.showsLayerStripes`.
- Produces:
  - `extension View { func layerStripe(_ layer: Layer, shown: Bool) -> some View }`: a 3 pt full-height bar inset at the cell's leading edge (overlay plus leading padding), hidden when `shown` is false. It is decorative, so `accessibilityHidden`.
  - **Detail:**
    - every row and section per Task 5's layers;
    - pending lines (`ProgressView` plus text when `working`; secondary text when waiting) in the spots §5.2 names, shown only while the result is absent;
    - a "Status" section after the existing sections: `StatusLine`s with their stripes, then the sync rows (sync layer) with Retry as today. The old "Sync" section is removed.
  - **TimelineRowView:** `ProgressView().controlSize(.mini)` for `.working`, `Image(systemName: "clock")` (secondary, caption) for `.waiting`, beside `SyncBadge`. Accessibility label gains ", processing" / ", waiting".
  - **TimelineView** and an open Detail reload on `EnrichmentRunner.taskFinished` (as `Notification.Name("HippoEnrichmentTaskFinished")`; the App target links `Enrichment`) and on the existing notifications. The timeline debounces reloads by 500 ms.
  - **SettingsView:**
    - `statusSummary` as a footer line in the Sync section;
    - the "Show where details came from" toggle and the footer copy from Global Constraints in the Enrichment section;
    - toggling it logs `settings.changed` (kind `layer_stripes`) through a `SettingsModel.setShowsLayerStripes(_:)`. Add that method plus a test in `SettingsTests`, in this task.

- [ ] **Step 1:** Implement the views and the `SettingsModel.setShowsLayerStripes` test plus code.
- [ ] **Step 2:** Run `make test` (PASS) and the App build check (`** BUILD SUCCEEDED **`). If a simulator is available, run `make uitest`, and update `CaptureFlowUITests` if it asserted on the removed "Sync" section header. Otherwise record "uitest not run: no simulator".
- [ ] **Step 3:** Commit `feat(app): layer stripes, pending lines, status section, timeline progress, settings summary`.

### Task 9: App — Developer mode, Activity, global log, launch and BG events (§8)

**Files:**
- Create: `App/Hippo/Settings/DeveloperSection.swift`, `App/Hippo/Detail/ActivityView.swift`, `App/Hippo/Settings/GlobalLogView.swift`
- Modify: `App/Hippo/Settings/SettingsView.swift`, `App/Hippo/Detail/CaptureDetailView.swift`, `App/Hippo/HippoApp.swift`, `App/Hippo/Settings/SyncScheduling.swift`, `HippoKit/Sources/HippoPresentation/Settings/SettingsModel.swift` (`developerMode` get/set, logging `settings.changed` kind `developer_mode`)
- Test: `HippoKit/Tests/HippoPresentationTests/SettingsTests.swift` (`developerModeToggleIsLogged`)

**Interfaces:**
- Consumes: Task 7 models, `AppSettings.developerMode`.
- Produces:
  - **Settings:**
    - a "Developer" section, last, in all builds, with the "Developer mode" switch;
    - when on, it also shows "Log" (a NavigationLink to `GlobalLogView`), "Clear log" (destructive, confirmation "Delete this iPhone's log? Copies already uploaded are kept."), and the `lastUpload` line;
    - the DEBUG-only Developer-folder rows stay where they are.
  - **Detail:** when Developer mode is on, a final "Activity" NavigationLink row to `ActivityView`.
  - **ActivityView / GlobalLogView:**
    - a `List` of lines (time monospaced digits, a 6 pt stripe dot, text);
    - a toolbar "Copy" button that writes `copyText(appVersion:)` to `UIPasteboard.general.string` and briefly shows "Copied";
    - an empty state "Nothing logged yet";
    - Activity shows a footer "Earlier events may have been removed (Hippo keeps 30 days)." when `mayBePruned`;
    - GlobalLogView has "Load more" when `canLoadMore`.
  - **Events:**
    - `HippoApp` logs global `app.launch` (code = `<version>-<build>` sanitized) once per launch, after the store opens, and calls `store.log.prune()` after launch recovery;
    - `SyncScheduling.handle` logs `bg.task` phase `start`, `expired` (in the expiration handler) and `end` (`on` = success);
    - every `SyncScheduling.runPass` call site passes a `trigger` to `syncNow(trigger:)`: `activation`, `bg`, `launch`, `enrichment`, `after_save`, `manual`.

- [ ] **Step 1:** Write the failing `developerModeToggleIsLogged` test, then implement the `SettingsModel` part. Run `make test`. Expected: PASS.
- [ ] **Step 2:** Implement the views and events.
- [ ] **Step 3:** Run `make test` (PASS) and the App build check (`** BUILD SUCCEEDED **`). Run `make uitest` if a simulator is available, else record it.
- [ ] **Step 4:** Commit `feat(app): developer mode with per-capture activity and global log`.

### Task 10: Acceptance rows, README, memory pointers (§11)

**Files:**
- Modify: `docs/acceptance.md`, `README.md`, `docs/superpowers/plans/2026-11-07-hippo-enrichment.md` (tick "Relative dates" in the open follow-ups, pointing to this plan)

- [ ] **Step 1:** Append rows V1–V8 to `docs/acceptance.md`, copied from design §11 with Result "not run". Add to E15's row: "Also record whether link previews downloaded video bytes on cellular."
- [ ] **Step 2:** README: a "Seeing what enrichment did" section covering:
  - stripes and their setting;
  - spinner vs clock;
  - the Status section;
  - Developer mode, Activity, the log;
  - `logs/` on the phone and `logs/<install-id>/` in the destination, with no content;
  - Copy for pasting into a Claude session.

  Also add one line under the Dropbox/Plan 3 notes: `replaceFile` must allow `logs/` as well as `enrichments/`.
- [ ] **Step 3:** Run `make test` and `scripts/validate-fixtures.sh`. Both pass.
- [ ] **Step 4:** Commit `docs: visibility acceptance rows V1–V8, README section`.

---

## After the build (not subagent tasks)
- Whole-branch final review (fresh reviewer, most capable model).
- **Device test with Jorge:** `make device` on a **DEBUG** build (V7 needs the Developer folder). Run E1–E15 and V1–V8 and record results in `docs/acceptance.md`.
- Update the `hippo-core-parked-followups` memory (Plan 3: `replaceFile` must allow `logs/`) and the visibility memory.
- PR to `main`.
