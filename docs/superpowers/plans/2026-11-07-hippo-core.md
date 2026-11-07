# Hippo Core (Plan 1 of 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Mac-testable Swift package (`HippoKit`) that turns a capture draft into an immutable portable package, indexes it in SQLite, recovers from crashes, and uploads it through a provider-neutral adapter (filesystem adapter included), with JSON Schema and fixtures for the future desktop reader.

**Architecture:** One local Swift package with four library targets: `CaptureCore` (format, paths, hashing, media facts, package writer/validator), `LocalRepository` (SQLite index, destinations, jobs, recovery, diagnostics), `SyncEngine` (adapter contract, retry policy, worker, the `HippoStore` facade), and `FilesystemAdapter`. No UIKit and no third-party dependencies, so `swift test` runs on macOS. Plans 2 (iPhone app + Share Extension + recorder + UI) and 3 (Dropbox adapter) build on this package unchanged.

**Tech Stack:** Swift 6.4 (Swift 6 language mode), SwiftPM, Swift Testing (`import Testing`), Foundation, CryptoKit, ImageIO, AVFoundation, system `SQLite3` (FTS5), `uvx check-jsonschema` for schema checks.

**Spec:** `hippo-v0-spec.md` (base) + `docs/superpowers/specs/2026-11-07-hippo-v0-design.md` (wins on conflict). Executors read both.

**Plan series:** 1 = this plan. 2 = iPhone app (XcodeGen project, Share Extension, note editor, recorder, timeline/filters/details/settings, device install script). 3 = Dropbox adapter (PKCE auth, uploads, content_hash, Hippo Dev integration tests). Plans 2 and 3 are written after this one lands.

**Branch:** `feat/hippo-core`, created from `design/hippo-v0`.

## Global Constraints

