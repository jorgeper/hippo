# Hippo Dropbox (Plan 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Dropbox the first real destination: connect from Settings, upload everything verified and resumable (in the background where iOS allows), delete both ways with tombstones and a safety valve, "Save space" (trim verified large files, download on tap), and "Download from Dropbox" (a recent window, light form), all through the provider-neutral `StorageAdapter` contract.

**Architecture:**
- **`DropboxAdapter`**, a new HippoKit target (depends on `SyncEngine`, `CaptureCore`): `DropboxAuth` (PKCE, token store, cross-process refresh lock), `DropboxTransport` (foreground `URLSession`; a background upload-from-file session in the app), `DropboxClient` (HTTP calls, error mapping), `DropboxAdapter: StorageAdapter`, `DropboxContentHash`. Nothing else in HippoKit imports it: `Package.swift` is the fence.
- **Contract additions** (`SyncEngine/StorageAdapter.swift`): `deleteFolder`, `latestCursor`, `listFolder`, `thumbnail`, `downloadFile` with progress; `FilesystemAdapter` implements them; `AdapterContract` covers them on both adapters (Dropbox under a test root when `.env` has credentials).
- **Durable state** (`LocalRepository`, schema v4): `RemoteStateStore` (remote-delete tombstones, local-delete records, per-destination change cursor, review items, "changed in Dropbox" records) and `TrimStore` (trimmed attachments). Thumbnails live in `<root>/thumbnails/`, transfer scratch in `<root>/transfers/`.
- **Sync steps** (`SyncEngine`): `RemoteDeleter` (tombstones, before uploads), `RemoteChangeDetector` (after uploads, like the gold pull), `SpaceSaver`, `AttachmentRestorer`, `RemoteDownloader`. `HippoStore` grows `deleteEverywhere`, `uploadAgain`, `removeAfterRemoteDelete` and the factories. `SyncCoordinator` runs the two new steps.
- **Presentation** (`HippoPresentation`): Storage status line, trimmed attachments and "changed" state in `CaptureDetail`; `DeletionPrompt.everywhere`; `RemoteReviewModel`, `SpaceSaveModel`, `DownloadModel`; Settings summary additions. Copy uses the destination's display name, never a hard-coded "Dropbox", except where the design fixes the words.
- **App**: `DropboxProvider` (`ASWebAuthenticationSession`, Keychain access group, background `URLSession` events), the connect sheet, Settings rows, the Save space / Download / Review sheets, the review banner, trimmed-attachment UI, connectivity and retry-timer triggers, `scripts/setup-dropbox.sh`.

