# Hippo capture package format, version 1.1

For developers building a reader (the desktop app). The signals added in 1.1 are listed in one table in `context-signals.md`. Machine-readable definitions: `schema/capture-metadata-v1.schema.json`, `schema/complete-v1.schema.json` and `schema/capture-comment-v1.schema.json`. Worked examples: `fixtures/packages/` in the repository (package 7 carries every 1.1 signal). In a synced Hippo folder this document is `format/package-format.md` and the schemas are in `format/schema/`. The reference writer and validator are `PackageWriter` and `PackageValidator` in `HippoKit/Sources/CaptureCore`.

## Versioning

The format version has two parts, written "major.minor". This document is version 1.1.

| Part | Where | Rule |
|---|---|---|
| major | `schema_version`, an integer | Changes only when an existing field changes meaning or type, a required field is removed, or the directory layout changes. This document is major 1. A reader rejects a major it does not know, in any file, with an "unsupported version" error. |
| minor | `schema_minor`, an optional integer >= 0 | Counts additive releases: a new optional field, observation key, facet kind, or known value of an open set. A missing `schema_minor` means 0. A reader accepts any minor, reads what it knows and ignores the rest. A writer writes the minor of the format it implements. |

- `schema_minor` sits beside `schema_version` in `metadata.json`, `complete.json`, each `comments/<comment-id>.json` and `enrichment.json`.
- There is no patch number. A documentation fix changes no file.
- Neither part is a string such as `"1.1"`. Both are integers.
- A facet's own `version` field describes that facet's payload shape and is independent of the format version.
- Everything written before format 1.1 is 1.0 and has no `schema_minor`. It stays valid and unchanged.

## Layout

Everything is UTF-8 JSON or raw attachment bytes. A destination's Hippo folder contains:

```text
captures/YYYY/MM/DD/<capture-id>/
  metadata.json
  content/<attachment-id>.<ext>      (absent when there are no attachments)
  complete.json
  comments/<comment-id>.json         (one per comment; absent when there are none)
  comments/<comment-id>.m4a          (only for an audio comment)
```

