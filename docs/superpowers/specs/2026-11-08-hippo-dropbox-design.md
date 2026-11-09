# Hippo Plan 3 design: Dropbox

Date: 2026-11-08. Branch: `feat/dropbox`. **Status: approved by Jorge on 2026-11-08 ("follow your recommendations … start building"), including the builder-check rulings in §4.4, §4.3 and §4.5.** Brainstorm notes, with Jorge's own words and how each decision was reached: `2026-11-08-hippo-dropbox-brainstorm.md`.

This builds on, and doesn't repeat:
- `2026-11-07-hippo-v0-design.md` §3.1: the Dropbox adapter requirements. They stand except where §3 below changes them.
- `docs/package-format.md`, `docs/enrichment-format.md` and `docs/log-format.md`: the formats that land in the folder.
- `HippoKit/Sources/SyncEngine/StorageAdapter.swift`: the provider-neutral contract.

"Jorge decided" marks his decisions. "My call" marks choices I made that he hasn't confirmed; the builder may revisit those with a reason.

## 1. Intent

Hippo's real product is a folder of memories in the cloud. An AI agent, and later a desktop reader, will read it. The phone is intake. Until now nothing left the phone in a release build: the only destination was the DEBUG-only Developer folder. This phase makes **Dropbox** the first real destination, and makes it work really well (Jorge's words).

It also defines how the phone and Dropbox relate once both hold captures:
- **Dropbox holds everything; the phone holds a subset.** Every sync makes sure everything on the phone is in Dropbox.
- **Absence never means delete.** A new or wiped phone must never remove anything in Dropbox.
- **Explicit deletes travel both ways.** A capture deleted in Dropbox leaves the phone. "Delete everywhere" on the phone removes it from Dropbox.
- **The phone can hold less on purpose.** "Save space" trims large files that are already safely in Dropbox. "Download from Dropbox" brings recent captures back, for example on a new phone.

## 2. Goals, non-goals, anti-goals

**Goals**
- G1. Connect Dropbox from Settings in release builds. Captures, enrichment (`enrichments/device/`) and logs upload to `Apps/Hippo/` reliably, verified, resumable, and in the background where iOS allows.
- G2. "Delete everywhere" removes a capture from the phone and from Dropbox. It works offline, finishing at the next sync.
- G3. A capture whose package folder is deleted in Dropbox is removed from the phone, with a safety valve against mass disappearance.
- G4. "Save space": a manual action that trims large, old files on the phone for captures verified in Dropbox. They download again on tap.
- G5. "Download from Dropbox": a manual action that brings captures from a recent window onto the phone, in light form.
- G6. Provider-neutral. Every new capability is an operation on the `StorageAdapter` contract. The Developer folder (`FilesystemAdapter`) implements all of it, and a future Google Drive or OneDrive adapter is "implement the contract", not "change sync".
- G7. Close the parked adapter follow-ups (§8).

**Non-goals (this phase)**
- Broader Dropbox access and a folder picker (Full Dropbox access type). Jorge decided: own folder first, broader access later. The connect screen must leave room for it (§4.1).
- Any provider other than Dropbox.
- Automatic trimming, or automatic background downloading of captures. Both actions are manual (Jorge decided).
- Editing captures in Dropbox and having the edits flow to the phone (packages are immutable).
- Two phones actively capturing at once beyond what immutability and per-install logs already allow. It must not corrupt anything (§6.6), but there's no merge UI.
- The desktop reader and the gold-producing server.

**Anti-goals (a failure even if everything else works)**
- Anything deletes in Dropbox because the phone lacks something.
- The phone deletes or trims a file that isn't verified in Dropbox.
- An existing remote file is overwritten. Only `enrichments/device/` and `logs/` may be replaced, as today.
- Credentials, refresh tokens, upload session IDs, the account email or capture content end up in git, logs, packages or diagnostics.
- Dropbox-specific code outside the Dropbox adapter and its auth module.
- Cellular data burned re-uploading the same log file every pass.

## 3. Changes to v0 §3.1

