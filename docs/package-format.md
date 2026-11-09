# Hippo capture package format, version 1

For developers building a reader (the desktop app). Machine-readable definitions: `schema/capture-metadata-v1.schema.json` and `schema/complete-v1.schema.json`. Worked examples: `fixtures/packages/`. The reference writer and validator are `PackageWriter` and `PackageValidator` in `HippoKit/Sources/CaptureCore`.

## Layout

Everything is UTF-8 JSON or raw attachment bytes. A destination's Hippo folder contains:

```text
captures/YYYY/MM/DD/<capture-id>/
  metadata.json
  content/<attachment-id>.<ext>      (absent when there are no attachments)
  complete.json
```

- `YYYY/MM/DD` is the date part of `local_datetime` (the capture's local calendar date). It never changes, even if the phone later changes time zone. Do not derive it from `captured_at`.
- `<capture-id>` and `<attachment-id>` are lowercase UUIDs. The directory name equals `capture_id`.
- Attachment filenames are generated (`content/<uuid>.<ext>`, ext is 1-10 chars of `[a-z0-9]`). Original names are only in metadata.
- Packages are immutable once `complete.json` exists. Nothing mutable (sync state, provider IDs, upload URLs, credentials) is stored in a package.

## Conventions

- Timestamps are RFC 3339. `captured_at` and `observed_at` are UTC with milliseconds and a `Z` suffix. `local_datetime` is whole seconds with a numeric offset (`+00:00`, never `Z`).
- SHA-256 values are 64 lowercase hex characters. Sizes are bytes.
- Omission rule: an unavailable optional field is omitted. It is never `null` and never an empty string; unknown is not a guess. Treat a missing key as unknown.
- Open sets: `capture_method`, `content_types` and the `source`/`provenance`/`representation_source` strings may take values you do not know. Accept and preserve them.
- Unknown additional keys, anywhere, must be ignored.
- `schema_version` is an integer. This document is version 1. Reject any other value (in either file) with a clear "unsupported version" error rather than guessing.

## `metadata.json`

Always present (required):

| Field | Type / units | Notes |
|---|---|---|
| `schema_version` | integer | `1` |
| `capture_id` | UUID string | Matches the directory name and `complete.json`. |
| `captured_at` | RFC 3339 UTC | When the capture began. |
| `local_datetime` | RFC 3339 with offset | Wall-clock time at capture; names the date directory. |
| `timezone_identifier` | IANA zone string | e.g. `America/Los_Angeles`. |
| `utc_offset_seconds` | integer seconds | East of UTC at `captured_at`. |
| `capture_method` | string | Known: `share_extension`, `typed_note`, `file_import`, `voice_recording`. |
| `content_types` | string array | Known: `text`, `url`, `image`, `video`, `audio`, `pdf`, `file`. May be empty (a comment-only capture). |
| `urls` | array | Objects `{url, source}`; `source` e.g. `shared_payload`, `detected_in_text`. May be empty. |
| `producer` | object | `{app_version, build, os_version}` strings of the writing app. |
| `attachments` | array | May be empty. |
| `metadata_observations` | array | Objects `{key, value, provenance}`; `value` is any JSON. |
| `extensions` | object | Reserved for additive data; may be empty. |

Optional (omitted when unknown):

| Field | Type / units | Notes |
|---|---|---|
| `user_note` | string | The user's comment. |
| `shared_title` | string | Title supplied by the sharing app. |
| `shared_text` | string | Text supplied by the sharing app. |
| `source_application` | string | |
| `capture_location` | object | `latitude`, `longitude` (degrees), `horizontal_accuracy_meters`, `observed_at` (RFC 3339 UTC), `provenance`. |

Attachment object:

| Field | Required | Type / units | Notes |
|---|---|---|---|
| `attachment_id` | yes | UUID string | |
| `relative_path` | yes | string | `content/<attachment-id>.<ext>`, relative to the package directory. |
| `uti` | yes | string | Uniform Type Identifier, e.g. `public.png`, `public.utf8-plain-text`. |
| `byte_count` | yes | integer bytes | |
| `sha256` | yes | hex string | Of the file bytes. |
| `representation_source` | yes | string | `item_provider_file`, `item_provider_data`, `typed_note`, `recording`. |
| `original_filename` | no | string | Display only. Never use it as a path. |
| `mime_type` | no | string | |
| `media` | no | object | See below. |

`media` (all optional): `width_pixels`, `height_pixels` (integers), `duration_seconds` (number), `embedded_created_at` (`{value, has_utc_offset}`: the time stored inside the file; `value` is local wall-clock time and only carries an offset when `has_utc_offset` is true), `embedded_location` (`latitude`, `longitude` in degrees, `altitude_meters`, negative below sea level), `camera_make`, `camera_model`.

A typed note's body is its first `public.utf8-plain-text` (or `public.plain-text`) attachment; a URL-only capture has no attachments and keeps its URL in `urls`.

## `complete.json` (the marker)

```json
{ "schema_version": 1, "capture_id": "<uuid>",
  "files": [ { "relative_path": "metadata.json", "byte_count": 665, "sha256": "<hex>" }, ... ] }
```

`files` lists every file in the package except `complete.json`: `metadata.json` first, then each attachment. Each `relative_path` is `metadata.json` or `content/<id>.<ext>`.

Marker semantics: the writer finishes and syncs all other files, then writes `complete.json`; the uploader uploads it last. So its presence means "the writer finished", and its manifest says exactly what must be present and intact. A package without it is in progress (or abandoned) and must not be read.

The package digest is the SHA-256 (lowercase hex) of the exact bytes of `complete.json`. It changes whenever any listed file changes.

## Reader algorithm

Follows the spec's future desktop-reader contract. Locate the configured Hippo root inside the provider-synced folder, watch it, and rescan periodically; never rely on filesystem event order.

1. For each directory `captures/YYYY/MM/DD/<capture-id>/`, skip it unless `complete.json` exists.
2. Decode `complete.json`. If `schema_version` is not 1, reject it as unsupported (report; do not retry). Otherwise ignore unknown keys.
3. Check every manifest `relative_path` is safe: relative, not empty, no `.` or `..` segment, no backslash, no NUL, and either `metadata.json` or under `content/`. Any unsafe path means corrupt. The manifest must include `metadata.json`.
4. For each manifest entry, the file must exist and match `byte_count` and `sha256`. A missing or mismatched file means the package is incomplete or still syncing: leave it pending and retry on later scans. Only after repeated failures over a reasonable period surface it as corrupt.
5. Decode `metadata.json` (version 1, unknown keys ignored). `metadata.capture_id` must equal the marker's and the directory name, and every attachment `relative_path` must be in the manifest; otherwise corrupt.
6. Index by `capture_id` plus package digest. The same pair already indexed means nothing to do; the same ID with a new digest replaces the entry. This makes rescans idempotent.

Keep your search/SQLite/vector indexes outside the synced folder; they must be rebuildable from packages alone. Store derived (AI) output separately, keyed by `capture_id`; see [`enrichment-format.md`](enrichment-format.md) for the format the phone and a server use for it. Never modify a package.

## Dropbox and online-only placeholders

Sync clients (Dropbox online-only, OneDrive Files On-Demand, iCloud) may show a file in a directory listing without its bytes being on disk. `complete.json` or an attachment can therefore appear present while its content is not downloaded, and files of one package can arrive in any order. Do not treat directory presence as availability:

- Read the bytes (or request materialization where the provider supports it) and verify size and hash before trusting a file. Reading a placeholder may block, fail, or trigger a download.
- Do not assume the marker arrives last, or that other files are local when it is.
- Treat read failures and size/hash mismatches as pending first (step 4), not corrupt.

A reader may see `captures/` packages written by several phones sharing one folder, and should expect packages to be deleted at any time (from the phone, from the Dropbox folder, or by another phone).

The phone also keeps a content-free event log in `logs/` (locally, and per install on the destination); it is not part of any package. See `docs/log-format.md`.
