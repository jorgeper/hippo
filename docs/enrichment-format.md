# Hippo enrichment format, version 1.1

For developers writing or reading enrichment: the desktop reader, and the server that produces gold. Machine-readable definition: `schema/enrichment-v1.schema.json`. Worked examples: `fixtures/packages/enrichments/` in the Hippo repository. The reference reader and writer are `EnrichmentDocument` and `EnrichmentJSON` in `HippoKit/Sources/CaptureCore/Enrichment` in the Hippo repository. The signals added in 1.1 are listed in one table in `context-signals.md`. In a synced Hippo folder these documents are in `format/` and the schemas in `format/schema/`. Read `package-format.md` first (it also defines the versioning rules): this format follows its conventions and sits beside the capture packages it describes.

Enrichment is derived data (title of a linked page, text recognized in an image, a transcript, a summary). It never changes a capture package's manifested files. A package is the source of truth and stays immutable.

## Layers and layout

There are two layers. Each has exactly one writer:

| Layer | Name | Writer |
|---|---|---|
| `device` | silver | the phone |
| `server` | gold | a server |

```text
enrichments/<layer>/YYYY/MM/DD/<capture-id>/
  enrichment.json
  assets/<sha256>.<ext>        (thumbnails etc.; absent when there are none)
```

- `YYYY/MM/DD/<capture-id>` is exactly the capture package's directory (`captures/YYYY/MM/DD/<capture-id>`) with `captures` replaced by `enrichments/<layer>`. A reader finds both from the same key. Do not recompute the date.
- `<capture-id>` is a lowercase UUID. `<sha256>` is 64 lowercase hex characters of the asset bytes; `<ext>` is 1-10 chars of `[a-z0-9]`.
- Asset names are content addressed, so replacing `enrichment.json` never breaks a reference partway through a sync, and an orphaned asset is harmless.
- One writer per layer: the phone writes only `enrichments/device/` and only reads `enrichments/server/`. A server writes only `enrichments/server/`. Nobody writes the other layer.

## Conventions

Same as `package-format.md`:

- Timestamps are RFC 3339 UTC with milliseconds and a `Z` suffix. SHA-256 values are 64 lowercase hex characters. Sizes are bytes.
- Omission rule: an unavailable optional field is omitted. It is never `null` and never an empty string. Treat a missing key as unknown.
- Open sets: facet kinds, `status` and `provenance` may take values you do not know. Accept and preserve them.
- Unknown additional keys, anywhere, must be ignored. Unknown facet kinds are kept and ignored.
- `schema_version` is an integer, the major version. This document is major 1. Reject any other value with an "unsupported version" error. `schema_minor` is an optional integer, missing means 0; accept any minor and ignore what you do not know (see Versioning in `package-format.md`).

## Write order

1. Write every asset the new `enrichment.json` references.
2. Write `enrichment.json` last, replacing the previous one atomically.

`enrichment.json` plays the role `complete.json` plays for packages: when it is present, every asset it references has been written. A reader trusts an asset only if its size and SHA-256 match the reference, and treats a missing or mismatched asset as still syncing. Because the file is replaced in place, a reader may see an older version; that is fine. Never delete assets as part of an update.

## `enrichment.json`

All fields required except `schema_minor`:

| Field | Type | Notes |
|---|---|---|
| `schema_version` | integer | `1` |
| `schema_minor` | integer | Optional. Format minor of the writer (1.1 writes `1`). Missing means 0. |
| `capture_id` | UUID string | Lowercase. Matches the directory name. |
| `layer` | string | `device` or `server`. Matches the directory. |
| `package_digest` | hex string | SHA-256 of the exact bytes of the capture's `complete.json` that this was derived from. See below. |
| `producer` | object | `{name, version, build}` strings of the writer. |
| `generated_at` | RFC 3339 UTC | When this document was written. |
| `facets` | object | Keyed by facet kind. May be empty. |