- **One registered Dropbox app, not two.** Jorge decided against creating more apps than necessary.
  - The production app "Hippo" (Scoped access, App folder) is the only registration.
  - The "Hippo Dev" test app is dropped.
  - Real-Dropbox integration tests run against the same app under a test root, `Apps/Hippo/_hippo-test/<run-id>/`, which readers never scan because it's outside `captures/`, `enrichments/` and `logs/`.
  - The tests are skipped unless `.env` (gitignored, with a committed `.env.example`) holds `HIPPO_DROPBOX_APP_KEY` and `HIPPO_DROPBOX_REFRESH_TOKEN`.
  - Each run deletes its own test root at the end.
- **Adapter root prefix.** The adapter takes a root prefix: `""` in production, the test root in tests. That's also the hook for a future chosen folder.
- **Guided setup script.** `scripts/setup-dropbox.sh` walks Jorge through the App Console:
  - create the app, pick the scopes, add the redirect URI, copy the app key;
  - write the key to `Config/Secrets.xcconfig`;
  - optionally run a one-time PKCE sign-in on the Mac to put a refresh token in `.env` for integration tests.
  - It never prints a full key or token, only the first and last four characters.
  - The README links to it.

Everything else in v0 §3.1 stands:
- PKCE with an offline refresh token in `ASWebAuthenticationSession`;
- the shared Keychain access group;
- the four scopes, with `files.content.write` covering deletes;
- `account_id` binding;
- `mode: add`, `autorename: false`, and the content-conflict rule;
- local `content_hash` verification before `complete.json`;
- the error mapping;
- background `URLSession` upload-from-file;
- the SDK-vs-HTTP evaluation, recorded in an ADR.

## 4. User-facing behaviour

### 4.1 Connect and disconnect

- **Settings → Storage:**
  - Not connected: "Connect Dropbox".
  - Connected: the account's display name, the sync summary line (existing), "Save space…", "Download from Dropbox…" and "Disconnect".
  - DEBUG builds still list the Developer folder.
- **Connecting** opens Dropbox sign-in in `ASWebAuthenticationSession`. On success, Hippo:
  - stores the tokens in the shared Keychain;
  - reads `account_id` and the display name;
  - activates the destination;
  - binds unassigned captures (existing `bindUnassignedToActive`), so captures saved before connecting upload straight away;
  - starts a sync.
- **Room for broader access.** The connect screen is a short sheet: what Hippo will create (`Apps/Hippo` in your Dropbox), what it can see (only that folder), and the Connect button. The "only that folder" line is where a future "or pick a folder (full Dropbox access)" choice goes. This phase builds only the own-folder path.
- **Sign-in expired or revoked.** Jobs move to `needs_authentication` (existing state). Settings shows "Reconnect Dropbox", and the sync summary says why. Background and extension code never shows UI.
- **Disconnect** stops syncing, revokes the token (best effort), removes the Keychain items and marks the destination signed out. It **never deletes anything**, on the phone or in Dropbox.
  - Captures stay bound to that `account_id`.
  - Connecting a different account never uploads them there (v0 V5).
  - Reconnecting the same account resumes.
  - The confirmation says trimmed files (§4.4) can't be downloaded until you reconnect.
- **Share extension copy** follows v0 §3.4: "Saves on this iPhone first. Uploads to Dropbox when it can.", or the not-connected variant.

### 4.2 Delete

- Detail's menu keeps **"Delete from iPhone…"** (today's behaviour and prompt) and adds **"Delete everywhere…"** (Jorge decided). The second is shown only when a destination is bound.
- **The "Delete everywhere" prompt** (my call on copy): "Delete from this iPhone and from Dropbox? Dropbox keeps deleted files for a while, so you can restore them on dropbox.com."
- **On confirm:**
  - The capture leaves the phone at once, exactly like "Delete from iPhone".
  - A **remote-delete tombstone** is queued, bound to the capture's destination and account and holding the package's relative directory.
  - The next sync with that account deletes the remote package folder and the capture's `enrichments/device/` folder. It also deletes the `enrichments/server/` folder. This is a documented exception to "the phone never writes the server layer": a delete isn't a write. My call.
  - Not-found counts as success.
  - The tombstone survives relaunches and is retried with the existing backoff.
- **Deleting during an upload** cancels the upload first (existing cancel path). The remote folder, which has no `complete.json` yet, is then deleted the same way.
- **Pending remote deletes** appear in the Settings sync summary ("1 delete waiting to reach Dropbox") and in the log.

### 4.3 Deletes made in Dropbox