- `YYYY/MM/DD` is the date part of `local_datetime` (the capture's local calendar date). It never changes, even if the phone later changes time zone. Do not derive it from `captured_at`.
- `<capture-id>` and `<attachment-id>` are lowercase UUIDs. The directory name equals `capture_id`.
- Attachment filenames are generated (`content/<uuid>.<ext>`, ext is 1-10 chars of `[a-z0-9]`). Original names are only in metadata.
- The manifested files are immutable once `complete.json` exists; `comments/` is append-only (below). Nothing mutable (sync state, provider IDs, upload URLs, credentials) is stored in a package.

## Conventions

- Timestamps are RFC 3339. `captured_at` and `observed_at` are UTC with milliseconds and a `Z` suffix. `local_datetime` is whole seconds with a numeric offset (`+00:00`, never `Z`).
- SHA-256 values are 64 lowercase hex characters. Sizes are bytes.
- Omission rule: an unavailable optional field is omitted. It is never `null` and never an empty string; unknown is not a guess. Treat a missing key as unknown.
- Open sets: `capture_method`, `content_types` and the `source`/`provenance`/`representation_source` strings may take values you do not know. Accept and preserve them.
- Unknown additional keys, anywhere, must be ignored.
- `schema_version` is an integer. This document is major version 1. Reject any other value (in any of these files) with a clear "unsupported version" error rather than guessing. Accept any `schema_minor` (see Versioning).

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
| `capture_method` | string | Known: `share_extension`, `typed_note`, `file_import`, `voice_recording`, `camera`. |
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
| `schema_minor` | integer | Format minor of the writer (1.1 writes `1`). Missing means 0. |
| `capture_location` | object | `latitude`, `longitude` (degrees), `horizontal_accuracy_meters`, `observed_at` (RFC 3339 UTC), `provenance`, and the optional extras below. |

`capture_location` extras (format 1.1). All optional. Each is omitted when Core Location reports it as invalid (negative accuracy, negative speed, a course outside 0-360, a value that is not finite). The location itself is kept. A single fix often has no speed or course; they are then absent.

| Field | Type / units | Notes |
|---|---|---|
| `altitude_meters` | number, meters | Above sea level; negative below. |
| `vertical_accuracy_meters` | number, meters | |
| `speed_meters_per_second` | number, m/s | |
| `speed_accuracy_meters_per_second` | number, m/s | |
| `course_degrees` | number, degrees | Clockwise from true north, 0-360. |
| `course_accuracy_degrees` | number, degrees | |

Attachment object:

| Field | Required | Type / units | Notes |
|---|---|---|---|
| `attachment_id` | yes | UUID string | |
| `relative_path` | yes | string | `content/<attachment-id>.<ext>`, relative to the package directory. |
| `uti` | yes | string | Uniform Type Identifier, e.g. `public.png`, `public.utf8-plain-text`. |
| `byte_count` | yes | integer bytes | |
| `sha256` | yes | hex string | Of the file bytes. |
| `representation_source` | yes | string | `item_provider_file`, `item_provider_data`, `typed_note`, `recording`, `camera` (taken with Hippo's camera button). |
| `original_filename` | no | string | Display only. Never use it as a path. |
| `mime_type` | no | string | |
| `media` | no | object | See below. |

`media` (all optional): `width_pixels`, `height_pixels` (integers), `duration_seconds` (number), `embedded_created_at` (`{value, has_utc_offset}`: the time stored inside the file; `value` is local wall-clock time and only carries an offset when `has_utc_offset` is true), `embedded_location` (`latitude`, `longitude` in degrees, `altitude_meters`, negative below sea level), `camera_make`, `camera_model`.

A typed note's body is its first `public.utf8-plain-text` (or `public.plain-text`) attachment; a URL-only capture has no attachments and keeps its URL in `urls`.

## Context observations

Format 1.1 adds five `metadata_observations` entries. Each is `{key, value, provenance}` and `value` is an object. A field that could not be read is omitted. If no field could be read, the whole entry is omitted. Strings are at most 100 characters. They are facts, never conclusions: nothing here says "in a car", only the audio route, the motion samples and the speed that suggest it. The registry of every signal is `context-signals.md`.

Absent means "not read that time". To tell that from "not collected", see `context.enabled`.

### `context.audio_route` (provenance `av_audio_session`)

Read from the current audio route without starting or changing an audio session.

| Field | Type | Notes |
|---|---|---|
| `outputs` | array | At most 8 ports. Omitted when empty. |
| `inputs` | array | At most 8 ports. Omitted when empty. |

Port: `{port_type, port_name?}`. `port_type` is an open set. Known values: `built_in_speaker`, `built_in_receiver`, `built_in_mic`, `headphones`, `headset_mic`, `bluetooth_a2dp`, `bluetooth_hfp`, `bluetooth_le`, `car_audio`, `airplay`, `hdmi`, `usb_audio`, `line_out`, `line_in`. Any other port is the raw system port string. `port_name` is the system's name for the port; for a Bluetooth device it is the accessory's own name, so it can be a personal name.

### `context.device` (provenance `device_state`)

| Field | Type / units | Notes |
|---|---|---|
| `battery_level` | number, 0 to 1 | Omitted when unknown. |
| `battery_state` | string | `unplugged`, `charging`, `full`. |
| `low_power_mode` | boolean | |
| `thermal_state` | string | `nominal`, `fair`, `serious`, `critical`. |
| `interface_style` | string | `light`, `dark`. |
| `orientation` | string | `portrait`, `portrait_upside_down`, `landscape_left`, `landscape_right`, `face_up`, `face_down`. Often absent for a capture made in the share sheet. |
| `locale` | string | For example `en_US`. |
| `uses_24_hour_clock` | boolean | |

### `context.network` (provenance `nw_path`)

| Field | Type | Notes |
|---|---|---|
| `interface` | string | `wifi`, `cellular`, `wired`, `other`, `none` (no usable path). |
| `expensive` | boolean | |
| `constrained` | boolean | Low Data Mode. |

Taken from the most recent network path the process had received. The snapshot is taken when the capture begins; the network part is read again at save time. If no path had arrived, the entry is omitted.

### `context.burst` (provenance `last_saved`)

| Field | Type / units | Notes |
|---|---|---|
| `previous_capture_id` | UUID string | The capture saved most recently before this one on this phone, whatever its age. |
| `seconds_since_previous` | number, seconds | Difference between the two `captured_at` values, one decimal. |

Omitted when there is no previous capture or the gap is negative. Written only when device context was on. You can also work out bursts from `captured_at` across packages; this entry saves the scan.

### `context.enabled` (provenance `settings`)

`{"groups": ["device_context", "location"]}`: the capture-time signal groups that were switched on when the capture was saved.

| Group | Meaning |
|---|---|
| `device_context` | The "Save device context with captures" switch was on. `context.audio_route`, `context.device`, `context.network` and `context.burst` were attempted. |
| `location` | The location switch was on and permission was granted. |

`groups` may be empty (`[]`). A build that knows this format writes `context.enabled` on every capture, even with everything off. If it is missing, the capture was written by a build without these signals (format 1.0), and nothing can be said about what was collected. The snapshot is used if it was taken at most 120 seconds from the capture start; otherwise the route and device entries are omitted.

## `complete.json` (the marker)

```json
{ "schema_version": 1, "schema_minor": 1, "capture_id": "<uuid>",
  "files": [ { "relative_path": "metadata.json", "byte_count": 665, "sha256": "<hex>" }, ... ] }
```

`files` lists every file in the package except `complete.json` and anything under `comments/`: `metadata.json` first, then each attachment. Each `relative_path` is `metadata.json` or `content/<id>.<ext>`.

Marker semantics: the writer finishes and syncs all other files, then writes `complete.json`; the uploader uploads it last. So its presence means "the writer finished", and its manifest says exactly what must be present and intact. A package without it is in progress (or abandoned) and must not be read.

The package digest is the SHA-256 (lowercase hex) of the exact bytes of `complete.json`. It changes whenever any listed file changes.

## Comments

A comment the user adds after the capture is a new file in `comments/`; the manifest never lists it, `metadata.json` and `complete.json` are never rewritten, and the package digest does not change. `comments/<comment-id>.json`, schema version 1 (comments written by format 1.1 also carry `schema_minor`):

| Field | Required | Notes |
|---|---|---|
| `schema_version` | yes | `1` |
| `capture_id` | yes | Matches the package. |
| `comment_id` | yes | Lowercase UUID; equals the file's base name. |
| `added_at` | yes | RFC 3339 UTC with milliseconds, `Z`. |
| `local_datetime`, `timezone_identifier`, `utc_offset_seconds` | yes | Same rules as in `metadata.json`. |
| `producer` | yes | Same object as in `metadata.json`. |
| `text` | one of | The typed comment, trimmed, non-empty. |
| `audio` | one of | `{relative_path, uti, mime_type, byte_count, sha256, media: {duration_seconds}}`; `relative_path` is `comments/<comment-id>.<ext>`. |

Exactly one of `text` or `audio` is present. The json is the comment's own marker: it is written after its audio file, on the phone (staging, then rename) and on the destination (audio uploaded first). An interrupted save can leave an audio file in `comments/` with no json beside it; no json means no comment, so ignore it (readers and the phone's uploader list `comments/*.json` only). A json whose audio file is missing, or does not match `byte_count` and `sha256`, is a pending comment, exactly like a package whose manifest entry has not arrived yet: retry on later scans. A `schema_version` other than 1 is unsupported; unknown keys are ignored. Deleting a package deletes its comments with it.

## Format history

| Format | Dates | Changes |
|---|---|---|
| 1.0 | 2026-11-07 to 2026-11-10 | Packages, enrichment, comments, the `camera` capture method. No `schema_minor`. |
| 1.1 | 2026-11-10 | `schema_minor`; the `context.*` observations; the six `capture_location` extras; the facet kinds `motion_activity`, `weather`, `barcodes`, `language`, `sound_classification`, `screenshot`. |

Every later minor adds a row here.

## Reader algorithm

Follows the spec's future desktop-reader contract. Locate the configured Hippo root inside the provider-synced folder, watch it, and rescan periodically; never rely on filesystem event order.

1. For each directory `captures/YYYY/MM/DD/<capture-id>/`, skip it unless `complete.json` exists.
2. Decode `complete.json`. If `schema_version` is not 1, reject it as unsupported (report; do not retry). Otherwise accept any `schema_minor` (missing is 0) and ignore unknown keys.
3. Check every manifest `relative_path` is safe: relative, not empty, no `.` or `..` segment, no backslash, no NUL, and either `metadata.json` or under `content/`. Any unsafe path means corrupt. The manifest must include `metadata.json`.
4. For each manifest entry, the file must exist and match `byte_count` and `sha256`. A missing or mismatched file means the package is incomplete or still syncing: leave it pending and retry on later scans. Only after repeated failures over a reasonable period surface it as corrupt.
5. Decode `metadata.json` (major 1, any minor, unknown keys and unknown observation keys ignored). `metadata.capture_id` must equal the marker's and the directory name, and every attachment `relative_path` must be in the manifest; otherwise corrupt.
6. Index by `capture_id` plus package digest. The same pair already indexed means nothing to do for the package; the same ID with a new digest replaces the entry. This makes rescans idempotent.
7. List `comments/*.json` (ignore any other file there) and index the package's comments by the set of comment ids: a comment id already indexed means nothing to do, a new one is added. A comment whose audio is missing or mismatched is pending.

Keep your search/SQLite/vector indexes outside the synced folder; they must be rebuildable from packages alone. Store derived (AI) output separately, keyed by `capture_id`; see `enrichment-format.md` for the format the phone and a server use for it. Never modify a package.

## Dropbox and online-only placeholders

Sync clients (Dropbox online-only, OneDrive Files On-Demand, iCloud) may show a file in a directory listing without its bytes being on disk. `complete.json` or an attachment can therefore appear present while its content is not downloaded, and files of one package can arrive in any order. Do not treat directory presence as availability:

- Read the bytes (or request materialization where the provider supports it) and verify size and hash before trusting a file. Reading a placeholder may block, fail, or trigger a download.
- Do not assume the marker arrives last, or that other files are local when it is.
- Treat read failures and size/hash mismatches as pending first (step 4), not corrupt.

A reader may see `captures/` packages written by several phones sharing one folder, and should expect packages to be deleted at any time (from the phone, from the Dropbox folder, or by another phone).

The phone also keeps a content-free event log in `logs/` (locally, and per install on the destination); it is not part of any package. See `docs/log-format.md`.