- Platforms in `Package.swift`: `.iOS("27.0")`, `.macOS("27.0")`. Swift language mode 6 (strict concurrency). Public types that cross actors are `Sendable`.
- No third-party dependencies in `HippoKit`. No `import UIKit`/`AppKit` in any HippoKit target.
- Package format: `schema_version` 1; UTF-8 JSON; snake_case keys; RFC 3339 timestamps; lowercase hex SHA-256; explicit units in key names (`_bytes`, `_seconds`, `_meters`, `_pixels`).
- **Optional-field rule (decided here):** unavailable optional fields are **omitted**, never `null` and never `""`. The schema marks them optional.
- Package layout (exact): `captures/YYYY/MM/DD/<capture-uuid>/metadata.json`, `content/<attachment-uuid>.<ext>`, `complete.json`. UUIDs are lowercase. The local store uses the same relative layout under its root.
- `complete.json` lists every file except itself (including `metadata.json`). It is written last locally and uploaded last remotely.
- Packages are immutable after commit. Sync state never goes inside a package.
- `capture_method` values: `share_extension`, `typed_note`, `file_import`, `voice_recording`. Readers accept unknown future values.
- `source_application` is never written in V0 (design §3.3).
- Logs and diagnostics never contain capture content, filenames, URLs, tokens, signed URLs or precise location.
- Product vocabulary: "Captures", never "Inbox".
- Commit after every task. Before each commit, run `git diff --cached` and read it for secrets (Jorge's global rule).

## Review Focus

1. **Search text with FTS syntax** (`"`, `*`, `-`, `NEAR`, `:`, unbalanced parentheses, emoji) must return results or nothing, never throw. → Task 9 `searchWithFTSOperatorsNeverThrows`.
2. **Captures near local midnight / DST / far time zones** partition by the *local* date recorded at capture, not the UTC date. → Task 2 `partitionUsesLocalDateNotUTC`.
3. **Odd filenames** (emoji, 300 characters, no extension, `../evil.png`, `.hidden`, `photo.JPEG`) produce safe generated names, and the original is preserved in metadata. → Task 2 `sanitizesExtensions`, Task 5 `preservesOriginalFilenameVerbatim`.
4. **Zero-byte and very large attachments**: an empty file is valid (hash `e3b0c442…`); a 256 MiB file hashes without loading it into memory. → Task 3, Task 5 `zeroByteAttachmentCommits`.
5. **App and Share Extension writing at the same time** (two connections, same DB): no `SQLITE_BUSY` failure and no duplicate rows. → Task 8 `concurrentWritersDoNotFail`, Task 10 `onlyOneClaimerWins`.

---

## File Structure

```
HippoKit/
  Package.swift
  Sources/
    CaptureCore/
      Model/OpenEnums.swift            CaptureMethod, ContentType (RawRepresentable, open for future values)
      Model/CaptureMetadata.swift      schema v1 Codable types
      Model/CompletionMarker.swift     complete.json types
      Model/DisplayTitle.swift         deterministic title fallback
      JSON/HippoJSON.swift             shared encoder/decoder + schema-version gate
      Paths/PackagePath.swift          date partition, safe names, relative-path validation
      Hashing/StreamingHasher.swift    SHA-256 + byte count by streaming
      Media/MediaInspector.swift       dimensions, duration, embedded time/GPS/camera
      Package/StoreLayout.swift        local root: staging/, captures/, hippo.sqlite, diagnostics.json
      Package/CaptureDraft.swift       writer input types
      Package/PackageWriter.swift      staging → hash → metadata → marker → atomic move
      Package/PackageValidator.swift   reader-side validation (desktop contract)
      Package/SpaceChecking.swift      free-space protocol + volume implementation
    LocalRepository/
      SQLite/Database.swift            thin sqlite3 wrapper (WAL, busy timeout, transactions)
      SQLite/Migrations.swift          schema v1 tables + FTS5
      CaptureIndex.swift               register, page, search, filters, detail
      CaptureFilter.swift              filter/sort/cursor/summary types
      DestinationStore.swift           destinations, sign-in/out, assignment, backfill
      JobStore.swift                   jobs, leases, receipts, checkpoints
      Reconciler.swift                 startup recovery
      Diagnostics.swift                redacted diagnostics.json
    SyncEngine/
      StorageAdapter.swift             protocol + value types + StorageError
      RetryPolicy.swift
      SyncWorker.swift                 one-job upload protocol (files, then marker)
      HippoStore.swift                 facade used by the app and extension
    FilesystemAdapter/
      FilesystemAdapter.swift          dev/test adapter with fault injection
    hippo-fixtures/
      main.swift                       executable: regenerates fixtures/
  Tests/
    CaptureCoreTests/  LocalRepositoryTests/  SyncEngineTests/
    AdapterContractTests/              reusable contract suite (Plan 3 runs it against Dropbox)
schema/
  capture-metadata-v1.schema.json
  complete-v1.schema.json
fixtures/packages/captures/2026/11/07/<uuid>/…   six fixture packages
scripts/validate-fixtures.sh
docs/package-format.md                 desktop-reader contract
docs/adr/0001-sqlite-wrapper.md
```

---

### Task 1: Package scaffold, schema v1 model, JSON conventions

**Files:**
- Create: `HippoKit/Package.swift`, `Sources/CaptureCore/Model/OpenEnums.swift`, `Model/CaptureMetadata.swift`, `Model/CompletionMarker.swift`, `JSON/HippoJSON.swift`
- Test: `Tests/CaptureCoreTests/MetadataCodingTests.swift`

**Interfaces:**
- Produces:
  - `struct CaptureMethod: RawRepresentable, Codable, Hashable, Sendable` with statics `.shareExtension, .typedNote, .fileImport, .voiceRecording`.
  - `struct ContentType` (same shape) with statics `.text, .url, .image, .video, .audio, .pdf, .file`.
  - `struct CaptureMetadata: Codable, Sendable, Equatable` with fields:
    - `schemaVersion: Int`, `captureID: String`, `capturedAt: Date`, `localDatetime: String`, `timezoneIdentifier: String`, `utcOffsetSeconds: Int`
    - `captureMethod: CaptureMethod`, `contentTypes: [ContentType]`
    - `userNote: String?`, `sharedTitle: String?`, `sharedText: String?`, `urls: [CapturedURL]`
    - `sourceApplication: String?`, `captureLocation: CaptureLocation?`, `producer: Producer`
    - `attachments: [Attachment]`, `metadataObservations: [MetadataObservation]`, `extensions: [String: JSONValue]`
  - Nested types:
    - `CapturedURL{url: String, source: String}`
    - `CaptureLocation{latitude: Double, longitude: Double, horizontalAccuracyMeters: Double, observedAt: Date, provenance: String}`
    - `Producer{appVersion, build, osVersion: String}`
    - `Attachment{attachmentID, relativePath: String, originalFilename: String?, uti: String, mimeType: String?, byteCount: Int64, sha256: String, representationSource: String, media: MediaFacts?}`
    - `MediaFacts{widthPixels: Int?, heightPixels: Int?, durationSeconds: Double?, embeddedCreatedAt: EmbeddedTimestamp?, embeddedLocation: EmbeddedLocation?, cameraMake: String?, cameraModel: String?}`
    - `EmbeddedTimestamp{value: String, hasUTCOffset: Bool}`
    - `EmbeddedLocation{latitude: Double, longitude: Double, altitudeMeters: Double?}`
    - `MetadataObservation{key: String, value: JSONValue, provenance: String}`
    - `enum JSONValue: Codable, Sendable, Equatable {string, number(Double), bool, array, object, null}`
  - `struct CompletionMarker: Codable{schemaVersion: Int, captureID: String, files: [ManifestEntry]}`, `ManifestEntry{relativePath: String, byteCount: Int64, sha256: String}`.
  - `enum HippoJSON { static func encode<T: Encodable>(_:) throws -> Data; static func decodeMetadata(_ data: Data) throws -> CaptureMetadata; static func decodeMarker(_ data: Data) throws -> CompletionMarker }`
  - `enum FormatError: Error, Equatable { case unsupportedSchemaVersion(Int), malformed(String) }`

- [ ] **Step 1: Create the package and branch.** Run `git checkout -b feat/hippo-core`. Write `Package.swift`:
  - library targets `CaptureCore`; `LocalRepository` (depends on CaptureCore); `SyncEngine` (depends on both); `FilesystemAdapter` (depends on SyncEngine, CaptureCore)
  - executable `hippo-fixtures`
  - test targets per the File Structure
  - platforms from Global Constraints
  - `swiftLanguageModes: [.v6]`

- [ ] **Step 2: Write failing tests**

```swift
@Test func encodesSnakeCaseRFC3339AndOmitsNil() throws {
    let m = CaptureMetadata.sample(userNote: nil)          // test helper in the test file
    let json = String(decoding: try HippoJSON.encode(m), as: UTF8.self)
    #expect(json.contains("\"schema_version\" : 1"))
    #expect(json.contains("\"captured_at\" : \"2026-11-07T17:00:00.000Z\""))
    #expect(json.contains("\"utc_offset_seconds\" : -28800"))
    #expect(!json.contains("user_note"))                    // omitted, not null
    #expect(!json.contains("null"))
}
@Test func roundTrips() throws {
    let m = CaptureMetadata.sample(userNote: "Gift idea")
    #expect(try HippoJSON.decodeMetadata(HippoJSON.encode(m)) == m)
}
@Test func ignoresUnknownFieldsAndAcceptsUnknownEnumValues() throws {
    var obj = try JSONSerialization.jsonObject(with: HippoJSON.encode(CaptureMetadata.sample())) as! [String: Any]
    obj["future_field"] = ["x": 1]; obj["capture_method"] = "watch_dictation"
    let m = try HippoJSON.decodeMetadata(JSONSerialization.data(withJSONObject: obj))
    #expect(m.captureMethod.rawValue == "watch_dictation")
}
@Test func rejectsUnsupportedMajorVersion() throws {
    var obj = try JSONSerialization.jsonObject(with: HippoJSON.encode(CaptureMetadata.sample())) as! [String: Any]
    obj["schema_version"] = 2
    #expect(throws: FormatError.unsupportedSchemaVersion(2)) {
        try HippoJSON.decodeMetadata(JSONSerialization.data(withJSONObject: obj))
    }
}
```

- [ ] **Step 3: Verify failure.** Run: `swift test --package-path HippoKit --filter MetadataCodingTests`. Expected: compile failure (types missing).

- [ ] **Step 4: Implement the types.**
  - Encoder: `.convertToSnakeCase`, `[.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]`.
  - Dates: custom ISO 8601 in UTC with exactly 3 fractional digits and a `Z` suffix. Decode with or without a fractional part.
  - Key overrides: `captureID` → `capture_id`, `attachmentID` → `attachment_id`, `sha256` → `sha256`. Use explicit `CodingKeys` wherever `convertToSnakeCase` would produce `capture_i_d`.
  - Decoding: read `schema_version` first; anything other than 1 throws `unsupportedSchemaVersion`.

- [ ] **Step 5: Verify pass** (same command; expected: 4 tests pass), then **commit**: `feat(core): schema v1 model and JSON conventions`.

---

### Task 2: Paths — local-date partition and safe names

**Files:** Create `Sources/CaptureCore/Paths/PackagePath.swift`. Test `Tests/CaptureCoreTests/PackagePathTests.swift`.

**Interfaces:**
- Produces:
  - `enum PackagePath`:
    - `static func captureDirectory(captureID: String, localDate: DateComponents) -> String`, returning `"captures/YYYY/MM/DD/<id>"`.
    - `static func localDateComponents(of instant: Date, in tz: TimeZone) -> DateComponents`
    - `static func localDatetimeString(_ instant: Date, tz: TimeZone) -> String`, RFC 3339 with offset and no fractional part, e.g. `2026-11-07T09:00:00-08:00`.
    - `static func attachmentPath(attachmentID: String, originalFilename: String?, uti: String) -> String`, returning `"content/<id>.<ext>"`.
    - `static func sanitizedExtension(originalFilename: String?, uti: String) -> String`
    - `static func validateRelative(_ path: String) throws(FormatError)`
- Extension rule: take the original filename's extension, lowercased, if it matches `^[a-z0-9]{1,10}$`. Otherwise use `UTType(uti)?.preferredFilenameExtension`. Otherwise `bin`.
- `validateRelative` rejects:
  - an empty path
  - a leading `/`
  - `.` or `..` segments
  - backslashes
  - NUL characters
  - paths over 255 UTF-8 bytes
  - anything not under `content/`, apart from `metadata.json`

- [ ] **Step 1: Failing tests**

```swift
@Test func partitionUsesLocalDateNotUTC() {
    let la = TimeZone(identifier: "America/Los_Angeles")!
    let instant = ISO8601DateFormatter().date(from: "2026-11-08T07:30:00Z")!   // 23:30 Nov 7 in LA
    let c = PackagePath.localDateComponents(of: instant, in: la)
    #expect(PackagePath.captureDirectory(captureID: "abc", localDate: c) == "captures/2026/11/07/abc")
    #expect(PackagePath.localDatetimeString(instant, tz: la) == "2026-11-07T23:30:00-08:00")
}
@Test func dstFallBackOffsetIsCorrect() {   // 2026-11-01 01:30 PST after fall-back
    let la = TimeZone(identifier: "America/Los_Angeles")!
    let instant = ISO8601DateFormatter().date(from: "2026-11-01T09:30:00Z")!
    #expect(PackagePath.localDatetimeString(instant, tz: la) == "2026-11-01T01:30:00-08:00")
}
@Test(arguments: [("photo.JPEG","public.jpeg","jpeg"), ("no-extension","public.png","png"),
                  ("😀.heic","public.heic","heic"), ("../evil.png","public.png","png"),
                  (".hidden","public.data","bin"), (String(repeating:"a",count:300)+".toolongext1","public.data","bin")])
func sanitizesExtensions(name: String, uti: String, ext: String) {
    #expect(PackagePath.sanitizedExtension(originalFilename: name, uti: uti) == ext)
}
@Test(arguments: ["", "/abs", "content/../x", "content/./x", "a\\b", "other/x.png", "content/\u{0}x"])
func rejectsUnsafeRelativePaths(p: String) { #expect(throws: FormatError.self) { try PackagePath.validateRelative(p) } }
@Test func acceptsValidPaths() throws {
    try PackagePath.validateRelative("metadata.json"); try PackagePath.validateRelative("content/0f.png")
}
```

- [ ] **Step 2: Verify failure.** Run `swift test --package-path HippoKit --filter PackagePathTests` and confirm it fails to compile.
- [ ] **Step 3: Implement.** Use a `Calendar(identifier: .gregorian)` with `timeZone = tz` for the components. Zero-pad the month and day.
- [ ] **Step 4: Verify pass**, then **commit** `feat(core): package paths and safe names`.

---

### Task 3: Streaming hasher

**Files:** Create `Sources/CaptureCore/Hashing/StreamingHasher.swift`. Test `Tests/CaptureCoreTests/StreamingHasherTests.swift`.

**Interfaces:**
- Produces `struct FileDigest: Sendable, Equatable { byteCount: Int64; sha256: String }` and `enum StreamingHasher { static func digest(of url: URL, chunkSize: Int = 1 << 20) throws -> FileDigest }`.

- [ ] **Step 1: Failing tests**
  - `emptyFileHash`: an empty file → `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`, byteCount 0.
  - `abcHash`: a file containing "abc" → `ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad`, byteCount 3.
  - `largeSparseFileMatchesOneShotAndStaysSmall`: create a 256 MiB sparse file (`FileHandle.truncate(atOffset:)`) with "x" written at a few offsets. Expect `digest.byteCount == 268_435_456`. Expect the hash to equal a reference computed in 8 MiB chunks in the test. Expect process resident memory growth during the call (via `task_info` `phys_footprint`) to stay under 64 MiB.
- [ ] **Step 2: Verify failure.** Then **Step 3: implement** with `FileHandle.read(upToCount:)` and `SHA256()` updates inside an `autoreleasepool`-free loop, producing lowercase hex output.
- [ ] **Step 4: Verify pass**, then **commit** `feat(core): streaming SHA-256`.

---

### Task 4: Media facts

**Files:** Create `Sources/CaptureCore/Media/MediaInspector.swift`. Test `Tests/CaptureCoreTests/MediaInspectorTests.swift`, plus `Tests/CaptureCoreTests/Support/MediaMaker.swift`, which generates JPEG/PNG data with optional EXIF/GPS through `CGImageDestination`, an `.m4a` through `AVAudioFile` (AAC, 1 s of silence), and a 1 s `.mov` through `AVAssetWriter`.

**Interfaces:**
- Produces `enum MediaInspector { static func facts(for url: URL, uti: String) async -> MediaFacts? }`. It never throws and returns `nil` when there is nothing to report. It is bounded: a 2 s timeout for AVFoundation loads, after which it returns whatever was gathered.
- Rules:
  - Images: `widthPixels`/`heightPixels` from ImageIO, with orientation not applied.
  - `embeddedCreatedAt` comes from EXIF `DateTimeOriginal`. When `OffsetTimeOriginal` is present, value = `"2026:11:07 09:11:00"` normalized to `"2026-11-07T09:11:00-08:00"` with `hasUTCOffset = true`. Otherwise value = `"2026-11-07T09:11:00"` with `hasUTCOffset = false`. Never apply the capture time zone.
  - GPS goes in `embeddedLocation`, with south and west made negative.
  - Camera make and model come from TIFF.
  - Audio and video: `durationSeconds` from `AVURLAsset.load(.duration)`. Video dimensions come from the first video track's `naturalSize` with `preferredTransform` applied (absolute values).

- [ ] **Step 1: Failing tests**
  - `imageDimensionsAndNoExif` (PNG 120×80 → 120/80, no embedded time)
  - `exifTimeWithoutOffsetStaysUnzoned` (expect `hasUTCOffset == false`, value `"2026-11-07T09:11:00"`)
  - `exifTimeWithOffset`
  - `gpsSouthWestIsNegative` (S 33.5, W 70.6 → −33.5/−70.6)
  - `audioDuration` (≈1.0 ± 0.1)
  - `videoDurationAndSize` (≈1.0 s; 64×48)
  - `garbageFileReturnsNil`
- [ ] **Step 2: Verify failure. Step 3: Implement. Step 4: Verify pass. Commit** `feat(core): media facts`.

---

### Task 5: Package writer

**Files:** Create `Package/StoreLayout.swift`, `Package/CaptureDraft.swift`, `Package/SpaceChecking.swift`, `Package/PackageWriter.swift` and `Model/DisplayTitle.swift`. Test `Tests/CaptureCoreTests/PackageWriterTests.swift`.

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces:
  - `struct StoreLayout: Sendable { let root: URL }` with `stagingDir`, `capturesDir`, `databaseURL` (`hippo.sqlite`), `diagnosticsURL` (`diagnostics.json`) and `func packageURL(relativeDirectory:) -> URL`.
  - `struct AttachmentSource: Sendable { enum Body: Sendable { case file(URL), data(Data) }; var body: Body; var originalFilename: String?; var uti: String; var mimeType: String?; var representationSource: String }`. `representationSource` values: `item_provider_file`, `item_provider_data`, `typed_note`, `recording`.
  - `struct CaptureDraft: Sendable { captureID: UUID; startedAt: Date; timeZone: TimeZone; method: CaptureMethod; userNote, sharedTitle, sharedText: String?; urls: [CapturedURL]; attachments: [AttachmentSource]; location: CaptureLocation?; observations: [MetadataObservation] }`
  - `enum PartialPolicy: Sendable { case rejectPartial, acceptPartial }`
  - `struct AttachmentFailure: Sendable, Equatable { index: Int; reason: String }`
  - `enum CaptureError: Error, Equatable { case insufficientSpace(requiredBytes: Int64, availableBytes: Int64), attachmentsFailed([AttachmentFailure]), emptyCapture, io(String) }`
  - `protocol SpaceChecking: Sendable { func availableBytes(at url: URL) throws -> Int64 }` and `struct VolumeSpaceChecker: SpaceChecking`, which uses `volumeAvailableCapacityForImportantUsageKey`.
  - `struct CommittedPackage: Sendable { metadata: CaptureMetadata; marker: CompletionMarker; relativeDirectory: String; directoryURL: URL; func noteBody() -> String? }`. `noteBody()` returns the first 4 KiB of the first `public.utf8-plain-text`/`public.plain-text` attachment for `typed_note` captures, and nil otherwise. It feeds the index title and search.
  - `final class PackageWriter: Sendable { init(layout: StoreLayout, producer: Producer, space: any SpaceChecking = VolumeSpaceChecker()); func commit(_ draft: CaptureDraft, partialPolicy: PartialPolicy = .rejectPartial) async throws -> CommittedPackage }`
  - `enum DisplayTitle { static func make(_ m: CaptureMetadata, noteBody: String?) -> String }`. Order:
    1. `sharedTitle`
    2. the first non-empty line of `noteBody` (truncated to 80 characters)
    3. the first URL's host + path
    4. the first attachment's `originalFilename`
    5. `"Voice note · m:ss"` for `voice_recording`
    6. a type word (`Image`, `Video`, `Audio`, `PDF`, `File`, `Note`, `Link`)
- Commit algorithm (exact order):
  1. Reject a draft with no attachments, no URLs, no `sharedText` and no `userNote` (`emptyCapture`).
  2. Estimate the size as the sum of the source sizes plus 1 MiB. If it exceeds the available space → `insufficientSpace`, and write nothing.
  3. Create `staging/<capture-id>/content/`. Hold an exclusive `flock` on `staging/<capture-id>/.lock` until the end.
  4. Copy each source (`FileManager.copyItem` for files, `write` for data) to `content/<attachment-uuid>.<ext>`. Collect failures. If there are failures and the policy is `rejectPartial` → delete the staging directory and throw `attachmentsFailed`. With `acceptPartial`, drop the failed attachments and add an observation per failure, `{key:"attachment_copy_failed", value:{index, reason}, provenance:"package_writer"}`.
  5. Hash each copied file (Task 3). Gather `MediaInspector` facts for image, video and audio UTIs.
  6. Build the metadata. `content_types` is the de-duplicated set, in order: from the attachment UTIs (image/video/audio/pdf → their types; plain text → `text`; else `file`), plus `url` if `urls` is non-empty, plus `text` if `sharedText` is non-empty. Write `metadata.json`.
  7. Hash `metadata.json`. Write `complete.json` with the manifest (metadata first, then the attachments in order). `fsync` each file and the directory.
  8. Create the parent `captures/YYYY/MM/DD/` directory, then `rename(2)` the staging directory into place (same volume, atomic). Remove `.lock` from the final directory before the rename (stage it outside `content`), so the final package contains only spec files.

- [ ] **Step 1: Failing tests** (use a temporary root and a fake `SpaceChecking`)
  - `commitsPackageWithExactLayout`: an image plus a URL. The final directory equals `captures/2026/11/07/<id>`. The files are exactly `{metadata.json, complete.json, content/<uuid>.png}`. The manifest has 2 entries with the correct hashes. Staging is empty afterwards.
  - `typedNoteStoresBodyAsTxtAttachment`: method `.typedNote` with a `.data("Call plumber")` attachment of UTI `public.utf8-plain-text` → `content/<id>.txt`, contentTypes `["text"]`, and `userNote == nil`.
  - `urlOnlyCaptureHasNoAttachments`
  - `zeroByteAttachmentCommits`
  - `preservesOriginalFilenameVerbatim`, using `"../😀 weird name.JPEG"`.
  - `insufficientSpaceWritesNothing`: the fake reports 10 bytes → throws `.insufficientSpace`, and `captures/` and `staging/` are both empty.
  - `failedAttachmentRejectsByDefault`: one source URL that doesn't exist → throws `.attachmentsFailed([.init(index: 1, …)])` and nothing is committed.
  - `acceptPartialRecordsObservation`
  - `displayTitleFallbacks`: one case per rule.
- [ ] **Step 2: Verify failure. Step 3: Implement. Step 4: Verify pass. Commit** `feat(core): atomic package writer`.

---

### Task 6: Package validator (desktop-reader contract)

**Files:** Create `Package/PackageValidator.swift`. Test `Tests/CaptureCoreTests/PackageValidatorTests.swift`.

**Interfaces:**
- Also produces `extension CommittedPackage { static func load(directory: URL, layout: StoreLayout) -> CommittedPackage? }`, which is non-nil only when the package validates `.complete`. The reconciler uses it.
- Produces `enum ValidationResult: Equatable, Sendable { case complete(metadata: CaptureMetadata, packageDigest: String), incomplete(String), corrupt(String), unsupportedSchema(Int) }` and `enum PackageValidator { static func validate(directory: URL) -> ValidationResult }`.
- `packageDigest` is the SHA-256 of the exact `complete.json` bytes.
- Rules:
  - No `complete.json` → `incomplete("no completion marker")`.
  - Marker or metadata at an unsupported version → `unsupportedSchema`.
  - A manifest path failing `validateRelative` → `corrupt`.
  - A manifest file that's missing → `incomplete("missing <path>")`. This is a reader's retry case, for example a Dropbox placeholder or a file still syncing.
  - A size or hash mismatch → `incomplete("mismatch <path>")`. Readers retry before surfacing corruption, per spec §12.
  - The metadata's `capture_id` differs from the marker's, or from the directory name → `corrupt`.
  - An attachment in the metadata that's absent from the manifest → `corrupt`.

- [ ] **Step 1: Failing tests:** build packages with `PackageWriter`, then tamper with them:
  - `validPackageIsComplete`: the digest equals the SHA-256 of the `complete.json` bytes
  - `missingMarkerIsIncomplete`
  - `markerFirstButFileMissingIsIncomplete` (acceptance 7)
  - `hashMismatchIsIncomplete`
  - `traversalInManifestIsCorrupt`
  - `idMismatchIsCorrupt`
  - `schemaV2IsUnsupported`
- [ ] **Step 2–4: Verify failure, implement, verify pass. Commit** `feat(core): package validator`.

---

### Task 7: JSON Schema, fixtures and format doc

**Files:**
- Create `schema/capture-metadata-v1.schema.json` and `schema/complete-v1.schema.json` (JSON Schema draft 2020-12)
- Create `Sources/hippo-fixtures/main.swift`
- Create `fixtures/packages/…` (generated output, committed)
- Create `scripts/validate-fixtures.sh` and `docs/package-format.md`
- Test `Tests/CaptureCoreTests/FixtureTests.swift`

**Interfaces:**
- Consumes `PackageWriter` (Task 5), with fixed UUIDs and a fixed clock injected through `CaptureDraft`. The `Producer` is fixed at `0.1.0`/`1`/`fixture`.
- Fixtures (six): `text-note`, `url-only`, `image` (PNG with EXIF time but no offset), `mixed` (2 images + a PDF + a URL + a comment), `video` (1 s `.mov`), `voice-recording` (1 s `.m4a`, method `voice_recording`). The fixture directory names are their capture UUIDs (`00000000-0000-4000-8000-00000000000N`), and a `fixtures/README.md` maps names to IDs.

- [ ] **Step 1: Write the schemas.** They cover:
  - `additionalProperties: true` (readers ignore unknown fields)
  - `schema_version` `const: 1`
  - `sha256` pattern `^[0-9a-f]{64}$`
  - `captured_at` `format: date-time`
  - `relative_path` pattern `^content/[0-9a-f-]{36}\.[a-z0-9]{1,10}$`
  - `capture_method` as an open string whose `examples` list the four known values
  - optional fields not listed in `required`
- [ ] **Step 2: Write `validate-fixtures.sh`.** It runs `uvx check-jsonschema --schemafile schema/capture-metadata-v1.schema.json fixtures/packages/captures/*/*/*/*/metadata.json` and the same for `complete.json`, and exits non-zero on failure.
- [ ] **Step 3: Write the failing test `allFixturesValidateComplete`.** It enumerates `fixtures/packages/captures/**/complete.json`, expects 6 packages, expects each `PackageValidator.validate` result to be `.complete`, and expects the methods and content types to match the table in `fixtures/README.md`.
- [ ] **Step 4: Implement the generator and run it.** Run: `swift run --package-path HippoKit hippo-fixtures fixtures/packages`, then `scripts/validate-fixtures.sh`. Expected: "ok — validation done" ×2.
- [ ] **Step 5: Write `docs/package-format.md`.** It covers:
  - the layout
  - every field with its units
  - the omission rule
  - marker semantics
  - the reader algorithm (spec §12): only process directories with `complete.json`; retry incomplete ones before calling them corrupt; index by `capture_id` + `packageDigest`; ignore unknown fields; reject a major version other than 1
  - the Dropbox online-only placeholder caveat
- [ ] **Step 6: Verify the tests pass. Commit** `feat(core): JSON Schema, fixtures, format doc`.

---

### Task 8: SQLite wrapper and migrations

**Files:** Create `LocalRepository/SQLite/Database.swift`, `SQLite/Migrations.swift` and `docs/adr/0001-sqlite-wrapper.md`. Test `Tests/LocalRepositoryTests/DatabaseTests.swift`.

**Interfaces:**
- Produces:
  - `final class Database: @unchecked Sendable`. Each instance owns one connection and serializes access with an internal lock. Members:
    - `init(url: URL) throws`, which opens with `SQLITE_OPEN_FULLMUTEX`, sets `PRAGMA journal_mode=WAL`, `busy_timeout=5000` and `foreign_keys=ON`, then runs the migrations
    - `func execute(_ sql: String, _ args: [SQLValue] = []) throws`
    - `func query(_ sql: String, _ args: [SQLValue] = []) throws -> [Row]`
    - `func transaction<T>(_ body: (Database) throws -> T) throws -> T`, which uses `BEGIN IMMEDIATE`
  - `enum SQLValue: Sendable { case null, int(Int64), double(Double), text(String), blob(Data) }`
  - `struct Row { subscript(_ name: String) -> SQLValue; func string(_:), int(_:), double(_:), date(_:) }`. Dates are stored as Int64 Unix milliseconds.
  - `enum DatabaseError: Error { case sqlite(code: Int32, message: String) }`
- Schema v1 (`PRAGMA user_version = 1`):

```sql
CREATE TABLE captures(capture_id TEXT PRIMARY KEY, captured_at_ms INTEGER NOT NULL, local_day TEXT NOT NULL,
  method TEXT NOT NULL, content_types TEXT NOT NULL /* ",image,url," */, title TEXT NOT NULL,
  note_excerpt TEXT, has_comment INTEGER NOT NULL, has_location INTEGER NOT NULL,
  attachment_count INTEGER NOT NULL, primary_attachment_path TEXT, relative_directory TEXT NOT NULL,
  package_digest TEXT NOT NULL, registered_at_ms INTEGER NOT NULL);
CREATE INDEX captures_order ON captures(captured_at_ms DESC, capture_id DESC);
CREATE VIRTUAL TABLE captures_fts USING fts5(capture_id UNINDEXED, title, user_note, shared_text, urls, filenames,
  tokenize='unicode61 remove_diacritics 2');
CREATE TABLE destinations(destination_id TEXT PRIMARY KEY, provider_kind TEXT NOT NULL, account_identifier TEXT NOT NULL,
  remote_root TEXT NOT NULL, display_name TEXT NOT NULL, status TEXT NOT NULL /* active|signed_out|disabled */,
  created_at_ms INTEGER NOT NULL);
CREATE TABLE jobs(job_id TEXT PRIMARY KEY, capture_id TEXT NOT NULL REFERENCES captures ON DELETE CASCADE,
  destination_id TEXT NOT NULL REFERENCES destinations, state TEXT NOT NULL, attempt_count INTEGER NOT NULL DEFAULT 0,
  next_attempt_at_ms INTEGER, last_error_code TEXT, lease_owner TEXT, lease_expires_at_ms INTEGER,
  cancel_requested INTEGER NOT NULL DEFAULT 0, updated_at_ms INTEGER NOT NULL, UNIQUE(capture_id, destination_id));
CREATE TABLE receipts(job_id TEXT NOT NULL REFERENCES jobs ON DELETE CASCADE, relative_path TEXT NOT NULL,
  byte_count INTEGER NOT NULL, evidence_kind TEXT NOT NULL, evidence_value TEXT NOT NULL, PRIMARY KEY(job_id, relative_path));
CREATE TABLE checkpoints(job_id TEXT NOT NULL REFERENCES jobs ON DELETE CASCADE, relative_path TEXT NOT NULL,
  data BLOB NOT NULL, PRIMARY KEY(job_id, relative_path));
```

- [ ] **Step 1: Failing tests**
  - `migratesOnceAndIsIdempotent`: open twice, `user_version == 1`
  - `fts5Available`
  - `transactionRollsBackOnThrow`
  - `concurrentWritersDoNotFail`: two `Database` instances on the same file, 200 interleaved inserts each from two `Task`s → 400 rows, no error
- [ ] **Step 2–4: Verify failure, implement, verify pass.** The ADR records why there's a thin wrapper over the system SQLite rather than GRDB: no dependencies, a small surface, and cross-process safety through WAL plus a busy timeout. **Commit** `feat(repo): sqlite wrapper and schema v1`.

---

### Task 9: Capture index — register, page, filter, search

**Files:** Create `LocalRepository/CaptureFilter.swift` and `LocalRepository/CaptureIndex.swift`. Test `Tests/LocalRepositoryTests/CaptureIndexTests.swift`.

**Interfaces:**
- Consumes `Database` (Task 8), `CommittedPackage` and `DisplayTitle` (Task 5).
- Produces:
  - `enum SyncBucket: String, Sendable { case notSynced, synced, needsAttention }`. Bucket rules (decided here):
    - no job → `notSynced`
    - any job in `needs_authentication`, `blocked` or `paused` → `needsAttention`
    - else, all jobs `synced` → `synced`
    - else → `notSynced` (pending, uploading, retryable_failure). Offline retries do not alarm the user; the details view shows the last error.
  - `enum SortOrder: Sendable { case newestFirst, oldestFirst }`
  - `struct CaptureFilter: Sendable { var dateRange: Range<Date>?; var contentTypes: Set<ContentType> = []; var methods: Set<CaptureMethod> = []; var hasComment: Bool?; var hasLocation: Bool?; var syncBuckets: Set<SyncBucket> = []; var searchText: String?; var sort: SortOrder = .newestFirst }`. Empty sets mean "any". Content types match any.
  - `struct PageCursor: Sendable, Equatable { capturedAt: Date; captureID: String }`
  - `struct CaptureSummary: Sendable, Equatable, Identifiable { id: String; capturedAt: Date; localDay: String; title: String; noteExcerpt: String?; contentTypes: [ContentType]; method: CaptureMethod; attachmentCount: Int; primaryAttachmentPath: String?; relativeDirectory: String; syncBucket: SyncBucket }`
  - `final class CaptureIndex: Sendable { init(db: Database); func register(_ p: CommittedPackage, noteBody: String?) throws -> Bool /* true = inserted, false = already present */; func page(_ f: CaptureFilter, after: PageCursor?, limit: Int) throws -> [CaptureSummary]; func metadata(captureID: String, layout: StoreLayout) throws -> CaptureMetadata?; func remove(captureID: String) throws; func count() throws -> Int }`
- `register` fills `captures_fts`: `title`; `user_note`; `shared_text` (plus `noteBody` for typed notes); `urls` (space-joined); `filenames` (space-joined `original_filename`s).
- Search: split the user text on whitespace. Each token becomes a quoted FTS phrase (`"` doubled) with a `*` prefix suffix, joined with spaces (implicit AND). If the result is empty, the search is skipped. `noteExcerpt` is `user_note` truncated to 120 characters. `primary_attachment_path` is the first image or video attachment path, else the first attachment.
- Pagination: keyset on `(captured_at_ms, capture_id)` in the sort direction, which is the stable capture-ID tie-break.

- [ ] **Step 1: Failing tests**
  - `registerIsIdempotent`
  - `newestFirstWithStableTieBreak`: 3 captures with the same timestamp → ordered by ID descending, and reversed for oldest-first
  - `paginationCoversAllWithoutDuplicates` (25 items, page size 10)
  - `mixedCaptureMatchesAnyType`
  - `filtersByMethodCommentLocationDate`
  - `searchMatchesTitleNoteSharedTextURLFilename`, one assertion per field. Also searching "ocr-only-word", which appears only inside an image, returns nothing.
  - `searchWithFTSOperatorsNeverThrows`, with arguments `["\"", "*", "-", "NEAR(", "a:b", "((", "😀", "AND OR NOT"]`; expect no throw
  - `syncBucketRules`, using raw SQL job inserts
  - `tenThousandCapturesStayResponsive`: insert 10,000 synthetic rows in one transaction. Expect a first page (limit 50) with a type filter and with a search to each take under 200 ms on the Mac (acceptance 8)
- [ ] **Step 2–4: Verify failure, implement, verify pass. Commit** `feat(repo): capture index, filters, search`.

---

### Task 10: Destinations and jobs

**Files:** Create `LocalRepository/DestinationStore.swift` and `LocalRepository/JobStore.swift`. Test `Tests/LocalRepositoryTests/DestinationJobTests.swift`.

**Interfaces:**
- Produces:
  - `enum JobState: String, Sendable { case pending, uploading, synced, retryableFailure = "retryable_failure", needsAuthentication = "needs_authentication", blocked, paused }`
  - `struct UploadJob: Sendable, Equatable { jobID, captureID, destinationID: String; state: JobState; attemptCount: Int; nextAttemptAt: Date?; lastErrorCode: String?; cancelRequested: Bool }`
  - `struct Destination: Sendable, Equatable { id, providerKind, accountIdentifier, remoteRoot, displayName: String; status: DestinationStatus }` with `enum DestinationStatus: String { case active, signedOut = "signed_out", disabled }`
  - `final class DestinationStore: Sendable { init(db:) }`. Methods:
    - `func connect(_ d: Destination) throws -> Int`: upsert as active, mark any other active destination `disabled`, resume this destination's `paused` jobs to `pending`, then create jobs for every **unassigned** capture (no job at all). Returns the number of jobs created.
    - `func signOut(destinationID:) throws`: status → `signed_out`; jobs in `pending`, `retryable_failure`, `uploading` or `needs_authentication` → `paused`.
    - `func active() throws -> Destination?`
    - `func backfill(destinationID:) throws -> Int`: creates jobs for captures lacking a job for this destination; it never alters other jobs.
  - `final class JobStore: Sendable { init(db:) }`. Methods:
    - `func enqueueIfActive(captureID:) throws`
    - `func claimNext(owner: String, now: Date, lease: TimeInterval) throws -> UploadJob?`, in one `BEGIN IMMEDIATE` transaction. It selects the oldest job where state ∈ {pending, retryable_failure} with `next_attempt_at ≤ now` (or null), the destination is active and `cancel_requested = 0`, **or** state = uploading with an expired lease. It sets `uploading`, the lease owner and the expiry.
    - `func renewLease(jobID:owner:now:lease:) throws -> Bool`
    - `func markSynced(jobID:owner:) throws`
    - `func markFailed(jobID:owner:state: JobState, errorCode: String, nextAttemptAt: Date?) throws`
    - `func requestCancel(captureID:) throws`
    - `func jobs(captureID:) throws -> [UploadJob]`
    - `func saveReceipt(jobID:_ r: StoredReceipt) throws`, where `struct StoredReceipt { relativePath: String; byteCount: Int64; evidenceKind: String; evidenceValue: String }`
    - `func receipts(jobID:) throws -> [StoredReceipt]`
    - `func saveCheckpoint(jobID:relativePath:data:)`, `checkpoint(jobID:relativePath:) -> Data?` and `clearCheckpoint(...)`
  - Every write by an owner verifies `lease_owner = owner` and throws `JobError.leaseLost` otherwise.

- [ ] **Step 1: Failing tests**
  - `captureBeforeAnyAccountIsUnassignedThenBoundOnConnect` (V5)
  - `accountBNeverPicksUpAccountAJobs` (V5, spec §8):
    1. Connect A, register a capture, and A gets a job.
    2. Sign out of A. A's job is paused.
    3. Connect B. B has 0 jobs for that capture, and A's job is still paused.
    4. Reconnect A. A's job is pending.
  - `backfillCreatesNewJobsOnly`
  - `onlyOneClaimerWins`: two `Database` connections, 50 jobs, two concurrent claim loops → 50 distinct claims, no job twice
  - `expiredLeaseIsReclaimable`
  - `leaseLostRejectsStaleOwner`
  - `cancelRequestedJobsAreNotClaimed`
  - `checkpointsRoundTrip`
- [ ] **Step 2–4: Verify failure, implement, verify pass. Commit** `feat(repo): destinations and leased jobs`.

---

### Task 11: Startup reconciler

**Files:** Create `LocalRepository/Reconciler.swift`. Test `Tests/LocalRepositoryTests/ReconcilerTests.swift`.

**Interfaces:**
- Consumes `StoreLayout`, `PackageValidator`, `CaptureIndex`, `JobStore`.
- Produces `struct RecoveryReport: Sendable, Equatable { removedStaging: Int; registered: Int; orphanedIndexRows: Int; invalidPackages: Int }` and `final class Reconciler { init(layout:index:jobs:); func run() throws -> RecoveryReport }`.
- Algorithm:
  1. For each `staging/<id>`, try a non-blocking `flock` on its `.lock`. If it's locked, skip it (the extension is mid-write). Otherwise delete the directory.
  2. Walk `captures/*/*/*/*`, validate each package, and `register(CommittedPackage.load(...), noteBody: pkg.noteBody())` any `.complete` package missing from the index, followed by `enqueueIfActive`. Count anything else as `invalidPackages` and leave it in place.
  3. Remove index rows whose package directory no longer exists.

- [ ] **Step 1: Failing tests**
  - `crashAfterCommitBeforeIndexRecoversExactlyOnce` (acceptance 3): commit with the writer, skip register, run the reconciler twice → `registered` 1 then 0, and `count() == 1`
  - `abandonedStagingIsRemoved`
  - `lockedStagingIsKept`: hold the `flock` in the test
  - `invalidPackageIsCountedNotDeleted`
  - `orphanRowsAreRemoved`
- [ ] **Step 2–4: Verify failure, implement, verify pass. Commit** `feat(repo): startup recovery`.

---

### Task 12: Storage adapter contract and filesystem adapter

**Files:** Create `SyncEngine/StorageAdapter.swift` and `FilesystemAdapter/FilesystemAdapter.swift`. Test `Tests/AdapterContractTests/AdapterContract.swift` (the reusable suite) and `Tests/AdapterContractTests/FilesystemAdapterContractTests.swift`.

**Interfaces:**
- Produces in `SyncEngine`:

```swift
public struct StorageCapabilities: Sendable { var supportsFolders, supportsResumableUpload, supportsBackgroundTransfers: Bool
    var serverSideSHA256: Bool; var maxSingleRequestBytes: Int64 }
public struct FileIntegrity: Sendable, Equatable { var byteCount: Int64; var sha256: String }
public struct ProviderHash: Sendable, Equatable { var algorithm: String; var value: String }
public struct RemoteFileInfo: Sendable, Equatable { var relativePath: String; var byteCount: Int64; var providerHash: ProviderHash? }
public struct VerificationEvidence: Sendable, Equatable { var kind: String /* "sha256" | "dropbox_content_hash" | "size_only" */; var value: String }
public struct UploadCheckpoint: Sendable, Equatable { var opaque: Data }
public struct UploadReceipt: Sendable, Equatable { var relativePath: String; var byteCount: Int64; var evidence: VerificationEvidence }
public enum StorageError: Error, Sendable, Equatable { case offline, needsAuthentication, rateLimited(retryAfter: TimeInterval?),
    quotaExceeded, conflict(existing: RemoteFileInfo), checkpointExpired, transient(code: String), permanent(code: String) }
public protocol StorageAdapter: Sendable {
    var capabilities: StorageCapabilities { get }
    func validateDestination() async throws
    func ensureContainer(relativePath: String) async throws
    func inspectFile(relativePath: String) async throws -> RemoteFileInfo?
    /// Returns evidence if `remote` provably matches the local file, nil if it differs.
    func verify(remote: RemoteFileInfo, localURL: URL, expected: FileIntegrity) async throws -> VerificationEvidence?
    func uploadFile(localURL: URL, relativePath: String, expected: FileIntegrity, checkpoint: UploadCheckpoint?,
                    saveCheckpoint: @Sendable (UploadCheckpoint) async throws -> Void) async throws -> UploadReceipt
}
```

- `FilesystemAdapter(root: URL, faults: FaultPlan = .none)`:
  - It writes to `<root>/.tmp-<uuid>` and then `rename`s into place. An existing different file → `conflict`; an identical one → success (idempotent).
  - Its `providerHash` is `sha256`.
  - It simulates resumable uploads: it copies in 1 MiB chunks and calls `saveCheckpoint` with the offset after each one, and it resumes from the checkpoint offset.
  - `FaultPlan` is a `Sendable` final class with a lock. It holds scripted faults keyed by relative path: `failBeforeWrite(StorageError)`, `failAfterBytes(Int64, StorageError)` and `writeButThrow(StorageError)` (the "request uncertainty" case). It also records an `operations: [String]` log, such as `"upload content/x.png"`.
- `AdapterContract` is a generic function, `runAdapterContract(makeAdapter: () async throws -> any StorageAdapter, scratch: URL) async throws`, which Plan 3 calls for Dropbox. Its checks: an exact-path write followed by inspect gives the same size; a repeat identical write is idempotent; a different content write gives `conflict`; `verify` returns evidence for a match and nil for a mismatch; a resumed upload from a checkpoint yields correct bytes.

- [ ] **Step 1: Failing tests:** `filesystemAdapterPassesContract`, `faultWriteButThrowLeavesFileForInspection` and `resumeFromCheckpointProducesCorrectBytes` (on a 5 MiB file, fail after 2 MiB).
- [ ] **Step 2–4: Verify failure, implement, verify pass. Commit** `feat(sync): adapter contract and filesystem adapter`.

---

### Task 13: Retry policy and sync worker

**Files:** Create `SyncEngine/RetryPolicy.swift` and `SyncEngine/SyncWorker.swift`. Test `Tests/SyncEngineTests/RetryPolicyTests.swift` and `Tests/SyncEngineTests/SyncWorkerTests.swift`.

**Interfaces:**
- Consumes `JobStore`, `DestinationStore`, `StoreLayout`, `PackageValidator`, `StorageAdapter`.
- Produces:
  - `struct RetryPolicy: Sendable { var base: TimeInterval = 30; var cap: TimeInterval = 21_600; func delay(attempt: Int, retryAfter: TimeInterval?, random: () -> Double) -> TimeInterval }`. Full jitter: `random() * min(cap, base * 2^(attempt-1))`, then `max(that, retryAfter ?? 0)`.
  - `struct SyncPassResult: Sendable, Equatable { var synced: Int; var failed: Int; var idle: Bool }`
  - `final class SyncWorker: Sendable { init(layout: StoreLayout, jobs: JobStore, destinations: DestinationStore, adapterFor: @Sendable (Destination) throws -> any StorageAdapter, owner: String, policy: RetryPolicy = .init(), now: @Sendable () -> Date = Date.init, random: @Sendable () -> Double = { .random(in: 0...1) }); func runOnce(maxJobs: Int = 20) async -> SyncPassResult }`
- Per-job protocol (exact):
  1. Claim (lease 120 s; renew before each file).
  2. Re-validate the local package with `PackageValidator`. If it's not complete → `blocked`/`local_package_invalid`.
  3. `ensureContainer(relativeDirectory)` and `.../content`.
  4. For each manifest entry **except** `complete.json`, in manifest order, skipping paths that already have a receipt:
     - `inspectFile`. If it's present → `verify`. Evidence → save a receipt. Nil → `blocked`/`remote_conflict`.
     - If it's absent → `uploadFile` with the stored checkpoint, persisting checkpoints via `saveCheckpoint`.
     - Then `inspect` + `verify` the result (don't trust the HTTP response alone). Save the receipt and clear the checkpoint.
     - Before each file, if `cancel_requested` → `markFailed(state: .paused, errorCode: "cancelled", nextAttemptAt: nil)` and stop.
  5. Only once all receipts exist: do the same for `complete.json`, then `markSynced`.
- Error mapping:
  - `offline`/`transient`/`rateLimited` → `retryable_failure` with the policy delay (Retry-After respected)
  - `needsAuthentication` → `needs_authentication`, with no automatic retry
  - `quotaExceeded` → `blocked`/`quota_exceeded`
  - `conflict` → `blocked`/`remote_conflict`
  - `checkpointExpired` → clear that file's checkpoint and retry immediately once within the pass, then `retryable_failure`
  - `permanent` → `blocked`
  - A thrown `JobError.leaseLost` aborts the job silently

- [ ] **Step 1: Failing tests** (FilesystemAdapter + FaultPlan + a temp store)
  - `retryDelayBoundsAndRetryAfter`: with `random` = 1: attempt 1 → 30, attempt 20 → 21600; `retryAfter` 900 with `random` 0 → 900
  - `uploadsAllFilesThenMarkerLast`: the operations log's last entry is `"upload …/complete.json"`, and the remote package validates `.complete`
  - `failureMidPackageNeverUploadsMarker` (acceptance 4/7)
  - `interruptedUploadResumesWithoutDuplicates`: fail after 2 MiB with `offline`, run again → the remote is byte-identical and there's exactly one package directory
  - `writeButThrowIsResolvedByInspection`: the request uncertainty case → synced without a conflict
  - `differentRemoteContentBlocks` → `blocked`/`remote_conflict`, and the remote is untouched
  - `authFailureNeedsAuthentication`, `quotaBlocks` and `rateLimitedSchedulesRetryAfter`
  - `cancelRequestedStopsBeforeMarker`
  - `syncedJobIsNotReclaimed`
  - `noOneDriveOrDropboxImports`: a test greps `Sources/SyncEngine` and `Sources/LocalRepository` for `Dropbox|OneDrive|Graph` → no matches (acceptance 10)
- [ ] **Step 2–4: Verify failure, implement, verify pass. Commit** `feat(sync): sync worker with marker-last protocol`.

---

### Task 14: HippoStore facade, deletion and diagnostics

**Files:** Create `SyncEngine/HippoStore.swift` and `LocalRepository/Diagnostics.swift`. Test `Tests/SyncEngineTests/HippoStoreTests.swift`. Modify `README.md` (create it): a "HippoKit" section covering the module map, `swift test`, fixture regeneration and the storage layout.

**Interfaces:**
- Produces `final class HippoStore: Sendable`. Members:
  - `static func open(root: URL, producer: Producer) throws -> HippoStore`
  - `let layout`, `index`, `jobs`, `destinations`
  - `func recover() throws -> RecoveryReport`
  - `func capture(_ d: CaptureDraft, partialPolicy: PartialPolicy = .rejectPartial) async throws -> CommittedPackage`: commit, then register, then `enqueueIfActive`. If register fails after commit, it still returns success, because the package is the truth and recovery registers it.
  - `func delete(captureID: String) async throws -> DeletionResult`
  - `func writeDiagnostics(appVersion: String) throws`
  - `struct DeletionResult: Sendable, Equatable { var wasSynced: Bool; var hadActiveUpload: Bool }`
- Deletion:
  1. `requestCancel`.
  2. Wait up to 10 s, polling every 100 ms, for any `uploading` lease held by another owner to clear or expire.
  3. Delete the index row (jobs cascade).
  4. Delete the package directory.
  5. Remote copies are never touched.
  The UI uses `wasSynced == false` to show the "not uploaded yet" warning before calling, through `index`/`jobs` queries.
- Diagnostics JSON, `{generated_at, app_version, schema_version, capture_count, jobs_by_state: {state: n}, recent_error_codes: [String] (≤20), destinations: [{provider_kind, status}]}`, contains no IDs, paths, account identifiers, content or locations.

- [ ] **Step 1: Failing tests**
  - `captureThenSyncEndToEnd` (an offline-first flow, acceptance 1, using the filesystem adapter): capture with no destination, then connect, then `runOnce` → synced
  - `commitSurvivesRegisterFailure`: inject a closed DB → the package exists, and `recover()` registers it
  - `deleteDuringActiveUploadCancelsAndNeverTouchesRemote` (acceptance 12): a worker paused mid-file via `FaultPlan`, delete → no marker uploaded, the remote partial files remain, the local package is gone
  - `diagnosticsContainNoContent`: a capture with note "SECRET-NOTE-123", the URL `https://private.example/x` and an account identifier `dbid:ABC` → the diagnostics text contains none of them
- [ ] **Step 2–4: Verify failure, implement, verify pass.**
- [ ] **Step 5: Full suite.** Run: `swift test --package-path HippoKit && scripts/validate-fixtures.sh`. Expected: all tests pass and both schema checks succeed.
- [ ] **Step 6: Commit and push.** Commit `feat(sync): HippoStore facade, deletion, diagnostics`. Then run `git push -u origin feat/hippo-core`, after reading the full branch diff for secrets.

---

## Spec coverage map (self-review)

| Requirement | Task |
|---|---|
| Spec §4 commit steps 1–7, low disk, partial-accept | 5, 11, 14 |
| §4 startup recovery | 11 |
| §5 SQLite, cross-process, modules | 8–10 (CaptureCore/LocalRepository/SyncEngine/adapters) |
| §6 format, schema, fixtures (+ voice) | 1, 2, 6, 7 |
| §7 media facts, honest time zones, allowlisted observations | 4, 5 (Share Extension clue gathering is Plan 2) |
| §8 adapter contract, destinations, switching, unassigned (design §3.6) | 10, 12 |
| §10 states, leases, backoff, marker-last | 10, 13 |
| §11 search/filter/sort/pagination, deletion | 9, 14 (UI is Plan 2) |
| §12 reader contract | 6, 7 |
| §13 redaction | 14 |
| §14 acceptance 1, 3, 4, 7, 8, 10, 11, 12 | 14, 11, 13, 6, 9, 13, 7, 14 |
| Acceptance 2, 5, 6 (device and Dropbox parts), 9, V1–V6 | 9/10 here (switching); the rest in Plans 2–3 |