`package_digest` records which version of the bronze package the derivation saw. Packages are immutable, so for a given capture it should equal the digest of the package you hold. If it does not, the writer has a bug (it derived from something else); the phone still shows the data and records a diagnostics code, so do not rely on a mismatch to hide anything.

### Facet

Each entry of `facets` is:

| Field | Required | Type | Notes |
|---|---|---|---|
| `version` | yes | integer | Version of that facet's payload shape. Known kinds are version 1. |
| `status` | yes | string | `ok`, `empty` (ran, found nothing) or `failed`. Open set. |
| `generated_at` | yes | RFC 3339 UTC | |
| `provenance` | yes | string | How it was made, e.g. `link_fetch`, `heuristic`, `vision`. Open set. |
| `data` | no | any JSON | Payload for the kind. Usually omitted for `empty` and `failed`. |

### Asset reference

Facet data refers to binary files with `{relative_path, byte_count, sha256, mime_type?}`. `relative_path` is relative to the enrichment directory and must be exactly `assets/<64 lowercase hex>.<ext>` (ext lowercase `[a-z0-9]`, 1-10 chars). Anything else is unsafe and the whole document is rejected. A reader collects references by scanning every JSON object in every facet's `data`: an object with a string `relative_path` and `sha256` and an integer `byte_count` is an asset reference, wherever it is nested. That is true for unknown kinds too, so a new kind can carry assets with no reader change.

## Known facet kinds

Every payload is an object with an `items` array (or the fields shown). Optional fields are omitted when unknown.

### `link_preview`: `{items: [...]}`, keyed by `url`

| Field | Required | Notes |
|---|---|---|
| `url` | yes | The captured URL this describes. The item key. |
| `title` | no | |
| `site_name` | no | |
| `channel` | no | Author or channel, e.g. a video's channel. |
| `description` | no | Short summary of the page. |
| `canonical_url` | no | |
| `thumbnail` | no | Asset reference to a JPEG, longest side at most 640 px. |

### `place`: `{items: [...]}`, keyed by `target`

`target` (required) is `capture` for the capture location or an attachment ID for a photo's embedded location. Optional: `sub_locality`, `locality`, `region`, `country`, and `nearby` `{name, distance_meters}` (a named point of interest close to the location).

### `text_recognition`: `{items: [...]}`, keyed by `attachment_id`

Each item: `attachment_id`, `text` (recognized text, reading order), `languages` (array of BCP 47 tags, may be empty).

### `transcript`: `{items: [...]}`, keyed by `attachment_id`

`attachment_id` names an attachment or, for a comment's audio, the `comment_id` of a `comments/` file.

Each item: `attachment_id`, `text`, `locale` (e.g. `en_US`), `segments` (array of `{start, end, text}`; seconds from the start of the audio; may be empty).

### `data_detection`: `{items: [...]}`

Each item: `type` (`date`, `phone`, `address` or `link`), `text` (as found), `source` (where: e.g. `user_note`, `shared_text`, or an attachment ID), and optional `value` (normalized: an RFC 3339 date, an E.164-style number, a URL) and `components` (string map, e.g. address parts).

### `source_app_guess`: `{app, reason}`

A single item. `app` is a display name. `reason` says why (e.g. `uti:public.url`). A guess, never shown as fact.

### `summary` (gold only, by convention): `{text}`

### `tags` (gold only, by convention): `{values: [string]}`

Any other kind is allowed, with any `data`.

## Facet kinds added in format 1.1

Six kinds, each facet `version` 1. A reader that does not know them keeps and ignores them. Timestamps in payloads are RFC 3339 UTC with milliseconds and `Z`. "On" or "off" below is the default of the phone's Settings switch.

When the phone decides a kind does not apply to a capture, or has to wait, it records that in its own local job table and writes no facet. So for a kind below, "no facet" can mean "not applicable", "not run yet", "switched off" or "unknown". The `status` `empty` means the source was queried and held nothing. See `context-signals.md` for what absence means per signal.

### `motion_activity` (provenance `core_motion`), off by default

What Core Motion recorded for 10 minutes before to 10 minutes after `captured_at`.