**Tech Stack:** Swift 6 language mode, Swift Testing, SQLite, Foundation `URLSession`, CryptoKit, Security (Keychain), ImageIO/AVFoundation (local thumbnails), `AuthenticationServices` (app only), XcodeGen, Xcode 27.2. No third-party dependencies (direct HTTP, not SwiftyDropbox; see Task 1's ADR).

**Spec:** `docs/superpowers/specs/2026-11-08-hippo-dropbox-design.md` (wins on conflict; §n below refers to it), on top of `2026-11-07-hippo-v0-design.md` §3.1. Executors read the Dropbox design in full. Background: `2026-11-08-hippo-dropbox-brainstorm.md`.

**Branch:** `feat/dropbox` (checked out, from `main` after PR #5).

## Plan-level calls (decisions the design left to the builder, §10)
- **Direct HTTP, not SwiftyDropbox.** The SDK owns its own OAuth manager and Keychain layout, so the cross-process refresh lock (§6.1) and the provider-neutral checkpoint (session ID + offset) would fight it, and HippoKit stays dependency-free and `swift test`-able on macOS. Task 1 records this in `docs/adr/0002-dropbox-direct-http.md`.
- **Destination identity:** `Destination(id: "dropbox:<account_id>", providerKind: "dropbox", accountIdentifier: <account_id>, remoteRoot: "", displayName: <name.display_name>)`. The ID is per account, so `DestinationStore.connect` resumes the same account and `accountMismatch` can't happen; the change cursor keyed by destination ID is therefore per account and survives Disconnect (§4.3).
- **Account binding check:** `users/get_current_account` runs at connect and in `validateDestination()`; a mismatch with the destination's `accountIdentifier` throws `.permanent(code: "account_mismatch")`. It is not re-checked per call: a refresh token belongs to one account.
- **Upload shape:** files ≤ 8 MiB go in one `files/upload`; larger files use upload sessions with 8 MiB chunks (a multiple of Dropbox's 4 MiB alignment, well under the 150 MiB per-request cap). Checkpoint = `{"session_id":…, "offset":…}` (sensitive; never logged). `incorrect_offset` adopts `correct_offset` and continues; a `not_found`/`closed` session throws `.checkpointExpired`.
- **Backoff:** the sync engine's existing `RetryPolicy` stays; the adapter itself retries nothing except one token refresh after a 401.
- **Trimmed state and thumbnails** live in `hippo.sqlite` (`trimmed_attachments`) and `<root>/thumbnails/<attachment-id>.jpg`, never in packages (§6.3–6.4).
- **Cross-process refresh lock:** `flock(LOCK_EX)` on `<store root>/dropbox-refresh.lock`; after taking it the store is re-read, so a refresh done by the other process is reused. Dropbox doesn't rotate refresh tokens, but two processes still must not race the access-token write.
- **Tombstone rows** are removed on success (no `done` state); `pending` and `failed` rows carry `attempt_count`, `next_attempt_at_ms` and `last_error_code`.
- **Remote-originated deletions** are applied with `HippoStore.removeAfterRemoteDelete`, which logs `capture.deleted` with `trigger: "remote"` and writes no local-delete record (Download wouldn't find the capture anyway).
- **Download window** lists `captures/YYYY/MM/` folders from one day before the window start; each candidate's `metadata.json` is downloaded first and the capture is skipped (not failed) when `captured_at` is outside the window, so the window applies to `captured_at` as §4.5 says.
- **Enrichment on trimmed files:** enrichers that read attachment bytes (`TextRecognitionEnricher`, `TranscriptEnricher`) declare `readsAttachmentBytes = true`; the runner doesn't schedule those kinds for a capture with a trimmed attachment and leaves any existing row as it is (§6.3).
- **Downloaded captures' enrichment:** the imported device document's facets become `enrichment_tasks` rows at the facet's version and status, so the runner only queues missing or outdated kinds (§4.5); the device revision is marked uploaded for the connected destination so silver isn't re-uploaded.
- **Review items** are per capture (`remote_review_items`), one reason each (`threshold`, `root_missing`, `cursor_reset`); the sheet shows every pending item for the active destination.
- **`StorageProvider.accountStatus(_:)`** (new, defaulted to `.ok`) lets Settings show "Reconnect <name>" after a revoked or expired sign-in even when no job has failed yet.
- **Redirect URI:** `db-<app key>://2/token` (the Dropbox convention), handled by `ASWebAuthenticationSession` with `callbackURLScheme: "db-<app key>"`; the setup script tells Jorge to register it.

## Global Constraints
- iOS 27.0 / macOS 27.0, Swift 6 language mode, no third-party dependencies. HippoKit targets import no UIKit/SwiftUI/AuthenticationServices and stay `swift test`-able on macOS (`make test`).
- **Secrets:** the app key lives only in gitignored `Config/Secrets.xcconfig` (committed `Config/Secrets.example.xcconfig` holds `HIPPO_DROPBOX_APP_KEY = YOUR_APP_KEY`); test credentials only in gitignored `.env` (committed `.env.example`). Never print or paste a full key or token: show the first and last four characters. Tokens, refresh tokens, upload session IDs, cursors, the account email and display name never appear in log events, `diagnostics.json`, packages, error codes or os_log.
- **Provider neutrality (§2 anti-goal):** Dropbox-specific code only in the `DropboxAdapter` target and `App/Hippo/Storage/`. `SyncEngine`, `LocalRepository`, `HippoPresentation` and `Enrichment` never depend on `DropboxAdapter` (Package.swift).
- **Never overwrite an existing remote file** except under `enrichments/` and `logs/` (`replaceFile`). `deleteFolder` works only under `captures/` and `enrichments/`, at least two segments deep.
- **Absence never deletes.** Nothing in Dropbox is deleted unless a tombstone exists; nothing on the phone is deleted or trimmed unless verified in Dropbox (§2).
- **Cancellation:** every Dropbox foreground call honours Task cancellation within 2 s (`BackgroundActivity.expiryGrace`) by cancelling its `URLSessionTask`; background-session uploads are exempt.
- **The UI never reads the log to decide state.** Every new log event name is in the closed `LogEventName` set and documented in `docs/log-format.md`; every code passes `Diagnostics.safeCode`.
- Exact copy (design §4; `<name>` = destination display name):
  - Connect sheet: title "Connect <provider name>", lines "Hippo will create a folder called Apps/Hippo in your Dropbox." and "Hippo can see only that folder.", button "Connect".
  - Settings, connected: the display name row, the existing summary, "Save space…", "Download from <name>…", "Disconnect". Not connected: "Connect <provider name>". Sign-in expired: "Reconnect <name>".
  - Disconnect confirmation: "Disconnect <name>? Nothing is deleted on this iPhone or in <name>." plus, when trimmed files exist, " Files kept only in <name> can't be downloaded until you reconnect." Button "Disconnect".
  - Detail menu: "Delete from iPhone…" (unchanged) and "Delete everywhere…" (only when a destination is bound). Everywhere prompt: title "Delete everywhere?", message "Delete from this iPhone and from <name>? <name> keeps deleted files for a while, so you can restore them on dropbox.com.", button "Delete everywhere".
  - Storage status line: "In <name> · verified", "Uploading…", "Waiting for a connection", "Changed in <name>", "Large files in <name> only".
  - Changed: Detail button "Upload again from iPhone"; trimmed-and-gone text "This file was only in <name> and is gone there. Restore it from Dropbox's deleted files on dropbox.com."
  - Review sheet: banner "<name> looks different"; sheet lists "N captures, <date range>" and, when present, "N of these have large files only in <name>"; buttons "Remove them from iPhone", "Keep and upload again" (or "Keep on iPhone as they are" for the trimmed group), "Decide later"; footer "You can restore deleted files on dropbox.com for a while."
  - Save space sheet: pickers "Older than" (1 week, 1 month, 3 months, 1 year; default 1 month) and "Larger than" (1 MB, 10 MB, 50 MB, 100 MB; default 10 MB); estimate "Frees about <bytes> from <n> captures"; empty "Nothing older than <age> and larger than <size> is in <name> yet"; note "These files will then be only in <name>."; button "Save space"; offline footer "Connect to the internet to save space."
  - Trimmed attachment: "In <name> · Download (<size>)"; not available: "Connect <name> (account <display name>) to download"; mismatch: "Changed in <name>: this file no longer matches".
  - Download sheet: picker "From the last" (2 weeks, 1 month, 3 months, 6 months, 1 year, everything; default 1 month); estimate "About <n> captures, <bytes>"; "Skipping <n> you removed from this iPhone" with switch "Include them" (off); button "Download"; result "<n> couldn't be downloaded".
  - Settings summary additions: "<n> delete(s) waiting to reach <name>", "Sign in again to <name>", "<name> looks different · review".
- Missing values are omitted, never "Unknown". Quiet native iOS, Dark Mode, Dynamic Type.
- App build check (App tasks): `xcodegen generate && xcodebuild -project Hippo.xcodeproj -scheme Hippo -configuration Debug -destination generic/platform=iOS -derivedDataPath build/DerivedData -allowProvisioningUpdates build`. Expected: `** BUILD SUCCEEDED **`. Without `Config/Secrets.xcconfig` the build still succeeds and the Dropbox provider is absent.
- Commit after every task. Before each commit, run `git diff --cached` and read all of it for secrets (Jorge's global rule). End commit messages with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

## Review Focus
1. **A deleted package folder arrives as one `deleted` entry for the folder (Dropbox) or as one entry per file (FilesystemAdapter).** Both must count as "the capture is gone", and a folder entry for a capture the phone never had must be ignored. Owned by Task 9 (`folderDeleteEntryRemovesCapture`, `fileDeletesRemoveCapture`, `unknownCaptureChangesAreIgnored`).
2. **Another phone's uploads show up in `listChanges` as upserts under directories this phone doesn't index.** They must never be reported as "changed" or trigger anything. Owned by Task 9 (`unknownCaptureChangesAreIgnored`).
3. **The app is killed mid-session after a chunk landed but before its checkpoint was saved.** The resume must adopt Dropbox's `correct_offset`, not restart or corrupt. Owned by Task 4 (`incorrectOffsetAdoptsCorrectOffset`).
4. **The app and the Share Extension both need a fresh access token at the same moment.** One refresh request, both get the token, no UI anywhere; an `invalid_grant` marks the account as needing sign-in. Owned by Task 3 (`concurrentRefreshesShareOneRequest`, `invalidGrantMarksNeedsReauthentication`).
5. **A remote package whose `complete.json` exists while an attachment is still syncing from another device.** Download must skip it, count it, and leave nothing in the index or `captures/`. Owned by Task 13 (`incompleteRemotePackageIsSkippedAndNotIndexed`).

---

### Task 1: Secrets plumbing, setup script, ADR, `DropboxAdapter` target with content hash

**Files:**
- Create: `Config/Secrets.example.xcconfig`, `.env.example`, `scripts/setup-dropbox.sh`, `docs/adr/0002-dropbox-direct-http.md`, `HippoKit/Sources/DropboxAdapter/DropboxContentHash.swift`, `HippoKit/Tests/DropboxAdapterTests/ContentHashTests.swift`
- Modify: `Config/Base.xcconfig`, `project.yml`, `Makefile`, `HippoKit/Package.swift`, `scripts/install-device.sh`, `.gitignore` (confirm `Config/Secrets.xcconfig` and `.env` are listed; they are), `README.md` (a "Dropbox setup" section linking the script)

**Interfaces:**
- Produces:
  - `Config/Base.xcconfig`: `HIPPO_DROPBOX_APP_KEY =` (empty default) before `#include? "Secrets.xcconfig"`.
  - `project.yml`, Hippo target `info.properties`: `HippoDropboxAppKey: $(HIPPO_DROPBOX_APP_KEY)` and `CFBundleURLTypes: [{CFBundleURLSchemes: ["db-$(HIPPO_DROPBOX_APP_KEY)"], CFBundleURLName: com.jorgeper.hippo.dropbox}]`. HippoShare target gets `HippoDropboxAppKey` too (it never signs in; the key is harmless and keeps one Info layout).
  - `Package.swift`: `.target(name: "DropboxAdapter", dependencies: ["SyncEngine", "CaptureCore"])`, product `DropboxAdapter`, `.testTarget(name: "DropboxAdapterTests", dependencies: ["DropboxAdapter", "SyncEngine", "CaptureCore"])`; `AdapterContractTests` gains the `DropboxAdapter` dependency. The Hippo app target lists `DropboxAdapter` in its products (HippoShare does not).
  - `public enum DropboxContentHash { public static let blockSize = 4 * 1024 * 1024; public static func of(_ url: URL) throws -> String; public static func of(_ data: Data) -> String }`: SHA-256 of each 4 MiB block, then SHA-256 of the concatenated block digests, lowercase hex.
  - `scripts/setup-dropbox.sh` (bash, `set -euo pipefail`): prints the App Console steps (create app → Scoped access → App folder → name "Hippo"; Permissions tab: `files.content.write`, `files.content.read`, `files.metadata.read`, `account_info.read`, Submit; Settings tab: add redirect URI `db-<APP KEY>://2/token`), reads the app key with `read -r -s` (never echoed), validates `^[a-z0-9]{15}$`, writes `Config/Secrets.xcconfig` (`chmod 600`), prints `HIPPO_DROPBOX_APP_KEY = abcd…wxyz`; then offers the optional one-time PKCE sign-in for integration tests: builds verifier/challenge with `openssl rand -base64 48 | tr '+/' '-_' | tr -d '='` and `openssl dgst -sha256 -binary | base64 | tr …`, prints the authorize URL (`https://www.dropbox.com/oauth2/authorize?client_id=…&response_type=code&token_access_type=offline&code_challenge=…&code_challenge_method=S256`, no redirect URI so the code is shown in the browser), reads the code silently, exchanges it with `curl -s https://api.dropboxapi.com/oauth2/token` (`grant_type=authorization_code`, `code_verifier`, `client_id`), extracts `refresh_token` with `python3 -I -c`, writes `.env` (`chmod 600`) with both variables, prints only masked values, and ends by saying to run `make generate`. If `.env` or `Secrets.xcconfig` exists it asks before overwriting.
  - `Makefile`: `dropbox-setup: scripts/setup-dropbox.sh`. `install-device.sh` warns (doesn't fail) when `Config/Secrets.xcconfig` is missing: "Dropbox is not configured; run make dropbox-setup".
  - `docs/adr/0002-dropbox-direct-http.md`: context (v0 §3.1 criteria), decision (direct `URLSession`), consequences, and the API facts the adapter relies on with the Dropbox docs URLs checked (upload 150 MiB/request, 4 MiB alignment, `content_hash` algorithm, `list_folder` ≤ 2000 per page, `Retry-After`, PKCE refresh without secret, `token/revoke` also revokes the refresh token).

- [ ] **Step 1: Write the failing test** `ContentHashTests`:
  - `smallFileHashIsDoubleSHA256`: for 1000 bytes, `DropboxContentHash.of(data) == hex(SHA256(SHA256(data)))`.
  - `multiBlockHashConcatenatesBlockDigests`: 4 MiB + 123 bytes → equals hex(SHA256(SHA256(block0) ‖ SHA256(block1))); `of(url)` equals `of(data)` for the same bytes.
  - `emptyFileHashIsSHA256OfNothing`: `of(Data()) == hex(SHA256(Data()))` (zero blocks → hash of the empty concatenation).
- [ ] **Step 2:** Run `swift test --package-path HippoKit --filter ContentHashTests`. Expected: FAIL (target missing).
- [ ] **Step 3:** Implement the target, the xcconfig/project.yml/Makefile changes, the script, the ADR and the README section. Run `bash -n scripts/setup-dropbox.sh` and `chmod +x` it.
- [ ] **Step 4:** Run the filter, then `make test`, then the App build check (no `Secrets.xcconfig` present). Expected: PASS, `** BUILD SUCCEEDED **`.
- [ ] **Step 5:** Commit `feat(dropbox): adapter target, content hash, secrets plumbing, setup script, ADR 0002`.

### Task 2: Contract additions on `StorageAdapter` and `FilesystemAdapter` (§5)

**Files:**
- Create: `HippoKit/Sources/CaptureCore/Media/LocalThumbnailer.swift`
- Modify: `HippoKit/Sources/SyncEngine/StorageAdapter.swift`, `HippoKit/Sources/FilesystemAdapter/FilesystemAdapter.swift`, `HippoKit/Tests/AdapterContractTests/AdapterContract.swift`, `HippoKit/Tests/AdapterContractTests/FilesystemAdapterContractTests.swift`, every test wrapper adapter (`HookedAdapter`, `PausingAdapter` in `SyncEngineTests/Support/SyncHarness.swift`; `HeldAdapter` in `HippoPresentationTests/Support/FakeStorageProvider.swift`; `GrowingAdapter` in `LogUploaderTests.swift`) forwards the new methods
- Test: `HippoKit/Tests/CaptureCoreTests/LocalThumbnailerTests.swift`

**Interfaces:**
- Produces (all `public`, `Sendable`):
  - `StorageCapabilities.supportsThumbnails: Bool` (new init parameter, default `false`).
  - `struct RemoteEntry: Equatable { var relativePath: String; var isFolder: Bool; var byteCount: Int64; var providerHash: ProviderHash? }`
  - `struct ListPage: Equatable { var entries: [RemoteEntry]; var cursor: String?; var hasMore: Bool }`
  - `StorageAdapter` gains:
    - `func deleteFolder(relativePath: String) async throws`: recursive, idempotent; not-found is success. Throws `.permanent(code: "invalid_path")` for an unsafe path and `.permanent(code: "delete_not_allowed")` unless the path starts with `captures/` or `enrichments/` and has at least two segments.
    - `func latestCursor(under prefix: String) async throws -> String`: a cursor for changes from now on, listing nothing. Creates the prefix folder if it doesn't exist.
    - `func listFolder(relativePath: String, recursive: Bool, cursor: String?) async throws -> ListPage`: files and folders with sizes and hashes; `cursor` nil starts; a missing folder returns an empty page with `hasMore == false`. Hidden entries (a segment starting with `.`) are never reported.
    - `func thumbnail(relativePath: String, maxPixelSize: Int) async throws -> Data?`: JPEG bytes or nil when the provider can't make one; callers check `supportsThumbnails` first.
    - `func downloadFile(relativePath: String, to localURL: URL, maxBytes: Int64, progress: (@Sendable (Int64) -> Void)?) async throws -> RemoteFileInfo` (bytes written so far). An `extension StorageAdapter` keeps the old 3-parameter signature as a convenience calling the new one with `nil`.
  - `listChanges` doc comment: a `.deleted` entry may name a folder (the whole subtree is gone) or a file; implementations may report either.
  - `LocalThumbnailer` (CaptureCore): `public static func jpeg(for url: URL, uti: String, maxPixelSize: Int) async -> Data?`: images via ImageIO (`CGImageSourceCreateThumbnailAtIndex`, transform applied, JPEG 0.8), video via `AVAssetImageGenerator` at 0 s, else nil. Never throws.
  - `FilesystemAdapter`: `deleteFolder` removes the directory; `latestCursor` writes a snapshot like `listChanges(cursor: nil)` and returns only its ID; `listFolder` walks the directory (recursive or one level) in one page; `thumbnail` uses `LocalThumbnailer` with the UTI from the extension; `supportsThumbnails: true`; `downloadFile(progress:)` reports once with the full size.

- [ ] **Step 1: Write failing tests** in `AdapterContract` (a new `runFolderOperationsContract(adapter:scratch:)` called at the end of `runAdapterContract`):
  - `deleteFolder` of `captures/2026/11/07/abc` after uploading two files there → `inspectFile` of both is nil; a second `deleteFolder` succeeds; `deleteFolder("captures/2026/11/07/never")` succeeds.
  - `deleteFolder("captures")`, `deleteFolder("enrichments")`, `deleteFolder("logs/abc")`, `deleteFolder("other/x")` → `.permanent(code: "delete_not_allowed")`; `deleteFolder("captures/../x")` → `.permanent(code: "invalid_path")`.
  - `latestCursor(under: "captures/")` on an empty root → non-empty; a file uploaded afterwards shows up in `listChanges(under: "captures/", cursor: that)`; nothing uploaded before it does.
  - `listFolder("captures/2026/11", recursive: true, cursor: nil)` (paging until `hasMore` is false) lists every file under two capture dirs with their byte counts, and the folders with `isFolder`; non-recursive lists only the direct children; `listFolder("captures/2099/01", …)` → empty page.
  - `thumbnail` of an uploaded PNG (use `HippoTestSupport.MediaMaker`; add it to the test target's dependencies) returns JPEG bytes (`FF D8` prefix) when `supportsThumbnails`, and `thumbnail` of a `.bin` file returns nil.
  - `downloadFile(progress:)` reports a final value equal to the file size.
  - `LocalThumbnailerTests.imageAndVideoProduceJPEG`, `unknownTypeIsNil`.
- [ ] **Step 2:** Run `make test`. Expected: the new tests FAIL (and the wrappers fail to compile until Step 3).
- [ ] **Step 3:** Implement. Update the wrappers to forward every new method.
- [ ] **Step 4:** Run `make test`. Expected: PASS.
- [ ] **Step 5:** Commit `feat(sync): deleteFolder, latestCursor, listFolder, thumbnail and download progress in the adapter contract`.

### Task 3: Dropbox auth: PKCE, token store, refresh lock, transport (§6.1)

**Files:**
- Create: `HippoKit/Sources/DropboxAdapter/DropboxTokens.swift`, `TokenStore.swift` (protocol + `MemoryTokenStore` + `FileTokenStore` + `KeychainTokenStore`), `PKCE.swift`, `DropboxTransport.swift` (protocol, `DropboxRequest`, `DropboxResponse`, `URLSessionTransport`), `DropboxAuth.swift`
- Test: `HippoKit/Tests/DropboxAdapterTests/Support/ScriptedTransport.swift`, `HippoKit/Tests/DropboxAdapterTests/DropboxAuthTests.swift`

**Interfaces:**
- Produces (all `public`, `Sendable`):
  - `struct DropboxTokens: Codable, Equatable { var accessToken: String; var expiresAt: Date; var refreshToken: String; var accountID: String; var needsReauthentication: Bool = false }`
  - `protocol TokenStore { func load() throws -> DropboxTokens?; func save(_ t: DropboxTokens) throws; func clear() throws }`
    - `final class MemoryTokenStore` (lock-protected), `struct FileTokenStore(url:)` (JSON, atomic write, 0600) for cross-process tests, `struct KeychainTokenStore(service: String = "com.jorgeper.hippo.dropbox", account: String = "tokens", accessGroup: String?)` using `kSecClassGenericPassword`, `kSecAttrAccessibleAfterFirstUnlock`, and `kSecAttrAccessGroup` when given. `static func sharedAccessGroup(suffix: String = "com.jorgeper.hippo.shared") -> String?`: adds-and-reads a probe item to learn the team prefix, returns `"<prefix>.<suffix>"`; nil off-device.
  - `struct PKCE: Equatable { let verifier: String; let challenge: String; static func make() -> PKCE }` (verifier: 32 random bytes base64url without padding; challenge: base64url(SHA256(verifier))).
  - `struct DropboxRequest { var url: URL; var method: String = "POST"; var headers: [String: String]; var body: Body; enum Body { case none, json(Data), form(Data), file(URL) } }`, `struct DropboxResponse { var status: Int; var headers: [String: String] /* lowercased keys */; var body: Data }`
  - `protocol DropboxTransport { func send(_ r: DropboxRequest) async throws -> DropboxResponse; func download(_ r: DropboxRequest, to localURL: URL, progress: (@Sendable (Int64) -> Void)?) async throws -> DropboxResponse /* body empty */ }`. Errors: `URLError` as thrown.
  - `final class URLSessionTransport: DropboxTransport { init(session: URLSession = .shared) }`: `.file` bodies use `uploadTask(with:fromFile:)`; both methods wrap the task in `withTaskCancellationHandler` cancelling it, so Task cancellation surfaces as `CancellationError` within the request's own latency.
  - `enum DropboxAuthError: Error, Equatable { case needsReauthentication, offline, transient(code: String), notConfigured }`
  - `final class DropboxAuth`:
    - `init(appKey: String, tokens: any TokenStore, lockURL: URL, transport: any DropboxTransport, now: @escaping @Sendable () -> Date = Date.init)`
    - `static let scopes = ["files.content.write", "files.content.read", "files.metadata.read", "account_info.read"]`
    - `func authorizationURL(pkce: PKCE, redirectURI: String?) -> URL` (`https://www.dropbox.com/oauth2/authorize`, `client_id`, `response_type=code`, `token_access_type=offline`, `code_challenge`, `code_challenge_method=S256`, `scope` space-joined, `redirect_uri` when given).
    - `func exchange(code: String, pkce: PKCE, redirectURI: String?) async throws -> DropboxTokens`: POST `https://api.dropboxapi.com/oauth2/token` form `grant_type=authorization_code`, `code`, `code_verifier`, `client_id`, `redirect_uri` when given; saves and returns tokens (`expiresAt = now + expires_in`).
    - `func accessToken() async throws -> String`: returns the stored token when it expires more than 60 s from now; otherwise takes the file lock, re-reads the store, refreshes if still needed (`grant_type=refresh_token`, `refresh_token`, `client_id`), saves, releases. A stored `needsReauthentication` or an `invalid_grant` response throws `.needsReauthentication` (and `invalid_grant` sets the flag in the store). No tokens → `.notConfigured`. `URLError` offline codes → `.offline`; 5xx / other → `.transient`.
    - `func invalidateAccessToken() throws`: sets `expiresAt = .distantPast` in the store (called after a 401).
    - `func signOut() async`: best-effort POST `/2/auth/token/revoke` with the current access token (ignoring errors, 5 s budget), then `tokens.clear()`.
    - `var storedAccountID: String? { get }`, `var needsReauthentication: Bool { get }`.
  - Test support: `final class ScriptedTransport: DropboxTransport`: a queue of `(matcher: (DropboxRequest) -> Bool, response: Result<DropboxResponse, Error>)` plus a recorded `requests: [DropboxRequest]`; an optional per-response delay for concurrency tests.

- [ ] **Step 1: Write failing tests** in `DropboxAuthTests`:
  - `authorizationURLCarriesPKCEAndOfflineAccess`: query has `code_challenge == pkce.challenge`, `code_challenge_method == S256`, `token_access_type == offline`, all four scopes, no `client_secret`.
  - `exchangeSavesTokensWithExpiry`: scripted 200 `{access_token, expires_in: 14400, refresh_token, account_id}` → store holds them, `expiresAt == now + 14400`; the request body has no secret and includes `code_verifier`.
  - `freshTokenIsReturnedWithoutRefresh`: `expiresAt = now + 3600` → one call, zero requests.
  - `expiringTokenIsRefreshedOnce`: `expiresAt = now + 30` → one refresh request; the new token is stored and returned.
  - `concurrentRefreshesShareOneRequest`: two `DropboxAuth` instances over one `FileTokenStore` and one `lockURL`, scripted refresh with a 100 ms delay; `async let` both `accessToken()` → both equal the new token; `requests.count == 1`.
  - `invalidGrantMarksNeedsReauthentication`: 400 `{"error":"invalid_grant"}` → throws `.needsReauthentication`; the store's flag is set; a second call throws without a request.
  - `offlineRefreshIsOffline`: `URLError(.notConnectedToInternet)` → `.offline`, store unchanged.
  - `signOutRevokesThenClears`: one request to `/2/auth/token/revoke` with `Authorization: Bearer …`, then `load() == nil`; a failing revoke still clears.
  - `tokensNeverAppearInErrors`: every thrown error's `String(describing:)` lacks the access and refresh token strings.
  - `pkceVerifierAndChallengeShape`: verifier 43 chars base64url; challenge == base64url(SHA256(verifier)).
- [ ] **Step 2:** Run `swift test --package-path HippoKit --filter DropboxAuthTests`. Expected: FAIL.
- [ ] **Step 3:** Implement. `KeychainTokenStore` is compiled but not unit-tested (no Keychain access group in `swift test`); keep it small and obvious.
- [ ] **Step 4:** Run the filter, then `make test`. Expected: PASS.
- [ ] **Step 5:** Commit `feat(dropbox): PKCE auth, token stores, cross-process refresh lock, URLSession transport`.

### Task 4: `DropboxClient` and `DropboxAdapter` with contract tests (§3, §5, §6.7, §8)

> **Executor note:** this task's integration tests need the Dropbox app key and a refresh token in `.env`. Before dispatching it, stop and walk Jorge through `scripts/setup-dropbox.sh` (the one allowed check-in). Unit tests with `ScriptedTransport` and the FilesystemAdapter contract don't need it; the real-Dropbox contract test is `.enabled(if:)` the credentials exist, so the task can be built and reviewed either way, but the plan expects it to have run for real before Task 5.

**Files:**
- Create: `HippoKit/Sources/DropboxAdapter/DropboxClient.swift`, `DropboxErrors.swift`, `DropboxAdapter.swift`, `DropboxPaths.swift`, `HippoKit/Tests/DropboxAdapterTests/DropboxClientTests.swift`, `DropboxAdapterTests.swift`, `HippoKit/Tests/AdapterContractTests/DropboxAdapterContractTests.swift`, `HippoKit/Tests/AdapterContractTests/Support/DropboxTestCredentials.swift`

**Interfaces:**
- Produces (all `public`, `Sendable`):
  - `struct DropboxCallError: Error, Equatable { var status: Int; var tags: [String] /* the `.tag` chain, e.g. ["path","conflict","file"] */; var retryAfter: TimeInterval?; var correctOffset: Int64? }` plus `func storageError() -> StorageError`: 401 → `.needsAuthentication`; 429 or tag `too_many_write_operations` / `too_many_requests` → `.rateLimited(retryAfter:)` (header, else `error.retry_after`, else 1 s); tag `insufficient_space` → `.quotaExceeded`; 5xx → `.transient(code: "http_5xx")`; 409 with other tags → `.permanent(code: "api:" + tags.joined("/"))` (safe-coded); anything else → `.transient(code: "http_\(status)")`. `URLError` mapping (static `DropboxClient.storageError(for: URLError)`): `.notConnectedToInternet`, `.networkConnectionLost`, `.dnsLookupFailed`, `.cannotFindHost`, `.cannotConnectToHost`, `.internationalRoamingOff`, `.dataNotAllowed` → `.offline`; `.timedOut` → `.transient(code: "timeout")`; `.cancelled` → `CancellationError`; else `.transient(code: "url_error")`.
  - `final class DropboxClient`:
    - `init(auth: DropboxAuth, transport: any DropboxTransport, uploadTransport: (any DropboxTransport)? = nil)` (`uploadTransport` for `.file` bodies; nil = `transport`); `var usesBackgroundUploads: Bool`.
    - `func rpc(_ endpoint: String, _ arg: (some Encodable)?) async throws -> Data` (`https://api.dropboxapi.com/2/<endpoint>`, JSON body or `null`), `func upload(_ endpoint: String, arg: some Encodable, file: URL) async throws -> Data` (`https://content.dropboxapi.com/2/<endpoint>`, `Dropbox-API-Arg` header, `application/octet-stream`), `func download(_ endpoint: String, arg: some Encodable, to: URL, progress:) async throws -> Data` (returns the `Dropbox-API-Result` header bytes).
    - Each call: `auth.accessToken()` (auth errors → `.needsAuthentication` / `.offline` / `.transient`), one request; on 401 → `auth.invalidateAccessToken()` and one retry; a non-2xx → `DropboxCallError`. Honours Task cancellation (transport).
  - `enum DropboxPaths { static func remote(_ relativePath: String, root: String) throws -> String /* "/" + root + "/" + rel, validated like FilesystemAdapter.resolve, root "" allowed */; static func relative(_ display: String, root: String) -> String? /* strips "/<root>/" case-insensitively */ }`
  - `struct DropboxAdapter: StorageAdapter`:
    - `init(client: DropboxClient, accountID: String, rootPrefix: String, scratchDirectory: URL, singleRequestCutoff: Int64 = 8 << 20, chunkSize: Int64 = 8 << 20)`
    - `capabilities`: folders true, resumable true, background = `client.usesBackgroundUploads`, `serverSideSHA256: false`, `maxSingleRequestBytes: singleRequestCutoff`, `supportsThumbnails: true`.
    - `validateDestination()`: `users/get_current_account` → `account_id` must equal `accountID` else `.permanent(code: "account_mismatch")`.
    - `ensureContainer`: `files/create_folder_v2` (`autorename: false`); tag `path/conflict/folder` → success.
    - `inspectFile`: `files/get_metadata`; `path/not_found` → nil; a folder → `.permanent(code: "path_is_directory")`; returns `RemoteFileInfo(byteCount: size, providerHash: ProviderHash(algorithm: "dropbox_content_hash", value: content_hash))`.
    - `verify`: `remote.byteCount == expected.byteCount` and `DropboxContentHash.of(localURL) == remote.providerHash.value` → `VerificationEvidence(kind: "dropbox_content_hash", value:)`, else nil.
    - `uploadFile`: `Task.checkCancellation()`; if `inspectFile` finds the path → verify → receipt or `.conflict(existing:)`. Size ≤ cutoff → `files/upload` with `{path, mode: add, autorename: false, mute: true, strict_conflict: true}`; `path/conflict/file` → inspect+verify → receipt or `.conflict`. Larger → sessions: checkpoint decode (`{"session_id","offset"}`; garbage → `.checkpointExpired`) or `upload_session/start {close:false}` with an empty body; loop: write the next chunk slice to `scratchDirectory/chunk-<uuid>` (removed after the request), `upload_session/append_v2 {cursor:{session_id, offset}, close:false}`; after each chunk `saveCheckpoint` (errors propagate unchanged); `incorrect_offset` → set `offset = correctOffset`, save checkpoint, continue; session `not_found`/`closed`/`too_large` → `.checkpointExpired`; then `upload_session/finish {cursor, commit:{path, mode: add, autorename: false, mute: true, strict_conflict: true}}` with an empty body; `path/conflict` → inspect+verify. The receipt carries `dropbox_content_hash` evidence from the response.
    - `replaceFile`: prefixes `enrichments/` or `logs/` only (else `.permanent(code: "replace_not_allowed")`); `files/upload` `mode: overwrite` (≤ cutoff) or a session with an `overwrite` commit; verifies `content_hash` against the local file (`.permanent(code: "integrity_mismatch")` on mismatch).
    - `listChanges`: `files/list_folder {path: "/<root>/<prefix without trailing slash>", recursive: true, include_deleted: false, limit: 2000}` when `cursor == nil` (a `path/not_found` → `ensureContainer` then retry once), else `list_folder/continue`; tag `reset` → `.cursorReset`; entries: `file` → `.upserted(RemoteFileInfo)`; `deleted` → `.deleted(relativePath:)` (folder or file); `folder` entries dropped; hidden segments dropped.
    - `latestCursor`: `list_folder/get_latest_cursor {path, recursive: true}` (creating the folder on `not_found`).
    - `listFolder`: `list_folder` (`recursive`, `limit: 2000`) / `continue`; returns `ListPage(cursor: has_more ? cursor : nil)`; `not_found` → empty page.
    - `deleteFolder`: scope rules from Task 2; `files/delete_v2`; tag `path_lookup/not_found` → success.
    - `downloadFile`: `inspectFile` first (nil → `.permanent(code: "not_found")`; `byteCount > maxBytes` → `.permanent(code: "too_large")`, nothing written); `files/download` via `transport.download` to a temp file beside `localURL`, then move; a written size over `maxBytes` → remove and `.permanent(code: "too_large")`.
    - `thumbnail`: `files/get_thumbnail_v2 {resource:{.tag:"path", path}, format:{.tag:"jpeg"}, size:{.tag: maxPixelSize > 640 ? "w1024h768" : "w640h480"}, mode:{.tag:"fitone_bestfit"}}`; any `DropboxCallError` with 409 → nil.
    - Every method: `URLError` → the static mapping; `DropboxCallError` → `storageError()` unless handled above.
  - `enum DropboxTestCredentials { static let appKey: String?; static let refreshToken: String?; static var available: Bool }`: parses `.env` found by walking up from `#filePath` (`KEY=value` lines, `#` comments).
  - `DropboxAdapterContractTests`: `@Test(.enabled(if: DropboxTestCredentials.available))`: builds `DropboxAuth` over a `MemoryTokenStore` seeded with the refresh token (`accessToken: ""`, `expiresAt: .distantPast`), `URLSessionTransport`, a `DropboxAdapter` with `rootPrefix: "_hippo-test/<run-uuid>"`, `singleRequestCutoff: 1 << 20`, `chunkSize: 4 << 20`; runs `runAdapterContract`; then a round trip: upload a 1 MiB file, `downloadFile`, SHA-256 equals the original; finally deletes the run root with `client.rpc("files/delete_v2", …)` directly (the adapter's scope rule forbids it). Also `listChangesReportsDeletedFolder`: upload under `captures/2026/11/07/abc/`, take `latestCursor`, `deleteFolder`, `listChanges` → contains `.deleted` whose path is the folder or its files.

- [ ] **Step 1: Write failing unit tests** (`ScriptedTransport`):
  - `DropboxClientTests.retriesOnceAfter401`: 401 then 200 → two requests, second has the new bearer; `twoUnauthorizedThrowsNeedsAuthentication`.
  - `errorMapping`: table of (status, body) → `StorageError` per the mapping above, including `Retry-After: 7` → `.rateLimited(retryAfter: 7)` and `insufficient_space`.
  - `urlErrorMapping`: the `URLError` table.
  - `cancellationCancelsTheRequest`: a transport that waits on a gate; cancel the task → `CancellationError` within 500 ms.
  - `DropboxAdapterTests.remotePathUsesRootPrefix`: `rootPrefix: ""` → `/captures/x`; `"_hippo-test/r1"` → `/_hippo-test/r1/captures/x`; `DropboxPaths.relative("/_hippo-test/r1/captures/x", root: "_hippo-test/r1") == "captures/x"`.
  - `smallUploadIsSingleRequestWithAddMode`: 1000 bytes → one `files/upload` whose `Dropbox-API-Arg` has `mode: add`, `autorename: false`, `strict_conflict: true`; the receipt evidence kind is `dropbox_content_hash`.
  - `conflictWithMatchingHashIsSuccess` / `conflictWithDifferentHashThrowsConflict`: scripted `path/conflict/file` then `get_metadata`.
  - `largeUploadUsesSessionsAndCheckpoints`: cutoff 1 KiB, chunk 1 KiB, 2.5 KiB file → `start`, `append_v2` ×2 (offsets 0 and 1024), `finish` with offset 2560; `saveCheckpoint` called after each append with decodable `{session_id, offset}`.
  - `incorrectOffsetAdoptsCorrectOffset`: resume from checkpoint offset 1024; `append_v2` returns 409 `incorrect_offset` with `correct_offset: 2048` → the next append carries offset 2048 and `finish` succeeds; a `not_found` session → `.checkpointExpired`.
  - `deleteFolderNotFoundIsSuccess`, `deleteFolderRefusesLogs`.
  - `listChangesMapsDeletedFolderAndDropsFolders`: entries `[folder, file, deleted(folder)]` → `[.upserted, .deleted(folder path)]`; `continue` with `reset` → `.cursorReset`.
  - `thumbnailUnsupportedIsNil`: 409 `unsupported_extension` → nil.
  - `downloadTooLargeWritesNothing`: metadata size 5000, `maxBytes: 10` → `.permanent(code: "too_large")`, no file, no download request.
  - `validateDestinationChecksAccount`: mismatched `account_id` → `.permanent(code: "account_mismatch")`.
- [ ] **Step 2:** Run `swift test --package-path HippoKit --filter "DropboxClientTests|DropboxAdapterTests"`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run the filter, then `make test` (the Dropbox contract test runs when `.env` is present; record in the ledger whether it ran). Expected: PASS.
- [ ] **Step 5:** Commit `feat(dropbox): HTTP client, error mapping and the StorageAdapter implementation with contract tests`.

### Task 5: Background uploads, the Dropbox provider and Settings connect/disconnect (§4.1, §3)

**Files:**
- Create: `HippoKit/Sources/DropboxAdapter/BackgroundUploadTransport.swift`, `App/Hippo/Storage/DropboxProvider.swift`, `App/Hippo/Storage/DropboxConnectSheet.swift`, `App/Hippo/AppDelegate.swift`
- Modify: `HippoKit/Sources/HippoPresentation/Settings/StorageProvider.swift`, `HippoKit/Sources/HippoPresentation/Settings/SettingsModel.swift`, `HippoKit/Sources/LocalRepository/JobStore.swift`, `HippoKit/Sources/LocalRepository/Log/LogEvent.swift`, `HippoKit/Sources/SyncEngine/SyncWorker.swift`, `HippoKit/Sources/HippoPresentation/Log/LogLine.swift`, `docs/log-format.md`, `App/Shared/AppEnvironment.swift`, `App/Hippo/HippoApp.swift`, `App/Hippo/Settings/SettingsView.swift`, `HippoKit/Tests/HippoPresentationTests/SettingsTests.swift`, `HippoKit/Tests/LocalRepositoryTests/DestinationJobTests.swift`, `HippoKit/Tests/DropboxAdapterTests/BackgroundTransportTests.swift` (new)

**Interfaces:**
- Produces:
  - `final class UploadBookkeeping: Sendable` (DropboxAdapter target): `func register(taskID: Int, _ continuation: CheckedContinuation<DropboxResponse, Error>)`, `func append(_ data: Data, taskID: Int)`, `func complete(taskID: Int, status: Int, headers: [String: String], error: Error?)` (resumes and forgets the continuation; a completion with no registered continuation is dropped and counted in `droppedCompletions: Int`).
  - `final class BackgroundUploadTransport: NSObject, DropboxTransport, URLSessionDataDelegate` (DropboxAdapter target; Foundation only): `init(identifier: String, sharedContainerIdentifier: String?)` builds a background `URLSessionConfiguration` (`isDiscretionary: false`, `sessionSendsLaunchEvents: true`). `send` accepts only `.file` bodies (others → `.transient(code: "not_file_body")`), runs `uploadTask(with:fromFile:)`, and drives `UploadBookkeeping` from the delegate callbacks (`didReceive data`, `didCompleteWithError`). Task cancellation does **not** cancel the URLSession task (§6.7 exemption): it throws `CancellationError` and lets the upload finish on its own. Tasks completing with no waiting continuation (process relaunch) are dropped. `func setEventsCompletion(_ handler: @escaping @Sendable () -> Void)` is called from `urlSessionDidFinishEvents(forBackgroundURLSession:)`. `download` throws `.transient(code: "unsupported")`.
  - `StorageProvider`: `enum ProviderAccountStatus: Sendable, Equatable { case ok, needsSignIn, notConfigured }` and `func accountStatus(_ d: Destination) async -> ProviderAccountStatus`, defaulted to `.ok` in a protocol extension.
  - `SettingsModel.accountStatus: ProviderAccountStatus` (refreshed in `refresh()`), `SettingsModel.disconnectPrompt(trimmedCount: Int) -> String` (Global Constraints copy), `SettingsModel.connectTitle(_ p: any StorageProvider) -> String`. `summary` additionally appends "Sign in again to <name>" when `accountStatus == .needsSignIn` or any job is `needs_authentication` (count via `index.counts()` is not enough: add `JobStore.count(state:destinationID:)`).
  - `DropboxProvider: StorageProvider` (`kind: "dropbox"`, `displayName: "Dropbox"`): `init?(appKey: String /* empty → nil */, storeRoot: URL, accessGroup: String?)`; owns one `DropboxAuth` (Keychain store, `lockURL: storeRoot/dropbox-refresh.lock`), one `URLSessionTransport`, one `BackgroundUploadTransport(identifier: "com.jorgeper.hippo.dropbox-uploads", sharedContainerIdentifier: AppEnvironment.appGroupID)`, one `DropboxClient`. `connect()`: presents `DropboxConnectSheet` (the caller shows it; see below) → runs `ASWebAuthenticationSession(url: auth.authorizationURL(pkce:redirectURI: "db-<key>://2/token"), callbackURLScheme: "db-<key>")` with `prefersEphemeralWebBrowserSession = false`, extracts `code`, `auth.exchange`, then `users/get_current_account` for `account_id` and `name.display_name`, returns the `Destination` from the plan-level call. `makeAdapter(for:)` → `DropboxAdapter(client:, accountID: d.accountIdentifier, rootPrefix: "", scratchDirectory: storeRoot/transfers)`. `signOut` → `auth.signOut()`. `accountStatus` → `.needsSignIn` when `auth.needsReauthentication` or no tokens stored while the destination is active; else `.ok`. `static func handleBackgroundEvents(identifier:completion:)` routes to the transport.
  - `DropboxConnectSheet`: the three lines and the Connect button from Global Constraints; a cancel. `SettingsView` shows it for the Dropbox provider before calling `model.connect(provider)` (the Developer folder connects directly, as today). Settings storage section when connected: display name row, "Disconnect" (confirmation from `disconnectPrompt`), "Reconnect <name>" when `accountStatus == .needsSignIn`; the Save space / Download rows come in Tasks 12 and 14. The "Sign out" wording is replaced by "Disconnect" for every provider.
  - `AppEnvironment`: builds `DropboxProvider(appKey: Bundle.main.infoDictionary["HippoDropboxAppKey"], storeRoot:, accessGroup: KeychainTokenStore.sharedAccessGroup())` and lists it first in the registry (DEBUG keeps the Developer folder after it).
  - `AppDelegate` (`@UIApplicationDelegateAdaptor`): `application(_:handleEventsForBackgroundURLSession:completionHandler:)` → `DropboxProvider.handleBackgroundEvents`.
  - Log: `auth.connected` / `auth.disconnected` (`dest` = provider kind) appended by `SettingsModel.connect` / `signOut`; `auth.refresh_failed` appended by the sync pass when any adapter call throws `.needsAuthentication` (add in `SyncWorker.record` when `failure.code == "needs_authentication"`). Add the three names to `LogEventName`, `LogLine` text ("Connected Dropbox", "Disconnected Dropbox", "Dropbox sign-in expired") and `docs/log-format.md`.

- [ ] **Step 1: Write failing tests:**
  - `BackgroundTransportTests.rejectsNonFileBodies`; `UploadBookkeepingTests.appendThenCompleteResumesWithBody` (register → two appends → complete 200 → the continuation gets status 200 and the concatenated body), `completeWithErrorThrows`, `unknownTaskCompletionIsDropped` (`droppedCompletions == 1`, no crash).
  - `DestinationJobTests.countByStateAndDestination`.
  - `SettingsTests.needsSignInShowsInSummary`: a `FakeStorageProvider` whose `accountStatus` returns `.needsSignIn` → `summary` contains "Sign in again to Developer folder".
  - `SettingsTests.connectAndDisconnectAreLogged`: `auth.connected` then `auth.disconnected` with `dest == "filesystem"`, and no event carries the destination's display name or account identifier.
  - `SettingsTests.disconnectPromptMentionsTrimmedOnlyWhenPresent`.
- [ ] **Step 2:** Run `make test`. Expected: the new tests FAIL.
- [ ] **Step 3:** Implement. Run the App build check with and without `Config/Secrets.xcconfig`.
- [ ] **Step 4:** Run `make test` and the App build check. Expected: PASS, `** BUILD SUCCEEDED **`.
- [ ] **Step 5:** Commit `feat(app): Dropbox provider with PKCE sign-in, background uploads, connect and disconnect`.

### Task 6: Sync timing: cellular log throttle, foreground retry timer, connectivity refresh (§4.6, §6.5, §8)

**Files:**
- Modify: `HippoKit/Sources/SyncEngine/LogUploader.swift`, `HippoKit/Sources/SyncEngine/HippoStore.swift`, `HippoKit/Sources/LocalRepository/JobStore.swift`, `HippoKit/Sources/HippoPresentation/Settings/SyncCoordinator.swift`, `App/Hippo/Enrichment/EnrichmentScheduling.swift` (`NetworkStatus`), `App/Hippo/Settings/SyncScheduling.swift`, `App/Shared/AppEnvironment.swift`
- Test: `HippoKit/Tests/SyncEngineTests/LogUploaderTests.swift`, `HippoKit/Tests/LocalRepositoryTests/DestinationJobTests.swift`, `HippoKit/Tests/HippoPresentationTests/SettingsTests.swift`

**Interfaces:**
- Produces:
  - `LogUploader.init(…, isConstrained: @escaping @Sendable () -> Bool = { false }, constrainedMinInterval: TimeInterval = 900, now: @escaping @Sendable () -> Date = Date.init)`: when `isConstrained()` and `lastAt` is within the interval → return `LogUploadResult(uploaded: 0, code: "throttled")` without touching the network or `last_at`. `HippoStore.makeLogUploader(installID:adapterFor:isConstrained:)`.
  - `JobStore.nextAttemptAt(destinationID: String) throws -> Date?`: the earliest `next_attempt_at_ms` among `retryable_failure` jobs of the destination.
  - `SyncCoordinator.init(…, isConstrained: @escaping @Sendable () -> Bool = { false })` passes it through; `SyncCoordinator.nextRetryAt() async -> Date?` (reads the active destination's `nextAttemptAt`).
  - `NetworkStatus`: `var isExpensive: Bool` (`path.isExpensive || path.isConstrained`) and `var onChange: (@Sendable (Bool /* online */) -> Void)?`; fires when `isOnline` flips.
  - `SyncScheduling`: `static func startConnectivityTrigger(_ environment: AppEnvironment)` (called once from `HippoApp.init`): when the status flips to online while `scenePhase == .active`, run a pass with trigger `connectivity` and `EnrichmentScheduling.run(reason: "connectivity")`. `static func scheduleForegroundRetry(_ environment:)`: after every pass (`passFinished`), read `nextRetryAt`; if non-nil, sleep until then (clamped to 5 s … 1 h) in a single replaceable task, then run a pass with trigger `retry`. Cancelled on `.background`.
  - `docs/log-format.md`: `trigger` gains `connectivity` and `retry`.

- [ ] **Step 1: Write failing tests:**
  - `LogUploaderTests.cellularThrottleSkipsWithinInterval`: constrained, `lastAt = now - 60` → `code == "throttled"`, no `replace` operation, state unchanged; `lastAt = now - 1000` → uploads; unconstrained → always uploads.
  - `DestinationJobTests.nextAttemptAtIsEarliestRetryable`: two retryable jobs and one blocked → the earlier retry time; none → nil.
  - `SettingsTests.coordinatorExposesNextRetry`: after a fault-injected offline pass, `nextRetryAt()` is non-nil and in the future.
- [ ] **Step 2:** Run `make test`. Expected: FAIL.
- [ ] **Step 3:** Implement. The App's `isConstrained` is `NetworkStatus.shared.isExpensive`.
- [ ] **Step 4:** Run `make test` and the App build check. Expected: PASS.
- [ ] **Step 5:** Commit `feat(sync): cellular log throttle, foreground retry timer, sync on connectivity return`.

### Task 7: Schema v4: remote state, trims, thumbnails, trimmed-aware validation (§6.2–6.4)

**Files:**
- Create: `HippoKit/Sources/LocalRepository/RemoteStateStore.swift`, `HippoKit/Sources/LocalRepository/TrimStore.swift`, `HippoKit/Tests/LocalRepositoryTests/RemoteStateStoreTests.swift`, `HippoKit/Tests/LocalRepositoryTests/TrimStoreTests.swift`
- Modify: `HippoKit/Sources/LocalRepository/SQLite/Migrations.swift`, `HippoKit/Sources/CaptureCore/Package/StoreLayout.swift`, `HippoKit/Sources/CaptureCore/Package/PackageValidator.swift`, `HippoKit/Sources/LocalRepository/JobStore.swift`, `HippoKit/Sources/LocalRepository/Reconciler.swift`, `HippoKit/Sources/SyncEngine/HippoStore.swift`, `HippoKit/Tests/CaptureCoreTests/PackageValidatorTests.swift`, `HippoKit/Tests/LocalRepositoryTests/DestinationJobTests.swift`, `HippoKit/Tests/LocalRepositoryTests/DatabaseTests.swift` (migration 3→4)

**Interfaces:**
- Produces:
  - `Migrations.currentVersion = 4`, `v4`:
    ```sql
    CREATE TABLE remote_tombstones(capture_id TEXT PRIMARY KEY, relative_directory TEXT NOT NULL,
      destination_id TEXT NOT NULL REFERENCES destinations, account_identifier TEXT NOT NULL,
      attempt_count INTEGER NOT NULL DEFAULT 0, next_attempt_at_ms INTEGER, last_error_code TEXT,
      created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL);
    CREATE TABLE local_deletes(capture_id TEXT PRIMARY KEY, relative_directory TEXT NOT NULL,
      account_identifier TEXT, deleted_at_ms INTEGER NOT NULL);
    CREATE TABLE remote_cursors(destination_id TEXT PRIMARY KEY REFERENCES destinations, cursor TEXT,
      updated_at_ms INTEGER NOT NULL);
    CREATE TABLE remote_review_items(capture_id TEXT NOT NULL REFERENCES captures ON DELETE CASCADE,
      destination_id TEXT NOT NULL REFERENCES destinations, reason TEXT NOT NULL, created_at_ms INTEGER NOT NULL,
      PRIMARY KEY(capture_id, destination_id));
    CREATE TABLE remote_changed(capture_id TEXT PRIMARY KEY REFERENCES captures ON DELETE CASCADE,
      destination_id TEXT NOT NULL REFERENCES destinations, paths TEXT NOT NULL /* JSON array */,
      detected_at_ms INTEGER NOT NULL);
    CREATE TABLE trimmed_attachments(capture_id TEXT NOT NULL REFERENCES captures ON DELETE CASCADE,
      attachment_id TEXT NOT NULL, relative_path TEXT NOT NULL, byte_count INTEGER NOT NULL, sha256 TEXT NOT NULL,
      destination_id TEXT NOT NULL REFERENCES destinations, state TEXT NOT NULL /* trimmed|mismatch */,
      trimmed_at_ms INTEGER NOT NULL, PRIMARY KEY(capture_id, attachment_id));
    ```
  - `StoreLayout.thumbnailsDir` (`root/thumbnails`), `thumbnailURL(attachmentID:) -> URL` (`thumbnails/<id>.jpg`), `transfersDir` (`root/transfers`). `HippoStore.open` creates both.
  - `PackageValidator.validate(directory: URL, trimmed: Set<String> = []) -> ValidationResult` and `CommittedPackage.load(directory:layout:trimmed: Set<String> = [])`: a manifest entry whose path is in `trimmed` may be absent (if present it is still hashed and must match).
  - `public struct RemoteTombstone: Sendable, Equatable { captureID, relativeDirectory, destinationID, accountIdentifier: String; attemptCount: Int; nextAttemptAt: Date?; lastErrorCode: String? }`
  - `public struct ReviewItem: Sendable, Equatable { captureID, destinationID, reason: String; createdAt: Date }`
  - `public struct RemoteChangedRecord: Sendable, Equatable { captureID, destinationID: String; paths: [String]; detectedAt: Date }`
  - `public final class RemoteStateStore: Sendable` (`init(db:)`):
    - tombstones: `addTombstone(captureID:relativeDirectory:destinationID:accountIdentifier:now:)` (upsert), `dueTombstones(destinationID:accountIdentifier:now:limit:) -> [RemoteTombstone]` (next attempt nil or ≤ now, oldest first), `pendingTombstoneCount(destinationID:) -> Int`, `hasTombstone(captureID:) -> Bool`, `removeTombstone(captureID:)`, `markTombstoneFailed(captureID:code:nextAttemptAt:now:)` (increments attempts).
    - local deletes: `recordLocalDelete(captureID:relativeDirectory:accountIdentifier:now:)`, `localDeletedCaptureIDs() -> Set<String>`, `removeLocalDelete(captureID:)`.
    - cursor: `changeCursor(destinationID:) -> String?`, `saveChangeCursor(destinationID:cursor:now:)` (nil clears).
    - review: `addReviewItems(_ items: [ReviewItem])` (ignore duplicates), `reviewItems(destinationID:) -> [ReviewItem]`, `clearReview(destinationID:)`.
    - changed: `markChanged(captureID:destinationID:paths:now:)` (upsert, union of paths), `changed(captureID:) -> RemoteChangedRecord?`, `clearChanged(captureID:)`, `changedCount(destinationID:) -> Int`.
  - `public enum TrimState: String, Sendable { case trimmed, mismatch }`, `public struct TrimmedAttachment: Sendable, Equatable { captureID, attachmentID, relativePath: String; byteCount: Int64; sha256, destinationID: String; state: TrimState; trimmedAt: Date }`
  - `public final class TrimStore: Sendable` (`init(db:)`): `record(_:)` (upsert), `trimmed(captureID:) -> [TrimmedAttachment]`, `trimmedPaths(captureID:) -> Set<String>`, `remove(captureID:attachmentID:)`, `setState(captureID:attachmentID:state:)`, `captureIDsWithTrimmed(in: [String]) -> Set<String>`, `totals(destinationID:) -> (captures: Int, bytes: Int64)`, `allTrimmedAttachmentIDs() -> [String]`.
  - `JobStore.insertSynced(captureID:destinationID:) throws` (a `synced` job with no receipts), `JobStore.clearReceipts(jobID:paths: [String]?) throws` (nil = all), `JobStore.capturesFullySynced(destinationID:) throws -> Set<String>`, `JobStore.requeue(jobID:) throws` (any state → `pending`, lease and retry time cleared, `cancel_requested` untouched). (`count(state:destinationID:)` came in Task 5.)
  - `Reconciler`: also removes files in `transfers/` older than 7 days.
  - `HippoStore.remoteState: RemoteStateStore`, `HippoStore.trims: TrimStore`.

- [ ] **Step 1: Write failing tests:**
  - `DatabaseTests.migratesFromV3ToV4`: a v3 database (via `Database(url:migratingUpTo: 3)`) with a capture, job and destination opens at v4 with the six tables and the old rows intact.
  - `RemoteStateStoreTests`: `tombstoneLifecycle` (add → due → markFailed moves `nextAttemptAt` and isn't due → remove), `dueTombstonesFilterByAccount`, `localDeleteRecordsSurviveAndCanBeRemoved`, `cursorPerDestinationSurvivesSignOut` (call `DestinationStore.signOut` then read), `reviewItemsCascadeWithCapture`, `changedUnionsPaths`.
  - `TrimStoreTests.recordReadTotalsAndCascade`.
  - `PackageValidatorTests.trimmedAttachmentMayBeMissing`: delete an attachment → `.incomplete` without `trimmed`, `.complete` with its path in `trimmed`; a present trimmed file with wrong bytes is still `.incomplete`.
  - `DestinationJobTests.insertSyncedAndClearReceipts`, `capturesFullySynced`.
- [ ] **Step 2:** Run `make test`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `make test`. Expected: PASS.
- [ ] **Step 5:** Commit `feat(store): schema v4 with remote tombstones, local deletes, cursors, review, changed and trimmed state`.

### Task 8: Delete everywhere: tombstones, `RemoteDeleter`, prompts, Detail menu (§4.2, §6.2)

**Files:**
- Create: `HippoKit/Sources/SyncEngine/RemoteDeleter.swift`, `HippoKit/Tests/SyncEngineTests/RemoteDeleterTests.swift`
- Modify: `HippoKit/Sources/SyncEngine/HippoStore.swift`, `HippoKit/Sources/LocalRepository/Log/LogEvent.swift`, `HippoKit/Sources/HippoPresentation/Detail/DeletionPrompt.swift`, `HippoKit/Sources/HippoPresentation/Detail/CaptureDetailModel.swift`, `HippoKit/Sources/HippoPresentation/Settings/SettingsModel.swift`, `HippoKit/Sources/HippoPresentation/Settings/SyncCoordinator.swift`, `HippoKit/Sources/HippoPresentation/Log/LogLine.swift`, `App/Hippo/Detail/CaptureDetailView.swift`, `docs/log-format.md`
- Test: `HippoKit/Tests/SyncEngineTests/HippoStoreTests.swift`, `HippoKit/Tests/HippoPresentationTests/DetailTests.swift`, `SettingsTests.swift`, `LogLineTests.swift`

**Interfaces:**
- Produces:
  - `LogEventName` gains `remoteDelete = "remote.delete"` (outcome `ok`/`failed`, `code`, `dest`, per capture), later tasks add more. `docs/log-format.md` documents it.
  - `HippoStore.delete(captureID:)` now also removes the capture's thumbnails (`trims.trimmed(captureID:)` attachment IDs → `thumbnailURL`) and writes a local-delete record (`accountIdentifier` = the bound destination's account, if any). Trim rows, review items and changed records cascade.
  - `HippoStore.deleteEverywhere(captureID:) async throws -> DeletionResult`: like `delete` but, when the capture has a job, writes a tombstone (`destinationID`, that destination's `accountIdentifier`, `relativeDirectory`) **before** removing the index row, inside the same flow, and writes no local-delete record; logs `remote.delete` with outcome nil (queued). With no job it behaves like `delete`.
  - `HippoStore.removeAfterRemoteDelete(captureID:) async throws`: `delete` without the local-delete record; `capture.deleted` carries `trigger: "remote"`.
  - `HippoStore.makeRemoteDeleter(adapterFor:) -> RemoteDeleter`.
  - `public struct RemoteDeleteResult: Sendable, Equatable { var deleted: Int; var failed: Int; var idle: Bool }`
  - `public final class RemoteDeleter: Sendable`: `init(destinations:, remoteState:, adapterFor:, policy: RetryPolicy = .init(), now:, random:, log:)`; `func runOnce(maxItems: Int = 20) async -> RemoteDeleteResult`: for the active destination's due tombstones (matching account): `deleteFolder(relativeDirectory)`, then `deleteFolder(EnrichmentPaths.remoteDirectory(.device, …))`, then `.server`; success → `removeTombstone`, log `remote.delete` ok; `.needsAuthentication` ends the pass (nothing recorded); other errors → `markTombstoneFailed` with `policy.delay(attempt:)`, log `remote.delete` failed with the safe code. Cancellation returns at once.
  - `SyncCoordinator.runPass` runs `deleter.runOnce()` before the package rounds (not part of the pass result or follow-up decision).
  - `DeletionPrompt.everywhere(destinationName: String) -> DeletionPrompt` (Global Constraints copy). `CaptureDetailModel.everywherePrompt: DeletionPrompt?` (non-nil only when the capture has a job) and `func deleteEverywhere() async throws -> HippoStore.DeletionResult`.
  - `SettingsModel.pendingRemoteDeletes: Int` (refresh) and `summary` appends "<n> delete(s) waiting to reach <name>" (singular/plural).
  - `LogLine`: `remote.delete` → "Delete queued for Dropbox" / "Deleted in Dropbox" / "Delete in Dropbox failed: <code>".
  - Detail menu adds "Delete everywhere…" below "Delete from iPhone…" when `everywherePrompt != nil`, with its own confirmation dialog.

- [ ] **Step 1: Write failing tests:**
  - `HippoStoreTests.deleteEverywhereQueuesTombstoneAndRemovesLocally`: capture bound to the harness destination → `remoteState.hasTombstone` true with the right directory and account, index row gone, no local-delete record. `deleteFromIPhoneRecordsLocalDeleteOnly`: record present, no tombstone. `deleteEverywhereWithoutJobBehavesLikeDelete`.
  - `RemoteDeleterTests.deletesPackageAndEnrichmentFoldersThenRemovesTombstone` (remote dirs gone; a second run is idle), `notFoundCountsAsSuccess`, `tombstoneForAnotherAccountIsNotRun` (connect a second destination; the first's tombstone stays), `failureBacksOffAndRetries` (fault → `attemptCount == 1`, `nextAttemptAt` in the future, not due; advance the clock → runs), `needsAuthenticationStopsPass`, `deleteDuringUploadCancelsThenDeletesRemote` (hold an upload with `PausingAdapter`, `deleteEverywhere`, release; the remote folder without `complete.json` is deleted by the next run).
  - `DetailTests.everywherePromptCopy`, `SettingsTests.pendingDeletesInSummary`, `LogLineTests.remoteDeleteLines`.
- [ ] **Step 2:** Run `make test`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `make test` and the App build check. Expected: PASS.
- [ ] **Step 5:** Commit `feat(sync): delete everywhere with durable tombstones processed before uploads`.

### Task 9: Remote change detection: deletes from Dropbox, "changed", safety valve, cursor reset (§4.3)

**Files:**
- Create: `HippoKit/Sources/SyncEngine/RemoteChangeDetector.swift`, `HippoKit/Tests/SyncEngineTests/RemoteChangeDetectorTests.swift`
- Modify: `HippoKit/Sources/SyncEngine/HippoStore.swift`, `HippoKit/Sources/SyncEngine/SyncWorker.swift`, `HippoKit/Sources/LocalRepository/Log/LogEvent.swift`, `HippoKit/Sources/HippoPresentation/Settings/SyncCoordinator.swift`, `HippoKit/Sources/HippoPresentation/Log/LogLine.swift`, `docs/log-format.md`, `HippoKit/Tests/EnrichmentTests/EnrichmentRunnerTests.swift` (`noEventCarriesContent`)
- Test: `HippoKit/Tests/SyncEngineTests/SyncWorkerTests.swift`, `HippoStoreTests.swift`

**Interfaces:**
- Produces:
  - `LogEventName` gains `remoteChanged = "remote.changed"` (per capture) and `remoteReview = "remote.review"` (global, `count`, `code` = reason).
  - `public struct RemoteChangeReport: Sendable, Equatable { var removed: Int; var changed: Int; var protected: Int; var reviewQueued: Int; var cursorReset: Bool; var code: String? }`
  - `public final class RemoteChangeDetector: Sendable`:
    - `public static let prefix = "captures/"`, `maxAutoRemovals = 20`, `maxAutoRemovalFraction = 0.10`, `softChangeLimit = 2000`.
    - `init(layout:, index:, jobs:, remoteState:, trims:, destinations:, adapterFor:, removeLocally: @escaping @Sendable (String) async throws -> Void, now:, log:)`
    - `func run() async -> RemoteChangeReport`.
  - Algorithm:
    1. Active destination or return. `cursor = remoteState.changeCursor(dest.id)`; nil → `adapter.latestCursor(under: prefix)`, save, return (first connect never enumerates history).
    2. Page through `listChanges(under: prefix, cursor:)` until `!hasMore` or `softChangeLimit`, saving the cursor after each page. `.cursorReset` → step 6.
    3. Classify each change by its capture directory `captures/YYYY/MM/DD/<id>` (`EnrichmentPaths`-style parsing; anything else is ignored): `.deleted(path)` where `path == "captures"` → `rootGone`; `path == dir` or `path == dir/complete.json` → deletion candidate for `<id>`; another file under an indexed dir → changed path. `.upserted(info)` for an indexed capture: `dir/complete.json` cancels a deletion candidate from this pass; a manifest file (metadata.json or an attachment, not trimmed) is compared with `adapter.verify(remote: info, localURL:, expected:)`; nil → changed path; a match clears that path from an existing changed record. Unknown IDs are ignored.
    4. Protection: a candidate whose jobs for this destination aren't all `synced` is dropped and counted `protected` (log `remote.changed` with `code: "unverified"`).
    5. Safety valve: `synced = jobs.capturesFullySynced(dest.id).count`; if `rootGone` or `candidates.count > 20` or `candidates.count > 0.10 * synced` → `addReviewItems` (reason `root_missing` or `threshold`), log `remote.review` (count, reason), apply nothing. Else `removeLocally(id)` for each (counted `removed`). Changed paths → `markChanged` + log `remote.changed` per capture.
    6. Cursor reset: `latestCursor` → save; list `captures/` fully with `listFolder(recursive: true)`; the set of directories having `complete.json`; every fully-synced indexed capture missing from it → review item reason `cursor_reset`; log `remote.review`; `cursorReset = true`; nothing is applied.
    7. Errors: `StorageError` ends the run with `code` (same mapping as `GoldPuller.code(for:)`); cancellation returns what was done.
  - `HippoStore.makeChangeDetector(adapterFor:) -> RemoteChangeDetector` (with `removeLocally = removeAfterRemoteDelete`).
  - `HippoStore.uploadAgain(captureID:) throws -> UploadAgainResult` with `public struct UploadAgainResult: Sendable, Equatable { var requeued: Bool; var unrestorablePaths: [String] }`: clears the receipts for the changed record's paths that aren't trimmed (and for `complete.json`), sets the job `pending` with `JobStore.requeue(jobID:)` (Task 7), clears the changed record, returns the trimmed paths it couldn't requeue.
  - `HippoStore.resolveReview(destinationID:, keep: Bool) async throws -> Int`: `keep == false` → `removeAfterRemoteDelete` each item; `keep == true` → `uploadAgain` for captures without trimmed files (all paths), nothing for those with; then `clearReview`. Returns the item count.
  - `SyncWorker.upload(job)`: loads the package with `trimmed: trims.trimmedPaths(captureID)` (the worker gains `trims: TrimStore`); a manifest file without a receipt whose local file is trimmed → `Failure(state: .blocked, code: "trimmed_file_missing")`; on `markSynced` the worker calls `remoteState.clearChanged(captureID)` (gains `remoteState`). `HippoStore.makeWorker` passes both.
  - `SyncCoordinator.runPass` runs `detector.run()` after the gold pull, before the log upload.
  - `LogLine`: `remote.changed` → "Changed in Dropbox" (or "Not removed: upload not verified" for code `unverified`); `remote.review` → "Dropbox looks different · N captures to review".
  - `noEventCarriesContent` extension: run connect/disconnect, a tombstone pass and a detector pass with a destination whose `displayName` is `"Secret Person"` and `accountIdentifier` `"dbid:SECRET"`, plus a fake token string `"sl.SECRETTOKEN"` placed in an adapter error code; assert no log file contains `Secret`, `SECRET`, `dbid:` or `@example.com`.

- [ ] **Step 1: Write failing tests** (`SyncHarness`, two captures synced through the worker, detector with `removeLocally` wired to a `HippoStore` built on the same root or to a recorded closure):
  - `firstRunBaselinesWithoutListing`: cursor saved, nothing removed, remote files uploaded before the baseline aren't reported.
  - `fileDeletesRemoveCapture`: delete the remote package dir on disk (the FilesystemAdapter reports per file) → the capture is removed locally, `capture.deleted` has `trigger == "remote"`, enrichment dirs gone.
  - `folderDeleteEntryRemovesCapture`: wrap the adapter so `listChanges` returns one `.deleted(dir)` → removed.
  - `markerDeleteAloneRemovesCapture`; `attachmentDeleteMarksChangedNotRemoved` (changed record with the path; capture stays; `remote.changed` logged); `metadataEditMarksChanged` (edit remote metadata.json → changed).
  - `unknownCaptureChangesAreIgnored`: files appear under a directory the phone doesn't index → report all zeros, no changed records.
  - `unverifiedCaptureIsProtected`: a capture whose job is `pending` → not removed, `protected == 1`.
  - `thresholdQueuesReviewInsteadOfDeleting`: 25 synced captures, delete all remotely → `reviewQueued == 25`, nothing removed, `remote.review` count 25 code `threshold`; `fractionThresholdWithFewCaptures`: 10 synced, delete 2 → review (2 > 10 %); delete 1 → removed.
  - `rootGoneQueuesReview`: `.deleted("captures")` → review, nothing removed.
  - `cursorResetListsAndQueuesReviewOnly`: garbage cursor saved; one capture missing remotely → review item reason `cursor_reset`, `cursorReset == true`, nothing removed; the new cursor is saved.
  - `restoredMarkerCancelsDeletionInSamePass`.
  - `resolveReviewRemoveAndKeep`: `keep: false` removes; `keep: true` requeues the jobs (`pending`, receipts cleared) and clears the review; a trimmed capture under `keep: true` is left as is.
  - `SyncWorkerTests.trimmedFileWithoutReceiptBlocks` (code `trimmed_file_missing`) and `markSyncedClearsChanged`.
  - `HippoStoreTests.uploadAgainClearsChangedReceiptsAndRequeues`, `uploadAgainReportsTrimmedPaths`.
  - `noEventCarriesContent` extension as above.
- [ ] **Step 2:** Run `make test`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `make test`. Expected: PASS.
- [ ] **Step 5:** Commit `feat(sync): detect deletes and changes made in the destination, with a safety valve and review queue`.

### Task 10: Presentation + App for changed captures and the review sheet (§4.3, §4.6)

**Files:**
- Create: `HippoKit/Sources/HippoPresentation/Settings/RemoteReviewModel.swift`, `App/Hippo/Settings/RemoteReviewSheet.swift`, `App/Hippo/Timeline/ReviewBanner.swift`
- Modify: `HippoKit/Sources/HippoPresentation/Detail/CaptureDetail.swift`, `CaptureDetailModel.swift`, `HippoKit/Sources/HippoPresentation/Settings/SettingsModel.swift`, `HippoKit/Sources/HippoPresentation/Timeline/TimelineModel.swift`, `App/Hippo/Detail/StatusSection.swift`, `App/Hippo/Detail/CaptureDetailView.swift`, `App/Hippo/Settings/SettingsView.swift`, `App/Hippo/Timeline/TimelineView.swift`
- Test: `HippoKit/Tests/HippoPresentationTests/DetailTests.swift`, `SettingsTests.swift`, `TimelineTests.swift`, `RemoteReviewTests.swift` (new)

**Interfaces:**
- Produces:
  - `CaptureDetail.storage: StatusLine?` (layer `.sync`): built in `make` from new parameters `changed: RemoteChangedRecord?`, `trimmedCount: Int`, `destinationName: String?`: precedence changed ("Changed in <name>", `.failed`) > any job `uploading` ("Uploading…", `.working`) > any job `retryableFailure` with code `offline` ("Waiting for a connection", `.waiting`) > trimmed ("Large files in <name> only", `.done`) > all synced ("In <name> · verified", `.done`) > nil. `CaptureDetail.changedPaths: [String]`, `CaptureDetail.unrestorableNote: String?` (the trimmed-and-gone copy when a changed path is trimmed).
  - `CaptureDetailModel.uploadAgain() async`: calls `store.uploadAgain`, syncs through an injected `sync: @Sendable () async -> Void` (new init parameter, default no-op; the App passes `coordinator.syncNow(trigger: "manual")`), reloads. `CaptureDetailModel.load` passes the changed record, trimmed count and destination name.
  - `@MainActor @Observable public final class RemoteReviewModel`: `init(store:, sync:)`; `items: [ReviewItem]`, `count`, `dateRange: String?` (earliest–latest captured day via `DateIntervalFormatter`), `trimmedCount: Int`, `destinationName: String`, `isPending: Bool`; `load()`, `removeFromPhone()`, `keepAndUploadAgain()`, `decideLater()` (no-op); copy constants from Global Constraints (`title`, `summaryLine`, `trimmedLine`, `footer`).
  - `SettingsModel.reviewPending: Int`; `summary` appends "<name> looks different · review" when > 0. `TimelineModel.reviewPending: Int` (read on reload).
  - App: `StatusSection` shows `detail.storage` first among the sync-layer rows, with an "Upload again from iPhone" button when `changedPaths` is non-empty and the unrestorable note when present. `ReviewBanner` (a tappable row above the timeline sections, and a row in Settings' Storage section) opens `RemoteReviewSheet`: the summary line, the trimmed line, the three buttons (the trimmed group uses "Keep on iPhone as they are"), the footer.

- [ ] **Step 1: Write failing tests:**
  - `DetailTests.storageLinePrecedence` (each state → the exact text and `StatusState`), `changedShowsUploadAgainAndUnrestorableNote`.
  - `DetailTests.uploadAgainRequeuesAndSyncs` (sync closure called once).
  - `RemoteReviewTests.loadsItemsDateRangeAndTrimmedCount`, `removeFromPhoneRemovesAndClears`, `keepRequeuesNonTrimmedAndClears`.
  - `SettingsTests.reviewPendingInSummary`, `TimelineTests.reviewPendingCount`.
- [ ] **Step 2:** Run `make test`. Expected: FAIL.
- [ ] **Step 3:** Implement models, then views.
- [ ] **Step 4:** Run `make test` and the App build check. Expected: PASS, `** BUILD SUCCEEDED **`.
- [ ] **Step 5:** Commit `feat(app): storage status line, upload again, review banner and sheet`.

### Task 11: Save space core: eligibility, fresh remote check, trimming, restore (§4.4, §6.3–6.4)

**Files:**
- Create: `HippoKit/Sources/SyncEngine/SpaceSaver.swift`, `HippoKit/Sources/SyncEngine/AttachmentRestorer.swift`, `HippoKit/Tests/SyncEngineTests/SpaceSaverTests.swift`, `AttachmentRestorerTests.swift`
- Modify: `HippoKit/Sources/SyncEngine/HippoStore.swift`, `HippoKit/Sources/LocalRepository/Reconciler.swift`, `HippoKit/Sources/LocalRepository/CaptureIndex.swift`, `HippoKit/Sources/Enrichment/Enricher.swift`, `EnrichmentRunner.swift`, `TextRecognitionEnricher.swift`, `TranscriptEnricher.swift`, `HippoKit/Sources/LocalRepository/Log/LogEvent.swift`, `HippoKit/Sources/HippoPresentation/Log/LogLine.swift`, `App/Hippo/Enrichment/EnrichmentScheduling.swift` (pass `trimmedPaths`), `docs/log-format.md`
- Test: `HippoKit/Tests/LocalRepositoryTests/ReconcilerTests.swift`, `HippoKit/Tests/EnrichmentTests/EnrichmentRunnerTests.swift`

**Interfaces:**
- Produces:
  - `LogEventName` gains `trimRun = "trim.run"` (global: `count` trimmed, `ms` unused, `code` nil or the last skip code; bytes go in a new optional `bytes: Int64?` field on `LogEvent`, documented) and `attachmentRestored = "attachment.restored"` (per capture, outcome ok / failed with code).
  - `public struct SpaceSaveOptions: Sendable, Equatable { var olderThan: TimeInterval; var largerThan: Int64 }` with `static let ageSteps: [TimeInterval] = [7, 30, 90, 365].map { $0 * 86_400 }`, `sizeSteps: [Int64] = [1, 10, 50, 100].map { $0 * 1_000_000 }`, `static let `default` = SpaceSaveOptions(olderThan: 30 days, largerThan: 10 MB)`.
  - `public struct TrimCandidate: Sendable, Equatable { captureID: String; attachment: Attachment; relativeDirectory: String; destinationID: String }`
  - `public struct SpaceSaveEstimate: Sendable, Equatable { var captures: Int; var files: Int; var bytes: Int64 }`
  - `public struct SpaceSaveResult: Sendable, Equatable { var trimmed: Int; var bytes: Int64; var skipped: Int; var code: String? }`
  - `public final class SpaceSaver: Sendable`: `init(layout:, index:, jobs:, destinations:, trims:, adapterFor:, now:, log:)`; `func candidates(_ o: SpaceSaveOptions) throws -> [TrimCandidate]` (captures with every job `synced` for the **active** destination and `captured_at < now - olderThan`, via a new `CaptureIndex.capturesSyncedBefore(destinationID:cutoff:) -> [(captureID, relativeDirectory)]`; per capture read `metadata.json`; attachments with `byteCount > largerThan`, not already trimmed, whose local file exists); `func estimate(_ o) throws -> SpaceSaveEstimate`; `func run(_ o, progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void) async -> SpaceSaveResult`: per candidate, `Task.checkCancellation()`; `inspectFile(remotePath)` must be non-nil with `byteCount == attachment.byteCount` and `verify(remote:, localURL:, expected: FileIntegrity(attachment))` non-nil, else skip (code `remote_mismatch` / `remote_missing`); then `LocalThumbnailer.jpeg(for:uti:maxPixelSize: 640)` written to `layout.thumbnailURL(attachmentID:)` when non-nil; then `trims.record(TrimmedAttachment(… state: .trimmed))`; then remove the file. A capture deleted mid-run (package dir gone) is skipped with code `capture_gone`. Logs `trim.run` at the end. Cancellation returns what was trimmed so far.
  - `public enum RestoreError: Error, Equatable { case notConnected(destinationName: String?), offline, mismatch, notFound, failed(code: String) }`
  - `public final class AttachmentRestorer: Sendable`: `init(layout:, index:, trims:, destinations:, adapterFor:, log:)`; `func restore(captureID: String, attachmentID: String, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws`: the trim row's `destinationID` must be the active destination (else `.notConnected(destinationName:)` with the row's destination display name); `downloadFile(remotePath, to: layout.transfersDir/restore-<uuid>, maxBytes: byteCount, progress:)`; SHA-256 must equal the row's `sha256` and size match, else `trims.setState(.mismatch)` and `.mismatch`; move into place; `trims.remove`; log `attachment.restored`. `.offline` / `.needsAuthentication` → `.offline` / `.notConnected`; `not_found` → `.notFound` (row state `.mismatch` too, so Detail says it's gone).
  - `HippoStore.makeSpaceSaver(adapterFor:)`, `makeRestorer(adapterFor:)`.
  - `Enricher.readsAttachmentBytes: Bool` (extension default `false`; `true` for text recognition and transcript). `EnrichmentRunner.init(…, trimmedPaths: @escaping @Sendable (String) throws -> Set<String> = { _ in [] })`: `scheduleOne` returns false (changing nothing) for a kind with `readsAttachmentBytes` when the capture has any trimmed path. `EnrichmentScheduling` passes `store.trims.trimmedPaths`.
  - `LogLine`: `trim.run` → "Saved space · N files · <bytes>"; `attachment.restored` → "Downloaded a file from Dropbox" / "Download failed: <code>".

- [ ] **Step 1: Write failing tests:**
  - `SpaceSaverTests.candidatesRequireSyncedOnActiveAccountAndBothLimits`: four captures (synced-old-large ✓; synced-recent-large ✗; synced-old-small ✗; pending-old-large ✗; a synced-old-large one bound to a second, disabled destination ✗) → one candidate; `estimate` bytes equal its size.
  - `runChecksRemoteThenTrims`: after run, the local file is gone, `trims.trimmed` has the row with the manifest sha, `thumbnails/<id>.jpg` exists for a PNG attachment (`MediaMaker`), the package still loads with `trimmed:`, the index row and enrichment stay, `trim.run` logged with count 1 and bytes.
  - `runSkipsWhenRemoteDiffers`: overwrite the remote file bytes → skipped, local file kept, no row. `runSkipsWhenRemoteMissing`.
  - `trimSkipsCaptureDeletedMidRun`: a hooked adapter deletes the capture (via `HippoStore.delete` on the same root) inside `inspectFile` → `skipped == 1`, no crash, no row.
  - `cancellationKeepsWhatWasTrimmed`.
  - `AttachmentRestorerTests.restoreVerifiesAndRemovesRow` (bytes equal; progress ends at the size), `restoreMismatchMarksRowAndKeepsThumbnail`, `restoreNeedsSameAccount` (second destination active → `.notConnected`), `restoreOfflineThrowsOffline`.
  - `ReconcilerTests.trimmedCaptureSurvivesRecover`: trim → `recover()` → the index row stays, `invalidPackages == 0` when the loader is given trimmed paths (the Reconciler gains `trimmedPaths:` like the runner; `HippoStore.recover` passes `trims.trimmedPaths`).
  - `EnrichmentRunnerTests.trimmedAttachmentKindsAreNotScheduled`: text recognition not queued for a capture with a trimmed image; data detection still is.
- [ ] **Step 2:** Run `make test`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `make test` and the App build check. Expected: PASS.
- [ ] **Step 5:** Commit `feat(sync): save space by trimming verified large files, with download-on-tap restore`.

### Task 12: Save space + trimmed attachments in Presentation and App (§4.4)

**Files:**
- Create: `HippoKit/Sources/HippoPresentation/Settings/SpaceSaveModel.swift`, `App/Hippo/Settings/SaveSpaceSheet.swift`, `App/Hippo/Detail/RemoteOnlyAttachmentView.swift`
- Modify: `HippoKit/Sources/HippoPresentation/Detail/DetailRow.swift` (`PreviewKind`), `CaptureDetail.swift`, `CaptureDetailModel.swift`, `HippoKit/Sources/HippoPresentation/Settings/SettingsModel.swift`, `HippoKit/Sources/HippoPresentation/Timeline/TimelineRow.swift`, `App/Shared/Thumbnailer.swift`, `App/Hippo/Detail/AttachmentPreview.swift`, `App/Hippo/Detail/CaptureDetailView.swift`, `App/Hippo/Settings/SettingsView.swift`, `App/Hippo/Timeline/TimelineRowView.swift`
- Test: `HippoKit/Tests/HippoPresentationTests/SpaceSaveTests.swift` (new), `DetailTests.swift`, `SettingsTests.swift`

**Interfaces:**
- Produces:
  - `public struct RemoteOnlyAttachment: Equatable, Sendable { var attachmentID: String; var relativePath: String; var byteCount: Int64; var thumbnailURL: URL?; var symbol: String /* "photo" | "video" | "doc" */; var state: State; enum State: Equatable, Sendable { case available(destinationName: String), unavailable(message: String), mismatch(message: String) } }`
  - `PreviewKind.remoteOnly(RemoteOnlyAttachment)`; `CaptureDetail.remoteOnly: [String: RemoteOnlyAttachment]` keyed by attachment ID; `make` gains `trimmed: [TrimmedAttachment]`, `thumbnailURL: (String) -> URL?`, `activeDestination: Destination?`. A trimmed attachment's rows add `DetailRow(label: "Storage", value: "In <name> · Download (<size>)")` or the unavailable/mismatch message; the preview is `.remoteOnly` when the first attachment is trimmed. `exportURLs` excludes trimmed files.
  - `CaptureDetailModel.restoreProgress: [String: Double]`, `restoreError: String?`, `func restore(attachmentID: String) async` (uses `store.makeRestorer(adapterFor:)` through an injected `adapterFor`; `init` gains `adapterFor: (@Sendable (Destination) throws -> any StorageAdapter)?`).
  - `@MainActor @Observable public final class SpaceSaveModel`: `init(store:, adapterFor:, isOnline:)`; `options: SpaceSaveOptions` (default), `estimate: SpaceSaveEstimate?`, `estimateText: String` ("Frees about <bytes> from <n> captures" or the empty copy), `canRun: Bool` (estimate files > 0 and online), `offlineFooter: String?`, `progress: (done: Int, total: Int)?`, `result: SpaceSaveResult?`, `resultText: String?` ("Freed <bytes> from <n> files" / plus " · <n> skipped"), `func refreshEstimate() async`, `func run() async`; step labels `static func ageLabel(_:) -> String` ("1 week", "1 month", "3 months", "1 year"), `sizeLabel(_:)` ("1 MB", …).
  - `SettingsModel.trimmedTotals: (captures: Int, bytes: Int64)` (refresh; feeds `disconnectPrompt`).
  - `TimelineRow` unchanged in shape; the App's `Thumbnailer.thumbnail(relativeDirectory:path:scale:)` falls back to `thumbnails/<attachment-id>.jpg` (the ID is the file name stem of `content/<id>.<ext>`) when the package file is missing; `Thumbnailer.init` gains `thumbnailURL: @Sendable (String) -> URL`.
  - App: `SaveSpaceSheet` (two `Picker`s, the live estimate, the note, the footer, the button with a progress line while running, result text; stops cleanly on `scenePhase == .background` by cancelling the task). Settings Storage section adds "Save space…" when connected. `RemoteOnlyAttachmentView`: thumbnail or symbol, the state text, a Download button → `model.restore`, a `ProgressView(value:)` while downloading, the mismatch/unavailable text otherwise. `AttachmentPreview` renders `.remoteOnly`.

- [ ] **Step 1: Write failing tests:**
  - `DetailTests.trimmedAttachmentRowsAndPreview`: states available (active same destination), unavailable (other destination active → "Connect Developer folder (account …) to download"; none active → "Connect … to download"), mismatch; `exportURLs` excludes it; preview is `.remoteOnly`.
  - `SpaceSaveTests.estimateTextAndCanRun` (empty copy with the chosen steps; offline disables), `runReportsProgressAndResult`, `labels`.
  - `SettingsTests.trimmedTotalsFeedDisconnectPrompt`.
- [ ] **Step 2:** Run `make test`. Expected: FAIL.
- [ ] **Step 3:** Implement models, then views.
- [ ] **Step 4:** Run `make test` and the App build check. Expected: PASS, `** BUILD SUCCEEDED **`.
- [ ] **Step 5:** Commit `feat(app): save space sheet, remote-only attachments with download on tap`.

### Task 13: Download from Dropbox core (§4.5, §6.2)

**Files:**
- Create: `HippoKit/Sources/SyncEngine/RemoteDownloader.swift`, `HippoKit/Tests/SyncEngineTests/RemoteDownloaderTests.swift`
- Modify: `HippoKit/Sources/SyncEngine/HippoStore.swift`, `HippoKit/Sources/LocalRepository/Log/LogEvent.swift`, `HippoKit/Sources/LocalRepository/Reconciler.swift` (skip `staging/download-*` dirs whose lock is held, as for gold), `HippoKit/Sources/HippoPresentation/Log/LogLine.swift`, `docs/log-format.md`

**Interfaces:**
- Produces:
  - `LogEventName` gains `downloadRun = "download.run"` (global: `count` downloaded, `code`) and `downloadCapture = "download.capture"` (per capture: outcome ok / skipped / failed, `code`).
  - `public struct DownloadWindow: Sendable, Equatable { var seconds: TimeInterval? /* nil = everything */; static let steps: [TimeInterval?] = [14, 30, 90, 180, 365].map { $0 * 86_400 } + [nil]; static let `default` = DownloadWindow(seconds: 30 * 86_400) }`
  - `public struct DownloadCandidate: Sendable, Equatable { var captureID: String; var relativeDirectory: String; var files: [RemoteEntry]; var lightBytes: Int64; var locallyDeleted: Bool }`
  - `public struct DownloadEstimate: Sendable, Equatable { var candidates: [DownloadCandidate]; var skippedLocallyDeleted: Int; var bytes: Int64; var count: Int }`
  - `public struct DownloadResult: Sendable, Equatable { var downloaded: Int; var skipped: Int; var failed: Int; var code: String? }`
  - `public final class RemoteDownloader: Sendable`: `public static let defaultLightAttachmentLimit: Int64 = 10 * 1024 * 1024`, `maxDocumentBytes = GoldPuller's`, `maxAssetBytes = GoldPuller's`; `init(layout:, index:, jobs:, destinations:, remoteState:, trims:, enrichments:, enrichmentTasks:, adapterFor:, lightAttachmentLimit: Int64 = defaultLightAttachmentLimit, calendar: Calendar = .current, now:, log:)`.
    - `func estimate(window: DownloadWindow, includeLocallyDeleted: Bool) async throws -> DownloadEstimate`: month folders `captures/YYYY/MM` from the month of `(now - seconds) - 1 day` to now (or `captures/` once when `seconds == nil`), each `listFolder(recursive: true)` paged; group files by `captures/YYYY/MM/DD/<id>`; a candidate needs `complete.json` and `metadata.json`; exclude indexed captures, `hasTombstone`, and (unless `includeLocallyDeleted`) `localDeletedCaptureIDs` (counted `skippedLocallyDeleted`, and still listed in `candidates` with `locallyDeleted: true` only when included); `lightBytes` = metadata + marker + attachments ≤ 10 MiB.
    - `func run(_ candidates: [DownloadCandidate], window: DownloadWindow, progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void) async -> DownloadResult`: per candidate under a `StagingLock`ed `staging/download-<uuid>/` work dir: download `metadata.json` (≤ 1 MiB), decode, skip (`outcome: skipped`, code `outside_window`) when `captured_at` is outside the window; download `complete.json` and every attachment ≤ 10 MiB; `PackageValidator.validate(directory: work/<id>, trimmed: largePaths)` must be `.complete` and the metadata's local date must match the remote directory, else fail (code `invalid_package` / `incomplete_package`), remove the work dir; move `work/<id>` to `layout.packageURL(relativeDirectory)` (create parents); `index.register`; `jobs.insertSynced(captureID:destinationID:)`; `trims.record` per large attachment (`state: .trimmed`, sha and size from metadata) and, when `supportsThumbnails`, `adapter.thumbnail(path, maxPixelSize: 640)` written to `thumbnailURL`; `remoteState.removeLocalDelete(captureID)`; then for each layer `[.device, .server]`: `inspectFile(enrichment.json)` → download, decode, download assets (`EnrichmentPaths.isValidAssetPath`, sizes capped, SHA-256 checked), `enrichments.write`; for `.device`: `enrichments.markUploaded(revision: StreamingHasher.digest(of: written enrichment.json).sha256)` and `enrichmentTasks.set(captureID, kind, version: facet.version, status: facet.status.rawValue)` for every facet whose key is a `FacetKind`. An enrichment failure logs and leaves the capture downloaded (silver is optional). Log `download.capture` per candidate and `download.run` at the end. Cancellation stops after the current capture; what landed stays (resumable).
  - `HippoStore.makeDownloader(adapterFor:)`.
  - `LogLine`: `download.run` → "Downloaded N captures from Dropbox"; `download.capture` → "Downloaded from Dropbox" / "Skipped: <code>" / "Couldn't download: <code>".

- [ ] **Step 1: Write failing tests** (two `SyncHarness` roots sharing one remote folder: phone A uploads with its worker, phone B downloads):
  - `estimateListsCompleteRemoteCapturesInWindow`: A uploads three captures dated 10, 40 and 400 days ago (drafts with `startedAt`); B's estimate for 1 month → 1 candidate; 3 months → 2; everything → 3; bytes equal the light sizes.
  - `estimateExcludesIndexedTombstonedAndLocallyDeleted`: B indexes one, tombstones one, locally deletes one → 0 candidates and `skippedLocallyDeleted == 1`; `includeLocallyDeleted: true` → 1 candidate flagged.
  - `runRegistersSyncedNeverReuploads`: after run, B's index has the capture, its job is `synced`, B's worker pass performs zero `upload` operations, the capture's `capture.saved` isn't logged (it's `download.capture`), timeline-ordering fields match.
  - `largeAttachmentArrivesRemoteOnly`: a downloader with `lightAttachmentLimit: 4096` and a 10 KiB attachment → not downloaded, `trims.trimmed` row present with the metadata sha, thumbnail written for a PNG.
  - `incompleteRemotePackageIsSkippedAndNotIndexed`: remove one remote attachment → `failed == 1`, nothing under B's `captures/`, no index row, no staging leftovers.
  - `badHashIsSkippedNeverHalfIndexed`: corrupt a remote attachment's bytes → same assertions.
  - `enrichmentDocumentsAreImported`: A's device and server docs exist remotely → B has both layers, `enrichment_tasks` rows at the facet versions, device revision marked uploaded (B's `EnrichmentUploader.runOnce` uploads nothing).
  - `includeThemRemovesLocalDeleteRecord`.
  - `outsideWindowByCapturedAtIsSkipped`: folder date inside the window, `captured_at` outside (build the package with a zone that shifts the date) → skipped with code `outside_window`.
  - `cancellationIsResumable`: cancel after the first capture; a second run downloads the rest.
- [ ] **Step 2:** Run `make test`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `make test`. Expected: PASS.
- [ ] **Step 5:** Commit `feat(sync): download recent captures from the destination in light form, never re-uploaded`.

### Task 14: Download sheet (§4.5)

**Files:**
- Create: `HippoKit/Sources/HippoPresentation/Settings/DownloadModel.swift`, `App/Hippo/Settings/DownloadSheet.swift`
- Modify: `App/Hippo/Settings/SettingsView.swift`
- Test: `HippoKit/Tests/HippoPresentationTests/DownloadModelTests.swift` (new)

**Interfaces:**
- Produces:
  - `@MainActor @Observable public final class DownloadModel`: `init(store:, adapterFor:, isOnline:)`; `window: DownloadWindow` (default), `includeLocallyDeleted = false`, `estimate: DownloadEstimate?`, `estimating: Bool`, `estimateText: String?` ("About <n> captures, <bytes>"), `skipText: String?` ("Skipping <n> you removed from this iPhone", only when > 0), `canRun`, `progress: (done: Int, total: Int)?`, `result: DownloadResult?`, `resultText: String?` ("Downloaded <n> captures" plus " · <n> couldn't be downloaded" when failed > 0), `func refreshEstimate() async`, `func run() async`, `static func windowLabel(_:) -> String` ("2 weeks", "1 month", "3 months", "6 months", "1 year", "everything"), `estimateFailed: Bool`.
  - App: `DownloadSheet` (the picker, estimate, skip line with the "Include them" toggle, Download button, progress, result). Runs inside `BackgroundActivity.run(name: "download")` so it continues in background time; cancellation on expiry leaves it resumable. Settings Storage section adds "Download from <name>…" when connected. After a run, post `SyncCoordinator.passFinished`-style reload: the sheet's dismiss triggers `model.refresh()` and the timeline reloads on `passFinished` (post it from the model after `run`, object nil).

- [ ] **Step 1: Write failing tests** in `DownloadModelTests`: `estimateAndSkipText`, `includeThemChangesEstimate`, `runReportsProgressAndResultText`, `labels`.
- [ ] **Step 2:** Run `make test`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `make test` and the App build check. Expected: PASS, `** BUILD SUCCEEDED **`.
- [ ] **Step 5:** Commit `feat(app): download from Dropbox sheet`.

### Task 15: Docs, acceptance rows, follow-up bookkeeping (§9)

**Files:**
- Modify: `docs/acceptance.md`, `README.md`, `docs/log-format.md` (final check that every new event is listed), `docs/package-format.md` (one sentence: a reader may see `captures/` packages written by several phones and should expect deletions), `docs/superpowers/plans/2026-11-07-hippo-enrichment.md` (tick "Dropbox work")

- [ ] **Step 1:** Append rows D1–D13 to `docs/acceptance.md`, copied from design §9 with Result "not run", in the order D1–D8, D13, D9–D12 as the design lists them. Add a line above the table: rows 1–24 upload halves are re-run in the same session.
- [ ] **Step 2:** README: a "Dropbox" section covering setup (`make dropbox-setup`, what goes in `Config/Secrets.xcconfig` and `.env`, never commit them), connect/disconnect, what lands where (`Apps/Hippo/captures`, `enrichments/device`, `logs/<install-id>`), delete both ways and the safety valve, Save space, Download from Dropbox, and the integration tests (`.env`, test root `_hippo-test/`). Update the Status paragraph (Dropbox exists; release builds upload). Update the "Known limits" bullet about new installs (Download from Dropbox replaces "does not rebuild"). Remove the "Until Dropbox (Plan 3) exists…" sentences.
- [ ] **Step 3:** Run `make test`, `scripts/validate-fixtures.sh` and the App build check. All pass.
- [ ] **Step 4:** Commit `docs: Dropbox acceptance rows D1–D13, README Dropbox section`.

---

## After the build (not subagent tasks)
- Whole-branch final review (fresh reviewer, most capable model), then "Rulings I made" at the end of the ledger.
- **Device test with Jorge:** `make device` (DEBUG build). Run D1–D13 and re-run rows 1–24's upload halves; record results in `docs/acceptance.md`.
- Update the `hippo-core-parked-followups` memory (items 1–7 of design §8 closed; still parked: time-zone filter, orphan recovery UI, 10k scale) and the `hippo-dropbox-brainstorm` memory (built; the "Hippo Dev" sentence is stale).
- PR to `main` (ask Jorge first).
