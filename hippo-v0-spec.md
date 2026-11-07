# Hippo V0 — iPhone Capture App

Status: implementation specification
Date: 2026-11-07
Working product name: Hippo (the earlier spoken “HIPAA” is interpreted as Hippo).

## 1. Product goal

Build a fast, local-first iPhone app for preserving things the user wants to remember: links, screenshots, photos, videos, documents, shared email content, text, and notes. Replace the habit of emailing oneself. Capture should require no categorization and no AI processing. Preserve the artifact and as much available factual context as practical, then upload a portable copy to a configurable storage backend.

The phone is primarily a capture app with minimal local browsing. A future desktop app can read the files from a locally synced cloud folder, build its own index, and run agents. That desktop app is not part of V0.

## 2. Binding design decisions

- Local files and local metadata are authoritative for captures made on this phone. Saving must work without connectivity, login, or a configured provider.
- Remote storage is a configurable destination accessed through an adapter. OneDrive is the only required production adapter for V0.
- Google Drive, Dropbox, GitHub, and a future custom storage API must fit the architecture without changing capture logic or the portable package format. Do not implement these integrations in V0.
- No custom backend, VPS, Supabase, cloud database, or LLM is required.
- Store ordinary files plus versioned JSON metadata. No proprietary remote database or synced SQLite file.
- No folders, tags, mandatory titles, or task decisions during capture.
- Preserve the representations actually supplied by iOS; do not claim access to unavailable source originals or context.
- Once locally committed, capture packages are immutable. Transfer state and UI state live separately.
- Never label an upload as complete before all required remote files and the completion marker are confirmed.

## 3. V0 scope

### Required

1. Native iPhone app and iOS Share Extension.
2. Capture shared URLs, text, images, videos, PDFs, and generic files; preserve multiple attachments in a single capture.
3. Compose a plain-text note inside the app. Accept shared audio files without requiring transcription.
4. Optional user comment when sharing; saving without a comment remains one tap after opening the extension.
5. Durable local persistence and a shared upload queue.
6. Minimal local capture list, details/preview, text search, filters, and sorting.
7. Settings for storage destination and optional capture-time location collection.
8. OneDrive sign-in, upload, recovery, retry, and status.
9. Provider-neutral interface and filesystem test adapter.
10. Documentation and portable package fixtures for a future desktop reader.

### Deferred

AI enrichment, OCR, embeddings, transcription, autonomous agents, task management, reminders, email forwarding addresses, direct mailbox integrations, webpage archiving, full-text extraction from documents, custom voice recorder, desktop app, multi-device reconciliation, remote browsing/download, remote deletion, editing committed captures, and additional production providers.

Sharing from an email app captures whatever that app exposes. V0 does not promise full MIME email, headers, attachments, sender identity, or message IDs unless explicitly supplied in the shared payload.

## 4. Capture and local commit

The main app and extension use an App Group container and shared capture code. Stream file representations to disk rather than loading large media into memory.

1. Generate a UUID capture ID and record capture-start timestamp/context.
2. Enumerate share items and supported representations. Prefer a high-fidelity file representation where available; retain useful distinct URL/text context too. Avoid copying equivalent representations unnecessarily.
3. Copy the content into a local staging directory while the item provider grants access. Never retain temporary item-provider URLs as durable attachments.
4. Collect fast metadata. Optional slow metadata must not block indefinitely. Do not silently discard failed attachments: show an error or ask the user to explicitly accept a partial capture.
5. Compute sizes and SHA-256 hashes by streaming. Generate portable metadata and a local completion marker.
6. Atomically move the complete package into its final local path on the same volume. Register it in the local index and queue. Treat the filesystem package as recoverable truth if index registration is interrupted.
7. Show “Saved on this iPhone” only after durable local commit. Close the extension promptly and schedule upload when feasible.

At startup, recover abandoned staging operations, discover committed packages missing from the database, and reconcile queue records. A failed or interrupted capture must not appear successfully saved. Low disk space must produce a clear error without damaging previous captures.