| Field | Type / units | Notes |
|---|---|---|
| `window_start`, `window_end` | RFC 3339 UTC | `captured_at` minus 10 min, and plus 10 min. |
| `at_capture` | object | The last sample that started at or before `captured_at`. Omitted when there is none. |
| `segments` | array | Every sample in the window in time order. Consecutive samples with identical flags and confidence are merged. At most 60: the first 60 are kept. |

Sample: `{started_at, activities, confidence}`.

| Field | Notes |
|---|---|
| `started_at` | RFC 3339 UTC. |
| `activities` | Array of the flags Core Motion raised: `stationary`, `walking`, `running`, `cycling`, `automotive`, `unknown`. Several can be true at once (for example `automotive` and `stationary` at a red light). A sample with no flag raised is `["unknown"]`. Never empty. |
| `confidence` | `low`, `medium` or `high`. |

- Statuses: `ok`; `empty` when the history was queried and held no samples for the window.
- No facet is written when the history has expired (Core Motion keeps about seven days), when Core Motion is unavailable on the device, or while Motion & Fitness permission is missing (the phone retries a day later). Absence means unknown.
- The phone runs it only after the window has closed, 10 minutes after the capture.
- Needs Motion & Fitness permission, asked once in the main app. Never asked from the Share Extension, so a share-sheet capture gets motion only if Hippo is opened within seven days.

### `weather` (provenance `open_meteo`), off by default

The weather for the hour containing `captured_at`, at the capture's location. Only for captures with a `capture_location`.

| Field | Type / units | Notes |
|---|---|---|
| `observed_hour` | RFC 3339 UTC | The hour, floored to the hour in UTC. |
| `temperature_celsius` | number, degrees Celsius | |
| `apparent_temperature_celsius` | number, degrees Celsius | |
| `relative_humidity_percent` | number, percent | As the source reports it, normally 0 to 100. |
| `precipitation_millimeters` | number, millimeters | Over the hour. |
| `cloud_cover_percent` | number, percent | |
| `wind_speed_meters_per_second` | number, m/s | Wind at 10 m. |
| `weather_code` | integer | The WMO code Open-Meteo returned, 0 to 99. |
| `condition` | string | A coarse reading of `weather_code`; an open set. Table below. |
| `is_day` | boolean | Open-Meteo's daylight flag for that hour. |
| `source` | string | `open-meteo.com` |
| `requested_latitude`, `requested_longitude` | number, degrees | The rounded coordinates that were sent. |

Every field except `observed_hour`, `source` and the two requested coordinates is omitted when the source had no value for it. A weather code that is not a whole number from 0 to 99, and any non-finite number, is dropped. Other numbers are recorded as the source reports them; the phone does not range-check them. `is_day` is recorded only when the source says 0 or 1.

- Statuses: `ok`; `empty` when Open-Meteo had no data for that hour.
- No facet is written when the capture has no location.
- Privacy: the request carries the coordinates rounded to 2 decimals (about 1 km) and the hour. No key or account is used. The forecast API is used for captures within 60 days of the request, the archive API for older ones. If the forecast API refuses with a permanent 4xx, the phone tries the archive API once.

`condition` for each WMO code (ranges are inclusive):

| WMO `weather_code` | `condition` |
|---|---|
| 0, 1 | `clear` |
| 2 | `partly_cloudy` |
| 3 | `cloudy` |
| 45, 48 | `fog` |
| 51 to 55 | `drizzle` |
| 56, 57, 66, 67 | `freezing_rain` |
| 61 to 65 | `rain` |
| 71 to 77, 85, 86 | `snow` |
| 80 to 82 | `showers` |
| 95 to 99 | `thunderstorm` |

A code in none of these rows (for example 4 to 44, 46, 47, 49 to 50, 58 to 60, 68 to 70, 78, 79, 83, 84, 87 to 94) has no `condition`, only the number.

Weather data by Open-Meteo.com (CC BY 4.0). If you republish this data, keep that attribution.

