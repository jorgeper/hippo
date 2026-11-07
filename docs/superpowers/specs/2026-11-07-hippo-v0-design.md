# Hippo V0 — Design (iPhone intake app)

Date: 2026-11-07
Base spec: [`hippo-v0-spec.md`](../../../hippo-v0-spec.md) (repo root). **That spec is binding except where this document changes it.** Read both. Where they disagree, this document wins.

## 1. Intent and why

Jorge emails himself things he wants to remember (screenshots, links, photos, emails, notes), stars them, and on weekends goes through them **on a computer**, looking for reminders and things to do. Hippo replaces that habit.

The system has two halves:

- **Hippo for iPhone (this project):** fast, decision-free intake. Saving is instant and local. Each capture becomes plain files plus versioned JSON in a cloud folder the user owns.
- **A desktop browser (not this project):** written later by Jorge. It reads that synced folder and adds enrichment, agents and the weekend review.

The files in the cloud folder are the real product. The phone app's job is to get them there correctly and honestly. It should also let you glance back through recent captures with a simple, well-designed timeline.

## 2. Goals, non-goals, anti-goals

**Goals**
- Capture takes about as long as starring an email: share, (optional comment), Save.
- No capture is ever lost or silently truncated, offline or not.
- Every package in Dropbox is complete, verifiable and readable without the app (spec §6, §12).
- A quiet, well-designed timeline for recent captures, with search, filters and sort.

**Non-goals for V0.** These are as in spec §3 "Deferred", with the changes listed below:
- AI, OCR, transcription, webpage fetching, desktop app, a server, multi-device sync.
- Special email handling. Whatever an email app shares (text, link, PDF via Print→Share) is captured generically, and nothing more. A forward-to address is deferred.
- Lock Screen, Action button, Control Center and widget entry points. Opening Hippo is fine for V0.

**Anti-goals** (failure even if it "works")
- Capture that feels slower or more effortful than emailing yourself.
- "Synced" shown for anything not fully verified remotely, including `complete.json` uploaded last.
- Fabricated metadata, such as guessing the source app from a URL host or assigning time zones to embedded timestamps.
- A package format the desktop reader can't trust.

## 3. Decisions made in brainstorming (changes to the base spec)

### 3.1 Storage provider: Dropbox first, not OneDrive
The base spec's OneDrive sections (§3 item 8, §9, references to OneDrive in §10, §14) are **replaced by Dropbox**. OneDrive becomes a future adapter like Google Drive. The provider-neutral `StorageAdapter` contract (§8) is unchanged in spirit and must still keep capture and sync free of Dropbox-specific code.

Dropbox adapter requirements. Verify each against current Dropbox API docs during step 1:
- **App registration:** Dropbox App Console, "Scoped access", **App folder** access type. Remote root is the app folder, which appears on the desktop as `~/Dropbox/Apps/<AppName>/`. Scopes: the minimum needed. Expected: `files.content.write`, `files.content.read`, `files.metadata.read`, `account_info.read`.
- **Auth:** OAuth 2 Authorization Code + **PKCE** as a public client. No app secret ships. Use `token_access_type=offline` to get a refresh token. Run the flow in the main app with `ASWebAuthenticationSession`. Store refresh and access tokens in the **shared Keychain access group**, so the extension and background work can refresh. Background or extension code never shows UI; on refresh failure the job moves to `needs_authentication`.
- **App key:** not a secret under PKCE, but per Jorge's global rules it lives in a gitignored `Config/Secrets.xcconfig`. Commit a `Secrets.example.xcconfig` with a placeholder. Jorge creates the Dropbox app and supplies the key; the README documents the console steps.
- **Destination identity:** persist the Dropbox `account_id` (from `users/get_current_account`) as the destination's account identifier. Never route jobs bound to one `account_id` to another (spec §8 "Provider switching").
- **Uploads:** single-request upload for small files; upload sessions (start / append / finish) for large files. Persist the session ID and committed offset as the opaque resume checkpoint. Treat session IDs as sensitive and keep them out of logs and packages. Chunk size and the single-request cutoff are adapter details. Check current limits, which are believed to be about 150 MB per request with 4 MB-multiple chunks.
- **Idempotent exact-path writes:** write with `mode: add`, `autorename: false`. On a path conflict, fetch the existing file's metadata. If its size and `content_hash` match the local file, treat it as success. Otherwise surface a **content conflict** (`blocked`) and never overwrite.
- **Integrity evidence:** compute the Dropbox `content_hash` locally (SHA-256 per 4 MB block, then SHA-256 of the concatenated digests) and compare it with the server's value for every file before uploading `complete.json`. Record this as provider-specific evidence. It does not equal the package SHA-256, and the docs must say so. Integration validation must also download one file and check its SHA-256 round-trip.
- **Errors:** handle expired or revoked tokens, offline, `429`/`Retry-After`, `insufficient_space` (→ `blocked`, user action), 5xx, and expired upload sessions (restart that file safely).
- **Background transfers:** use a background `URLSession` with the App Group `sharedContainerIdentifier` where the request shape allows it (upload-from-file). Refresh the access token before handing a request to the background session. Do not promise timing (spec §10).
- **SDK vs direct HTTP:** in step 1, check whether the current SwiftyDropbox SDK supports PKCE + refresh in a shared Keychain, background upload-from-file, app-extension use, and persisting upload-session checkpoints. If it does, prefer the SDK (the common route, less code). Otherwise call the HTTP API directly with `URLSession`. Record the decision in an ADR. The SDK must stay inside the Dropbox adapter.
- **Integration-test destination (decided by Jorge):** a second Dropbox app, **"Hippo Dev"** (App folder → `Apps/Hippo Dev`), in Jorge's same account. Real-Dropbox integration tests write only there, never into the production `Apps/Hippo` folder the desktop reader scans. Its app key and a long-lived refresh token live in a gitignored `.env` at the repo root (with a committed `.env.example`), so integration tests run on the Mac via `swift test`. They are skipped when the env vars are absent. The production app key lives in `Config/Secrets.xcconfig` (gitignored).

