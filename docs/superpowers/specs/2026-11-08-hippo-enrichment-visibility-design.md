# Hippo Enrichment Visibility — Design (layer stripes, progress, status, logs)

Status 2026-11-08: design, awaiting Jorge's approval. Branch `feat/enrichment-visibility`.
Supersedes the handoff notes in `2026-11-08-hippo-enrichment-visibility-brainstorm.md` (kept for history).
Decisions are Jorge's unless marked *(my call)*. Builds on `2026-11-07-hippo-enrichment-design.md`
("the enrichment design") and `2026-11-07-hippo-v0-design.md`.

## 1. Intent and why

On the first device test of the enrichment phase (PR #4), Jorge believed transcripts, link previews,
calendar dates and screenshot text "weren't working". The store, pulled off the phone, showed every enricher
had run and its results were stored. Most "failures" were results nobody could see, or captures with
nothing to find. Nothing in the app says **what was added, by which layer, or whether work is still
pending**, so "not done yet", "nothing to find" and "broken" look the same.

This batch makes enrichment visible on two levels:
- **For everyone (always on):** where each detail came from (layer stripes), what is still being worked on
  (spinners and pending lines), and a plain status of every step for a capture and for the app as a whole.
  This answers "where is this now?".
- **For diagnosing (Developer mode):** a history of everything that happened, per capture and globally, with
  times and reasons, copyable into a Claude session and uploaded to the destination for reading on the
  desktop. This answers "what happened, step by step?".

Success: on the next device test Jorge can tell, from the phone alone, for any capture, whether each
enrichment is done, found nothing, is waiting (and for what), or failed (and why), and can hand a log to a
Claude session without pulling the store off the phone.

## 2. Goals, non-goals, anti-goals

**Goals**
1. Layer stripes on Detail (§4).
2. Progress indicators on timeline rows and in Detail (§5).
3. A Status section in every Detail and a status summary in Settings, always on (§6).
4. One event log, recorded always, stored in its own folder on the phone and uploaded to the destination (§7).
5. Developer mode (release builds too) showing a per-capture Activity log and a global log (§8).
6. Two enrichment follow-ups folded in: relative dates resolve against the capture (§9), and device
   acceptance E1–E15 is run in this batch's device test (§11).

**Non-goals (this batch)**
- Stripes on timeline rows. Detail only *(my call)*.
- A user-facing Retry for enrichment (unchanged from the enrichment design §10). Status explains; it doesn't act.
- Any log viewer on the desktop beyond the uploaded files themselves; searching or filtering the log in the app.
- Deleting uploaded logs from the destination. The phone never deletes remote log files.
- The other enrichment follow-ups: stale gold after a cursor reset, LinkPresentation video bytes (observed in
  E15 only), Dropbox `replaceFile`/`listChanges`/`downloadFile` (Plan 3), bare times like "at 2", and the
  smaller deferred items (double launch pass, `networkConnectionLost`, tel: "+"). Jorge, 2026-11-08: leave.

**Anti-goals (failure even if it technically works)**
- **The UI reads the log to decide what to show.** Stripes, spinners, pending lines and Status come from real
  state (enrichment tasks, enrichment documents, upload jobs). The log is history only. A missing, pruned or
  corrupt log must never make the UI wrong. (Jorge, 2026-11-08.)
- **The log holds content.** Never transcript, note, shared text, OCR text, titles, URLs, hostnames, file
  names, place names or coordinates. Only times, kinds, capture IDs, outcomes, reason codes and counts.
- **Logging slows or breaks capture.** "✓ Saved on this iPhone" is never delayed by logging, and a logging
  failure never fails a save, an enrichment or a sync.
- **Rows that spin forever.** A capture waiting hours for a connection must not look busy (§5.1).

## 3. Changes to earlier specs (call-outs)

- **Adapter contract:** `replaceFile` today rejects any path not under `enrichments/`. It now also allows
  `logs/` (§7.4). The contract tests and the Plan 3 Dropbox note change with it.
- **Destination layout:** a new top-level `logs/` folder beside `captures/` and `enrichments/`. Readers of
  packages and enrichments ignore it. Documented in a new `docs/log-format.md`; `docs/package-format.md`
  gets one sentence pointing there.
- **Detail:** the "Sync" section becomes part of the new Status section (§6.1), keeping its rows, messages and
  Retry. The `fromServerNote` footnote ("Some details come from your server.") is replaced by the gold stripe
  and the Status line for server results.
- **Data detection:** version 2 → 3 (§9), so existing results are recomputed.

## 4. Layer stripes (Detail)

A coloured bar down the left edge of each Detail row or section, by where its content came from
(Jorge: option C in the mockup, no legend row):

| Layer | Meaning | Light | Dark *(my call)* |
|---|---|---|---|
| Bronze | captured (the package) | `#b0763c` | `#c98a4b` |
| Silver | added on this iPhone | `#a2a9b0` | `#b8bfc6` |
| Gold | added by the server | `#d4ab2a` | `#e0b83a` |
| Sync *(Status and Activity only)* | upload and sync | `#5ac8fa` | `#64d2ff` |

- About 3 pt wide, full row height, inset inside the grouped-list cell's leading edge. Builder tunes width and
  exact values as asset-catalog colours with light/dark variants. The stripe is decorative: every fact it
  marks is also stated in words in Status, so it is never the only signal.
- **Setting:** Settings › Enrichment › "Show where details came from", **on by default** (Jorge). Footer:
  "Bronze: what you captured. Silver: added on this iPhone. Gold: added by your server." *(my call: the
  Settings footer is the only explanation, so Detail stays legend-free.)* Stored in App Group defaults beside
  the enrichment switches. Off hides every stripe; nothing else changes.
- **Which layer each element gets** *(my call)*. Resolution is still gold over silver over bronze per item and
  per field (enrichment design §6.1); the stripe shows the winning layer:
  - Bronze: preview, Your comment, Shared title, Shared text, Links, Captured › When / How / Coordinates,
    every attachment row except "Taken in".
  - Silver or gold, by which layer supplied it: Captured › Source ("Probably from …"), Captured › Where
    (place line), attachment › Taken in, each link card, each Transcript item, each Text in image item,
    Found in this capture (one layer for the list, since gold replaces the list whole), Summary, Tags.
  - **Mixed item:** a link card or place whose shown fields come from both layers is **gold** if any shown
    field is gold *(my call)*.
  - Pending lines (§5.2) are silver. Status lines carry their own layer (§6.1).
- `ResolvedEnrichment` gains per-item "came from gold" for places, transcripts, recognized text, detections,
  source-app guess, summary and tags (links already have `fromServer`). `CaptureDetail` carries a layer per
  row/item so the stripe mapping is unit-tested in HippoKit, not decided in SwiftUI.

## 5. Progress indicators (always on, not a setting)

Source of truth: the `enrichment_tasks` rows for the capture (status, `next_attempt_at`, `last_error_code`)
plus whether a pass is processing that task right now. Never the log.

**Two states the task rows don't show** *(my call, after the builder check)*. The presentation layer works
them out; `EnrichmentRunner`'s offline handling is unchanged:
- **Offline.** While offline the runner just skips network kinds, so their rows stay `pending` with no retry
  time or code. The app's connectivity state (the same signal the runner uses) is passed into the
  presentation derivation. A pending network kind (link preview, place) while offline is **waiting: offline**,
  not working.
- **Waiting for inputs.** Data detection runs at once and reruns when OCR or a transcript lands. If its row is
  done but an input kind (transcript, text in image) for the same capture is still pending, Status and the
  pending line show "Dates, phone numbers and addresses: will check again after the transcript" (or "after
  the image text") rather than "nothing found". The row counts as waiting or working by that input's state.

### 5.1 Timeline rows
- **Working:** a small spinner beside the sync dot while any of the capture's enrichment tasks is `pending`
  and due now (no `next_attempt_at`, or it has passed) or currently running.
- **Waiting:** when every pending task is deferred (offline, throttled, model not installed) or backing off
  after a transient error, a small static `clock` glyph instead of the spinner *(my call: a row waiting hours
  for a connection must not spin)*.
- **Done:** nothing. `ok`, `empty`, `failed` and `not_applicable` are all "done" here; Detail says which.
- A kind switched off in Settings doesn't count as pending for the row.
- Upload state stays the existing sync dot; the spinner is enrichment only.
- Cost: one grouped query per timeline page (`capture_id → working | waiting`), not per-row reads.

### 5.2 Detail pending lines
Where a result will appear and isn't there yet, Detail shows a pending line in that spot with a spinner
(working) or the waiting reason (waiting). Wording *(my call)*:

| Kind | Working | Waiting |
|---|---|---|
| link_preview | "Fetching link preview…" | "Link preview: waiting for a connection" |
| place | "Looking up the place…" | "Place: waiting for a connection" / "…Apple Maps is busy, will retry" |
| transcript | "Transcribing…" | "Transcript: waiting for the speech model to download" |
| text_recognition | "Reading text in the image…" | — (on-device, never deferred) |
| data_detection | "Looking for dates, phone numbers and addresses…" | "…will check again after the transcript / image text" (§5 above) |
| source_app_guess | (too fast to show; no pending line) | — |

Generic waiting after a transient error: "<Kind>: couldn't finish yet. Hippo will retry." Placement: link
previews in the link-card spot, place on the Where row, transcript and image text in their sections, found
items in "Found in this capture". Exact codes → wording table is the builder's, from the codes the enrichers
actually throw (`offline`, `throttled`, `model_missing`, …); an unknown code gets the generic line.

### 5.3 Live updates
Timeline and an open Detail refresh when a task finishes or changes state (the runner already signals
enrichment changes; extend it to per-task state changes if it doesn't). No polling.

## 6. Status (always on)

### 6.1 Detail › Status
A section near the bottom of every Detail (above the Activity entry, §8.2), one plain line per step that
applies to this capture, each with its stripe:

- Bronze: "Saved on this iPhone" ✓ with the save time.
- Silver/gold, one line per enrichment kind that has a task row other than `not_applicable`:
  - `ok` → "<Kind>: done" (gold stripe if the gold facet supplied the shown result).
  - `empty` → "<Kind>: nothing found".
  - pending → the working or waiting line from §5.2, with spinner.
  - `failed` → "<Kind>: couldn't <verb>" plus a plain reason when the code maps to one ("the page didn't
    respond", "the file is too large"), otherwise no reason.
  - Switched off in Settings and not done → "<Kind>: off in Settings".
  - Kind names: Link preview, Place, Transcript, Text in image, Dates, phone numbers and addresses, App guess.
- Sync (blue): the existing per-destination rows (Uploaded to Dropbox ✓ / Waiting to upload / Uploading… /
  the existing failure messages) with Retry where it is today.
- Gold: "From your server" ✓ with the arrival time, **only when a gold document exists** *(my call: there is no
  server yet, so "none yet" on every capture would be noise)*.

The derivation lives in HippoPresentation as a pure function of (metadata, task rows, documents, jobs,
switches), unit-tested.

### 6.2 Settings › Sync summary
Under the Sync section, one or two quiet lines, for example:
"Last sync 2 min ago · 3 captures being processed · 1 waiting for a connection".
- Last sync: end time of the last sync pass, persisted in the store (not the log). "Never" before the first.
  If the last pass failed, say so in its existing plain words.
- Being processed: distinct captures with a working task (§5.1). Waiting: distinct captures whose pending
  tasks are all waiting. Optionally "N couldn't be processed" for captures with a `failed` task *(my call:
  include it; it is the only place a failure shows without opening each capture)*. Zero counts are omitted.

## 7. The event log (recorded always)

One log, recorded **always**, whether or not Developer mode is on, and uploaded always. Developer mode only
shows or hides the screens (Jorge, 2026-11-08). Events about a capture carry its ID; those appear in that
capture's Activity. Events without a capture ID appear in the global log.

### 7.1 Storage on the phone
- Folder: `Library/Application Support/Hippo/logs/` in the App Group container, beside `hippo.sqlite`,
  `captures/` and `enrichments/`, and never inside them (Jorge: "stored somewhere in the phone along with the
  rest of the metadata, but clearly separable"). It can be cleared, copied or exported without touching
  captures. `StoreLayout` gains `logsDir`.
- **Format** *(my call)*: JSON Lines, one file per UTC day, `logs/YYYY-MM-DD.jsonl`, so the same file uploads
  as-is and opens in any editor. Times inside are RFC 3339 UTC with milliseconds; the app shows local time.
- Log bookkeeping (what was uploaded, §7.4) lives in `logs/` too (for example `logs/upload-state.json`), not
  in `hippo.sqlite`.
- **Writers:** the app and the share extension both append. Each event is one line written with a single
  append under an advisory file lock (`flock`) on the day file, so the two processes never interleave lines.
  A torn or unparseable line is skipped by readers.
- **Never in the way:** writes are tiny and synchronous enough that the extension's "saved" event lands before
  it exits, but any logging error is swallowed (and counted in `diagnostics.json` as `log_write_failures`).
  The save path never waits on the log lock for more than a short bound (builder picks, ~100 ms); on timeout
  the event is dropped.

### 7.2 Retention
*(my calls)*
- Keep the last **30 days** of files; older files are deleted at launch and after each sync pass.
- Cap each day file at **2 MB**. Past the cap, one `log.truncated` event is written and further events that
  day are dropped. Worst case on the phone ≈ 60 MB; normal use is far smaller.
- **Settings › Developer › Clear log** deletes the phone's log files only (after a confirm). It then writes a
  `log.cleared` event into a fresh file. Remote copies are untouched.
- **Segments** *(my call, after the builder check)*: so a clear never overwrites today's remote copy with a
  near-empty file, events after a clear go to a new segment of the same day: `YYYY-MM-DD.jsonl`, then
  `YYYY-MM-DD.1.jsonl`, `YYYY-MM-DD.2.jsonl`, … Each segment uploads as its own remote file. Readers treat
  all segments of a day, in order, as that day's log. `docs/log-format.md` defines this.

### 7.3 Events
Fields: `t` (time), `v` (1, the log format version), `proc` (`app` | `share` | `bg`), `event` (dotted name),
and optional `capture_id`, `kind` (facet kind), `outcome` (`ok` | `empty` | `not_applicable` | `deferred` |
`retrying` | `failed` | `skipped` | `cancelled`), `code` (reason code, the same codes the store already
records), `attempt`, `count`, `ms` (duration), `trigger`, and `dest` (the destination's **provider kind**,
`dropbox` or `filesystem`; never an account or destination ID) *(my call, after the builder check: the
event records what it was at the time, and Activity renders it as "Uploaded to Dropbox" or "Uploaded to the
Developer folder")*. Only these; nothing free-form. Exact names below
are a starting set; the builder may adjust names and must document the final list in `docs/log-format.md`.

Per capture (shown in Activity):
- `capture.saved` (`proc` says app or share; `trigger`: note, recording, share, import) and `capture.deleted`.
  A failed save has no capture to attach to, so `capture.save_failed` (code) is global.
- `enrich.queued` (kind), `enrich.started` (kind, attempt), `enrich.finished` (kind, outcome, count, ms),
  `enrich.deferred` (kind, code, retry time), `enrich.retrying` (kind, code, attempt), `enrich.failed`
  (kind, code, attempt).
- `silver.uploaded` / `silver.upload_failed` (code), per destination.
- `package.uploaded` / `package.upload_failed` (code), per destination.
- `gold.applied`, `gold.removed`, `gold.skipped` (code).

Global (shown in the global log):
- `app.launch` (version, build in `code`), `sync.pass` start and end (`trigger`: activation, bg, manual,
  after_save; counts; result code), `bg.task` start, expiry and end, `gold.pull` end (count, code, whether a
  cursor reset happened), `enrich.pass` start and end (processed count, why it stopped), `settings.changed`
  (which switch, on/off — never values like folder names), `enrich.backfill` (kind, count queued),
  `log.truncated`, `log.cleared`, `capture.save_failed`.
- Backfills queue many captures at once; `enrich.queued` per capture is fine (each line is ~150 bytes), but
  the global log shows only the one `enrich.backfill` line.

Log uploads themselves are **not** logged as events (that would change the file every pass and loop); their
last result is shown on the Developer screen (§8.1).

### 7.4 Upload to the destination
- Remote path: `logs/<install-id>/YYYY-MM-DD.jsonl`. `<install-id>` is a random lowercase UUID created once
  per install and kept in App Group defaults *(my call: two phones, or a reinstall, never overwrite each
  other's files)*.
- When: at the end of every sync pass (app activation, BG task, manual, after save), **after** package
  uploads, silver uploads and the gold pull, against the active destination only. It never changes the pass
  result or the follow-up decision.
- What: every day file whose current size differs from what was last uploaded for it, oldest first, at most
  a few files per pass (builder picks, ~5). Today's file is replaced as it grows (`replaceFile`, now allowed
  under `logs/`); a closed day uploads once more at its final size and is then done. Bookkeeping in
  `logs/upload-state.json`.
- Upload a snapshot: copy the day file (under the lock) to staging, upload the copy, record its size, so a
  file growing mid-upload never fails verification.
- No destination, or the active one needs sign-in: logs stay local and upload later. Failures retry next pass;
  they are never surfaced outside the Developer screen.
- Remote files are never deleted by the phone; the 30-day pruning is local only.
- `FilesystemAdapter` and the `AdapterContract` tests allow `replaceFile` under `logs/`; Plan 3 (Dropbox)
  inherits it. Update the parked follow-ups note.

## 8. Developer mode (release builds too)

### 8.1 Settings › Developer
- A **Developer** section at the bottom of Settings, present in release builds, with one switch:
  **Developer mode**, **off** by default *(my call)*, stored in App Group defaults. The existing DEBUG-only
  Developer-folder storage and sample-gold button stay DEBUG-only and where they are.
- When on, the section also shows:
  - **Log** → the global log screen.
  - **Clear log** (destructive, confirm).
  - A quiet line: "Logs upload to <destination> · last upload <time or result>".

### 8.2 Activity (per capture)
- With Developer mode on, each Detail ends with an **Activity** row (below Status) that opens the capture's
  Activity screen (Jorge: option A).
- Everything logged for that capture, **oldest first**, one line each: local time to the second, a stripe dot
  (bronze for capture events, silver for on-phone enrichment, gold for server, blue for package/silver upload
  and sync), and the event in plain words, for example "Transcript · nothing found · 2.1 s",
  "Link preview · waiting: offline · retry 14:32", "Uploaded to Dropbox".
- Reads only day files from the capture's own date onward (events can't precede the capture).
- If the capture is older than the 30-day retention, the screen says early events may have been pruned.
- **Copy** button: copies the shown list as plain text with a one-line header (capture ID, app version), ready
  to paste into a Claude session.

### 8.3 Global log
- Settings › Developer › Log: global events (no capture ID), **newest first** *(my call: it's long and you
  usually want the latest)*, same line style. Shows the most recent ~500 with "Load more".
- **Copy** button: copies what's shown, same header without a capture ID.

## 9. Relative dates resolve against the capture (folded-in follow-up)

Today the data detector reads "tomorrow", "Friday", "tonight at 7" or "Nov 12" (no year) against the moment
enrichment runs, so a backfilled old note prefills the wrong calendar day.

- **Behaviour:** any part of a detected date that the text did not state (the day, month or year that the
  detector filled in from "now") is resolved against the **capture's local date and time zone** instead
  (`local_datetime` / `timezone_identifier`). Dates the text states in full are unchanged. When enrichment
  runs the same day as the capture (the common case), results are identical to today's.
- Examples the tests pin: a note captured Mon 2 Nov 2026 saying "tomorrow at 3pm", enriched on 8 Nov → Tue 3 Nov
  15:00; "Friday" → Fri 6 Nov; "Nov 12" → 12 Nov 2026; "12 Nov 2027" → unchanged; "at 2" → still not detected
  (out of scope).
- `NSDataDetector` takes no reference date, so the method is the builder's (for example, classify each
  match as fully stated or relative, and re-anchor relative ones; weekday names need re-resolving, not a
  plain day shift). Tests must not depend on the real "now": inject the run time where possible, or build
  captures dated relative to the real now.
- Bump `DataDetectionEnricher.version` to 3 so existing results are recomputed. Gold is untouched.

## 10. Where the pieces live *(builder may adjust)*

- **HippoKit / new log module** (or inside `LocalRepository`): event type, JSONL writer with `flock`, reader
  (by capture, global, paged), retention, clear, upload-state. Used by both app and extension through
  `HippoStore`.
- **Instrumentation points:** `HippoStore.capture` / `delete` (saved, deleted, save_failed), `EnrichmentRunner`
  (queued, started, finished, deferred, retrying, failed, pass), `SyncWorker` (package uploads),
  `EnrichmentUploader` (silver), `GoldPuller` (applied/removed/skipped, pull end), `SyncCoordinator` (pass
  start/end, then log upload), the BG task, `SettingsModel` (switch changes, backfills), app launch.
- **HippoPresentation:** stripe layers on `CaptureDetail`, `TaskProgress` (working/waiting) for timeline and
  Detail, the Status derivation, the Settings summary, Activity/global log view models and plain-words
  rendering of events.
- **App:** stripe modifier, spinner/clock on `TimelineRowView`, pending lines and Status in Detail, the Developer
  section, Activity and Log screens with Copy.

## 11. Testing and acceptance

**HippoKit (`make test`):**
- Log: append and read back; two writers (separate handles, and a child process if practical) never interleave
  lines; torn last line skipped; 2 MB cap and `log.truncated`; 30-day pruning; Clear; by-capture reads start
  at the capture's day; no content fields can be encoded (type-level: the event has no free-text field).
- Upload: only after the other sync steps; changed files only; snapshot upload; per-pass cap; offline/sign-in
  leaves files local; `replaceFile` allowed under `logs/` and still rejected elsewhere (contract tests).
- Instrumentation: a capture through the share path and the app path, an enrichment that defers then succeeds,
  one that fails, a silver upload, a gold apply — each produces the expected event sequence.
- Presentation: stripe layer per element incl. mixed items; working vs waiting vs done per task state; pending
  wording incl. unknown codes; Status lines for every task state and the off-in-Settings case; Settings summary
  counts; the UI is unchanged when the log folder is missing or corrupt.
- Relative dates per §9.

**App:** build check (BUILD SUCCEEDED); `make uitest` if a simulator is available.

**Device test (this batch):** run the existing rows **E1–E15** (still "not run") and new rows, recording results
in `docs/acceptance.md`:
- V1 Stripes show the right layers on a link share, a voice note and a Developer-folder gold sample; the
  setting hides them.
- V2 A voice note shows "Transcribing…" in Detail and a spinner on its row, then the transcript; the spinner goes.
- V3 Airplane mode: a shared link shows the `clock` glyph and "Link preview: waiting for a connection"; it
  completes after reconnecting.
- V4 Status lines for a typed note with nothing to find read "nothing found", not blank.
- V5 Developer mode on: Activity for a share-extension capture shows "saved (share)" through enrichment and
  upload; Copy pastes readable text.
- V6 Global log shows sync passes, a BG task run and a switch change; Clear log empties it.
- V7 `logs/<install-id>/` appears in the destination with today's file, growing across syncs; no content in it.
  Until Dropbox (Plan 3) exists, the only destination is the DEBUG-only Developer folder, so V7 runs on a
  DEBUG build; a release build records logs and shows them but has nowhere to upload yet.
- V8 Relative date: a note captured on an earlier day saying "tomorrow" (re-enriched by the version bump)
  offers Add to Calendar on the day after the capture.
- E15 also records whether link previews downloaded video bytes on cellular.

## 12. Constraints

- iOS 27, SwiftUI, existing HippoKit modules and patterns; no new dependencies.
- The share extension stays light: logging adds a file append, nothing else.
- Everything is on-device or to the user's own destination; nothing new leaves the phone except the log
  files, which contain no content.
- Quiet native iOS look, Dark Mode, Dynamic Type (V0 design §3.4).

## 13. Left to the builder

- Module placement, exact Swift types, event names (within §7.3's rules), and the code → wording tables.
- Stripe width and final colour values; spinner and glyph sizing.
- Lock timeout, per-pass log upload cap, global-log page size.
- How live updates are signalled.
- The relative-date method (§9), as long as the pinned examples pass.