### `barcodes` (provenance `vision`), on by default

Barcodes and QR codes found in image attachments. `{items: [...]}`, keyed by `attachment_id`; one attachment can have several items.

| Field | Required | Notes |
|---|---|---|
| `attachment_id` | yes | The image attachment. |
| `symbology` | yes | Lowercase; an open set (`qr`, `ean13`, `code128`, ...). |
| `payload` | yes | The decoded string, at most 2,048 characters. |
| `url` | no | The payload, when it is a single `http` or `https` URL with a host and no whitespace. Never present when the payload was cut at 2,048 characters. |

- At most 20 items per attachment.
- A URL is recorded, never fetched, and is not added to the capture's `urls`.
- Statuses: `ok`; `empty` when no image held a barcode. No facet when the capture has no image.

### `language` (provenance `natural_language`), on by default

The language of the capture's own text.

| Field | Notes |
|---|---|
| `source` | `user_note`, `shared_text` or `note_body` (the body of a typed note). |
| `language` | BCP 47 tag, for example `en`. |
| `confidence` | number, 0 to 1. |

- Text shorter than 20 characters (after trimming) is skipped. If nothing is long enough, no facet is written (the phone records the code `text_too_short` locally). Absence means unknown.
- A language that could not be determined is dropped. If no text yields a language, the status is `empty`.
- Recognized text and transcripts carry their own language fields and are not repeated here.

### `sound_classification` (provenance `sound_analysis`), on by default

What Apple's built-in sound classifier (version 1) heard in audio attachments and audio comments. `{items: [...]}`.

| Field | Notes |
|---|---|
| `attachment_id` | The audio attachment, or the `comment_id` for a comment's audio (as in `transcript`). |
| `labels` | Array of `{label, confidence}`: the classifier's own label identifiers (for example `speech`, `music`, `traffic_noise`), `confidence` the mean over the file, 0 to 1. Only labels at 0.3 or above, at most 8, strongest first. |

- A file with no label at 0.3 or above has no item. If no file has one, the status is `empty`.
- When Save space has trimmed an audio attachment, the earlier labels for it are carried forward from the current facet of the same version.

### `screenshot` (provenance `heuristic`), on by default

A guess, never a fact. `{items: [{attachment_id, reason}]}` for image attachments that look like a screenshot.

| `reason` | Meaning |
|---|---|
| `exif_user_comment` | The image's EXIF user comment is "Screenshot", which iOS writes. |
| `screen_size_match` | The pixel size equals this phone's screen (the size the app last remembered) in either orientation, and the camera make and model are both missing or blank. |

No match: the status is `empty`.

## Override rule

When the same item is available from several layers, the reader resolves it **per item, and field by field within an item**. A gold item's field wins only when the gold facet's `status` is `ok` and the field is present. Otherwise the silver field shows, then bronze. A gold facet that is `empty` or `failed` never hides silver.

Example: gold supplies only a better `title` for one URL. Silver's `thumbnail` and `channel` for that URL still show, because gold did not supply them. Items are matched by key: `url` for `link_preview`, `attachment_id` for `text_recognition` and `transcript`, `target` for `place`. A gold item with no silver counterpart simply appears; gold may cover part of a facet. Facets with a single item are matched by kind.

## Limits the phone enforces on gold

The phone skips (and records a diagnostics code for) gold that exceeds these, so stay under them:

- `enrichment.json` at most 1,048,576 bytes (1 MiB).
- Each asset at most 5,242,880 bytes (5 MiB).
- Each document references at most 32 distinct assets, declaring at most 52,428,800 bytes (50 MiB) in total. A document over either is skipped (`gold_too_large`) before any of its assets is downloaded.
- A pull handles about 200 changed files per pass, and each asset it downloads counts as one. The limit is soft: the pull stops fetching new pages once it reaches 200, and the rest follow on the next pass.
- Only assets referenced from `enrichment.json` are fetched, and only after their size and hash are checked.
- Gold for a capture the phone does not hold is ignored.