## 5. Local storage and app structure

Suggested stack: Swift, SwiftUI, Foundation, UniformTypeIdentifiers, system preview/media APIs, SQLite, URLSession, and Microsoft-supported native authentication tooling. Choose a currently supported stable iOS deployment target and document it.

Use a SQLite-backed repository in the App Group container for capture indexing, filters, queue state, and destination configuration references. SQLite coordinates cross-process access; database transactions must be short. Use appropriate locking/coordination for filesystem commit and queue ownership. Do not sync this database to cloud storage.

Separate these modules:

- CaptureCore: normalization, metadata collection, package creation and validation.
- LocalRepository: local index, migrations, reconciliation, queries.
- SyncEngine: durable jobs, scheduling, retries, destination routing.
- StorageAdapters: provider-specific auth and remote operations.
- MainApp: browsing, notes, setup, settings, status.
- ShareExtension: compact capture UI using the shared modules.

Keep credentials out of capture packages and ordinary settings files. Store credentials/token cache using supported Keychain/auth-library mechanisms; share only the minimum needed access with the extension.

## 6. Portable capture package

Logical remote root: the configured destination’s Hippo folder, preferably the provider’s dedicated app folder when suitable. The provider-neutral relative layout is:

```text
captures/YYYY/MM/DD/<capture-uuid>/
  metadata.json
  content/
    <attachment-uuid>.<extension>
    <another-attachment-uuid>.<extension>
  complete.json
```

Partition by the capture’s recorded local calendar date; preserve that path permanently even if the phone later changes time zone. Use generated safe filenames and store original filenames in metadata. Attachment paths must be relative, unique, and free of traversal. A plain note can use `content/<id>.txt` encoded as UTF-8. A URL-only capture may have no attachments because its URL is stored in metadata.

Use schema version 1, UTF-8 JSON, explicit units, RFC 3339 timestamps, and lowercase hex SHA-256 values. Omit unavailable optional fields or set them to null consistently. Unknown is not an empty string or a fabricated guess. Readers must ignore unknown additive fields and reject unsupported major schema versions clearly.

Illustrative metadata shape (placeholders below are not literal fixture values):

```json
{
  "schema_version": 1,
  "capture_id": "<uuid>",
  "captured_at": "2026-11-07T17:00:00Z",
  "local_datetime": "2026-11-07T09:00:00-08:00",
  "timezone_identifier": "America/Los_Angeles",
  "utc_offset_seconds": -28800,
  "capture_method": "share_extension",
  "content_types": ["image", "url"],
  "user_note": "Gift idea",
  "shared_title": null,
  "shared_text": null,
  "urls": [{"url": "https://example.com/item", "source": "shared_payload"}],
  "source_application": null,
  "capture_location": null,
  "producer": {"app_version": "0.1.0", "build": "1", "os_version": "<version>"},
  "attachments": [
    {
      "attachment_id": "<uuid>",
      "relative_path": "content/<uuid>.png",
      "original_filename": "screenshot.png",
      "uti": "public.png",
      "mime_type": "image/png",
      "byte_count": 123456,
      "sha256": "<64 lowercase hex characters>",
      "representation_source": "item_provider_file",
      "media": {"width_pixels": 1170, "height_pixels": 2532}
    }
  ],
  "metadata_observations": [],
  "extensions": {}
}
```

The coding agent must supply a formal JSON Schema and valid fixtures, including a text note, URL-only capture, image, mixed multi-attachment capture, and video.

`complete.json` contains schema version, capture ID, and a manifest listing every required file except itself, with relative path, byte count, and SHA-256. Include `metadata.json` and every attachment. It is written only after the package is finalized; upload the identical marker last. Never put mutable sync timestamps, credentials, provider IDs, or temporary upload-session URLs into the package.

## 7. Metadata collection without LLMs

Capture factual context with supported APIs and retain provenance. Do not use private APIs or scrape unrelated phone state.