- **What counts as deleted:** a capture is deleted remotely when its package folder `captures/YYYY/MM/DD/<id>/` is gone, or its `complete.json` is gone. My call: readers treat a package without the marker as absent, so the phone does too.
- **Moves and renames** inside the folder count as a delete of the old path. Hippo doesn't follow moves.
- **A missing or changed attachment, or a missing or changed `metadata.json`, while `complete.json` remains,** deletes nothing.
  - The capture is marked **"changed in Dropbox"**: a Status line in Detail.
  - Detail offers **"Upload again from iPhone"**, which re-uploads missing files with `mode: add` and never overwrites. A file that exists with different content stays a content conflict, shown as such.
  - This keeps "everything on the phone is in Dropbox" true without ever overwriting.
- **Detection** uses `listChanges(under: "captures/", cursor:)`.
  - The cursor is per destination, meaning per `account_id`, and is **kept across Disconnect and reconnecting the same account**. My call; otherwise deletes made while disconnected would be missed.
  - It is baselined with a new `latestCursor(under:)` only when no cursor exists yet, which means the first connect of that account. So the first connect never enumerates history.
  - If a kept cursor has expired, the `cursorReset` path below runs, and that can show the review sheet after a reconnect.
  - It runs on each sync pass after uploads, like the gold pull.
- **Unverified captures are protected.** A remote change never removes a capture whose upload isn't verified. Its jobs aren't all `synced`. That case is logged and ignored, and the next upload recreates the remote copy.

**Safety valve (my call on the thresholds)**
- If one pass would remove **more than 20 captures, or more than 10 % of the phone's synced captures**, or the `captures/` root itself is gone, Hippo applies nothing.
- It records a pending "Dropbox looks different" review instead. Settings and the timeline show a banner. The review sheet lists the count and the date range, and offers:
  - **"Remove them from iPhone"**: applies the deletes.
  - **"Keep and upload again"**: re-uploads them, recreating the remote copies.
  - **"Decide later"**.
- **A cursor reset** (`cursorReset`) never produces deletes by itself. Hippo re-baselines, then lists `captures/` in full and compares it against the phone's synced captures. Any synced capture missing remotely goes to the same review sheet, whatever the count. It is never applied automatically, because a reset can't tell "deleted" from "not listed".

### 4.4 Save space (Jorge decided: manual, two options)

- **Settings → Storage → "Save space…"** opens a sheet with:
  - **Older than:** 1 week, 1 month (the default), 3 months, 1 year. My call on the steps.
  - **Larger than:** 1 MB, 10 MB (the default), 50 MB, 100 MB. My call on the steps.
  - A live estimate: "Frees about 2.3 GB from 41 captures".
  - A "Save space" button.
- **What qualifies:**
  - Only attachments of captures whose every job is `synced`, verified, and bound to the **currently connected** account.
  - Only attachments both older and larger than the limits. Age is the capture's `captured_at`.
  - If nothing qualifies, the button is disabled and the estimate says why: "Nothing older than 1 month and larger than 10 MB is in Dropbox yet".
- **Trimming** deletes the attachment's bytes locally and records it as **in Dropbox only**. The package directory, `metadata.json`, `complete.json`, all enrichment, the index row and search all stay.
  - First a local thumbnail is made and kept, for images and videos (§6.4), so the timeline and Detail still show a picture.
  - The Reconciler and package validation learn that a trimmed attachment is expected to be missing locally (§6.3).
- **Detail** shows a trimmed attachment as its thumbnail with "In Dropbox · Download (34 MB)".
  - Tapping it downloads the file over any connection, with progress, verifies its SHA-256 against `metadata.json`, and restores it locally. It stays restored until trimmed again.
  - If it's offline, signed out or connected to a different account, it says so: "Connect Dropbox (account …) to download".
