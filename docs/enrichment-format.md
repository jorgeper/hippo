# Hippo enrichment format, version 1

For developers writing or reading enrichment: the desktop reader, and the server that produces gold. Machine-readable definition: `schema/enrichment-v1.schema.json`. Worked examples: `fixtures/packages/enrichments/`. The reference reader and writer are `EnrichmentDocument` and `EnrichmentJSON` in `HippoKit/Sources/CaptureCore/Enrichment`. Read `package-format.md` first: this format follows its conventions and sits beside the capture packages it describes.

Enrichment is derived data (title of a linked page, text recognized in an image, a transcript, a summary). It never changes a capture package. A package is the source of truth and stays immutable.

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
- `schema_version` is an integer. This document is version 1. Reject any other value with an "unsupported version" error.

## Write order

1. Write every asset the new `enrichment.json` references.
2. Write `enrichment.json` last, replacing the previous one atomically.

`enrichment.json` plays the role `complete.json` plays for packages: when it is present, every asset it references has been written. A reader trusts an asset only if its size and SHA-256 match the reference, and treats a missing or mismatched asset as still syncing. Because the file is replaced in place, a reader may see an older version; that is fine. Never delete assets as part of an update.

## `enrichment.json`

All fields required:

| Field | Type | Notes |
|---|---|---|
| `schema_version` | integer | `1` |
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

Each item: `attachment_id`, `text`, `locale` (e.g. `en_US`), `segments` (array of `{start, end, text}`; seconds from the start of the audio; may be empty).

### `data_detection`: `{items: [...]}`

Each item: `type` (`date`, `phone`, `address` or `link`), `text` (as found), `source` (where: e.g. `user_note`, `shared_text`, or an attachment ID), and optional `value` (normalized: an RFC 3339 date, an E.164-style number, a URL) and `components` (string map, e.g. address parts).

### `source_app_guess`: `{app, reason}`

A single item. `app` is a display name. `reason` says why (e.g. `uti:public.url`). A guess, never shown as fact.

### `summary` (gold only, by convention): `{text}`

### `tags` (gold only, by convention): `{values: [string]}`

Any other kind is allowed, with any `data`.

## Override rule

When the same item is available from several layers, the reader resolves it **per item, and field by field within an item**. A gold item's field wins only when the gold facet's `status` is `ok` and the field is present. Otherwise the silver field shows, then bronze. A gold facet that is `empty` or `failed` never hides silver.

Example: gold supplies only a better `title` for one URL. Silver's `thumbnail` and `channel` for that URL still show, because gold did not supply them. Items are matched by key: `url` for `link_preview`, `attachment_id` for `text_recognition` and `transcript`, `target` for `place`. A gold item with no silver counterpart simply appears; gold may cover part of a facet. Facets with a single item are matched by kind.

## Limits the phone enforces on gold

The phone skips (and records a diagnostics code for) gold that exceeds these, so stay under them:

- `enrichment.json` at most 1,048,576 bytes (1 MiB).
- Each asset at most 5,242,880 bytes (5 MiB).
- A pull applies at most 200 changed files per pass (soft: it stops fetching new pages once it reaches 200; the rest follow on the next pass).
- Only assets referenced from `enrichment.json` are fetched, and only after their size and hash are checked.
- Gold for a capture the phone does not hold is ignored.