### 3.2 Voice notes are in V0 (changes spec §3 "Deferred: custom voice recorder")
- The main app has a **Record** button that opens a simple recorder: big record/stop, elapsed time, Save/Discard. On Save it creates a capture with one `.m4a` (AAC) attachment, plus duration and timestamps.
- New `capture_method` value: `voice_recording`. The schema enum stays open for future values.
- Microphone permission is requested the first time Record is used. If permission is denied, show an explanation and a link to Settings.
- *Builder's call, recommended:* enable the background audio mode so locking the phone doesn't stop a recording. Interruptions (calls, Siri) stop the recording and offer to save what was captured. No transcription.
- Shared audio files (e.g. from Voice Memos) are captured like any file, as in the base spec.
- Typed notes support keyboard dictation automatically; nothing special is needed.

### 3.3 Source application: not available; save clues instead
iOS gives Share Extensions **no supported API** for the host app's identity. A private workaround reportedly stopped working in iOS 26.4. Per spec §7, `source_application` stays `null`, and Hippo never guesses it. Instead, record **factual clues** in `metadata_observations` so the desktop can infer later and label it as inferred:
- each attachment's full ordered list of `registeredTypeIdentifiers` (some are app-specific)
- `suggestedName`, shared title or attributed content title, and the URL list (already in metadata)
- bounded, allowlisted `NSExtensionItem.userInfo` keys if any are present

Re-check the iOS 27 SDK during step 1 for any new public API. If one exists, use it and record its provenance.

### 3.4 Phone UI: "Timeline" layout
Mockups approved on 2026-11-07, in `.superpowers/brainstorm/*/content/timeline-flow.html` (local only).

- **Timeline list:** the large title "Captures" with a gear (Settings) at the top right. Below it, a search field, then quick filter chips (All · Links · Images · Notes · Audio · Filters). Days are grouped under headers ("TODAY · SAT NOV 7"), and the time appears in a left column. Rows vary by type:
  - image/video: medium thumbnail (about 60 pt)
  - multi-attachment: a strip of small thumbnails plus a "+N" count
  - link: page title (or URL) plus host
  - note: first line
  - voice: "Voice note · m:ss"
  - PDF or file: original filename
  The user comment shows in italics, visually distinct from shared content. Every row has a sync dot with a label: *On iPhone* (pending or uploading), *Synced*, or *Needs attention* (any error state, including *Needs sign-in*). The bottom bar has two buttons: **✎ Note** and **● Record**.
- **Filters sheet:** sort (newest/oldest, stable tie-break by capture ID), date (Today / Last 7 / Last 30 / custom range), type (Link, Image, Video, Note, Audio, PDF, File; mixed captures match any of their types), how it was saved (Shared / Typed note / Recorded), other (**Has my comment**, Has location), and sync (Not synced yet / Synced / Needs attention).
- **Capture details:** large preview, your comment, then a "Captured" section (when, how, where you were with accuracy and age), an "Attachments" section (filename, dimensions, size, photo-taken time and location if embedded), and a "Sync" section (destination plus state plus an actionable error). Share/Export and "Delete from iPhone…" follow spec §11. Missing values are omitted, never shown as blank or "Unknown".
- **Share Extension:** Cancel / Hippo / Save header, a preview with count and size, an optional comment field, the line "Saves on this iPhone first. Uploads to Dropbox when it can." (or "…when you connect a storage account" if none), and a Save button. After a durable commit, "✓ Saved on this iPhone" shows for about 1 s and then the sheet closes.
- **Settings:** follows spec §11, with Dropbox as the only provider listed.
- **Visual quality bar:** quiet, native iOS look with system fonts, system colors and full Dark Mode and Dynamic Type support. Use the vocabulary "Captures", never "Inbox".