- Save space runs in the foreground, with a progress line. It stops cleanly if the app is backgrounded, and whatever it already trimmed stays valid.
- **Trimming makes Dropbox the only copy of those files. My call on everything in this list.**
  - **The sheet says so plainly:** "These files will then be only in Dropbox."
  - **Fresh remote check before trimming:** just before trimming a file, Save space checks the remote copy with `inspectFile`. The size and provider hash must still match the upload receipt; a file that fails is skipped and counted. So Save space needs a connection, and the sheet's button is disabled offline.
  - **The review sheet (§4.3):** it lists captures with trimmed files separately ("N of these have large files only in Dropbox"). For those, "Keep and upload again" can't restore the trimmed files. It re-uploads what the phone still has and leaves the package without `complete.json`.
    - Their choices are "Remove them from iPhone" and "Keep on iPhone as they are".
    - Either way, the sheet points to Dropbox's deleted-files restore on dropbox.com.
    - A package is never published with files missing from its own manifest.
  - **"Upload again from iPhone" (changed in Dropbox)** can't restore a trimmed file. Detail says "This file was only in Dropbox and is gone there. Restore it from Dropbox's deleted files on dropbox.com."
  - **A trimmed file whose remote copy no longer matches** fails the SHA-256 check on download. It's shown as "Changed in Dropbox: this file no longer matches", with the thumbnail kept and nothing restored. It's never accepted unverified.
  - **Remote deletes under the safety-valve threshold** apply to trimmed captures too, because the user deleted them in Dropbox.

### 4.5 Download from Dropbox (Jorge's idea; manual)

- **Settings → Storage → "Download from Dropbox…"** opens a sheet with:
  - **From the last:** 2 weeks, 1 month (the default), 3 months, 6 months, 1 year, everything. My call on the steps.
  - An estimate after a listing pass: "About 120 captures, 340 MB".
  - A "Download" button.
- **Which captures:** complete remote captures in the window that aren't on the phone, aren't pending remote deletes, and **weren't removed with "Delete from iPhone" on this phone** (Jorge decided, following my recommendation).
  - The sheet says "Skipping 12 you removed from this iPhone" and has an "Include them" switch, off by default.
  - A new install has no such records, so a new phone gets everything in the window.
  - For each one Hippo downloads `metadata.json`, `complete.json` and every attachment **at or under 10 MB**. My call; it's the Save space default size.
  - It also downloads the capture's `enrichments/device/` and `enrichments/server/` documents, if present.
  - Larger attachments arrive as **in Dropbox only**, with a thumbnail from the adapter's thumbnail operation if it has one, else a type icon. They download on tap, as in §4.4.
- **Validation** follows `package-format.md`'s reader algorithm: sizes and SHA-256 against `metadata.json`, with the marker checked last. A capture that fails is skipped, logged and counted ("3 couldn't be downloaded"). It's never half-indexed.
- **A downloaded capture** is registered in the index:
  - bound to the connected account;
  - with jobs `synced`, so it's **never re-uploaded**;
  - shown in the timeline by its own date.
  - Its enrichment documents are imported as the current device and server layers. The enrichment runner then only schedules kinds that are missing or outdated, as for any capture.
- **Window semantics:** the window applies to `captured_at`. Listing walks only the `captures/YYYY/MM/` folders the window covers (my call), so "last month" doesn't list ten years.
- **When it runs:** in the foreground with progress, continuing in iOS background time when it can. It's resumable: what's downloaded stays, and running it again picks up the rest.
- **A new phone** connects Dropbox and runs this. It never deletes anything (§1).

### 4.6 Sync timing and visibility

- Sync runs on launch, on returning to the foreground, while open, and in iOS background tasks. Started uploads continue in a background `URLSession` after suspension. No timing is promised.
- **Two parked follow-ups now land (my call, since Dropbox makes them visible):**
  - a foreground retry timer for `next_attempt_at`;
  - a sync pass and a progress refresh when connectivity returns while the app is in the foreground (an `NWPathMonitor` change).
- **Visibility batch integration:**
  - The Settings sync summary covers Dropbox states: needs sign-in, quota full, conflicts, pending remote deletes, and the review pending.
  - Detail's Status section gets a **Storage** line: "In Dropbox · verified", "Uploading…", "Waiting for a connection", "Changed in Dropbox", or "Large files in Dropbox only".
  - The new operations log content-free events (§6.5).

## 5. Provider-neutral contract additions

These are added to `StorageAdapter`. Dropbox specifics stay inside the Dropbox adapter.

