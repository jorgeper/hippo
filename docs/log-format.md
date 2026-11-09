# Hippo event log format

The phone keeps a content-free log of what Hippo did: captures saved and deleted, enrichment work, uploads,
syncs. It is meant for a desktop reader (you, a script) debugging why something did or did not happen.
Version of this format: `v` = 1.

## Layout

On the phone, in the App Group store root, beside `hippo.sqlite`, `captures/` and `enrichments/` (never inside them):

```
logs/
  2026-11-08.jsonl        UTC day, first segment
  2026-11-08.1.jsonl      segment 1 of the same day (created by Clear log)
  2026-11-08.2.jsonl
  upload-state.json       bookkeeping for log uploads (not a log file)
```

- One JSON object per line (JSON Lines), UTF-8, `\n` terminated. Files are named by the **UTC** day of the event.
- **Segments:** after the user clears the log, new events go to the next segment of the same day, so a clear
  never overwrites that day's already-uploaded file with a near-empty one. Read all segments of a day in
  numeric order (`.jsonl`, `.1.jsonl`, `.2.jsonl`, ...) as that day's log.
- On the destination: `logs/<install-id>/<same file name>`. `<install-id>` is a random lowercase UUID created
  once per install. **The phone never deletes remote copies.** Local files older than 30 days are pruned;
  remote files stay until you remove them.
- Size cap: 2,097,152 bytes per segment file. When a segment is full, one `log.truncated` event is written and
  further events for that segment are dropped.
- Two processes append (the app and the share extension), each line in a single `write` under an advisory
  `flock`. If the lock cannot be taken within about 100 ms, the event is dropped rather than delay a capture.
  A torn or unparseable line should be skipped by readers.

## Fields

Keys are snake_case; absent values are omitted, never `null`.

| Key | Type | Meaning |
|---|---|---|
| `t` | string | Event time, RFC 3339 UTC with milliseconds, e.g. `2026-11-08T17:00:00.123Z` |
| `v` | int | Log format version, always `1` |
| `proc` | string | `app` or `share` (background tasks run in the app process; `bg.task` brackets them) |
| `event` | string | Dotted event name (below) |
| `capture_id` | string | The capture the event is about; absent for global events |
| `kind` | string | Enrichment facet kind, or for `settings.changed` the name of the switch |
| `outcome` | string | `ok`, `empty`, `not_applicable`, `deferred`, `retrying`, `failed`, `skipped`, `cancelled` |
| `code` | string | Reason code, matching `^[a-z0-9_:.-]{1,64}$` (anything else is stored as `unrecognized`) |
| `attempt` | int | Attempt number |
| `count` | int | A count (items processed, queued, uploaded) |
| `ms` | int | Duration in milliseconds |
| `bytes` | int | A byte total (`trim.run`: bytes freed) |
| `trigger` | string | What started it: capture method (`note`, `recording`, `share_extension`, `import`), or a sync trigger (`launch` after launch recovery, `activation`, `bg`, `manual`, `connectivity` when the network came back, `retry` after a failed upload's wait, `after_save`, `enrichment` after enrichment ran, to upload its results) |
| `dest` | string | The destination's provider kind (`filesystem`, `dropbox`); never an account or destination ID |
| `on` | bool | New state of a switch, for `settings.changed`; for `gold.pull`, true when the server reset the change cursor and the pull listed everything again |
| `phase` | string | `start`, `end` or `expired`, for `sync.pass`, `enrich.pass`, `bg.task` |
| `retry_at` | string | RFC 3339 time a deferred task will next be tried |

## Events

Per capture (carry `capture_id`):

| Event | Meaning |
|---|---|
| `capture.saved` | A capture was committed to disk (`proc` says app or extension; `trigger` is the capture method) |
| `capture.deleted` | The capture was deleted from this phone (`trigger` is `remote` when it was deleted in the destination and applied here) |
| `enrich.queued` | A facet task was queued (`kind`) |
| `enrich.started` | A task began (`kind`, `attempt`) |
| `enrich.finished` | A task finished (`kind`, `outcome`, `count`, `ms`) |
| `enrich.deferred` | A task is waiting (`kind`, `code`, `retry_at`) |
| `enrich.retrying` | A task failed and will retry (`kind`, `code`, `attempt`) |
| `enrich.failed` | A task failed for good (`kind`, `code`, `attempt`) |
| `silver.uploaded`, `silver.upload_failed` | Silver enrichment uploaded or failed (`dest`, `code`) |
| `package.uploaded`, `package.upload_failed` | Capture package uploaded or failed (`dest`, `code`) |
| `remote.delete` | "Delete everywhere": no `outcome` when queued, `ok` once removed in the destination, `failed` with `code` (`dest`) |
| `remote.changed` | A file of the capture is missing or different in the destination, so it is marked changed (`dest`); `code` `unverified` when the capture's package or marker is gone there but its upload isn't verified, so it was not removed |
| `attachment.restored` | A trimmed file was downloaded back (`dest`); `ok`, or `failed` with `code` |
| `gold.applied`, `gold.removed`, `gold.skipped` | Server enrichment applied, removed, or skipped (`code`) |

Global (no `capture_id`):

| Event | Meaning |
|---|---|
| `capture.save_failed` | A save failed, so there is no capture to attach it to (`code` names the failure) |
| `enrich.scheduled` | Tasks were queued for a kind (`kind`, `count`) |
| `enrich.pass` | An enrichment pass started or ended (`phase`, `count`, `code` = why it stopped) |
| `sync.pass` | A sync pass started or ended (`phase`, `trigger`, `count`, `code`) |
| `bg.task` | A background task started, expired or ended (`phase`) |
| `gold.pull` | A gold pull ended (`count` applied, `code`, `on` if the change cursor was reset) |
| `remote.review` | Deletes found in the destination were not applied and wait for review (`count` captures, `dest`); `code` is `threshold` (too many at once), `root_missing` (the `captures/` folder is gone) or `cursor_reset` (the change cursor was reset and a full listing missed them) |
| `trim.run` | Save space ended (`count` files trimmed, `bytes` freed, `code` = the last skip or stop reason, if any) |
| `app.launch` | The app launched (`code` = version-build) |
| `settings.changed` | A switch changed (`kind`, `on`); never values such as folder names |
| `log.truncated` | A segment reached its size cap; later events in it were dropped |
| `log.cleared` | The user cleared the log on the phone |

## No content, ever

The log holds no capture content: no text, notes, transcripts, OCR, titles, URLs, hostnames, file names,
paths, place names, coordinates, or account and destination IDs. Every free-form field (`code`, `kind`,
`trigger`, `dest`, `phase`) is checked against `^[a-z0-9_:.-]{1,64}$` and replaced by `unrecognized` otherwise.
`capture_id` is the one identifier, and it is already the capture's public ID in its package.
