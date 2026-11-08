# Hippo Enrichment — Design (silver/gold layers, two-way sync, capture tweaks)

Date: 2026-11-07
Branch: `feat/enrichment` (stacked on `feat/hippo-app`, PR jorgeper/hippo#3; rebase onto `main` after #3 merges).

Builds on [`hippo-v0-spec.md`](../../../hippo-v0-spec.md) and [`2026-11-07-hippo-v0-design.md`](2026-11-07-hippo-v0-design.md). **Both stay binding except where this document changes them** (§3 lists every change). Where they disagree, this document wins.

## 1. Intent and why

Hippo's captures are honest but thin. A YouTube link is just a URL, a screenshot is just pixels, a voice note is just audio, and a location is a pair of coordinates. When Jorge reviews on the weekend, he has to open each one to remember what it was. He wants captures to come back **richer**: titles and thumbnails for links, the text in screenshots, a transcript for voice notes, and a place name instead of numbers.

He also wants a path to heavier enrichment later. A future server app will run LLMs and similar tools over the Dropbox folder offline, and its results should show up on the phone too.

Hence three layers per capture (Jorge's model):

| Layer | What | Who writes it | Where it lives |
|---|---|---|---|
| **Bronze** | The immutable capture package plus source metadata (time, zone, location, source clues). This is V0 as built. | Phone, once | `captures/YYYY/MM/DD/<id>/` |
| **Silver** | Cheap on-device enrichment, run asynchronously right after save. Each kind can be switched off in Settings. | Phone (the app, never the extension) | `enrichments/device/…` |
| **Gold** | Offline server-side enrichment (LLMs etc.) by a future server app. | Server only | `enrichments/server/…`, **synced back to the phone** |

Capture speed and package honesty stay the top priority. Enrichment is a bonus layered beside the package. It must never slow down, block or alter a capture.

## 2. Goals, non-goals, anti-goals

**Goals**
- Silver for the first batch (§4) runs automatically after save, with no user action, and shows in the timeline and Detail.
- Silver results are written to Dropbox beside the packages, so the desktop and the future server can read them.
- The phone pulls gold from Dropbox and shows it in preference to silver. Gold is enrichment files only, never captures.
- OCR text, transcripts, link titles and place names are searchable in the timeline search.
- Two capture tweaks: Record starts recording on the first tap, and shares try for a fresh location fix.

**Non-goals (this phase)**
- Building the server or the desktop app. This phase defines the gold *format* and the phone's pull. Gold is tested with hand-made files in the DEBUG Developer folder.
- Building the Dropbox adapter. That is Plan 3. This phase extends the adapter **contract** and implements it in `FilesystemAdapter`. Plan 3 must implement the new methods for Dropbox (§6.4).
- Multi-device sync, rebuilding the library from Dropbox, or downloading captures. These remain out of scope as in V0.
- LLM work on the phone.
- Enrichment inside the Share Extension.
- Weather (WeatherKit needs the paid developer program). Summaries, tags and cross-capture links are gold-only.
- The "later batch" in §4.2.

**Anti-goals** (failure even if it "works")
- A capture that saves slower, or fails, because of enrichment.
- Any change to a bronze package's bytes, or to `metadata.json`. Packages stay immutable (package-format.md).
- A guess shown as fact. The source-app guess and the nearest point of interest are always labelled as guesses (§5.6, §5.2).
- Gold for a capture deleted on the phone reappearing on the phone.
- Two writers on one file. The phone never writes `enrichments/server/`, and the server never writes `enrichments/device/`.
- Enrichment that runs constantly or drains the battery. Each piece of work runs once per capture per enricher version, with bounded retries.

## 3. Changes to the earlier specs (call-outs)

1. **Base spec §7 ("Do not fetch webpages, geocode addresses, run OCR, or enrich via an LLM in V0")** is lifted **for silver only**. Silver may fetch link metadata, reverse-geocode, run OCR and transcribe on device. LLM enrichment stays off the phone. **Bronze collection is unchanged.** `metadata.json` gains nothing from enrichment.
2. **Base spec §7 ("never infer app identity from a URL host")** still holds for bronze. `source_application` stays omitted, as in V0 design §3.3. A heuristic source-app guess may appear **in silver only**, with provenance `heuristic`, and is always displayed as a guess.
3. **V0 design §2 non-goals** ("OCR, transcription, webpage fetching, a server") and **§3.2** ("No transcription") are lifted to the extent described here.
4. **Base spec §7, "Do not wait for a fresh fix in the Share Extension"** still holds. The extension now *requests* a fresh fix when the sheet opens and uses it only if it has arrived by Save. It never waits (§7.2).
5. **Package format §"Store derived (AI) output separately, keyed by `capture_id`"** is implemented here as `enrichments/`, with its own versioned format (§6.1). `docs/package-format.md` gains a pointer to the new `docs/enrichment-format.md`.
6. **Storage adapter contract (base spec §8)** gains list-changes, download and replace-on-write (§6.4). Replace-on-write is allowed **only under `enrichments/`**. `captures/` stays write-once.
7. **Base spec §10 / V0 design §6 ("a new install doesn't rebuild the library from Dropbox")** is unchanged. Two-way sync covers gold enrichment files only.
8. **Base spec §13 ("No analytics or third-party content processing by default")** is lifted for link previews and place names, which default on (Jorge, §14 Q2). They can be switched off per kind in Settings.

## 4. Scope

### 4.1 First batch (this phase)
Confirmed by Jorge as one phase (§14 Q3).

1. **Recorder auto-start** (§7.1).
2. **Fresh location fix on shares** (§7.2), plus **place names** for capture locations (§5.2).
3. **Link previews**, with YouTube first (§5.1).
4. **Screenshot/image OCR** and **data detectors** (§5.3, §5.4).
5. **On-device voice-note transcription** (§5.5).
6. **Photo origin:** place names for embedded photo locations. The taken-at time and coordinates are already in bronze (§5.2).
7. **Source-app guess**, labelled as a guess (§5.6).
8. **Enrichment section in Settings** (§8).
9. **Two-way sync plumbing:** silver upload, gold pull, the adapter contract and the `FilesystemAdapter` implementation (§6).

Order of sources by Jorge's priority: YouTube, then browser links, screenshots, iMessage, WhatsApp. iOS doesn't tell a Share Extension the sender or the chat, so iMessage and WhatsApp captures get OCR, data detectors and the app guess, but not sender or chat.

### 4.2 Later batch (not this phase)
Motion activity at capture time, and the current calendar event. Also *(my suggestion, not discussed)* PDF text extraction (PDFKit) for search.

## 5. Silver enrichers

Each enricher is independent, has a **kind** name and an integer **version**, and runs at most once per (capture, kind, version). Its result is a **facet** in the capture's silver file (§6.1). An enricher that has nothing to say records `status: "empty"`, not an error. A failure never affects the capture.

| Kind | Applies to | Uses network? |
|---|---|---|
| `link_preview` | captures with URLs | yes (the linked site; YouTube oEmbed) |
| `place` | `capture_location` and each attachment's `media.embedded_location` | yes (Apple Maps) |
| `text_recognition` | image attachments | no |
| `data_detection` | text from notes, shared text, OCR and transcripts | no |
| `transcript` | audio attachments (voice notes and shared audio) | no (on-device model; a one-time model download may be needed) |
| `source_app_guess` | every capture | no |

### 5.1 Link previews (`link_preview`)
- For each URL in `urls` (cap: the first 5), produce: title, site or channel name, a short description if available, the canonical URL, and a thumbnail image saved as a silver asset.
- **YouTube** (`youtube.com/watch`, `youtu.be`, `youtube.com/shorts`, `m.youtube.com`): use the public oEmbed endpoint (`https://www.youtube.com/oembed?url=…&format=json`). It returns title, `author_name` (channel) and `thumbnail_url`; download the thumbnail. No API key is needed. *Builder: verify the endpoint and field names.*
- **Other links:** `LPMetadataProvider` (LinkPresentation). Title and image come from it; site name is the URL host.
- Timeouts are short (about 15 s per URL). There is no JavaScript rendering or scraping beyond what these APIs do. Thumbnails are downscaled (longest side ≤ 640 px, JPEG).
- **Never fetched** *(my call; a plain GET can consume a magic link or trigger an unsubscribe)*. These URLs get `status: "empty"` with a reason code:
  - anything other than `http`/`https`
  - hosts that are IP literals, `localhost`, `.local`, or private/link-local ranges
  - URLs whose path or query looks single-use: a query key such as `token`, `code`, `key`, `sig`, `signature`, `auth`, `otp` or `magic`, or a path containing `unsubscribe`, `login`, `verify`, `reset` or `confirm`

  YouTube oEmbed is exempt from these rules, because it fetches YouTube's endpoint and not the link itself. Keep the rule list as versioned data.

### 5.2 Place names (`place`)
- **Area** (neighbourhood/sub-locality, city, region, country) comes from reverse geocoding. Jorge: "having the name would be nice"; area is the reliable part.
- **Nearest point of interest**, shown as **"near X"**, never as "at X". Use it only when the fix's accuracy is ≤ 100 m and the POI is within 100 m (*my thresholds*). Otherwise show the area only.
- Done separately for the capture location ("where you were") and for each embedded photo location ("where the photo was taken"). Base spec §7 says to keep these separate, and the UI must too.
- APIs: MapKit reverse geocoding (`MKReverseGeocodingRequest`; `CLGeocoder` is deprecated as of iOS 26) and `MKLocalPointsOfInterestRequest` for the POI. *Builder: verify both on the iOS 27 SDK.* Respect Apple's geocoding rate limits. Serialize requests and back off on throttling.
- Coordinates are rounded to 4 decimal places (about 11 m) for the cache key, so nearby captures reuse a result.

### 5.3 Text recognition (`text_recognition`)
- Runs Vision text recognition (accurate level, automatic language detection, language correction on) on **every image attachment**, not only screenshots. *My call:* screenshots can't be told apart reliably, and photos of signs, receipts and whiteboards benefit too. Skip images under 32 px on a side, and downscale very large ones before recognition.
- Output: the full recognized text (lines in reading order) and the detected language(s). Bounding boxes are not stored.

### 5.4 Data detectors (`data_detection`)
- `NSDataDetector` over user note, shared text, typed-note body, OCR text and transcript. It finds dates, phone numbers, postal addresses and links.
- Each hit records its type, the matched text, the normalized value (ISO date, E.164-ish phone where parseable, URL) and which **source** it came from (`user_note`, `shared_text`, `note_body`, `text_recognition:<attachment-id>`, `transcript:<attachment-id>`).
- It reruns automatically whenever an input it reads changes (for example after a transcript lands). Treat it as depending on the other facets' versions.
- Dates found in text are shown as found. Hippo never assigns them a time zone they didn't state (base spec §7 spirit).

### 5.5 Transcript (`transcript`)
- On-device speech-to-text for audio attachments, with the Speech framework's on-device `SpeechAnalyzer`/`SpeechTranscriber` (iOS 26+). Nothing is sent to a server. If the on-device model for the language isn't installed, request the asset download via the framework and retry later. Never fall back to server recognition.
- Output: the full text, the locale used, and segment timings (start/end seconds per segment) so a future UI can seek.
- **Language: English only** (§14 Q1).
- Long audio: process in the background task budget. It must be resumable or restartable. A transcript is written only when complete. Audio longer than 60 minutes is skipped with `status: "empty"` and a reason code *(my call)*.

### 5.6 Source-app guess (`source_app_guess`)
- Inputs: bronze `metadata_observations` (registered type identifiers, `suggestedName`, allowlisted `userInfo` keys), URL hosts, and filename patterns (for example `WhatsApp Image …`, `IMG_…`, screenshot naming).
- Output: a guessed app name and a short machine-readable **reason** (for example `uti:net.whatsapp.image`, `host:youtube.com`). Provenance is always `heuristic`.
- Shown as "Probably from WhatsApp", never as "From WhatsApp". No guess means nothing is shown.
- The rule table is data inside the enricher. Start with YouTube, Safari/browsers, Photos/screenshots, Messages, WhatsApp. Version the table: a new table version reruns the guess.

## 6. Storage, format and sync

### 6.1 Enrichment file format (`enrichment-v1`)
One JSON file per capture per layer, plus optional binary assets. Document it in `docs/enrichment-format.md` with a JSON Schema (`schema/enrichment-v1.schema.json`) and fixtures, as V0 did for packages. **The server will write gold in this same format**, so the doc is written for a server author too.

```text
enrichments/<layer>/YYYY/MM/DD/<capture-id>/
  enrichment.json
  assets/<sha256>.<ext>        (thumbnails etc.; content-addressed)
```
- `<layer>` is `device` (silver) or `server` (gold). `YYYY/MM/DD/<capture-id>` mirrors the package's directory, so a reader finds both from the same key. *(My call.)*
- `enrichment.json` fields: `schema_version` (1), `capture_id`, `layer`, `package_digest` (the SHA-256 of the bronze `complete.json` it was derived from), `producer` `{name, version, build}`, `generated_at` (RFC 3339 UTC), and `facets`. `facets` is an object keyed by kind. Each facet is `{version, status: ok|empty|failed, generated_at, provenance, data}`.
- Assets are referenced from `data` as `{relative_path, byte_count, sha256, mime_type}`. They are uploaded **before** `enrichment.json` (the same marker idea as `complete.json`). A reader trusts an asset only if its size and hash match.
- Content-addressed asset names mean replacing `enrichment.json` never breaks a reference mid-sync. Orphaned assets are harmless. Clean-up is deferred.
- Conventions follow package-format.md: the omission rule, open sets for kinds and provenance, unknown keys ignored, and an unsupported `schema_version` rejected.
- **Items inside a facet are keyed**, so gold can cover part of a facet:
  - `link_preview`: by URL
  - `text_recognition` and `transcript`: by attachment ID
  - `place`: by target (`capture` or an attachment ID)
  - other kinds: a single item
- **Override rule** *(my call; written into enrichment-format.md for the server author)*: resolution is per item, and field by field within an item. A gold item's field wins only when the gold facet's status is `ok` and the field is present. Otherwise the silver field shows, then bronze. A gold facet that is `empty` or `failed` never hides silver. Example: gold supplies only a better title for one URL, and silver's thumbnail and channel still show.
- Gold may contain **any** facet kind. The phone renders the kinds it knows (§9) plus two gold-only kinds defined now so the server has a target: `summary` (`{text}`) and `tags` (`{values: [string]}`). Unknown kinds are kept and ignored.

### 6.2 Local storage
- Silver and gold live **outside** packages, under the store root: `Library/Application Support/Hippo/enrichments/{device,server}/<capture-id>/` (`enrichment.json` + `assets/`). Locally the directory is keyed **by capture ID only**, with no date shards *(my call)*. The remote path is derived at upload time from the capture's package `relative_directory`. Gold pull maps a remote path back to a capture ID from its last path segment.
- Writes are atomic: write to staging, then rename.
- SQLite (migration v3) tracks enrichment work: per (capture, kind) the version, status, attempt count, next attempt time and last error code. It also tracks per-capture silver upload jobs and the per-destination gold cursor. *Table shapes are the builder's call.*
- **Local delete** (`HippoStore.delete`) also deletes the capture's local silver and gold and their rows. As in V0, remote copies are never touched.
- `recover()` also sweeps enrichment staging leftovers and orphaned enrichment dirs with no capture.

### 6.3 Silver upload
- Silver for a capture uploads to **each destination its package job is bound to** (normally one), and to each one only **after that destination's package job is `synced`**. The server therefore never sees enrichment without its capture. Unassigned captures keep silver local until they are bound (V0 design §3.6).
- A new silver version (any facet changed) re-uploads with replace-on-write: assets first, then `enrichment.json`. Coalesce: if silver changes again while an upload is pending, upload only the latest.
- Silver upload state is **not** shown in the timeline sync dot. The dot keeps meaning "the capture package is safe". Silver failures go to diagnostics only. *(My call.)*
- Silver uploads use the existing worker, leases, retry policy and cancellation rules, including the 2 s expiry-grace cancellation requirement carried into Plan 3.

### 6.4 Adapter contract additions
Add to `StorageAdapter` (exact Swift shapes are the builder's call):
- **`replaceFile(localURL:relativePath:expected:)`**: overwrites atomically. It **must reject** any path not under `enrichments/` with `permanent(code: "replace_not_allowed")`. The returned evidence is verified like an upload.
- **`listChanges(under prefix:cursor:)`** returns `(changes: [added/modified(path, byteCount, providerHash) | deleted(path)], nextCursor, hasMore)`. A nil cursor means a full listing. An expired cursor raises a distinct error (`cursorReset`), and the caller relists from nil.
- **`downloadFile(relativePath:to localURL:maxBytes:)`** writes to a local temp file and returns its byte count and the provider hash. It enforces `maxBytes`.
- `FilesystemAdapter` implements all three. Its cursor may be a snapshot of (path, size, mtime) or anything else that satisfies the contract tests. The shared `AdapterContract` tests gain cases for all three, so Dropbox (Plan 3) inherits them.
- **Plan 3 (Dropbox) must implement these:** `files/upload` with `mode: overwrite` under `enrichments/` only, `files/list_folder` (recursive) + `list_folder/continue` with the `reset` error mapped to `cursorReset`, and `files/download`. Needs scope `files.content.read` (already expected). *I'll update the parked-follow-ups note so Plan 3 picks this up.*

### 6.5 Gold pull
- Runs as a step of each sync pass (app activation, BG task, manual), after uploads, against the **active destination** only. Prefix: `enrichments/server/`.
- For each change:
  - Added or modified `enrichment.json` for a capture that **exists locally**: download to staging, validate (schema version, `capture_id` matches the path, safe paths, size cap), then download any referenced assets not already present locally and verify their hashes. Then atomically replace the local gold for that capture and refresh its search text.
  - A change for a capture **not in the local index** (deleted on this phone, or never here): ignored. Nothing is stored. Jorge's rule.
  - Deleted `enrichment.json`: remove the local gold for that capture.
  - Asset files are fetched only when referenced; changes to them alone are otherwise ignored.
- Persist the cursor per destination **after** applying a page, so a crash re-applies at most one page (idempotent by content).
- Caps *(my call)*: `enrichment.json` ≤ 1 MB, each asset ≤ 5 MB, at most 200 files per pass. Over-cap files are skipped with a diagnostics code.
- Gold whose `package_digest` doesn't match the local package is still shown. Packages are immutable, so a mismatch means a server bug: log a diagnostics code.

## 7. Capture tweaks

### 7.1 Recorder: one tap
Tapping **● Record** in the timeline opens the recorder **already recording**. Today the recorder sheet needs a second tap. On first use the microphone permission prompt appears first; granting starts recording, denying shows the existing denied state. Stop, Save, Discard, interruption handling and Cancel-confirm are unchanged. Update acceptance row 16 and the UI test.

### 7.2 Fresh fix on shares
- The Share Extension calls the equivalent of `beginSessionFix()` when the sheet loads. The app's Note and Recorder already do this. `LocationPolicy.pick` already prefers the newer of a session fix and last-known.
- **Never wait.** Save uses whatever is available at that moment. The location toggle stays **off by default**, and nothing changes when it's off.
- Whether a Share Extension can get a fix with the app's when-in-use authorization must be checked on the device (base spec §7). If it can't, last-known remains. If neither works, there is no location. The acceptance row (§11) records the finding.

## 8. Settings: "Enrichment" section
A new section below the location setting. It has one switch per kind, in plain words, with a footer saying what leaves the phone:
- **Link previews** ("Fetches the page title and picture from the website")
- **Place names** ("Looks up place names with Apple Maps")
- **Text in images**
- **Voice note transcripts**
- **Dates, phone numbers and addresses**
- **App guesses**

Defaults: all **on** (Jorge, §14 Q2). Place names need a location, so they do nothing for capture locations while location saving is off; they still name embedded photo locations. Settings are stored in App Group defaults like `locationEnabled`.

Switch behaviour *(my calls)*:
- Turning a kind **on** backfills existing captures, newest first, in the background.
- Turning it **off** stops new work. Existing results stay, locally and in Dropbox, and are still shown.
- Gold pull has **no switch**. It's on whenever a destination is connected. Gold is Jorge's own server writing to his own folder.

## 9. UI

Rule: per facet, show **gold, then silver, then raw bronze**. Gold overrides silver kind by kind, not as a whole file. When nothing exists, show what V0 shows today. Missing values are omitted, never shown as "Unknown" (V0 design §3.4).

- **Timeline rows**
  - Link rows: the preview title (instead of the raw shared title/URL) plus the site or channel, and a small thumbnail when there is one.
  - Voice rows: "Voice note · m:ss", plus the first line of the transcript as the subtitle.
  - Image rows: unchanged.
  - Rows don't badge enrichment state.
- **Detail**
  - **Link card:** thumbnail, title, channel/site, description.
  - **Captured → Where:** "Capitol Hill, Seattle · near Victrola Coffee", plus the existing coordinates and accuracy as a secondary line.
  - **Attachments → photo "Taken at" place**, kept separate from capture place.
  - **Transcript** (collapsible), **Text in image** (collapsible, per image, selectable/copyable), **Found in this capture** (dates, phones, addresses, with system actions: add to calendar, call, open in Maps), **Summary** and **Tags** when gold has them.
  - "Probably from WhatsApp" appears as a quiet line in Captured.
  - A small provenance hint on gold-sourced content (for example "From your server" in the footnote style) *(my call)*.
- **Search:** the timeline search matches OCR text, transcripts, link titles/descriptions/channels, place names, summaries and tags. FTS5 can't add columns, so either rebuild `captures_fts` with an extra column in migration v3 or add a second FTS table. The builder picks; search behaviour is what matters. The index is refreshed when silver or gold changes and is rebuildable from packages plus local enrichment files.
- **Visual bar:** unchanged from V0 design §3.4 (quiet native iOS, Dark Mode, Dynamic Type).

## 10. Where and when silver runs
- **In the app only.** The extension never enriches: it's memory-limited and must close fast. Captures saved through the extension are enriched on the next app activation or BG task (Jorge-approved).
- Triggers:
  - right after a save in the app (note, recording)
  - app activation, for anything pending (including extension captures)
  - the existing BG processing task, after sync
  - a Settings switch turned on (backfill)
  - first launch of this version (backfill all existing captures, newest first)
- One enrichment queue per process, with modest concurrency (network kinds and on-device kinds can overlap; transcription one at a time). It honours BG-task expiry the same way sync does.
- Network kinds wait for connectivity rather than burning retries offline. Retries use exponential backoff, at most 5 attempts per (capture, kind, version), then `failed` (diagnostics only). There is no user-facing retry for enrichment in this phase *(my call)*.
- `diagnostics.json` gains enrichment counts by kind and status, gold-pull last result code and cursor age. It contains no content.

## 11. Testing and acceptance
- **HippoKit (macOS `swift test`):** the format encoder/validator with fixtures; the enrichment queue and its state machine with fake enrichers; the adapter contract for replace/list/download against `FilesystemAdapter` (including the `cursorReset` path and rejecting replace outside `enrichments/`); silver upload ordering (only after the package is synced; assets before json); gold pull (ignored for unknown/deleted captures, delete removes local gold, crash between page apply and cursor save); the gold > silver > raw resolution; FTS includes enrichment text; local delete removes enrichments.
- Real Vision OCR and `NSDataDetector` can run on macOS against fixture images and text. The network and Speech enrichers sit behind protocols with fakes. Their real implementations are covered by device acceptance.
- **Gold in the Developer folder:** a small script or `hippo-fixtures` subcommand writes a valid gold `enrichment.json` (with a summary, tags and an overriding link title) into `HippoDevRemote/enrichments/server/…` for a chosen capture ID. Real-device testing then needs no server.
- **New device acceptance rows** in `docs/acceptance.md`:
  - Record starts on one tap.
  - YouTube share shows title, channel and thumbnail.
  - Safari link preview.
  - Screenshot text is searchable.
  - Voice note transcript appears and is searchable.
  - Place name shows "near X" only when accurate.
  - Extension fresh fix (record whether it worked).
  - Gold file in the Developer folder appears after sync and overrides silver.
  - Gold for a deleted capture is ignored.
  - Turning a switch off/on behaves as in §8.
  - Enrichment never delays the share sheet's "✓ Saved".

## 12. Constraints
- Everything in V0 design §4 still applies: no secrets in git, a full staged-diff review before commits, opt-in location, and the extension never waits.
- No new third-party dependencies are expected. Apple frameworks only: Vision, Speech, LinkPresentation, MapKit, Foundation's `NSDataDetector`. Any dependency needs an ADR.
- Enricher code that touches iOS-only frameworks stays in the app target or behind protocols, so HippoKit still builds and tests on macOS.
- Logs stay fixed category strings: no URLs, text, transcripts or coordinates.
- Privacy strings: add the speech-recognition usage description if the chosen Speech API requires it. *Builder: check whether on-device `SpeechAnalyzer` needs authorization.*
- *Builder: verify on device* whether LinkPresentation, MapKit requests and `SpeechAnalyzer` work inside a BG processing task. Any that don't run only while the app is in the foreground. Record the finding in an acceptance row.

## 13. Left to the builder
- Swift types and module placement. A new `Enrichment` target in HippoKit is the likely shape.
- The SQLite schema for enrichment state, upload jobs and cursors. Also the FTS approach (§9).
- `FilesystemAdapter` cursor representation.
- Concurrency limits, timeouts and backoff constants within §10.
- Exact data-detector normalization formats, and the source-app rule table contents beyond the named apps.
- Visual details within §9.
- Recording each such choice in an ADR or the README.

## 14. Decisions after the builder check (Jorge, 2026-11-07)
- **Q1. Transcription language: English only.** Use an English `SpeechTranscriber` locale: the phone's English variant if its language is English, else `en-US`. There's no language picker and no detection. The transcript facet records the locale used.
- **Q2. Network enrichment on by default, with backfill: yes.** This lifts base spec §13's "no third-party content processing by default" for link previews and place names. They stay **controllable per kind in Settings** (§8); Jorge's wording was "bronze enrichment controllable through settings", read here as the on-device enrichment switches. The never-fetch rules in §5.1 apply.
- **Q3. First batch in §4.1: confirmed as one phase.**
- Design approved 2026-11-07 ("go ahead and implement it").