| Operation | Meaning | Dropbox | FilesystemAdapter |
|---|---|---|---|
| `deleteFolder(relativePath:)` | Recursive, idempotent delete. Not-found counts as success. Allowed only under `captures/` and `enrichments/`. | `files/delete_v2` | remove the directory |
| `latestCursor(under:)` | A cursor for "changes from now on" without listing. | `list_folder/get_latest_cursor` (recursive) | a snapshot token |
| `listFolder(relativePath:recursive:)` → pages | Entries (folders and files, with size and provider hash) for the download listing and the reset comparison. | `list_folder` + `continue` | directory walk |
| `thumbnail(relativePath:maxPixelSize:)` → Data? | Optional, gated by a capability flag. | `files/get_thumbnail_v2` | ImageIO/AVFoundation, or nil |
| `listChanges`, `downloadFile`, `replaceFile` | Exist today. Dropbox implements them per the parked notes (§8). | `list_folder` + `continue`, `reset` → `cursorReset`; `files/download`; upload with overwrite mode | exist |

- `StorageCapabilities` gains `supportsThumbnails`.
- The shared **AdapterContract tests** cover every operation, including the path-scope rules (`deleteFolder` refuses `logs/` and anything outside the allowed prefixes, and `..` is rejected after resolution). They run against the FilesystemAdapter always, and against Dropbox under the test root when `.env` is present.

## 6. Mechanics the builder must respect

### 6.1 Auth module
- PKCE, the refresh token, and access-token refresh shared across the app, the extension (which only reads, and never shows UI) and background work.
- Refreshing is serialised across processes, for example with a Keychain-stored token plus a file lock in the App Group, so two processes never race the refresh-token rotation.
- Tokens never appear in logs, diagnostics or crash reports.

### 6.2 Tombstones
- Remote-delete tombstones are durable rows in `hippo.sqlite`: capture ID, relative directory, destination ID, account ID, state and attempts.
- They're processed by the sync worker before uploads.
- They're bound to an account like jobs, so a tombstone never runs against another account.
- Download from Dropbox skips any capture with a pending tombstone.
- **Local-delete records:** "Delete from iPhone" writes a durable row (capture ID, relative directory, account ID, deleted-at) with no remote effect.
  - Download from Dropbox excludes these captures unless "Include them" is on. Including one that is then downloaded removes its record.
  - The records never lapse on their own (my call). They're local to this install, so a reinstall or new phone starts with none.
  - "Delete everywhere" writes a tombstone instead.

### 6.3 Trimmed attachments
- Trimmed state lives in the index (or a sidecar in the store), **never inside the package**: packages stay immutable, and the package format says nothing mutable goes in them.
- `metadata.json` keeps the attachment's size and SHA-256, so a later download is verified against it.
- The Reconciler, package validation, the enrichment runner and any re-upload path must treat "trimmed" as a valid state: not corrupt, and not a reason to re-upload or re-enrich. Inputs an enricher needs from a trimmed file (for example OCR on a trimmed image) are already done, because trimming requires synced captures. If one isn't, that kind stays as it is.

### 6.4 Thumbnails
- Local thumbnails for trimmed or remote-only attachments are generated before trimming. When downloading, they come from the adapter's thumbnail operation.
- They're stored in a store cache directory outside packages, keyed by attachment ID.
- The timeline and Detail use them whenever the original isn't local.

### 6.5 Log events (content-free, added to `docs/log-format.md`)
- `auth.connected` and `auth.disconnected`: the provider, never the account email or name.
- `auth.refresh_failed`.
- `remote.delete` (queued, done, or failed with a code).
- `remote.changed`.
- `remote.review` (count only).
- `trim.run` (counts and bytes).
- `download.run` and `download.capture` (counts, outcome).

Log uploads are **throttled on cellular** to at most once every 15 minutes (my call on the number), with no limit on Wi-Fi.

### 6.6 Two phones
- An old phone and a new one can both be connected to the same account. Packages are immutable and logs are per install, so nothing collides.
- Each phone's deletes reach the other through §4.3.
- The `enrichments/device/` layer is last-writer-wins per capture. That's acceptable: the documents describe the same immutable package.

### 6.7 Cancellation
- Every Dropbox network call honours Task cancellation within `BackgroundActivity.expiryGrace` (2 s), so a long upload can't outlive the background assertion (0xdead10cc).
- Background-session uploads are exempt, because the system owns them.

## 7. Constraints

