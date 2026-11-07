# Hippo

Hippo is a fast, local-first iPhone capture app that replaces emailing yourself things to remember. Each capture is saved on the phone first, as plain files plus versioned JSON, and then uploaded as a portable package to a cloud folder you own, where a future desktop app can read it.

- Spec: [`hippo-v0-spec.md`](hippo-v0-spec.md)
- Design (where it differs from the spec, it wins): [`docs/superpowers/specs/2026-11-07-hippo-v0-design.md`](docs/superpowers/specs/2026-11-07-hippo-v0-design.md)

**Status:** only `HippoKit`, the core Swift package, exists. The iPhone app with its Share Extension (Plan 2) and the Dropbox adapter (Plan 3) are not built yet.

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