| Metadata | Requirements |
| --- | --- |
| Capture time | UTC instant, local date/time, time-zone identifier, offset; no need to persist a redundant “morning” label |
| Method | share_extension, typed_note, or file_import; allow future values |
| Shared context | title, text, URLs, optional user comment, and useful safe serializable context explicitly provided |
| Source application | optional, only when reliably available through supported APIs; never infer app identity from a URL host |
| File facts | original filename if available, type identifiers, MIME type, size, hash |
| Media facts | dimensions, duration, embedded creation timestamp, embedded GPS/camera information when available |
| Capture location | optional permission-based best effort, with latitude/longitude, accuracy meters, observation timestamp, and provenance |
| Producer | app/build/OS version; a locally generated install ID only if needed, never a hardware identifier |

Keep capture location, embedded media location, and a referenced place separate. Saving a holiday photo at home must not change where it was taken. Preserve timestamps with unknown embedded time zones as such rather than assigning the capture time zone.

Location is disabled until the user opts in. Ask for permission in an appropriate main-app flow. Capture must work when denied, restricted, unavailable, or imprecise. Do not request continuous/background tracking. Do not wait for a fresh fix in the Share Extension; use context only when legitimately accessible, label its age and accuracy, or omit it. Validate actual extension capabilities on a physical device.

Do not fetch webpages, geocode addresses, run OCR, or enrich via an LLM in V0. Optional metadata collection must not cause an otherwise valid artifact to fail. Preserve useful bounded metadata using an allowlist rather than blindly serializing arbitrary dictionaries.

## 8. Configurable storage adapters

“Configurable storage” means the local repository is fixed and reliable while the upload destination is replaceable. Local capture does not depend on a provider SDK.

Persist a destination record with stable ID, provider kind, account identifier, remote root, display name, and status. Store secrets separately. Each capture-destination pair has its own upload job and state. V0 UI supports one active destination; the model must permit more later without a format change.

Define a provider-neutral contract with equivalents of:

```swift
protocol StorageAdapter {
    var capabilities: StorageCapabilities { get }
    func validateDestination() async throws
    func ensureContainer(relativePath: String) async throws
    func inspectFile(relativePath: String) async throws -> RemoteFileInfo?
    func uploadFile(localURL: URL, relativePath: String,
                    expected: FileIntegrity, checkpoint: UploadCheckpoint?) async throws -> UploadReceipt
}
```

The exact Swift types can evolve. The contract must support asynchronous operations, cancellation, structured errors, idempotent exact-path writes, opaque persisted resume checkpoints, remote verification evidence, and provider capabilities. A successful HTTP request alone is not enough to report an entire capture synced.

Authentication UI belongs to the main app. Background execution must report `needs_authentication` instead of attempting interactive login. The adapter owns provider-specific SDKs, chunk sizing, path encoding, rate limits, and resumable sessions. The sync engine owns package semantics and marker ordering.

Do not assume every provider supports folders, atomic rename, server-side SHA-256, background transfers, or individual-file writes equally. GitHub, for example, may need batching into a commit and has binary/repository constraints; leave room for a package-level upload optimization. Do not store credentials in a Git repository. Future adapter implementations must document limitations and any additional permissions.

Implement a local filesystem adapter for development and contract tests. It is not an advertised cloud provider.

### Provider switching

Changing destination affects future captures. Existing jobs remain bound to their original destination unless the user explicitly pauses them. Offer a separate explicit “Upload existing local captures to this destination” action; this creates new jobs without altering packages or deleting old remote copies. Signing out pauses that destination’s jobs and retains local data. Never silently upload one account’s pending jobs into a different account.

## 9. OneDrive V0 adapter

Use Microsoft Graph and supported native OAuth tooling as a public client. No embedded client secret. Prefer delegated app-folder access with the least permissions that actually work for the supported account type. Personal Microsoft accounts are the V0 target; work/school account support is optional and must not be claimed without validation.

