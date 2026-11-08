# Hippo Enrichment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add on-device (silver) enrichment, two-way sync of enrichment files (silver up, gold down) and two capture tweaks: Record starts on one tap, and shares request a fresh location fix.

**Architecture:**
- **Format and paths:** the enrichment file format, its typed facet payloads and the path rules go in `CaptureCore`, next to the package format.
- **Local state:** local enrichment files plus the task/upload/cursor tables live in `LocalRepository`, so `HippoStore` can delete and recover them.
- **Enrichers and runner:** a new Mac-testable `Enrichment` target holds the enricher protocol, the runner and every enricher whose core logic doesn't need iOS-only frameworks. Link metadata, place lookup and transcription are reached through protocols, and the app supplies the LinkPresentation, MapKit and Speech implementations.
- **Sync:** silver upload and gold pull are two new `SyncEngine` steps that `SyncCoordinator` runs after package uploads.
- **Presentation:** `HippoPresentation` resolves gold over silver over bronze for the timeline and Detail.

**Tech Stack:** Swift 6 language mode, Swift Testing, SQLite FTS5, Vision (`RecognizeTextRequest`), Foundation `NSDataDetector`, ImageIO, URLSession (HippoKit). LinkPresentation, MapKit, Speech (`SpeechAnalyzer`/`SpeechTranscriber`), EventKitUI, Network (`NWPathMonitor`) (App). XcodeGen, Xcode 27.2.

**Spec:** `docs/superpowers/specs/2026-11-07-hippo-enrichment-design.md` (wins on conflict), on top of `docs/superpowers/specs/2026-11-07-hippo-v0-design.md` and `hippo-v0-spec.md`. Executors read the enrichment design in full; section numbers below (§n) refer to it.

**Branch:** `feat/enrichment` (already checked out; stacked on `feat/hippo-app`).

## Plan-level calls (deviations and decisions the design left open)
- **No leases for enrichment work or silver uploads.** Only the app process runs them: the extension never syncs or enriches, and each one is serialized by its own actor. Design §6.3 said "uses the existing worker, leases…"; this keeps the retry policy and cancellation rules but drops leases.
- **The runner is sequential:** one task at a time. That meets §10's "modest concurrency" in its simplest form.
- **Search:** `captures_fts` is rebuilt in migration v3 with one extra column, `enrichment`. Multi-word searches still AND across all fields.
- **POI for photos:** "near X" is used for the capture location only. Embedded photo locations have no accuracy, so they get the area only.
- **Gold pass cap:** the 200-file cap is soft. The puller stops fetching new pages once it has processed 200 changes in this pass.
- **Developer-folder gold:** sample gold is written by a DEBUG-only Settings button, not from the Mac. `devicectl` can't reliably write into the App Group.
- **Remote layout:** remote paths come from the package's `relative_directory`.
  - `captures/2026/11/07/<id>` → `enrichments/device/2026/11/07/<id>/enrichment.json`
  - Assets go under `…/<id>/assets/<sha256>.<ext>`.

## Global Constraints
- iOS 27.0 / macOS 27.0, Swift 6 language mode, no third-party dependencies (§12).
- HippoKit targets import no UIKit, AppKit, SwiftUI, MapKit, LinkPresentation or Speech, and stay `swift test`-able on macOS. Vision, ImageIO, CoreGraphics, CoreText and Foundation are fine.
- Bronze is never modified. `metadata.json`, `complete.json` and attachments are byte-for-byte unchanged by anything in this plan.
- `replaceFile` is allowed only for paths under `enrichments/`; `captures/` stays write-once (§3 item 6).
- **One writer per layer:** the phone writes only `enrichments/device/`, and only reads `enrichments/server/`.
- Never fetched (§5.1):
  - non-`http(s)` schemes;
  - IP-literal, `localhost`, `.local`, private or link-local hosts;
  - query keys `token`, `code`, `key`, `sig`, `signature`, `auth`, `otp`, `magic` (case-insensitive);
  - path segments containing `unsubscribe`, `login`, `verify`, `reset`, `confirm` (case-insensitive).
- Transcription is English only: the phone's locale if its language is English, else `en_US`. It runs on device only and never falls back to server recognition (§5.5, §14).
- The source-app guess is shown only as "Probably from <App>". The POI is shown only as "near <Name>".
- Caps:
  - Gold `enrichment.json` ≤ 1,048,576 bytes; gold asset ≤ 5,242,880 bytes; 200 gold changes per pass (soft).
  - First 5 URLs per capture.
  - Link timeout 15 s.
  - Thumbnail longest side ≤ 640 px, JPEG.
  - Audio > 3600 s is skipped.
  - Enrichment attempts max 5.
  - POI only when accuracy ≤ 100 m and distance ≤ 100 m.
  - Geocode cache key rounds coordinates to 4 decimals.
- Settings copy (§8), exact:
  - section header "Enrichment"
  - switches "Link previews", "Place names", "Text in images", "Voice note transcripts", "Dates, phone numbers and addresses", "App guesses"
  - footer "Link previews fetch the page title and picture from the website. Place names are looked up with Apple Maps. Everything else runs on this iPhone."
  - Defaults: all on.
