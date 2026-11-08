# Hippo

Hippo is a fast, local-first iPhone capture app that replaces emailing yourself things to remember. Each capture is saved on the phone first, as plain files plus versioned JSON, and then uploaded as a portable package to a cloud folder you own, where a future desktop app can read it.

- Spec: [`hippo-v0-spec.md`](hippo-v0-spec.md)
- Design (where it differs from the spec, it wins): [`docs/superpowers/specs/2026-11-07-hippo-v0-design.md`](docs/superpowers/specs/2026-11-07-hippo-v0-design.md)

**Status:** `HippoKit` (the core Swift package) and the iPhone app with its Share Extension exist. The app saves captures locally and syncs them to a DEBUG-only Developer folder; the Dropbox adapter (Plan 3) is not built yet, so nothing leaves the iPhone in a release build.

## The iPhone app

Timeline of captures, a detail view, a note editor, a voice recorder, a Share Extension, and Settings.

### Requirements

- Xcode 27.2
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`); `Hippo.xcodeproj` is generated and not committed
- An iPhone on iOS 27 (the Simulator is enough for development)

### First-time setup

1. Copy `Config/Local.example.xcconfig` to `Config/Local.xcconfig` (gitignored) and set `DEVELOPMENT_TEAM` to your own Apple team ID.
2. Find your team ID in Xcode under Settings > Accounts (select your team; the ID is the 10-character value shown for it), or on the Membership page of the Apple developer portal. A free Personal Team works.
3. Keep the ID only in `Config/Local.xcconfig`. Never put it in `project.yml`, the README, or any committed file.

### Commands

| Command | What it does |
|---|---|
| `make device` | Build and install on a connected iPhone (needs `Config/Local.xcconfig`). |
| `make sim` | Build, install and launch in the Simulator with the fixture captures. |
| `make test` | HippoKit unit tests on the Mac. |
| `make uitest` | UI smoke tests in the Simulator (`HIPPO_SIM` picks the simulator; default `iPhone 18 Pro`). They are simulator-only: on a device the `com.jorgeper.hippo.uitests` bundle would need its own App ID. |
| `make diagnostics` | Print `diagnostics.json` from the app on a connected iPhone. |

> **Free-team installs expire after 7 days. Rerun `make device`; captures survive unless you delete the app.**

Device scenarios to run by hand are in [`docs/acceptance.md`](docs/acceptance.md).

### Identifiers and storage

- App Group: `group.com.jorgeper.hippo`
- Keychain access group: `$(AppIdentifierPrefix)com.jorgeper.hippo.shared`
- The store lives in the App Group container at `Library/Application Support/Hippo/` (layout below). The app and the Share Extension both use it.

### Developer folder (DEBUG only)

Debug builds offer a "Developer folder" destination in Settings. It "uploads" into `HippoDevRemote/` next to the store in the App Group container, so the full sync path can be exercised without an account. Release builds do not include it. The UI tests launch with `-HippoResetStore YES` (DEBUG only), which wipes the store and this folder first.

### Location is opt-in

Hippo saves a location with a capture only if you turn on "Save location with captures" in Settings and allow the iOS permission. It is read at the moment you save, never in the background.

### Known limits

- The source app is not recorded. Hippo saves type-identifier clues instead.
- Email capture is limited to what the email app shares. If an email app shares nothing useful, use Print, then Share as PDF from the print preview, and share that PDF to Hippo.
- The free-account 7-day reinstall applies (see above).
- Uploads are a copy, not a backup policy. Deleting the app deletes local captures that have not been uploaded.
- A new install does not rebuild the library from Dropbox.
- Background upload timing is up to iOS.

## HippoKit

`HippoKit/` is a Swift package with no third-party dependencies. It builds for iOS 27 and macOS 27, so all of its tests run on a Mac without a simulator or device.

### Module map

| Module | Responsibility |
|---|---|
| `CaptureCore` | The package format: metadata and completion-marker models, `HippoJSON`, safe paths, streaming SHA-256, media inspection, `PackageWriter` (atomic commit through `staging/`), `PackageValidator`. |
| `LocalRepository` | The on-phone SQLite store: `Database`, `CaptureIndex` (timeline, filters, full-text search), `JobStore` (upload jobs, leases, receipts, checkpoints), `DestinationStore` (accounts and binding rules), `Reconciler` (startup recovery), `Diagnostics`. |
| `SyncEngine` | The `StorageAdapter` contract, `SyncWorker` (marker-last uploads, retry policy), and `HippoStore`, the facade the app and Share Extension use for everything. |
| `FilesystemAdapter` | A `StorageAdapter` that writes to a local folder, with `FaultPlan` for injected failures. For development and contract tests; not a cloud provider. |
| `HippoTestSupport` | Generates small media files (images, audio, video, PDF) for tests and fixtures. |
| `hippo-fixtures` | Command-line tool that regenerates the committed fixture packages. |

`SyncEngine` and `LocalRepository` contain no provider-specific code. A test enforces this.

### Running the tests

```sh
swift test --package-path HippoKit
```

### Fixtures and schemas

`fixtures/packages/` holds valid example packages for building a reader, and `schema/` holds the JSON Schemas for `metadata.json` and `complete.json`. Check every fixture against the schemas (needs [`uv`](https://docs.astral.sh/uv/), which runs `check-jsonschema`):

```sh
scripts/validate-fixtures.sh
```

Regenerate the fixtures after a format change, then validate them and commit the output as a whole:

```sh
swift run --package-path HippoKit hippo-fixtures fixtures/packages
scripts/validate-fixtures.sh
```

The generator is deterministic for IDs, clock and time zone, but media files embed creation timestamps, so their hashes change on every run. See [`fixtures/README.md`](fixtures/README.md).

### Local storage layout

On the phone the store lives in the App Group container, under `Library/` so that `devicectl` can copy it to a Mac:

```
<App Group>/Library/Application Support/Hippo/
  captures/YYYY/MM/DD/<capture-id>/   committed packages (metadata.json, content/, complete.json), immutable
  staging/                            in-progress commits and packages being deleted; leftovers removed at launch
  hippo.sqlite                        index, upload jobs and destinations (WAL; shared by app and extension)
  diagnostics.json                    redacted counts, safe error codes and versions; no content, IDs or locations
```

`captures/` uses the same relative layout as the remote destination. The packages are the source of truth: `HippoStore.recover()`, run at launch, rebuilds missing index rows from them. Recovery isolates failures: one bad item is counted in `RecoveryReport.failed` and skipped, never aborting the rest. Blocked or waiting uploads (for example after a full Dropbox) are retried on demand with `HippoStore.retry(captureID:)` or `retryAll()`.