Resolve and persist the actual remote root identity; do not hardcode the desktop folder’s display path. Use file upload for suitable small files and resumable upload sessions for larger files according to current Graph documentation. Persist resume state securely; treat upload URLs as sensitive temporary credentials.

Upload attachments and metadata first, validate their remote presence/size and provider-supported integrity evidence, then upload the completion marker last. Handle request uncertainty by inspecting the existing destination rather than creating new IDs. If existing content conflicts with the immutable local package, stop and surface the conflict; never silently overwrite different data or invent a new capture.

Use durable per-file progress. Handle token expiry, revoked authorization, offline operation, throttling with Retry-After, quota exhaustion, server errors, and expired upload sessions. Preserve local content on every failure. Do not equate a provider-specific hash with SHA-256; document the verification guarantee and test remote download/hash round trips during integration validation.

## 10. Sync engine and lifecycle

Suggested capture-destination states: pending, uploading, synced, retryable_failure, needs_authentication, blocked, paused. Keep attempt count, next retry time, last safe error, per-file receipts, and resume checkpoints in the local database.

Only one worker may own a job at once across the app and extension. Use transactional claiming and recoverable leases. Retry transient failures with bounded exponential backoff and jitter, respecting server instructions. Quota/configuration/content conflicts require visible user action rather than tight automatic retries.

Use file-backed background URLSession transfers where the chosen adapter permits them, with the shared container configured. Support foreground catch-up whenever the app opens. iOS controls background scheduling; do not promise immediate upload after an extension closes, after force-quit, or while the device is locked. Expose a manual retry/sync action.

Keep local originals indefinitely in V0; no automatic eviction. OneDrive upload is a copy, not a complete backup policy. Remote changes or deletion are not automatically mirrored back into the phone. New installations do not automatically reconstruct the collection from cloud storage in V0; document this limitation.

## 11. Minimal phone experience

Use the product vocabulary “Captures” or “Library,” never “Inbox.” Keep the interface quiet and functional.

### Share Extension

Compact preview/count, optional note, Save, Cancel. No folder picker, tagging, login wall, or mandatory title. If cloud setup is missing, save locally anyway. Unsupported items or failed attachment copies must be explained clearly.

### Capture list

A vertical list, newest first, grouped by local capture day. Each row shows a small preview/type icon, supplied title or deterministic fallback, date/time, note excerpt, and sync status. No generated summaries. Lazy thumbnails and paginated database queries must keep large collections responsive.

Provide simple local search over supplied title, user note, shared text, URL, and original filename. Do not imply OCR or document-content search. Search must work offline.

Filters: day/date range; content type; capture method; has location; sync status. Mixed captures match any relevant attachment type. Sort newest/oldest with stable capture-ID tie-breaking. Additional metadata filters can be added later; avoid a general query builder.

### Capture details

Preview supported local content, list attachments, open links, share/export content, and display captured context with missing values omitted. Clearly distinguish the optional user note from supplied text. Show upload state and actionable errors. Read-only after commit in V0.

### Settings

Connect/disconnect storage, destination/account display, sync status and retry, upload existing captures, optional location, and local storage usage. Provider picker displays implemented providers only; do not show nonfunctional Google Drive/Dropbox/GitHub choices as working integrations.

### Local deletion

Allow explicit local deletion with confirmation. Warn when the capture has not synced; explain that local deletion does not delete an already uploaded remote copy. Coordinate cancellation of pending transfers before deletion. A partially uploaded package may remain remote without a completion marker and must be ignored by readers. Remote cleanup and cross-device deletion are deferred.

## 12. Future desktop-reader contract

A desktop reader locates the configured Hippo root in a provider-synced directory, watches it, and periodically rescans for missed changes. It must not assume filesystem event order or that cloud placeholder files are downloaded.

Process only packages with `complete.json`, supported schema, safe paths, and all manifest files available with correct sizes and hashes. Missing or mismatched files are incomplete/pending and should be retried before surfacing corruption. Index by capture ID and package digest for idempotence.