- iOS 27, Swift 6, HippoKit tested with `swift test` on macOS (Swift Testing), and the app generated by XcodeGen. The existing App Group is `group.com.jorgeper.hippo`; a shared Keychain group is added in `project.yml`. These work on the free Personal Team, per the device-signing memory.
- Free-team installs need reinstalling every 7 days. Data and Keychain items survive a reinstall over the existing app.
- Secrets:
  - App keys go only in gitignored `Config/Secrets.xcconfig`, with the committed `Secrets.example.xcconfig`.
  - Test credentials go only in gitignored `.env`, with the committed `.env.example`.
  - Never paste or print full keys: show the first and last four characters.
- The UI never reads the log to decide state (visibility design).
- Dropbox API limits: check current docs during the SDK-vs-HTTP step. These include upload session limits, `Retry-After` handling and `list_folder` page sizes.

## 8. Parked follow-ups this phase closes

From the `hippo-core-parked-followups` memory:
1. Cancellation within the 2 s grace (§6.7).
2. `replaceFile` with overwrite, only under `enrichments/` and `logs/`.
3. `listChanges` via `list_folder` recursive + `continue`, with `reset` → `cursorReset`.
4. `downloadFile`.
5. The AdapterContract tests against real Dropbox.
6. Throttling log uploads on cellular.
7. The foreground retry timer and the connectivity refresh (§4.6).

Still parked: the timeline time-zone filter, recording-orphan recovery UI, and the 10k-capture scale check.

## 9. Acceptance

**Automated**
- Contract tests for the §5 operations, on both adapters.
- Tombstone durability and account binding.
- Safety-valve thresholds, including the cursor-reset path, which never auto-deletes.
- "Changed in Dropbox" detection.
- Trim eligibility: only verified captures on the connected account, both limits applied.
- Trimmed-state survival across Reconciler runs.
- Download validation: a bad hash means the capture is skipped, never half-indexed.
- Downloaded captures are never re-uploaded.
- Captures removed with "Delete from iPhone" are skipped by Download unless "Include them" is on.
- No tokens or emails in log files: extend `noEventCarriesContent`.
- The cellular log throttle.

**Device rows** to add to `docs/acceptance.md` (D-rows):
- D1. Connect Dropbox. Captures saved before connecting upload, and `Apps/Hippo/captures/…` appears on the Mac.
- D2. Airplane-mode captures upload after reconnecting, and a large video resumes after the app is backgrounded mid-upload.
- D3. Delete everywhere while online: the capture is gone from the phone and from Dropbox. While offline: gone from the phone, and from Dropbox after the next sync.
- D4. Delete a capture's folder on the Mac. After the next sync it's gone from the phone.
- D5. Delete or rename 25 captures' folders, or the whole `captures/` folder, on the Mac. The review sheet appears, and nothing is removed until a choice is made. "Keep and upload again" restores them.
- D6. Edit or delete one attachment on the Mac. Detail shows "Changed in Dropbox", and "Upload again" restores the missing file.
- D7. Save space with 1 month and 10 MB. The estimate matches, the videos show thumbnails and "Download", and tapping one restores it.
- D8. Download from Dropbox (1 month) after deleting the app and reinstalling. Recent captures appear, large files show "Download", and nothing is re-uploaded.
- D13. On the same phone, "Delete from iPhone" a capture, then run Download from Dropbox. The sheet says it skips 1 and the capture doesn't come back. With "Include them" on, it does.
- D9. Disconnect. Nothing is deleted anywhere. Connect a second account: nothing from the first is uploaded there.
- D10. Revoke Hippo's access on dropbox.com. Settings shows "Reconnect Dropbox", and reconnecting resumes.
- D11. Background sync uploads after a BG task, with no 0xdead10cc in the crash logs.
- D12. Logs appear under `Apps/Hippo/logs/<install-id>/` and contain no content.

Rows 1–24, whose upload halves waited for Dropbox, get re-run in the same device session.

## 10. Left to the builder

- SwiftyDropbox or direct HTTP, per the v0 §3.1 criteria. Record it in an ADR.
- Chunk sizes, the single-request cutoff, and the backoff constants.
- Where trimmed state and thumbnails are stored (index columns vs sidecar), within §6.3–6.4.
- The cross-process refresh lock mechanism (§6.1).
- The exact copy for sheets and banners, within the meanings above, following the existing plain-wording style.
- The order of the plan's tasks. Recommended: auth and adapter with contract tests first, then upload end to end, then deletes (tombstones, remote detection, review), then Save space, then Download.