- Logs use fixed category strings only: no URLs, text, transcripts, coordinates, IDs or paths (§12). Diagnostics stay content-free.
- The UI follows V0 design §3.4. Missing values are omitted, never "Unknown".
- Commit after every task. Before each commit, run `git diff --cached` and read all of it for secrets (Jorge's global rule).
- App build check (used by the App tasks): `xcodegen generate && xcodebuild -project Hippo.xcodeproj -scheme Hippo -configuration Debug -destination generic/platform=iOS -derivedDataPath build/DerivedData -allowProvisioningUpdates build`. Expected: `** BUILD SUCCEEDED **`.

## Review Focus
1. **A capture deleted while its enrichment runs, or while gold for it arrives:** nothing reappears, nothing crashes, and no orphan files are left. → Task 5 `deletedMidRunDropsResult`, Task 4 `deleteRemovesLocalEnrichments`, Task 10 `goldForUnknownCaptureIgnored`.
2. **Offline (airplane mode) with a backlog:** network kinds wait without using up attempts, and on-device kinds still run. → Task 5 `offlineDefersNetworkKindsWithoutAttempts`.
3. **Malformed or hostile gold** (wrong schema version, an asset path with `..`, an oversize file, a mismatched `capture_id`): skipped with a diagnostics code, the cursor still advances, nothing else is touched. → Task 10 `goldUnsafeAssetPathSkipped`, `goldOverCapSkipped`, `goldWrongCaptureSkipped`, `goldBadVersionSkipped`.
4. **One-time links** (unsubscribe, magic login, password reset, `?token=`): never fetched. → Task 7 `linkPolicyTable`.
5. **Background time expiring mid-enrichment or mid-upload:** no half-written local documents, no stuck rows, and work resumes next time. → Task 4 `writeIsAtomicAndSweepsStaging`, Task 5 `cancellationLeavesTaskPending`, Task 9 `cancelBeforeDocumentLeavesRevisionPending`.

---

## File Structure

```
HippoKit/
  Package.swift                                      + Enrichment library/target, EnrichmentTests            (Task 5)
  Sources/CaptureCore/Enrichment/
    EnrichmentDocument.swift   EnrichmentLayer, FacetKind, FacetStatus, Facet, AssetRef, EnrichmentProducer,
                               EnrichmentDocument, EnrichmentJSON                                               (Task 2)
    FacetData.swift            typed facet payloads                                                             (Task 2)
    EnrichmentPaths.swift      local/remote path rules                                                          (Task 2)
    EnrichmentSearchText.swift searchable text from documents                                                   (Task 4)
  Sources/CaptureCore/Package/StoreLayout.swift      + enrichment dirs                                          (Task 4)
  Sources/SyncEngine/StorageAdapter.swift            + replaceFile, listChanges, downloadFile                   (Task 3)
  Sources/FilesystemAdapter/FilesystemAdapter.swift  + the three methods                                        (Task 3)
  Sources/LocalRepository/SQLite/Migrations.swift    + v3                                                       (Task 4)
  Sources/LocalRepository/Enrichment/
    EnrichmentStore.swift       local documents, assets, FTS, revisions, uploads, gold cursor                   (Task 4)
    EnrichmentTaskStore.swift   per (capture, kind) work rows                                                   (Task 4)
  Sources/LocalRepository/CaptureIndex.swift         + packageDigest, FTS column                                (Task 4)
  Sources/LocalRepository/Diagnostics.swift          + enrichment section                                       (Task 10)
  Sources/SyncEngine/HippoStore.swift                + enrichments, delete/recover, factories                   (Task 4, 9, 10)
  Sources/SyncEngine/EnrichmentUploader.swift                                                                   (Task 9)
  Sources/SyncEngine/GoldPuller.swift                                                                           (Task 10)
  Sources/Enrichment/
    Enricher.swift              Enricher, EnricherInput, EnricherOutput, EnrichmentError                        (Task 5)
    EnrichmentRunner.swift                                                                                      (Task 5)
    DataDetectionEnricher.swift SourceAppGuessEnricher.swift TextRecognitionEnricher.swift                      (Task 6)
    LinkFetchPolicy.swift YouTubeOEmbed.swift HTTPFetching.swift ThumbnailEncoder.swift LinkPreviewEnricher.swift (Task 7)
    PlaceEnricher.swift                                                                                         (Task 7)
    TranscriptEnricher.swift                                                                                    (Task 8)
  Sources/HippoPresentation/Enrichment/ResolvedEnrichment.swift PlaceText.swift GoldSample.swift                (Task 11, 12)
  Sources/HippoPresentation/Timeline/TimelineRow.swift TimelineModel.swift                                      (Task 11)
  Sources/HippoPresentation/Detail/CaptureDetail.swift CaptureDetailModel.swift                                 (Task 11)
  Sources/HippoPresentation/Settings/AppSettings.swift SettingsModel.swift SyncCoordinator.swift                (Task 9, 12)
  Sources/hippo-fixtures/main.swift                  + `enrichments` subcommand                                 (Task 2)
schema/enrichment-v1.schema.json  docs/enrichment-format.md  fixtures/packages/enrichments/…                     (Task 2)
scripts/validate-fixtures.sh                                                                                    (Task 2)
App/
  Hippo/Capture/RecorderView.swift  HippoShare/ShareViewController.swift                                        (Task 1)
  Hippo/Enrichment/LinkPresentationFetcher.swift MapKitPlaceLookup.swift SpeechTranscriberService.swift
                   EnrichmentScheduling.swift                                                                   (Task 13)
  Shared/AppEnvironment.swift  Hippo/HippoApp.swift  Hippo/Settings/SyncScheduling.swift                        (Task 13)
  Hippo/Settings/SettingsView.swift DevFolderProvider.swift                                                     (Task 14)
  Hippo/Detail/CaptureDetailView.swift EnrichmentSections.swift  Hippo/Timeline/TimelineRowView.swift           (Task 14)
project.yml                                                                                                     (Task 13)
docs/acceptance.md  README.md  docs/package-format.md                                                           (Task 15)
```

---

### Task 1: Capture tweaks: one-tap Record, fresh fix on shares (§7)

**Files:**
- Modify: `App/Hippo/Capture/RecorderView.swift`, `App/HippoShare/ShareViewController.swift`, `App/HippoUITests/CaptureFlowUITests.swift`, `docs/acceptance.md` (row 16 steps)

**Interfaces:** none new.

- [ ] **Step 1:** In `RecorderView`, start recording when the sheet appears. Add `.task { await model.start() }`, which runs once per presentation. It sits next to the existing `.onAppear { location.beginSessionFix() }`. `RecorderModel.start()` already handles the permission prompt, the denied state and double calls. Keep the record button for restarting from `.idle`/`.denied`/`.failed`.
- [ ] **Step 2:** In `ShareViewController.viewDidLoad`, in the `.success` branch, call `LocationService.shared.beginSessionFix()` before building the model. It must not await anything. Update the class doc comment to read: "requests a fresh fix but never waits for it".
- [ ] **Step 3:** In `CaptureFlowUITests`, add `testRecordStartsImmediately`. It launches with `-HippoResetStore YES`, taps the "Record" toolbar button and asserts that the "Stop" button exists within 5 s. Skip it when `XCTSkipUnless` finds that microphone permission can't be pre-granted. UI tests are simulator-only, as documented.
- [ ] **Step 4:** Update `docs/acceptance.md` row 16 steps: "Tap Record (recording starts at once), speak, Stop, Save."
- [ ] **Step 5:** Run the App build check. Expected: `** BUILD SUCCEEDED **`. Run `make test`. Expected: all pass.
- [ ] **Step 6:** Commit `feat(app): record starts on one tap; share sheet requests a fresh location fix`.

### Task 2: Enrichment format v1 (§6.1)

**Files:**
- Create: `HippoKit/Sources/CaptureCore/Enrichment/EnrichmentDocument.swift`, `FacetData.swift`, `EnrichmentPaths.swift`, `schema/enrichment-v1.schema.json`, `docs/enrichment-format.md`
- Modify: `HippoKit/Sources/hippo-fixtures/main.swift`, `scripts/validate-fixtures.sh`, `fixtures/README.md`
- Test: `HippoKit/Tests/CaptureCoreTests/EnrichmentFormatTests.swift`

**Interfaces:**
- Produces (all `public`, `Sendable`, `Equatable`, `Codable` with snake_case keys, nil optionals omitted, encoded via `HippoJSON.encode`):
  - `enum EnrichmentLayer: String { case device, server }`
  - `struct FacetKind` (an open set, built exactly like `CaptureMethod` in `OpenEnums.swift`, and `Hashable`). Constants:
    - `.linkPreview` "link_preview"
    - `.place` "place"
    - `.textRecognition` "text_recognition"
    - `.dataDetection` "data_detection"
    - `.transcript` "transcript"
    - `.sourceAppGuess` "source_app_guess"
    - `.summary` "summary"
    - `.tags` "tags"
  - `struct FacetStatus` (open set): `.ok`, `.empty`, `.failed`.
  - `struct AssetRef { relativePath, byteCount: Int64, sha256, mimeType: String? }`
  - `struct EnrichmentProducer { name, version, build }`
  - `struct Facet { version: Int; status: FacetStatus; generatedAt: Date; provenance: String; data: JSONValue? }` with `func decodeData<T: Decodable>(_ type: T.Type) -> T?` (nil when data is absent or doesn't decode).
  - `struct EnrichmentDocument { schemaVersion: Int; captureID; layer; packageDigest; producer; generatedAt: Date; facets: [String: Facet] }` with:
    - `subscript(kind: FacetKind) -> Facet?`
    - `func referencedAssets() -> [AssetRef]`: every JSON object anywhere in any facet's `data` that has string `relative_path` and `sha256` and integer `byte_count`, deduplicated by path.
  - `enum EnrichmentJSON`:
    - `static func encode(_ d: EnrichmentDocument) throws -> Data`
    - `static func decode(_ data: Data) throws -> EnrichmentDocument`, which throws:
      - `FormatError.unsupportedSchemaVersion` for `schema_version != 1`;
      - `FormatError.malformed` for a non-lowercase-UUID `capture_id` or a non-64-hex `package_digest`;
      - `FormatError.unsafePath` when any referenced asset fails `EnrichmentPaths.isValidAssetPath`.
  - `FacetData.swift` payloads:
    - `LinkPreviewData { items: [LinkPreviewItem] }`, with `LinkPreviewItem { url, title?, siteName?, channel?, summary? (key "description"), canonicalURL? (key "canonical_url"), thumbnail: AssetRef? }`
    - `PlaceData { items: [PlaceItem] }`, with `PlaceItem { target ("capture" or an attachment ID), subLocality?, locality?, region?, country?, nearby: NearbyPlace? }` and `NearbyPlace { name, distanceMeters: Double }`
    - `TextRecognitionData { items: [RecognizedText] }`, with `RecognizedText { attachmentID, text, languages: [String] }`
    - `TranscriptData { items: [TranscriptItem] }`, with `TranscriptItem { attachmentID, text, locale, segments: [TranscriptSegment] }` and `TranscriptSegment { start: Double, end: Double, text }`
    - `DataDetectionData { items: [Detection] }`, with `Detection { type ("date"|"phone"|"address"|"link"), text, value: String?, components: [String: String]?, source }`
    - `SourceAppGuessData { app, reason }`
    - `SummaryData { text }`
    - `TagsData { values: [String] }`
  - `enum EnrichmentPaths`:
    - `static let documentName = "enrichment.json"`
    - `static func remoteDirectory(_ layer: EnrichmentLayer, packageDirectory: String) throws -> String`. It maps `captures/YYYY/MM/DD/<uuid>` to `enrichments/<layer>/YYYY/MM/DD/<uuid>`, and throws `FormatError.unsafePath` on any other shape.
    - `static func parseRemote(_ path: String) -> RemoteEnrichmentPath?`, where `struct RemoteEnrichmentPath { layer; captureID; directory: String; file: File }` and `enum File { case document, asset(String) }`. It accepts only `enrichments/<layer>/<4d>/<2d>/<2d>/<lowercase uuid>/enrichment.json` or `…/assets/<name>` with a valid asset name.
    - `static func isValidAssetPath(_ p: String) -> Bool`: true only for `assets/<64 lowercase hex>.<1–10 of [a-z0-9]>`.

- [ ] **Step 1: Write failing tests** in `EnrichmentFormatTests`:
  - `roundTripPreservesFacets`: a document with `linkPreview` (one item with a thumbnail AssetRef) and `sourceAppGuess` encodes and decodes equal. Keys appear in snake_case (`"site_name"`, `"canonical_url"`, `"package_digest"`). A nil `title` is absent from the JSON.
  - `unknownKindsAndKeysSurvive`: decoding JSON with facet `"weather": {...}` and a top-level `"extra": 1` keeps `facets["weather"]` and doesn't throw.
  - `rejectsOtherSchemaVersion`: `schema_version: 2` throws `FormatError.unsupportedSchemaVersion(2)`.
  - `rejectsUnsafeAssetPath`: thumbnail `relative_path` `"../x.jpg"`, `"assets/abc.jpg"` and `"assets/<64hex>.JPG"` each throw `FormatError.unsafePath`.
  - `referencedAssetsFindsNested`: two items each with a thumbnail. The result has 2 refs, and a duplicate path is counted once.
  - `remoteDirectoryMapping`: `captures/2026/11/07/<uuid>` with `.server` gives `enrichments/server/2026/11/07/<uuid>`. `captures/x` throws.
  - `parseRemoteCases`: a document path parses to `.document`; an asset path parses to `.asset(name)`; `enrichments/server/2026/11/07/<uuid>/other.json`, `enrichments/server/../x` and an uppercase UUID return nil.
  - `decodeDataTyped`: `Facet.decodeData(LinkPreviewData.self)` returns the item. Wrong-shaped data returns nil.
- [ ] **Step 2:** Run `swift test --package-path HippoKit --filter EnrichmentFormatTests`. Expected: FAIL (types not defined).
- [ ] **Step 3:** Implement the three files. Decoding uses the same date strategy as `HippoJSON`. Add `HippoJSON.decoder` access if it is private: a `static func decode<T: Decodable>(_:from:)` made `public` is fine.
- [ ] **Step 4:** Run the filter. Expected: PASS.
- [ ] **Step 5:** Write `schema/enrichment-v1.schema.json` (draft 2020-12) to match. Known facet payloads are typed; unknown facets allow any `data`; `additionalProperties` is true everywhere.
- [ ] **Step 6:** Add `hippo-fixtures enrichments <root>`. It reads `<root>/captures/2026/11/07/00000000-0000-4000-8000-000000000002/complete.json` (the url-only fixture), computes its digest, and writes two documents for that capture:
  - a **device** document with `link_preview` (title "Example Domain", site "example.com", a thumbnail asset from `MediaMaker.imageData(width: 64, height: 36, type: .jpeg)` written to `assets/<sha>.jpg`) and `source_app_guess` (`{app: "Safari", reason: "uti:public.url"}`, provenance `heuristic`);
  - a **server** document with `summary` ("A placeholder page used in documentation examples."), `tags` (["example", "reference"]) and a `link_preview` item for the same URL with only `title` "Example Domain (server)".

  Fixed producer `{name: "hippo-fixtures", version: "1", build: "1"}` and fixed `generated_at` `2026-11-07T18:00:00.000Z`. Run `swift run --package-path HippoKit hippo-fixtures enrichments fixtures/packages`.
- [ ] **Step 7:** Extend `scripts/validate-fixtures.sh` to also validate `fixtures/packages/enrichments/*/*/*/*/*/enrichment.json` against the new schema. Run it. Expected: all valid.
- [ ] **Step 8:** Write `docs/enrichment-format.md` for a server or desktop author. Cover:
  - the layout;
  - the conventions (same as package-format.md);
  - every field and known facet payload;
  - item keys (link by `url`, OCR and transcript by `attachment_id`, place by `target`);
  - **the override rule**, verbatim from §6.1: per item, field by field; gold wins only if its facet status is `ok` and the field is present; `empty`/`failed` gold never hides silver;
  - write order: assets first, `enrichment.json` last;
  - one writer per layer;
  - `package_digest` meaning;
  - caps the phone enforces on gold.

  Add a fixtures table row to `fixtures/README.md`.
- [ ] **Step 9:** Run `make test` (PASS). Commit `feat(core): enrichment format v1 with schema, fixtures and reader docs`.

### Task 3: Adapter contract: replace, list changes, download (§6.4)

**Files:**
- Modify: `HippoKit/Sources/SyncEngine/StorageAdapter.swift`, `HippoKit/Sources/FilesystemAdapter/FilesystemAdapter.swift`, `HippoKit/Tests/AdapterContractTests/AdapterContract.swift`, `HippoKit/Tests/AdapterContractTests/FilesystemAdapterContractTests.swift`, `HippoKit/Tests/SyncEngineTests/Support/SyncHarness.swift` (`HookedAdapter`, `PausingAdapter`), `HippoKit/Tests/HippoPresentationTests/Support/FakeStorageProvider.swift` (`HeldAdapter`)

**Interfaces:**
- Produces:
  - `public enum RemoteChange: Sendable, Equatable { case upserted(RemoteFileInfo), deleted(relativePath: String) }`
  - `public struct ChangePage: Sendable, Equatable { changes: [RemoteChange]; cursor: String; hasMore: Bool }`
  - `StorageError.cursorReset` (new case; `SyncWorker.failure(for:)` maps it to `retryableFailure`, code `"cursor_reset"`).
  - `StorageAdapter` requirements:
    - `func replaceFile(localURL: URL, relativePath: String, expected: FileIntegrity) async throws -> UploadReceipt`: an atomic overwrite. Throws `.permanent(code: "replace_not_allowed")` unless `relativePath` starts with `enrichments/`.
    - `func listChanges(under prefix: String, cursor: String?) async throws -> ChangePage`. A nil cursor returns every file under `prefix` as `.upserted`. A non-nil cursor returns changes since that cursor. An unknown or garbled cursor throws `.cursorReset`. Directories are never reported, and neither are hidden or temporary entries (any segment starting with `.`).
    - `func downloadFile(relativePath: String, to localURL: URL, maxBytes: Int64) async throws -> RemoteFileInfo`. Over `maxBytes` throws `.permanent(code: "too_large")` and leaves no file at `localURL`. A missing file throws `.permanent(code: "not_found")`.
  - `FilesystemAdapter`:
    - The cursor is an opaque string of at most 4 KB. Recommended: a snapshot of `(path, size, mtime)` stored at `<root>/.hippo-cursors/<uuid>.json`, with the UUID as the cursor.
    - It returns a single page (`hasMore == false`).
    - `replaceFile` writes a temp file and then calls `FileManager.replaceItemAt`.
    - `downloadFile` copies the file and returns the sha256 provider hash.

- [ ] **Step 1: Write failing contract tests.** Extend `runAdapterContract` with these checks so any adapter inherits them:
  - `replace`:
    - writing `enrichments/device/2026/11/07/abc/enrichment.json` twice with different bytes leaves the second content (inspect byteCount and hash match the second file);
    - `replaceFile` at `captures/…/x.bin` throws `.permanent(code: "replace_not_allowed")`.
  - `listChanges`:
    - `listChanges(under: "enrichments/server/", cursor: nil)` after uploading two files there and one under `enrichments/device/` returns exactly the two server files, with paths relative to the adapter root;
    - after replacing one and adding a third, listing with the returned cursor reports exactly those two as `.upserted`;
    - listing again with the newest cursor reports no changes;
    - the cursor `"garbage"` throws `.cursorReset`.
  - `download`:
    - a round trip gives the same SHA-256;
    - `maxBytes: 10` on a 1000-byte file throws `too_large` and no file exists at the destination;
    - a missing path throws `not_found`.
- [ ] **Step 2:** In `FilesystemAdapterContractTests`, add the FilesystemAdapter-specific test `deletedFilesAreReported`. It removes a listed file directly from disk, and the next `listChanges` returns `.deleted(relativePath:)` for it.
- [ ] **Step 3:** Run `swift test --package-path HippoKit --filter AdapterContractTests`. Expected: FAIL (methods missing).
- [ ] **Step 4:** Add the protocol requirements and types. Implement them in `FilesystemAdapter`, and forward them in `HookedAdapter`, `PausingAdapter` and `HeldAdapter` to their inner adapter.
- [ ] **Step 5:** Run `make test`. Expected: all pass.
- [ ] **Step 6:** Commit `feat(sync): adapter contract gains replace under enrichments/, list changes and download`.

### Task 4: Local enrichment storage, migration v3, search (§6.2, §9 search)

**Files:**
- Create: `HippoKit/Sources/LocalRepository/Enrichment/EnrichmentStore.swift`, `HippoKit/Sources/LocalRepository/Enrichment/EnrichmentTaskStore.swift`, `HippoKit/Sources/CaptureCore/Enrichment/EnrichmentSearchText.swift`
- Modify: `HippoKit/Sources/LocalRepository/SQLite/Migrations.swift`, `HippoKit/Sources/LocalRepository/CaptureIndex.swift`, `HippoKit/Sources/CaptureCore/Package/StoreLayout.swift`, `HippoKit/Sources/SyncEngine/HippoStore.swift`
- Test: `HippoKit/Tests/LocalRepositoryTests/EnrichmentStoreTests.swift`, `HippoKit/Tests/LocalRepositoryTests/EnrichmentTaskStoreTests.swift`, `HippoKit/Tests/SyncEngineTests/HippoStoreTests.swift` (additions)

**Interfaces:**
- Consumes: Task 2 types.
- Produces:
  - **`StoreLayout`:**
    - `enrichmentsDir` (`root/enrichments`)
    - `enrichmentDirectory(_ layer: EnrichmentLayer, captureID: String) -> URL` (`root/enrichments/<layer>/<captureID>`)
    - `enrichmentStagingDir` (`stagingDir/enrichments`)
  - **`Migrations.currentVersion = 3`**, with v3 SQL exactly:
    ```sql
    ALTER TABLE captures ADD COLUMN device_revision TEXT;
    CREATE TABLE enrichment_tasks(capture_id TEXT NOT NULL REFERENCES captures ON DELETE CASCADE, kind TEXT NOT NULL,
      version INTEGER NOT NULL, status TEXT NOT NULL /* pending|ok|empty|failed|not_applicable */,
      attempt_count INTEGER NOT NULL DEFAULT 0, next_attempt_at_ms INTEGER, last_error_code TEXT,
      updated_at_ms INTEGER NOT NULL, PRIMARY KEY(capture_id, kind));
    CREATE TABLE enrichment_uploads(capture_id TEXT NOT NULL REFERENCES captures ON DELETE CASCADE,
      destination_id TEXT NOT NULL REFERENCES destinations, uploaded_revision TEXT, attempted_revision TEXT,
      blocked INTEGER NOT NULL DEFAULT 0, attempt_count INTEGER NOT NULL DEFAULT 0, next_attempt_at_ms INTEGER,
      last_error_code TEXT, updated_at_ms INTEGER NOT NULL, PRIMARY KEY(capture_id, destination_id));
    CREATE TABLE gold_cursors(destination_id TEXT PRIMARY KEY REFERENCES destinations, cursor TEXT,
      last_result_code TEXT, last_pull_at_ms INTEGER);
    CREATE VIRTUAL TABLE captures_fts_v3 USING fts5(capture_id UNINDEXED, title, user_note, shared_text, urls, filenames,
      enrichment, tokenize='unicode61 remove_diacritics 2');
    INSERT INTO captures_fts_v3(capture_id, title, user_note, shared_text, urls, filenames, enrichment)
      SELECT capture_id, title, user_note, shared_text, urls, filenames, '' FROM captures_fts;
    DROP TABLE captures_fts;
    ALTER TABLE captures_fts_v3 RENAME TO captures_fts;
    ```
  - **`CaptureIndex`:**
    - `register` inserts `enrichment` = `''`.
    - New `func packageDigest(captureID: String) throws -> String?`.
    - `page` search is unchanged in shape and now also matches the `enrichment` column.
  - **`EnrichmentSearchText.make(device: EnrichmentDocument?, server: EnrichmentDocument?) -> String`.** Joined with newlines, in this order: link titles, site names, channels and descriptions; place sub-locality, locality, region, country and nearby name; OCR text; transcript text; summary; tags. It reads both layers' `ok` facets.
  - **`public final class EnrichmentStore: Sendable`**, `init(db: Database, layout: StoreLayout)`:
    - `func document(_ layer: EnrichmentLayer, captureID: String) throws -> EnrichmentDocument?`: nil if absent; throws if unreadable.
    - `func assetURL(_ layer: EnrichmentLayer, captureID: String, asset: AssetRef) -> URL`
    - `func write(_ d: EnrichmentDocument, newAssets: [String: URL]) throws`. The behaviour:
      - Throws `EnrichmentStoreError.notIndexed` if `d.captureID` isn't in `captures`.
      - Every `d.referencedAssets()` entry must come from `newAssets` (keyed by relative path) or already exist in that layer's local directory with a matching sha256. Otherwise it throws `.missingAsset`.
      - It builds the new directory under `enrichmentStagingDir/<uuid>/`, then swaps it into place atomically. Unreferenced old assets are dropped.
      - Then, in one transaction, it sets `captures_fts.enrichment` from `EnrichmentSearchText`. For a device document it also sets `captures.device_revision` to the lowercase SHA-256 of the written `enrichment.json` bytes.
    - `func removeLayer(_ layer: EnrichmentLayer, captureID: String) throws`: removes the files, refreshes the FTS text, and for device clears `device_revision`.
    - `func removeAll(captureID: String) throws`: files only. Rows go with the capture via cascade or `index.remove`.
    - `func sweep() throws -> Int`: removes `enrichmentStagingDir` contents and any `enrichments/<layer>/<id>` directory whose capture isn't indexed. Returns the count.
    - `func uploadCandidates(destinationID: String, now: Date, limit: Int) throws -> [(captureID: String, relativeDirectory: String, revision: String)]`. A capture qualifies when all of these hold: `device_revision` is not null; it has a `synced` job for `destinationID`; there is no upload row, or `uploaded_revision IS NOT device_revision`; it is not (`blocked = 1 AND attempted_revision = device_revision`); and `next_attempt_at_ms` is null or `<= now`. Newest capture first.
    - `func markUploaded(captureID:destinationID:revision:now:)` sets `uploaded_revision` and `attempted_revision`, and clears blocked, attempts and the error.
    - `func markUploadFailed(captureID:destinationID:revision:code:blocked:nextAttemptAt:now:)`
    - `func goldCursor(destinationID:) throws -> String?`, `func saveGoldCursor(destinationID:cursor:now:)` (nil allowed), `func recordGoldResult(destinationID:code:now:)`
  - **`public struct EnrichmentTask: Sendable, Equatable { captureID; kind: FacetKind; version: Int; status: String; attemptCount: Int; nextAttemptAt: Date?; lastErrorCode: String? }`**
  - **`public final class EnrichmentTaskStore: Sendable`**, `init(db: Database)`:
    - `func capturesNeeding(kind: FacetKind, version: Int, limit: Int) throws -> [String]`: captures with no row for `kind`, or a row whose `version != version`. Newest first.
    - `func set(captureID:kind:version:status:now:)`: an upsert that resets attempts, next attempt and error.
    - `func claimNext(kinds: Set<FacetKind>, now: Date) throws -> EnrichmentTask?`: a `pending`, due task whose kind is in `kinds`. Order: newest capture first, then `data_detection` after other kinds of the same capture. It doesn't change state (no leases; see Plan-level calls).
    - `func recordAttempt(captureID:kind:status:errorCode:nextAttemptAt:incrementAttempts:now:)`
    - `func resetToPending(captureID:kind:now:)`: only if a row exists and its status isn't `not_applicable`.
    - `func counts() throws -> [String: [String: Int]]` (kind → status → n)
    - `func hasDueWork(kinds: Set<FacetKind>, now: Date) throws -> Bool`
  - **`HippoStore`:**
    - `public let enrichments: EnrichmentStore` and `public let enrichmentTasks: EnrichmentTaskStore`
    - `delete` calls `enrichments.removeAll(captureID:)` after `index.remove`. Errors are logged as `"delete_enrichment_cleanup_failed"` and not thrown.
    - `recover()` calls `enrichments.sweep()` after the reconciler. Errors are logged, not thrown.

- [ ] **Step 1: Write failing tests:**
  - `migrationV3KeepsSearch` (LocalRepositoryTests): open a v2 database with one registered capture, migrate, and check that a title search still finds it.
  - `writeThenReadDocument`: register a fixture package, write a device doc with one new asset, then read it back equal. The asset file exists at `assetURL` with the right bytes, and `device_revision` equals the SHA-256 of the file.
  - `writeReusesExistingAssets`: a second write that references the same asset with an empty `newAssets` succeeds. A reference to an unknown asset throws `.missingAsset`.
  - `writeForUnindexedCaptureThrows`: `.notIndexed`.
  - `enrichmentTextIsSearchable`: write a server doc with summary "quokka sighting". `index.page(CaptureFilter(searchText: "quokka"), …)` returns the capture. `searchText: "quokka <word-from-title>"` also returns it (AND across columns).
  - `removeLayerClearsSearch`: after `removeLayer(.server, …)`, "quokka" finds nothing.
  - `writeIsAtomicAndSweepsStaging`: leave a fake `enrichmentStagingDir/x/` and a directory for an unindexed capture ID. `sweep()` returns 2 and both are gone. The existing documents are intact.
  - `uploadCandidatesRules`: the table of cases (no synced job → excluded; synced + new revision → included; uploaded same revision → excluded; blocked on the same revision → excluded; blocked then a new revision → included; future `next_attempt` → excluded).
  - `taskStoreClaimOrder` (EnrichmentTaskStoreTests): two captures, each with pending `text_recognition` and `data_detection`. Claims come newest capture first, with `data_detection` after `text_recognition`. Kinds not in the set are never claimed. A future `next_attempt` is not claimed.
  - `capturesNeedingVersionBump`: a row at version 1 is listed for version 2, and not for version 1.
  - `deleteRemovesLocalEnrichments` (HippoStoreTests): a capture with device and server docs. After `delete`, both directories are gone and the task rows are gone (cascade).
- [ ] **Step 2:** Run `swift test --package-path HippoKit --filter "Enrichment|HippoStoreTests|migration"`. Expected: FAIL.
- [ ] **Step 3:** Implement the migration, layout, `EnrichmentSearchText`, `EnrichmentStore`, `EnrichmentTaskStore`, and the `CaptureIndex` and `HippoStore` changes.
- [ ] **Step 4:** Run `make test`. Expected: all pass.
- [ ] **Step 5:** Commit `feat(repo): local enrichment storage, migration v3 and enrichment search`.

### Task 5: Enrichment target and runner (§10)

**Files:**
- Modify: `HippoKit/Package.swift`. Add the library product `Enrichment`, the target `Enrichment` (deps `CaptureCore`, `LocalRepository`), and the test target `EnrichmentTests` (deps `Enrichment`, `CaptureCore`, `LocalRepository`, `SyncEngine`, `HippoTestSupport`).
- Create: `HippoKit/Sources/Enrichment/Enricher.swift`, `HippoKit/Sources/Enrichment/EnrichmentRunner.swift`
- Test: `HippoKit/Tests/EnrichmentTests/EnrichmentRunnerTests.swift`, `HippoKit/Tests/EnrichmentTests/Support/FakeEnricher.swift`

**Interfaces:**
- Consumes: Task 4 stores; `CaptureIndex.metadata`, `packageDigest`, `relativeDirectory`; `CommittedPackage.noteBody()`; `RetryPolicy`.
- Produces:
  - `public struct EnricherInput: Sendable { captureID; metadata: CaptureMetadata; packageURL: URL; noteBody: String?; current: EnrichmentDocument? }`. `current` is the existing device doc.
  - `public struct EnricherOutput: Sendable { status: FacetStatus; data: JSONValue?; provenance: String; newAssets: [String: URL] }`
  - `public enum EnrichmentError: Error, Sendable, Equatable { case deferred(code: String, retryAfter: TimeInterval), transient(code: String), permanent(code: String) }`
  - `public protocol Enricher: Sendable { var kind: FacetKind { get }; var version: Int { get }; var usesNetwork: Bool { get }; var inputs: Set<FacetKind> { get }; func applies(to m: CaptureMetadata) -> Bool; func run(_ input: EnricherInput) async throws -> EnricherOutput }`
  - `public struct EnrichmentPassResult: Sendable, Equatable { ran: Int; failed: Int; idle: Bool }`
  - `public actor EnrichmentRunner`:
    - `init(layout: StoreLayout, index: CaptureIndex, tasks: EnrichmentTaskStore, store: EnrichmentStore, enrichers: [any Enricher], producer: EnrichmentProducer, isEnabled: @escaping @Sendable (FacetKind) -> Bool, isOnline: @escaping @Sendable () -> Bool, policy: RetryPolicy = .init(), now: @escaping @Sendable () -> Date = Date.init, random: @escaping @Sendable () -> Double = { .random(in: 0...1) })`
    - `public static let maxAttempts = 5`
    - `public static let passFinished = Notification.Name("HippoEnrichmentPassFinished")`, posted on the main actor after each `runPending`.
    - `@discardableResult func schedule(limitPerKind: Int = 500) throws -> Int`. For each enabled enricher, for each capture in `capturesNeeding(kind, version)`, it loads the metadata and sets the row to `pending` if `applies`, else `not_applicable`.
    - `func runPending(maxTasks: Int = 50) async -> EnrichmentPassResult`
    - `func hasWork() throws -> Bool`
  - No `HippoStore` factory: SyncEngine must not depend on Enrichment. Callers (tests, the App in Task 13) construct `EnrichmentRunner` from `store.layout`, `store.index`, `store.enrichmentTasks` and `store.enrichments`.

`runPending` rules, per claimed task. Claimed kinds = enabled kinds, minus network kinds when `isOnline()` is false.
1. Load the metadata. If the capture is gone, skip it.
2. Run the enricher.
3. **Success:**
   - Merge `Facet(version, status, generatedAt: now, provenance, data)` into the current device doc, or a new doc with `packageDigest` from the index, the producer, and `layer .device`. Set `generatedAt = now`.
   - Call `store.write(doc, newAssets:)`.
   - Record the task status (`ok`/`empty`).
   - Then, for every enricher whose `inputs` contains this kind, call `resetToPending`, but only if this facet's `data` changed.
   - `notIndexed` from the write means the capture was deleted. Drop the result.
4. **`deferred`:** set `next_attempt = now + retryAfter` without incrementing attempts.
5. **`transient`:** increment attempts. If attempts reach 5, write a `failed` facet (no data) and record `failed`. Otherwise `next_attempt = now + policy.delay(attempt:)`.
6. **`permanent`:** write a `failed` facet and record `failed`.
7. **`CancellationError` or `Task.isCancelled`:** leave the row untouched and return.
8. Delete temp files from `newAssets` after the write. The enricher writes them under `layout.enrichmentStagingDir/tmp-<uuid>/`.

- [ ] **Step 1: Write failing tests**, using a `FakeEnricher` with configurable kind, version, network use, inputs, applies and a scripted results queue, and real captures committed through `HippoStore`:
  - `scheduleMarksApplicability`: a fake that applies only to captures with URLs. After `schedule()`, the url capture has `pending` and the note capture has `not_applicable`.
  - `successWritesFacet`: after `runPending`, the device doc has the facet with status `ok`, its data, version and provenance. The task status is `ok`.
  - `versionBumpReruns`: rerunning with the same kind at version 2 reschedules and runs again.
  - `transientRetriesThenFails`: 5 transient results end with the task `failed` and a `failed` facet. The `next_attempt` values grow.
  - `offlineDefersNetworkKindsWithoutAttempts`: with `isOnline` false, a network fake is never invoked and its `attempt_count` stays 0, while an on-device fake runs. With `isOnline` true, the network fake runs.
  - `deferredDoesNotCountAttempts`: `.deferred(code:"model_missing", retryAfter: 900)` gives attempt count 0 and `next_attempt = now + 900`.
  - `disabledKindNotRun`: `isEnabled` false for the kind means it is never invoked.
  - `inputChangeResetsDependent`: a fake `data_detection` with `inputs: [.textRecognition]` ran first. When `text_recognition` then writes new data, `data_detection` is pending again and reruns.
  - `deletedMidRunDropsResult`: a fake that deletes the capture via `HippoStore.delete` inside `run`. No directory exists afterwards and nothing throws.
  - `cancellationLeavesTaskPending`: a fake that awaits until cancelled. The task is cancelled, and the row is still `pending` with attempt count 0.
- [ ] **Step 2:** Run `swift test --package-path HippoKit --filter EnrichmentRunnerTests`. Expected: FAIL.
- [ ] **Step 3:** Implement it.
- [ ] **Step 4:** Run `make test`. Expected: all pass.
- [ ] **Step 5:** Commit `feat(enrichment): enricher protocol and runner with retries, offline deferral and dependencies`.

### Task 6: On-device text enrichers (§5.3, §5.4, §5.6)

**Files:**
- Create: `HippoKit/Sources/Enrichment/DataDetectionEnricher.swift`, `SourceAppGuessEnricher.swift`, `TextRecognitionEnricher.swift`
- Test: `HippoKit/Tests/EnrichmentTests/DataDetectionEnricherTests.swift`, `SourceAppGuessEnricherTests.swift`, `TextRecognitionEnricherTests.swift`

**Interfaces:**
- Consumes: Task 5 `Enricher`; Task 2 payload types.
- Produces:
  - **`public struct DataDetectionEnricher: Enricher`**: kind `.dataDetection`, version 1, no network, inputs `[.textRecognition, .transcript]`, applies always, provenance `"ns_data_detector"`.
    - Sources and source strings: `user_note`, `shared_text`, `note_body`, `text_recognition:<attachment_id>` and `transcript:<attachment_id>`, the last two taken from `input.current`'s `ok` facets.
    - Types: date, phone, address, link.
    - `value`:
      - Date: if the match has a `timeZone`, an RFC 3339 string with offset. Otherwise wall-clock `yyyy-MM-dd'T'HH:mm:ss` with **no offset**, formatted in the capture's `timezone_identifier`.
      - Phone: the detected number string.
      - Link: the absolute URL string.
    - Addresses: `components` from `addressComponents`.
    - Links equal to any `metadata.urls` entry are dropped. Duplicates (same type, value and source) are dropped.
    - No hits gives status `empty`.
  - **`public struct SourceAppGuessEnricher: Enricher`**: kind `.sourceAppGuess`, version 1, no network, provenance `"heuristic"`, applies when `captureMethod == .shareExtension`.
    - Rules: `static let rules: [Rule]` with `struct Rule { app: String; match: Match; reason: String }` and `enum Match { case typeIdentifierPrefix(String), filenamePrefix(String), host([String]) }`.
    - Match against the `share.registered_type_identifiers` and `share.suggested_names` observations, `attachments[].originalFilename`, and URL hosts (with `www.` and `m.` stripped). The first matching rule wins.
    - Initial table, in order:
      - `net.whatsapp.` → WhatsApp (`uti:net.whatsapp`)
      - filename `WhatsApp ` → WhatsApp (`filename:whatsapp`)
      - `com.apple.mobilesms` / `com.apple.messages` (type ID prefix, case-insensitive) → Messages (`uti:messages`)
      - host `youtube.com`/`youtu.be` → YouTube (`host:youtube`)
      - `com.apple.mobilesafari` (type ID prefix) → Safari (`uti:safari`)
      - filename `IMG_` → Photos (`filename:img`)

      The builder adds rows confirmed on the device (acceptance row E8).
    - No match gives `empty`.
  - **`public struct TextRecognitionEnricher: Enricher`**: kind `.textRecognition`, version 1, no network, provenance `"vision_accurate"`.
    - Applies when any attachment's `UTType(uti)` conforms to `.image`.
    - Uses Vision `RecognizeTextRequest` with `.accurate`, `usesLanguageCorrection = true` and automatic language detection.
    - Skips images under 32 px on a side. Downsamples via ImageIO to a 4096 px longest side before recognition.
    - Lines are joined with `\n` in Vision's order. `languages` come from the observations' detected languages when available, else `[]`.
    - An image with no text has no item. No items at all gives `empty`.

- [ ] **Step 1: Write failing tests:**
  - `detectsPhoneDateAddressWithSources`: user note "Call 415-555-0100 tomorrow"; a `current` doc with OCR text for `att1`, "Meet 12 Dec 2026 at 3pm at 1 Infinite Loop, Cupertino, CA". Expect a phone from `user_note`, a date from `text_recognition:att1` whose value has no offset (`2026-12-12T15:00:00`), and an address with locality "Cupertino".
  - `dateWithZoneKeepsOffset`: "3pm PST on Dec 12 2026" gives a value ending in `-08:00`.
  - `sharedURLNotRepeated`: shared_text containing the metadata URL gives no link detection.
  - `noTextIsEmpty`.
  - `sourceAppGuessTable`: a parameterized test over fixtures for each rule, plus a no-match case (`empty`). `reason` strings are as listed.
  - `ocrReadsRenderedText` (TextRecognitionEnricherTests): render "HIPPO 42" with CoreText into a 600×200 PNG (a helper in the test file). Running gives one item containing "HIPPO" and "42".
  - `ocrSkipsTinyAndTextless`: a 20×20 image and a blank 300×300 image give `empty`.
- [ ] **Step 2:** Run `swift test --package-path HippoKit --filter "DataDetection|SourceAppGuess|TextRecognition"`. Expected: FAIL.
- [ ] **Step 3:** Implement the three enrichers.
- [ ] **Step 4:** Run the filter (PASS), then `make test`.
- [ ] **Step 5:** Commit `feat(enrichment): data detectors, source-app guess and image text recognition`.

### Task 7: Network enrichers: link previews and places (§5.1, §5.2)

**Files:**
- Create: `HippoKit/Sources/Enrichment/LinkFetchPolicy.swift`, `YouTubeOEmbed.swift`, `HTTPFetching.swift`, `ThumbnailEncoder.swift`, `LinkPreviewEnricher.swift`, `PlaceEnricher.swift`
- Test: `HippoKit/Tests/EnrichmentTests/LinkPreviewEnricherTests.swift`, `PlaceEnricherTests.swift`

**Interfaces:**
- Produces:
  - **`public enum LinkFetchDecision: Equatable { case youTube(videoURL: URL), fetch, skip(reason: String) }`** and `public enum LinkFetchPolicy { static func decide(_ url: URL) -> LinkFetchDecision }`.
    - YouTube URLs are checked first: hosts `youtube.com`, `www.youtube.com`, `m.youtube.com`, `youtu.be`, with paths `/watch?v=`, `/shorts/<id>`, or `youtu.be/<id>`.
    - Skip reasons: `"scheme"`, `"private_host"`, `"single_use"`, per the Global Constraints rules.
  - **`public enum YouTubeOEmbed`:**
    - `static func requestURL(for videoURL: URL) -> URL` gives `https://www.youtube.com/oembed?url=<percent-encoded>&format=json`.
    - `static func parse(_ data: Data) -> (title: String?, channel: String?, thumbnailURL: URL?)` reads `title`, `author_name` and `thumbnail_url`.
  - **`public protocol HTTPFetching: Sendable { func get(_ url: URL, timeout: TimeInterval, maxBytes: Int) async throws -> Data }`.** It throws `EnrichmentError.deferred(code: "offline", retryAfter: 60)` for not-connected errors, `.transient` for timeouts and 5xx, and `.permanent` for 4xx. Implemented by `public struct URLSessionHTTPFetcher: HTTPFetching` (ephemeral session, no cookies).
  - **`public struct LinkMetadata: Sendable { title: String?; siteName: String?; summary: String?; imageData: Data? }`** and `public protocol LinkMetadataFetching: Sendable { func metadata(for url: URL, timeout: TimeInterval) async throws -> LinkMetadata }`. The app implements it in Task 13.
  - **`public enum ThumbnailEncoder { static func jpeg(from data: Data, maxPixel: Int = 640) throws -> Data }`** (ImageIO).
  - **`public struct LinkPreviewEnricher: Enricher`**: kind `.linkPreview`, version 1, usesNetwork, provenance `"oembed"` / `"link_presentation"` (the facet uses `"link_presentation"` unless every item came from oEmbed). `init(http: any HTTPFetching, metadata: any LinkMetadataFetching, tempDirectory: URL)`.
    - Applies when `urls` is non-empty.
    - For the first 5 URLs:
      - YouTube: oEmbed with `site_name` "YouTube" and `channel` = `author_name`; the thumbnail is downloaded (max 5 MB) and re-encoded.
      - `fetch`: LinkPresentation, with site name = the host without `www.` and the image re-encoded.
      - `skip`: no item.
    - Each thumbnail becomes an asset `assets/<sha256>.jpg` in `newAssets`.
    - Errors:
      - If every attempted URL failed with `deferred`, rethrow the first `deferred`.
      - Else, if every attempted URL failed, rethrow the first error.
      - Otherwise keep the items that worked.
    - No items gives `empty`.
  - **`public struct PlaceArea: Sendable, Equatable { subLocality: String?; locality: String?; region: String?; country: String? }`** and `public protocol PlaceLookup: Sendable { func area(latitude: Double, longitude: Double) async throws -> PlaceArea?; func nearestPointOfInterest(latitude: Double, longitude: Double, radiusMeters: Double) async throws -> NearbyPlace? }`. The app implements it in Task 13.
  - **`public struct PlaceEnricher: Enricher`**: kind `.place`, version 1, usesNetwork, provenance `"mapkit"`. `init(lookup: any PlaceLookup)`.
    - Targets: `"capture"` for `captureLocation`, and the attachment ID for each `media.embeddedLocation`.
    - Area for every target.
    - `nearby` only for `"capture"`, when `horizontalAccuracyMeters <= 100`; the POI request uses radius 100, and the result is kept only if `distanceMeters <= 100`.
    - An in-process cache (`actor`, keyed by coordinates rounded to 4 decimals) avoids repeat lookups.
    - Errors are aggregated as for links. No targets or no results gives `empty`.

- [ ] **Step 1: Write failing tests** with fakes for `HTTPFetching`, `LinkMetadataFetching` and `PlaceLookup`:
  - `linkPolicyTable`: a parameterized table.
    - `https://www.youtube.com/watch?v=abc` → `.youTube`; `https://youtu.be/abc` → `.youTube`.
    - `https://example.com/a` → `.fetch`.
    - `ftp://x` → `.skip("scheme")`.
    - `http://192.168.1.4/` → `private_host`; also `http://[fe80::1]/`, `http://printer.local/` and `http://localhost:8080/`.
    - `https://x.com/unsubscribe?u=1` → `single_use`; also `https://x.com/a?token=abc`, `https://x.com/a?Sig=1`, `https://x.com/reset-password` and `https://x.com/login/magic`.
    - `https://x.com/codes/list` → `.fetch` (a path containing "code" is fine; only a *query key* `code` is a single-use match).
  - `youTubeUsesOEmbed`: the fake HTTP returns `{"title":"T","author_name":"C","thumbnail_url":"https://i.ytimg.com/x.jpg"}` and JPEG bytes. The result item has title T, channel C, site "YouTube", and a thumbnail asset whose file exists with ≤ 640 px longest side. LinkPresentation is never called.
  - `genericUsesLinkPresentation`: title, siteName from the host, and a thumbnail when imageData is present.
  - `onlyFirstFiveURLs`: 7 URLs give at most 5 fetches.
  - `allOfflineRethrowsDeferred`, `partialFailureKeepsSuccesses`, `allSkippedIsEmpty`.
  - `placeCaptureWithPOIWhenAccurate`: accuracy 30 and a POI at 60 m give `nearby` set. Accuracy 150 gives no `nearby`, and no POI call is made. A POI at 140 m is dropped.
  - `placePhotoAreaOnly`: an embedded location gives an item with target = attachment ID and no `nearby`.
  - `placeCacheReusesNearbyCoordinates`: two targets 5 m apart (the same 4-decimal key) give one area lookup.
- [ ] **Step 2:** Run `swift test --package-path HippoKit --filter "LinkPreview|PlaceEnricher"`. Expected: FAIL.
- [ ] **Step 3:** Implement it.
- [ ] **Step 4:** Run the filter (PASS), then `make test`.
- [ ] **Step 5:** Commit `feat(enrichment): link previews with YouTube oEmbed and fetch safety rules; place names`.

### Task 8: Transcript enricher (§5.5)

**Files:**
- Create: `HippoKit/Sources/Enrichment/TranscriptEnricher.swift`
- Test: `HippoKit/Tests/EnrichmentTests/TranscriptEnricherTests.swift`

**Interfaces:**
- Produces:
  - `public protocol Transcribing: Sendable { func transcribe(fileURL: URL, locale: Locale) async throws -> (text: String, segments: [TranscriptSegment]) }`. It throws `EnrichmentError.deferred(code: "model_missing", retryAfter: 900)` when the on-device model isn't installed yet. The app implements it in Task 13.
  - `public enum TranscriptLocale { static func choose(current: Locale) -> Locale }`: current if its `language.languageCode == .english`, else `Locale(identifier: "en_US")`.
  - `public struct TranscriptEnricher: Enricher`: kind `.transcript`, version 1, no network, provenance `"speech_analyzer"`. `init(transcriber: any Transcribing, locale: Locale)`.
    - Applies when any attachment conforms to `.audio`.
    - Skips attachments with `media.durationSeconds > 3600`.
    - One item per transcribed attachment (`locale` = the identifier used). Text that is empty after trimming gives no item. No items gives `empty`.

- [ ] **Step 1: Write failing tests:**
  - `localeChoice`: `en_GB` → `en_GB`; `es_ES` → `en_US`; `fr` → `en_US`.
  - `transcribesEachAudio`: two audio attachments give two items with segments preserved.
  - `skipsOverAnHour`: duration 3601 → the fake is never called → `empty`.
  - `modelMissingIsDeferred`: the deferred error propagates unchanged.
- [ ] **Step 2:** Run `swift test --package-path HippoKit --filter TranscriptEnricherTests`. Expected: FAIL.
- [ ] **Step 3:** Implement it.
- [ ] **Step 4:** Run the filter (PASS), then `make test`.
- [ ] **Step 5:** Commit `feat(enrichment): on-device English transcript enricher`.

### Task 9: Silver upload (§6.3)

**Files:**
- Create: `HippoKit/Sources/SyncEngine/EnrichmentUploader.swift`
- Modify: `HippoKit/Sources/SyncEngine/HippoStore.swift`, `HippoKit/Sources/HippoPresentation/Settings/SyncCoordinator.swift`
- Test: `HippoKit/Tests/SyncEngineTests/EnrichmentUploaderTests.swift`, `HippoKit/Tests/HippoPresentationTests/` (coordinator addition)

**Interfaces:**
- Consumes: Task 3 adapter methods; Task 4 `uploadCandidates`, `markUploaded`, `markUploadFailed`, `document`, `assetURL`; `EnrichmentPaths.remoteDirectory`.
- Produces:
  - `public final class EnrichmentUploader: Sendable`:
    - `init(layout: StoreLayout, destinations: DestinationStore, enrichments: EnrichmentStore, adapterFor: @escaping @Sendable (Destination) throws -> any StorageAdapter, policy: RetryPolicy = .init(), now: …, random: …)`
    - `func runOnce(maxCaptures: Int = 20) async -> SyncPassResult`
  - `HippoStore.makeEnrichmentUploader(adapterFor:) -> EnrichmentUploader`
  - `SyncCoordinator.runPass` calls `uploader.runOnce()` after the package rounds, unless cancelled, before writing diagnostics. Package results alone drive follow-ups.

Per candidate, using the **active** destination only:
1. Compute `remoteDir`.
2. Call `ensureContainer(remoteDir)`, and `remoteDir + "/assets"` when there are assets.
3. For each asset: `inspectFile`, then `verify` against the local file. If the remote file matches, skip it. If it is absent, call `uploadFile` with a nil checkpoint and a `saveCheckpoint` that calls `Task.checkCancellation()`. A conflict marks it blocked with `"remote_conflict"`.
4. Re-read the local doc. If its revision changed since selection, stop: the next pass handles it.
5. `replaceFile(enrichment.json)`, then `inspectFile` + `verify`, then `markUploaded`.

Error mapping is the same as `SyncWorker.failure(for:)`: blocked for permanent, quota and conflict; retry with `policy.delay` otherwise. `needsAuthentication` stops the pass without counting. `CancellationError` returns at once without recording anything.

- [ ] **Step 1: Write failing tests** using `SyncHarness` with a `FilesystemAdapter` remote:
  - `uploadsOnlyAfterPackageSynced`: before the package job is synced, nothing is under `enrichments/`. After the worker syncs it and the uploader runs, `enrichments/device/2026/…/<id>/enrichment.json` and its asset exist with the local bytes.
  - `assetsBeforeDocument`: a `HookedAdapter` records the order. The asset upload comes before the `enrichment.json` replace.
  - `newRevisionReplacesRemote`: write a new device doc locally, run again, and the remote JSON equals the new bytes.
  - `unchangedRevisionNotReuploaded`: a second run makes no adapter writes.
  - `failureBacksOff`: a transient fault records `next_attempt` in the future, and the capture isn't retried before then.
  - `cancelBeforeDocumentLeavesRevisionPending`: cancel after the asset upload. The remote has no `enrichment.json`, and `uploadCandidates` still lists the capture.
  - `inactiveDestinationSkipped`.
- [ ] **Step 2:** Run `swift test --package-path HippoKit --filter EnrichmentUploaderTests`. Expected: FAIL.
- [ ] **Step 3:** Implement the uploader, the factory and the coordinator call.
- [ ] **Step 4:** Run `make test`. Expected: all pass, including the existing coordinator tests.
- [ ] **Step 5:** Commit `feat(sync): upload silver enrichment after the package is synced`.

### Task 10: Gold pull and diagnostics (§6.5, §10)

**Files:**
- Create: `HippoKit/Sources/SyncEngine/GoldPuller.swift`
- Modify: `HippoKit/Sources/SyncEngine/HippoStore.swift`, `HippoKit/Sources/HippoPresentation/Settings/SyncCoordinator.swift`, `HippoKit/Sources/LocalRepository/Diagnostics.swift`
- Test: `HippoKit/Tests/SyncEngineTests/GoldPullerTests.swift`, `HippoKit/Tests/LocalRepositoryTests/` (diagnostics test additions)

**Interfaces:**
- Produces:
  - `public struct GoldPullResult: Sendable, Equatable { applied: Int; removed: Int; ignored: Int; skipped: Int; code: String? }`
  - `public final class GoldPuller: Sendable`:
    - `public static let prefix = "enrichments/server/"`
    - `maxDocumentBytes: Int64 = 1_048_576`, `maxAssetBytes: Int64 = 5_242_880`, `softChangeLimit = 200`
    - `init(layout:, index: CaptureIndex, destinations: DestinationStore, enrichments: EnrichmentStore, adapterFor:, now:)`
    - `func pull() async -> GoldPullResult`
  - `HippoStore.makeGoldPuller(adapterFor:) -> GoldPuller`
  - `SyncCoordinator.runPass` calls `puller.pull()` after the uploader, unless cancelled.
  - Diagnostics gains:
    - `enrichment_tasks` (kind → status → n)
    - `enrichment_uploads_pending` (count of upload candidates for the active destination)
    - `gold` `{last_result_code, last_pull_age_seconds}`

`pull()` rules:
- Active destination only; none gives a zero result.
- `listChanges(prefix, cursor)`. A `cursorReset` restarts once from nil.
- For each change, `EnrichmentPaths.parseRemote`: nil or `.asset` → ignored; layer not `.server` → ignored; capture not indexed → ignored.
- Upserted document:
  - Over the size cap → skipped, code `gold_too_large`.
  - Download to `stagingDir/gold-<uuid>/`. `EnrichmentJSON.decode` failure → skipped, `gold_invalid` (or `gold_unsupported_version`). `captureID` or `layer` mismatch → skipped, `gold_mismatch`.
  - For each referenced asset: reuse the local server-layer asset if its sha matches, else download `<dir>/<asset path>` capped at `maxAssetBytes` and check the SHA-256 locally. A mismatch, missing file or over-cap asset → skipped, `gold_asset_invalid`.
  - Then `enrichments.write(doc, newAssets:)`. If `doc.packageDigest != index.packageDigest`, apply anyway and set code `gold_digest_mismatch`.
- Deleted document → `removeLayer(.server, id)`.
- After each page: `saveGoldCursor`. Stop fetching more pages once 200 changes have been processed.
- Always `recordGoldResult` and clean up staging.
- Any thrown adapter error ends the pull with `code` `"transient:<…>"` / `"needs_authentication"` etc.; the cursor stays at the last saved page.

- [ ] **Step 1: Write failing tests.** Gold files are written directly into the `FilesystemAdapter` root with `EnrichmentJSON.encode`.
  - `appliesGoldForKnownCapture`: after `pull()`, `enrichments.document(.server, id)` equals the remote doc, its asset exists locally, and a summary word is searchable.
  - `goldForUnknownCaptureIgnored`: a doc for a random UUID gives `ignored == 1` and no local directory.
  - `deletedRemoteRemovesLocal`: apply, delete the remote file, pull, and the local server layer is gone.
  - `incrementalOnlyChanges`: a second pull with no changes gives `applied == 0`.
  - `cursorResetRelists`: corrupt the saved cursor (set `"garbage"`). The pull still applies and saves a fresh cursor.
  - `goldUnsafeAssetPathSkipped`, `goldOverCapSkipped` (a 1,048,577-byte doc), `goldWrongCaptureSkipped` (a doc at path A with `capture_id` B), `goldBadVersionSkipped` (`schema_version` 2). Each gives `skipped == 1`, no local directory, and a saved cursor.
  - `deviceLayerNeverPulled`: files under `enrichments/device/` never reach the local server layer.
  - `diagnosticsIncludeEnrichment` (LocalRepositoryTests): the JSON has `enrichment_tasks`, `enrichment_uploads_pending` and `gold.last_result_code`, and contains no capture ID.
- [ ] **Step 2:** Run `swift test --package-path HippoKit --filter "GoldPuller|diagnostics"`. Expected: FAIL.
- [ ] **Step 3:** Implement it.
- [ ] **Step 4:** Run `make test`. Expected: all pass.
- [ ] **Step 5:** Commit `feat(sync): pull gold enrichment from enrichments/server with caps and validation`.

### Task 11: Resolution (gold > silver > bronze), timeline and Detail models (§9)

**Files:**
- Create: `HippoKit/Sources/HippoPresentation/Enrichment/ResolvedEnrichment.swift`, `HippoKit/Sources/HippoPresentation/Enrichment/PlaceText.swift`
- Modify: `HippoKit/Sources/HippoPresentation/Timeline/TimelineRow.swift`, `TimelineModel.swift`, `HippoKit/Sources/HippoPresentation/Detail/CaptureDetail.swift`, `CaptureDetailModel.swift`
- Test: `HippoKit/Tests/HippoPresentationTests/ResolvedEnrichmentTests.swift`, `TimelineTests.swift`, `DetailTests.swift`

**Interfaces:**
- Produces:
  - `public struct ResolvedLink: Equatable, Sendable { url: String; title: String?; siteName: String?; channel: String?; summary: String?; thumbnailURL: URL?; fromServer: Bool }`
  - `public struct ResolvedEnrichment: Equatable, Sendable`, with fields:
    - `links: [String: ResolvedLink]` (by URL)
    - `places: [String: PlaceItem]` (by target)
    - `recognizedText: [String: String]` (by attachment ID)
    - `transcripts: [String: TranscriptItem]`
    - `detections: [Detection]`
    - `sourceAppGuess: String?`
    - `summary: String?`
    - `tags: [String]`
    - `usesServer: Bool` (any field came from gold)

    and `static let empty`, and `static func make(device: EnrichmentDocument?, server: EnrichmentDocument?, assetURL: (EnrichmentLayer, AssetRef) -> URL) -> ResolvedEnrichment`. It implements the override rule: per item key, per field, gold field if the gold facet is `ok` and the field is non-nil, else silver (`ok` only). Detections, the source guess, the summary and the tags are single items.
  - `public enum PlaceText`:
    - `static func area(_ p: PlaceItem) -> String?`: the first two non-nil of (subLocality, locality, region, country), joined with ", ", e.g. "Capitol Hill, Seattle".
    - `static func nearby(_ p: PlaceItem) -> String?`: "near \(name)".
    - `static func line(_ p: PlaceItem) -> String?`: area and nearby joined with " · ".
  - `TimelineRow.make(_:metadata:enrichment:locale:)` gains `enrichment: ResolvedEnrichment?` and `public var thumbnailURL: URL?`.
    - Link rows: `title` = the resolved title for the first URL, else the existing title; `subtitle` = channel ?? siteName ?? host; `thumbnailURL` = the resolved thumbnail.
    - Voice rows: `subtitle` = the first non-empty line of the first audio attachment's transcript, truncated to 80 characters.
  - `TimelineModel.loadPage` loads metadata for link rows too (extend `needsMetadata` with `attachmentCount == 0 && contentTypes.contains(.url)`). For link and voice rows it loads both documents through `store.enrichments` and resolves them. It reloads on `EnrichmentRunner.passFinished`. The view subscribes by name, `"HippoEnrichmentPassFinished"`; HippoPresentation doesn't import Enrichment, so declare the same name as `TimelineModel.enrichmentChanged`.
  - `CaptureDetail.make` gains `enrichment: ResolvedEnrichment` and the fields:
    - `linkCards: [ResolvedLink]` (in `urls` order)
    - `transcripts: [(title: String, text: String)]` and `recognizedText: [(title: String, text: String)]`, titled "Attachment N"
    - `found: [FoundItem]`, where `public struct FoundItem: Equatable, Sendable { kind: String; text: String; action: FoundAction? }` and `public enum FoundAction: Equatable, Sendable { case call(URL), map(URL), addToCalendar(start: Date, title: String), open(URL) }`
      - phone → `tel:` with digits and `+`;
      - address → `maps://?q=<encoded text>`;
      - date → `addToCalendar`, where `start` is the date parsed back from `value`, using the capture zone if there is no offset, and `title` is the capture's display title;
      - link → `open`.
    - `summary: String?`, `tags: [String]`, `fromServerNote: String?` ("Some details come from your server." when `usesServer`).

    Captured rows:
    - With a place for `"capture"`, the "Where" row becomes `PlaceText.line`, and the old coordinate text moves to a new row "Coordinates".
    - A source guess adds the row `("Source", "Probably from <App>")` after "How".

    Attachment rows: a photo place adds `("Taken in", PlaceText.area)` after the existing taken-at rows.
  - `CaptureDetailModel.load` resolves the enrichment the same way.

- [ ] **Step 1: Write failing tests:**
  - `goldFieldOverridesSilverField`: silver has a link with title S, channel C and a thumbnail; gold has the same URL with only title G. Resolved: title G, channel C, thumbnail present, `usesServer` true.
  - `failedGoldNeverHides`: a gold `link_preview` with status `failed` leaves silver intact and `usesServer` false.
  - `goldOnlyItemAdded`: a gold item for a second URL appears.
  - `placeTextFormats`: (subLocality "Capitol Hill", locality "Seattle", nearby "Victrola Coffee") → "Capitol Hill, Seattle · near Victrola Coffee". Only country → "Spain".
  - `linkRowUsesPreview` (TimelineTests): title, subtitle channel, thumbnailURL. Without enrichment, the row is unchanged from today, except the subtitle now shows the host.
  - `voiceRowShowsTranscriptLine`.
  - `detailWhereUsesPlace`, `detailSourceGuessRow`, `detailFoundActions` (a phone → `tel:+14155550100`), `detailServerNote`.
- [ ] **Step 2:** Run `swift test --package-path HippoKit --filter "Resolved|TimelineTests|DetailTests"`. Expected: FAIL.
- [ ] **Step 3:** Implement it.
- [ ] **Step 4:** Run `make test`. Expected: all pass.
- [ ] **Step 5:** Commit `feat(presentation): resolve gold over silver; enriched timeline rows and detail`.

### Task 12: Settings model and sample gold (§8, §11)

**Files:**
- Create: `HippoKit/Sources/HippoPresentation/Enrichment/GoldSample.swift`
- Modify: `HippoKit/Sources/HippoPresentation/Settings/AppSettings.swift`, `SettingsModel.swift`
- Test: `HippoKit/Tests/HippoPresentationTests/SettingsTests.swift`, `HippoKit/Tests/HippoPresentationTests/GoldSampleTests.swift`

**Interfaces:**
- Produces:
  - `AppSettings`:
    - `func isEnrichmentEnabled(_ kind: FacetKind) -> Bool`: defaults key `"enrichment.<rawValue>"`, absent = true.
    - `func setEnrichmentEnabled(_ kind: FacetKind, _ on: Bool)`
  - `public struct EnrichmentSwitch: Identifiable, Sendable { kind: FacetKind; title: String }` and `public static let enrichmentSwitches: [EnrichmentSwitch]` on `SettingsModel`, in this order with the exact titles from the Global Constraints:
    - `.linkPreview`, `.place`, `.textRecognition`, `.transcript`, `.dataDetection`, `.sourceAppGuess`

    Also `public static let enrichmentFooter: String` (exact copy).
  - `SettingsModel.init` gains `onEnrichmentEnabled: @escaping @Sendable (FacetKind) async -> Void = { _ in }`. `public func setEnrichment(_ kind: FacetKind, on: Bool) async` stores the value, and when `on` awaits `onEnrichmentEnabled(kind)`.
  - `public enum GoldSample { static func make(metadata: CaptureMetadata, packageDigest: String, now: Date) -> EnrichmentDocument }`. It produces a server-layer doc with:
    - `summary` "Sample server summary for testing."
    - `tags` ["sample", "hippo"]
    - for the first URL, if any, a `link_preview` item with title "Sample title from server"

    Producer `{name: "hippo-gold-sample", version: "1", build: "1"}`, and no assets.

- [ ] **Step 1: Write failing tests:**
  - `enrichmentDefaultsOn`: a fresh defaults suite reports every switch kind enabled.
  - `turningOnTriggersBackfill`: `setEnrichment(.place, on: true)` calls the closure once with `.place`. Turning it off doesn't call it, and stores false.
  - `switchCopyExact`: the titles and footer equal the constraint strings.
  - `goldSampleValid`: `EnrichmentJSON.decode(EnrichmentJSON.encode(sample))` round-trips, the layer is `.server`, and the summary is present.
- [ ] **Step 2:** Run `swift test --package-path HippoKit --filter "SettingsTests|GoldSample"`. Expected: FAIL.
- [ ] **Step 3:** Implement it.
- [ ] **Step 4:** Run `make test`. Expected: all pass.
- [ ] **Step 5:** Commit `feat(presentation): enrichment settings and a gold sample builder`.

### Task 13: App wiring: real enrichers, runner, triggers (§5, §10)

**Files:**
- Create: `App/Hippo/Enrichment/LinkPresentationFetcher.swift`, `MapKitPlaceLookup.swift`, `SpeechTranscriberService.swift`, `EnrichmentScheduling.swift`
- Modify: `project.yml` (link the `Enrichment` product to the app target, not the extension), `App/Shared/AppEnvironment.swift`, `App/Hippo/HippoApp.swift`, `App/Hippo/Settings/SyncScheduling.swift`, `App/Hippo/Capture/NoteEditorView.swift` and `RecorderView.swift` (trigger after save)

**Interfaces:**
- Consumes: Tasks 5–8 and 12.
- Produces:
  - `LinkPresentationFetcher: LinkMetadataFetching`: `LPMetadataProvider` with `timeout`. The image comes from `imageProvider` loaded as `Data` (UTType.image). Map `NSURLErrorNotConnectedToInternet` to `.deferred(code: "offline", retryAfter: 60)`.
  - `MapKitPlaceLookup: PlaceLookup`: `MKReverseGeocodingRequest` for the area (map its address representation fields to `PlaceArea`). `MKLocalPointsOfInterestRequest(center:radius:)` + `MKLocalSearch` for the nearest POI by distance. A throttling error maps to `.transient("geocode_throttled")`. **Verify both APIs against the iOS 27 SDK**; if a name differs, use the SDK's current equivalent and note it in the commit message.
  - `SpeechTranscriberService: Transcribing`: `SpeechTranscriber(locale:…)` + `SpeechAnalyzer` over an `AVAudioFile`. Segments come from result ranges. If `AssetInventory` reports the locale isn't installed, request the install and throw `.deferred("model_missing", 900)`. Never use server recognition. **Check** whether authorization or an Info.plist usage string is required; if so, add `NSSpeechRecognitionUsageDescription: "Hippo turns your voice notes into text on this iPhone."` to `project.yml`.
  - `AppEnvironment`:
    - `let enrichment: EnrichmentRunner?`. App only. It is built with all six enrichers, `producer` `{name: "hippo-ios", version: appVersion, build}`, `isEnabled` from `LocationService.settings.isEnrichmentEnabled`, and `isOnline` from a shared `NWPathMonitor` wrapper (`path.status == .satisfied`).
    - Temp dir: `store.layout.enrichmentStagingDir`. Locale: `TranscriptLocale.choose(current: .current)`.
  - `enum EnrichmentScheduling` (MainActor):
    - `static func run(_ env: AppEnvironment, reason: String) async`. A coalescing single-flight: one in-flight task, and a call made while running sets a rerun flag. Inside `BackgroundActivity.run(name: "enrichment", onExpire: cancel)`: `schedule()`, then `runPending()` in a loop while `ran > 0` and not cancelled, then, if anything ran, `SyncScheduling.runPass(coordinator, name: "enrichment-sync")`.
    - `static func cancel()`
  - Triggers. Each calls `EnrichmentScheduling.run`:
    - after launch recovery (after the first sync);
    - on `scenePhase == .active`;
    - after a note save and a recording save;
    - from the `onEnrichmentEnabled` closure passed to `SettingsModel`;
    - in the BG task after the sync pass. The expiry handler also calls `EnrichmentScheduling.cancel()`.
  - `SyncScheduling.scheduleBackgroundTask` also has work when `try environment.store.enrichmentTasks.hasDueWork(kinds: <enabled kinds>, now: Date())`.

- [ ] **Step 1:** Implement the three service files and `EnrichmentScheduling`, and wire up `AppEnvironment` and the triggers.
- [ ] **Step 2:** Run the App build check. Expected: `** BUILD SUCCEEDED **`. Run `make test`. Expected: pass.
- [ ] **Step 3:** Commit `feat(app): run on-device enrichment with LinkPresentation, MapKit and SpeechAnalyzer`.

### Task 14: App UI: Settings section, Detail sections, timeline rows, DEBUG sample gold (§8, §9)

**Files:**
- Create: `App/Hippo/Detail/EnrichmentSections.swift`
- Modify: `App/Hippo/Settings/SettingsView.swift`, `App/Hippo/Settings/DevFolderProvider.swift`, `App/Hippo/Detail/CaptureDetailView.swift`, `App/Hippo/Timeline/TimelineRowView.swift`, `App/Hippo/Timeline/TimelineView.swift`

**Interfaces:**
- Consumes: Task 11 and 12 models.
- Produces:
  - **SettingsView** `enrichmentSection`, after `locationSection`: a `Toggle` per `SettingsModel.enrichmentSwitches` bound through `setEnrichment`, with the footer `SettingsModel.enrichmentFooter`.
  - **DEBUG only**, in the Developer-folder storage row's section: a button "Write sample server enrichment". It takes the newest capture (first row of `index.page(CaptureFilter(), after: nil, limit: 1)`). If that capture has a synced job to the dev folder, it writes `GoldSample.make(…)` via `EnrichmentJSON.encode` to `<HippoDevRemote>/<EnrichmentPaths.remoteDirectory(.server, packageDirectory:)>/enrichment.json`, then runs a sync pass. Otherwise it shows "Sync this capture first."
  - **Detail**, in this order after the existing preview and comment:
    - link cards (thumbnail via `AsyncImage(url: fileURL)`, title, channel or site, description);
    - Summary and Tags;
    - "Found in this capture" (each `FoundItem`; actions open `tel:`/`maps:`/URL via `openURL`, and `addToCalendar` presents `EKEventEditViewController` wrapped in `UIViewControllerRepresentable`, with the title and start prefilled, a 1 h duration, and the default calendar store);
    - Transcript and Text in image, each a `DisclosureGroup` with `.textSelection(.enabled)`;
    - then the existing sections. `fromServerNote` is shown as a footnote at the end of Captured.
  - **TimelineRowView:** a link row shows a 44 pt thumbnail from `thumbnailURL` when present. A voice row shows `subtitle` in secondary style.
  - **TimelineView** reloads on `TimelineModel.enrichmentChanged`.

- [ ] **Step 1:** Implement the views.
- [ ] **Step 2:** Run the App build check (BUILD SUCCEEDED) and `make test` (pass). If a simulator is available, run `make uitest`. Otherwise record "uitest not run: no simulator" in the task report.
- [ ] **Step 3:** Commit `feat(app): enrichment settings, enriched detail and timeline rows, debug gold sample`.

### Task 15: Acceptance rows, docs, README (§11)

**Files:**
- Modify: `docs/acceptance.md`, `README.md`, `docs/package-format.md`

- [ ] **Step 1:** Append rows E1–E12 to `docs/acceptance.md` (Result "not run"):
  - E1 Record starts on one tap.
  - E2 A YouTube share shows its title, channel and thumbnail after opening the app.
  - E3 A Safari link preview.
  - E4 Screenshot text is searchable.
  - E5 A voice note transcript appears and is searchable. Note whether the model downloaded.
  - E6 The capture place shows "near X" only when accurate. Compare an indoor and an outdoor capture.
  - E7 The extension's fresh fix: record whether the share's `capture_location.provenance` is `core_location_request`.
  - E8 Source-app guesses from WhatsApp, Messages, Safari and Photos. Record the observed type identifiers and add confirmed rules.
  - E9 The Developer-folder sample gold overrides the link title and shows Summary and Tags.
  - E10 Gold written for a capture, then the capture deleted on the phone: nothing comes back after a sync.
  - E11 A switch off then on: no new work while off; backfill when on.
  - E12 Enrichment never delays "✓ Saved on this iPhone". Also: whether LinkPresentation, MapKit and SpeechAnalyzer worked in the BG task (§12).
- [ ] **Step 2:** README: an "Enrichment" section covering:
  - the layers and paths;
  - what leaves the phone (link fetches to the linked site; coordinates to Apple Maps);
  - English-only transcripts;
  - the never-fetched links;
  - that the server is not built yet;
  - the Dropbox adapter (Plan 3) must implement `replaceFile`/`listChanges`/`downloadFile`.

  In `docs/package-format.md`, change the "Store derived (AI) output separately" sentence to point to `docs/enrichment-format.md`.
- [ ] **Step 3:** Run `make test` and `scripts/validate-fixtures.sh`. Both pass.
- [ ] **Step 4:** Commit `docs: enrichment acceptance rows, README and format pointer`.