### 3.5 Platform, tooling, signing
- **iOS deployment target: 27.0.** Jorge's iPhone 18 Pro runs 27.0.1. Xcode 27.2, Swift 6 language mode.
- **Signing: free Apple "Personal Team"**, not the paid program. The team ID is a per-developer value: keep `DEVELOPMENT_TEAM` in a gitignored `Config/Local.xcconfig` (commit a `Local.example.xcconfig`), never in `project.yml`. A spike verified on-device on 2026-11-07 that this team can sign an app plus Share Extension sharing an **App Group** and a **Keychain access group**, and that the extension can write to the group. Consequences:
  - Installs expire after **7 days**. Provide a one-command reinstall (`make device` or `scripts/install-device.sh`) using `xcodebuild -allowProvisioningUpdates` and `devicectl`. Captures survive reinstall as long as the app isn't deleted; the README must say this prominently.
  - The free team allows about 10 new App IDs per 7 days. Use exactly two final bundle IDs (app plus extension) and don't churn them.
  - No TestFlight.
- **Bundle and group IDs:** `com.jorgeper.hippo`, `com.jorgeper.hippo.share`, `group.com.jorgeper.hippo`, keychain group `$(AppIdentifierPrefix)com.jorgeper.hippo.shared`.
- **Project generation:** XcodeGen (`project.yml`, installed via Homebrew); don't commit the generated `.xcodeproj`. *(Builder's call is fine if there's a strong reason otherwise.)*
- **Testability:** CaptureCore, LocalRepository, SyncEngine and StorageAdapters live in a local Swift package that also builds for **macOS**, so `swift test` runs on the Mac with no simulator or device. UI and extension code stays thin. The iOS Simulator may not be installed yet (Jorge is downloading it); don't block on it.
- **On-device observability:** `devicectl` can read the App Group's `Library/` subtree from the Mac, but not other top-level folders (observed in the spike). Put Hippo's store under the App Group's `Library/Application Support/Hippo/` (captures, staging, SQLite). Write a small redacted `Library/Application Support/Hippo/diagnostics.json`: counts by sync state, last errors as safe codes, schema and app version, with no content, tokens or precise location. Then on-device behavior can be checked from the Mac. Verify early that `devicectl device copy from` can read nested `Library/` paths.

### 3.6 Captures made with no account connected (decided by Jorge; refines spec §8)
- A capture committed while **no destination is active** (never connected, or after signing out with nothing else connected) gets **no** upload job. It is "unassigned" and shows *On iPhone*.
- When a destination becomes active, by connecting or by signing back in, all unassigned captures automatically get jobs for that destination. This is the only automatic backfill.
- Captures that already have a job bound to destination A stay bound to A. Signing out of A pauses those jobs (spec §8). Connecting a different account B never picks them up. They resume when A signs back in, or move only through the explicit "Upload existing local captures to this destination" action.
- The Share Extension's line when nothing is connected: "Saves on this iPhone. Uploads once you connect Dropbox in Hippo."

### 3.7 No in-app file/photo import in V0 (builder's call)
Files and photos come in via the Share Extension from Files, Photos, etc. The main app has only Note and Record. `file_import` stays a valid schema value for the future but is not produced in V0, and "Imported file" is **removed** from the V0 filters sheet.

### 3.8 Email
No special handling (Jorge: "skip for now"). The README notes the Print→Share-as-PDF workaround and the deferred forward-to address.

## 4. Constraints (carried over and emphasized)
- Everything in base spec §2 (binding decisions), §4 (commit protocol), §6 (package format plus JSON Schema plus fixtures), §7 (metadata honesty), §10 (states, leases, backoff), §13 (security) and §14 (acceptance; read OneDrive as Dropbox and add the voice scenario below) applies.
- No credentials or app keys in git. Before any commit, review the full staged diff for secrets (Jorge's global rule).
- Location is opt-in, with no background tracking, and the extension never waits for a fix (spec §7).

**Additional acceptance scenarios**
- V1. Record a 30 s voice note offline. It appears in the timeline with its duration and later uploads with matching bytes.
- V2. Interrupt a recording (incoming call or Siri). A valid partial recording is offered and saved; nothing is half-committed.
- V3. Share from three different apps. `source_application` is null, and `metadata_observations` contains the type-identifier clues.
- V4. After a reinstall over an existing install (7-day re-sign), all captures and queue state are intact.
- V5. Captures saved before Dropbox is first connected upload automatically after connecting. Captures bound to account A are not uploaded after signing out of A and connecting account B.
- V6. Integration tests never write outside `Apps/Hippo Dev`.

## 5. Left to the builder
- Exact Swift types for the adapter contract, error enums and repository API.
- SQLite access layer: a thin wrapper over the system `sqlite3` or a well-maintained library (e.g. GRDB). Keep dependencies few and justified.
- SwiftyDropbox vs direct HTTP, per the evaluation criteria in §3.1.
- Thumbnail generation and caching strategy, pagination size, and search implementation (SQLite FTS5 recommended).
- Exact Dropbox chunk sizes and retry and backoff constants, within the spec's rules.
- Visual details within §3.4 (spacing, iconography, empty states).
- Documenting every such choice in the README or an ADR.

## 6. Known limits to state plainly in the README
- The source app is not recorded (§3.3).
- Email capture is limited to what the email app shares.
- The free-account 7-day reinstall applies.
- Uploads are a copy, not a backup policy. Deleting the app deletes local captures that haven't been uploaded.
- A new install doesn't rebuild the library from Dropbox (spec §10).
- Background upload timing is up to iOS.