The desktop’s SQLite/search/vector indexes live outside the synced folder and can be rebuilt completely from packages. Future AI outputs should live in separate derived storage keyed by capture ID, not mutate original captures. OneDrive and similar providers can supply desktop folder synchronization; a future GitHub/custom provider may require its own desktop retrieval mechanism.

## 13. Security and operational constraints

Use TLS, OS file protection compatible with the supported background-transfer behavior, and Keychain-backed credentials. Document lock-state limitations rather than weakening protection silently. Redact tokens, signed URLs, content, and precise location from logs. No analytics or third-party content processing by default. This design is not end-to-end encryption against the chosen storage provider; do not claim that property.

Validate all relative paths, sizes, and JSON inputs. Never execute attachments or render active HTML as trusted app content. Preserve originals without silently recompressing media. Do not assume source metadata survives sharing.

## 14. Required validation

Automate meaningful package/schema, persistence/recovery, adapter-contract, and sync failure tests. Use physical-device tests for extension and lifecycle behavior.

Acceptance scenarios:

1. Offline sharing of a screenshot saves locally, appears in the list, and uploads later.
2. URL-only, typed note, PDF, audio file, mixed attachments, and large video round-trip with correct bytes and grouping.
3. Crash after package commit but before database insertion recovers exactly once.
4. Interrupted/expired upload resumes or safely restarts without duplicate captures or premature markers.
5. Missing permission/source metadata never prevents capture; no context is fabricated.
6. Token expiry, sign-out, quota exhaustion, throttling, and account switching preserve content and expose correct states.
7. Completion marker arriving first on desktop does not permit indexing absent or corrupt files.
8. Local search/filter/sort work offline and remain usable with at least 10,000 synthetic capture records.
9. Changing destination does not reroute existing account-bound jobs; explicit historical upload retains IDs and bytes.
10. Filesystem adapter contract tests prove capture/sync modules have no OneDrive-specific dependency.
11. Exported packages validate against JSON Schema and can be read without the app/database.
12. Local deletion handles active transfer races and never silently deletes remote copies.

## 15. Implementation sequence and deliverables

1. Verify current Apple extension/background APIs, Microsoft authentication setup, app-folder permissions, and Graph upload behavior. Document actual supported versions/account types. Resolve feasibility with a physical-device spike before building assumptions into UI.
2. Implement portable schema, package writer/validator, filesystem adapter, local database, recovery, and fixtures.
3. Build note capture, Share Extension, and minimal offline browsing.
4. Add OneDrive auth, durable upload engine, completion protocol, and failure handling.
5. Run device and integration acceptance scenarios; document known limits.

Deliver an Xcode project, source code, JSON Schema, example packages, meaningful tests, and README with signing/App Group/Keychain configuration, Microsoft app registration/redirect setup, required permissions, build/install instructions, storage layout, provider-extension guide, and acceptance-test results. No credentials in the repository. Record unresolved items plainly rather than claiming untested lifecycle support.

## 16. Reference documentation

These are implementation starting points; coding agents must verify current APIs and constraints.

- Apple: https://developer.apple.com/documentation/foundation/nsitemprovider
- Apple shared containers/background transfers: https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html
- Apple extension items: https://developer.apple.com/documentation/foundation/nsextensionitem
- OneDrive app folder: https://learn.microsoft.com/en-us/graph/onedrive-sharepoint-appfolder
- Graph resumable uploads: https://learn.microsoft.com/en-us/graph/api/driveitem-createuploadsession

## 17. Instruction to the implementation agent

Implement the iPhone V0 described here. Prioritize durable capture and honest sync state over extra features. Use OneDrive first while keeping capture storage and transfer orchestration provider-neutral. Keep browsing minimal. Do not build AI, a desktop app, a VPS, or additional production providers. Make routine implementation choices autonomously, document them, and call out any platform limitation that materially changes a requirement.
