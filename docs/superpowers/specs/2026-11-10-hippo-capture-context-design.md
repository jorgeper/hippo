# Hippo: capture context signals, a versioned format, and a folder that describes itself — design

Date: 2026-11-10. Follows the comments phase (`2026-11-10-hippo-comments-design.md`). Implements the roadmap item "Decided: capture context" (`docs/roadmap.md`). Decisions Jorge made in conversation are stated plainly; every call marked **(my call)** is mine.

## 1. Intent

Jorge's words: "I want to capture all this stuff and collect as much data as I can and enrich it so that eventually I can ask recall questions such as, tell me all the pictures that I shared last week, and now show me the ones that I shared last week while I was on a car. Or maybe I think I was actually working out while I did this."

So this phase is about **recall by circumstance**. The phone's job is to record, at and around each capture, plain facts about what was going on, in a form an AI agent can read with no help. The phone is "more a capture app than a consumption app" for now; Jorge will consume the data mostly "from my AI agents through a different path": agents pointed at the synced folder, possibly helped later by an offline indexer.

Three parts:

1. **Context signals.** Each capture records more facts: audio route, device state, network, the previous capture, altitude/speed/course, motion activity, weather, and what on-device detectors find in the content.
2. **A versioned, documented format.** A two-part version (major.minor), a changelog, and a registry of every signal with its key, shape and units. Adding data must never break a reader.
3. **A self-describing folder.** The phone uploads the format documents and JSON Schemas into the destination, so an agent or a future desktop app pointed at the folder learns how to parse it from the folder alone.

## 2. Goals, non-goals, anti-goals

Goals:
- Every signal is a **fact**, with a stable documented key, a typed value with units, and provenance. "In a car" is never stored by the phone; "motion: automotive, high confidence" and "audio route: CarPlay" are.
- An agent can tell "recorded and negative" from "not recorded": it can see which signal groups were switched on for a capture (§4.6) and which format minor wrote the file (§7).
- Collecting context never delays, blocks or fails a save, in the app or in the Share Extension. A signal that cannot be read is omitted.
- Every package already in Dropbox stays valid, unchanged, and readable by the same rules.
- Jorge can see on the phone what was recorded for a capture.
- A reader written today against these documents keeps working when later minors add signals.

Non-goals:
- Inferring an activity on the phone ("you were driving"), or asking Jorge to confirm one. That is for the agents or the desktop, and a confirmed conclusion goes in the existing server enrichment layer.
- Searching or filtering by context on the phone. The local index is not changed. (It can be rebuilt from the files later; the facts cannot be re-captured later, which is why capture comes first.)
- Any index or summary file in the destination. The uploader only adds files (plus replaceable enrichment); a shared index would need rewriting on every capture. The offline indexer is a separate project.
- Health data (heart rate, workouts, sleep): dropped on the roadmap. Consequence: a gym session is not detectable; Core Motion knows walking, running, cycling and driving only.
- Step counts and pace (CMPedometer), calendar events, Safari preprocessing, Photos library links, Wi-Fi name: not in this phase.
- A consumption UI on the phone (Jorge's later idea: ask in text, get back a visual, browsable set of captures). Recorded on the roadmap only.

Anti-goals (a failure even if it works):
- A save that waits on a sensor, a permission prompt or the network.
- A permission prompt from the Share Extension.
- A file written by this build that an older reader following `docs/package-format.md` rejects.
- Signal values in the logs. Logs keep carrying fixed codes only.
- A signal whose meaning or units an agent has to guess from Swift source.

## 3. Where each signal lives

A package is frozen once `complete.json` exists. So:

| Known when | Goes in | Written by |
|---|---|---|
| At the moment of capture | `metadata.json`: `metadata_observations` entries, and new optional fields of `capture_location` | app and Share Extension |
| Later, looked up or derived from content | `enrichments/device/…/enrichment.json`: new facet kinds | main app's enrichment runner |

An agent reads two files per capture. `docs/context-signals.md` (§8) says for every signal which file and key.

## 4. Capture-time signals (in `metadata.json`)

All of §4.1–§4.4 sit behind one Settings switch, "Save device context with captures", **on by default (my call:** nothing here needs a permission or leaves the phone, and Jorge wants as much as possible). Location extras (§4.5) ride on the existing "Save location with captures" switch.

Each is one `metadata_observations` entry `{key, value, provenance}`. `value` is an object; any field that cannot be read is omitted; if no field can be read the whole entry is omitted. Strings are capped at 100 characters.

### 4.1 `context.audio_route` (provenance `av_audio_session`)

From `AVAudioSession.sharedInstance().currentRoute`, read without activating or reconfiguring the session.

```json
{ "outputs": [ { "port_type": "car_audio", "port_name": "CarPlay" } ],
  "inputs":  [ { "port_type": "built_in_mic", "port_name": "iPhone Microphone" } ] }
```

`port_type` is an open set. Known values, mapped from `AVAudioSession.Port`: `built_in_speaker`, `built_in_receiver`, `built_in_mic`, `headphones`, `headset_mic`, `bluetooth_a2dp`, `bluetooth_hfp`, `bluetooth_le`, `car_audio`, `airplay`, `hdmi`, `usb_audio`, `line_out`, `line_in`; anything else is the raw `AVAudioSession.Port` string. `port_name` is the system's name for the port (for Bluetooth, the accessory's name, e.g. "Jorge's AirPods Pro"). Either array may be empty and is then omitted. At most 8 ports each.

### 4.2 `context.device` (provenance `device_state`)

| Field | Type / units | Notes |
|---|---|---|
| `battery_level` | number 0–1 | Omitted when the system reports unknown. |
| `battery_state` | string | `unplugged`, `charging`, `full`. |
| `low_power_mode` | boolean | |
| `thermal_state` | string | `nominal`, `fair`, `serious`, `critical`. |
| `interface_style` | string | `light`, `dark`. |
| `orientation` | string | `portrait`, `portrait_upside_down`, `landscape_left`, `landscape_right`, `face_up`, `face_down`. Omitted when unknown (expected in the Share Extension). |
| `locale` | string | e.g. `en_US`. |
| `uses_24_hour_clock` | boolean | |

### 4.3 `context.network` (provenance `nw_path`)

`{ "interface": "wifi", "expensive": false, "constrained": false }`. `interface` is `wifi`, `cellular`, `wired`, `other` or `none` (no usable path). Taken from the most recent `NWPath` the process has received; if none has been delivered yet the entry is omitted. Never waits.

Today's `NetworkStatus` (`App/Shared/NetworkStatus.swift`) only exposes `isOnline` and one merged expensive flag, and starts optimistic. It grows: the interface type, separate `expensive` and `constrained`, and a "has received a path" flag. The Share Extension starts its monitor when the sheet opens, so a path has normally arrived well before Save **(my call)**.

### 4.4 `context.burst` (provenance `last_saved`)

`{ "previous_capture_id": "<uuid>", "seconds_since_previous": 41.2 }`: the capture **saved most recently before this one on this phone**, whatever its age, and the gap between the two `captured_at` values in seconds (one decimal). Omitted when there is none, or when the gap is negative (two overlapping captures).

The local index cannot answer this from the Share Extension: it only learns about a shared capture when the main app next reconciles. So every capture path, in both processes, records the ID and `captured_at` of the capture it just saved in the App Group defaults after a successful save, and reads the previous value before saving **(my call)**. Provenance is therefore `last_saved`, not `capture_index`. A reader can also derive bursts from `captured_at` across packages; this entry saves it the scan.

### 4.5 Location extras (additive fields of `capture_location`)

All optional, omitted when Core Location reports the value invalid (negative accuracy or negative value):

| Field | Units |
|---|---|
| `altitude_meters` | meters above sea level, negative below |
| `vertical_accuracy_meters` | meters |
| `speed_meters_per_second` | m/s |
| `speed_accuracy_meters_per_second` | m/s |
| `course_degrees` | degrees clockwise from true north, 0–360 |
| `course_accuracy_degrees` | degrees |

A one-shot fix often has no speed or course; that is expected and they are then absent.

### 4.6 `context.enabled` (provenance `settings`)

`{ "groups": ["device_context", "location"] }`: which capture-time groups were switched on when this capture was saved. Known values: `device_context` (§4.1–4.4), `location` (the location switch on **and** permission granted). Written on every capture by a build that knows this design, even when empty. This is what lets an agent treat a missing `context.audio_route` as "unknown that time" rather than "not collecting" **(my call)**.

### 4.7 How it is collected

- Platform reads (AVAudioSession, UIDevice, ProcessInfo, trait collection, Locale) live in `App/Shared` so both targets use them. The mapping from a plain snapshot value to observations is pure code in HippoKit with unit tests.
- A snapshot is taken once, **when the capture begins**: the instant recorded as `captured_at` (the share sheet opening, the recording starting, the camera or note editor opening, a file being picked). That is the moment the location fix, the motion window and the weather hour are all anchored on, and a recording or an open sheet can last minutes **(my call)**. After-the-fact comments do not record context.
- Every read is synchronous and cheap, or already cached. No collector may throw into the save path; a failure is an omitted entry.
- The caps in this section (100-character strings, 8 ports per direction) are new: `DraftSanitizer` today only drops non-finite numbers and invalid locations. The mapping code applies the caps; `DraftSanitizer` additionally drops a location extra that is non-finite or out of range (course outside 0–360, negative speed or accuracy) while keeping the location.
- `CaptureLocation` and `LocationFix` gain the six optional fields of §4.5.

## 5. Looked-up signals (device enrichment facets)

New facet kinds, each an `Enricher` in the existing runner, each with its own switch following the existing per-kind enrichment switches. Facet `version` 1 each. Two things in that mechanism change: `AppSettings.isEnrichmentEnabled` treats an unset key as on, so `motion_activity` and `weather` need a per-kind default of off; and the fixed kind list in `EnrichmentScheduling` gains the six kinds. Switching a kind on backfills existing captures, as it does today.

### 5.1 `motion_activity` (provenance `core_motion`) — off until switched on

Queries `CMMotionActivityManager` history for a window of 10 minutes before to 10 minutes after `captured_at`.

```json
{ "window_start": "…Z", "window_end": "…Z",
  "at_capture": { "activities": ["automotive"], "confidence": "high", "started_at": "…Z" },
  "segments": [ { "started_at": "…Z", "activities": ["walking"], "confidence": "medium" },
                { "started_at": "…Z", "activities": ["automotive"], "confidence": "high" } ] }
```

- `activities` is the set of flags Core Motion raised for that sample: `stationary`, `walking`, `running`, `cycling`, `automotive`, `unknown`. Several can be true at once (e.g. `automotive` and `stationary` at a red light); record them all.
- `confidence` is `low`, `medium` or `high`.
- `at_capture` is the last sample that started at or before `captured_at`; omitted when there is none. `segments` is every sample in the window in time order, consecutive samples with identical flags and confidence merged, at most 60.
- Not run until 10 minutes after the capture (deferred, no attempt counted), so the window is complete.
- Core Motion keeps about seven days. A capture older than that when the enricher first reaches it is recorded locally as not applicable and **no facet is written**, so a reader sees absence, meaning unknown **(my call)**. `empty` is written only when the history was queried and held no samples for the window.
- The switch is off by default. Turning it on asks for Motion & Fitness access once, in the main app. Denied or restricted: the switch stays off and its footer points to iOS Settings, like location today. While off or unauthorized the kind is not scheduled; nothing is written.
- The app's Info.plist (generated from `project.yml`) gains `NSMotionUsageDescription`: "Hippo records whether you were still, walking, running, cycling or in a vehicle around the time of each capture."
- Known limit: a capture made from the share sheet is enriched the next time the main app runs. If that is more than seven days later, its motion is lost.

### 5.2 `weather` (provenance `open_meteo`) — off until switched on

For captures with a `capture_location`. One HTTPS GET to Open-Meteo for the hour containing `captured_at`, at the capture's coordinates **rounded to two decimals (about 1 km) (my call:** weather needs no more, and less precise coordinates leave the phone).

```json
{ "observed_hour": "2026-11-10T22:00:00.000Z",
  "temperature_celsius": 14.2, "apparent_temperature_celsius": 12.9,
  "relative_humidity_percent": 81, "precipitation_millimeters": 0.4,
  "cloud_cover_percent": 100, "wind_speed_meters_per_second": 3.1,
  "weather_code": 61, "condition": "rain", "is_day": false,
  "source": "open-meteo.com", "requested_latitude": 47.61, "requested_longitude": -122.33 }
```

- `weather_code` is the WMO code Open-Meteo returns. `condition` is a coarse reading of it, an open set: `clear`, `partly_cloudy`, `cloudy`, `fog`, `drizzle`, `rain`, `freezing_rain`, `snow`, `showers`, `thunderstorm`. `is_day` is Open-Meteo's daylight flag for that hour.
- Endpoint: the forecast API for recent captures and the archive API for older ones (hourly variables `temperature_2m`, `apparent_temperature`, `relative_humidity_2m`, `precipitation`, `cloud_cover`, `wind_speed_10m`, `weather_code`, `is_day`; wind in m/s; times in GMT). The builder confirms the exact parameters and the day ranges each endpoint serves against Open-Meteo's live documentation before coding, and uses the existing `HTTPFetching` seam so tests never touch the network.
- No API key. Open-Meteo is free for non-commercial use under CC BY 4.0; the Settings footer and README say "Weather data by Open-Meteo.com".
- Off by default **(my call:** it sends an approximate location and time to a third party). Switching it on looks up every located capture already on the phone, not only new ones, as the roadmap's "backfilled" intends; the footer says so. The runner paces requests well inside Open-Meteo's free limits (at most one request per second). `usesNetwork` is true. No location on the capture: `not_applicable`. Network or server failure: transient, retried with the runner's backoff. No data for that hour: `empty`.
- The WeatherKit swap noted on the roadmap is not part of this phase.

### 5.3 `barcodes` (provenance `vision`) — on by default

Image attachments, `VNDetectBarcodesRequest`. `{items: [{attachment_id, symbology, payload, url?}]}`. `symbology` is lowercase (`qr`, `ean13`, `code128`, …, open set). `payload` is the decoded string, capped at 2,048 characters. `url` is present when the payload is an `http` or `https` URL. The URL is recorded only: it is not fetched and not added to the capture's `urls` **(my call)**. At most 20 items per attachment. Reads attachment bytes, so it follows the existing rule for trimmed attachments.

### 5.4 `language` (provenance `natural_language`) — on by default

`NLLanguageRecognizer` over the capture's own text. `{items: [{source, language, confidence}]}` with `source` one of `user_note`, `shared_text`, `note_body`; `language` a BCP 47 tag; `confidence` 0–1. Text shorter than 20 characters is skipped. Recognized text and transcripts already carry their own language fields and are not repeated here.

### 5.5 `sound_classification` (provenance `sound_analysis`) — on by default

Audio attachments and audio comments, Apple's built-in classifier (`SNClassifySoundRequest`, classifier version 1). `{items: [{attachment_id, labels: [{label, confidence}]}]}`: the classifier's own label identifiers (e.g. `speech`, `music`, `traffic_noise`), each with its mean confidence over the file, keeping those at or above 0.3, at most 8, strongest first. `attachment_id` is the `comment_id` for a comment's audio, as in `transcript`. Sets `readsAttachmentBytes` and `readsCommentAudio`.

### 5.6 `screenshot` (provenance `heuristic`) — on by default

A guess, like `source_app_guess`. `{items: [{attachment_id, reason}]}` for image attachments that look like a screenshot. `reason` is `exif_user_comment` (the image's EXIF user comment is "Screenshot", which iOS writes) or `screen_size_match` (pixel size equals this phone's screen in either orientation and there is no camera make or model). No match: `empty`.

## 6. Settings and what the phone shows

Settings gets a "Context" section:

- "Save device context with captures" (on by default). Footer: "Records the audio route (speaker, headphones, car), battery, network and the time since your last capture. Nothing leaves this iPhone except with your captures."
- "Motion activity" (off). Footer names the permission and the seven-day limit.
- "Weather" (off). Footer: "Looks up the weather where and when you captured, for all your captures with a location. Sends an approximate location and the time to Open-Meteo.com. Weather data by Open-Meteo.com."

The existing Enrichment section gets four more switches: "Barcodes and QR codes", "Language", "Sounds in recordings", "Screenshots".

The device-context switch lives in the App Group defaults, like the location switch, so the Share Extension reads the same value.

Capture detail gets one plain "Context" section, shown when anything was recorded: one row per signal in words ("Audio: CarPlay", "Battery: 62%, charging", "Network: Wi-Fi", "Previous capture: 41 s earlier", "Motion: Driving, high confidence", "Weather: 14°C, rain, night", "Sounds: speech, traffic", "QR code: example.com/…", "Looks like a screenshot"). Bronze and silver stripes as elsewhere. No filtering, no timeline changes. The exact wording is the builder's; the aim is only that Jorge can see what is being captured.

## 7. Format version: major.minor

Decision (Jorge asked "you tell me"): two parts, without changing a byte of what exists.

- `schema_version` stays the integer it is and is the **major**. It changes only when an existing field changes meaning or type, a required field is removed, or the directory layout changes. A reader rejects a major it does not know, as today.
- A new optional integer `schema_minor` sits beside it in `metadata.json`, `complete.json`, each `comments/<id>.json` and `enrichment.json`. Missing means 0. It counts additive releases of the whole format: a new optional field, observation key, facet kind, or known value of an open set. A reader **accepts any minor**, reads what it knows and ignores the rest. A writer writes the minor of the format it implements.
- No patch number: a documentation fix changes no file.
- This build writes `schema_version` 1, `schema_minor` 1. The format is "1.1". Everything written before this build is 1.0 (it has no `schema_minor`), including packages with comments.
- A facet's own `version` keeps describing that facet's payload shape, independently.
- A server writing gold should write `schema_minor` too; the phone accepts its absence.
- The version is not put in a string such as `"1.1"`: `schema_version` is an integer in every existing file and in the phone's reader.

Changelog, kept in `docs/package-format.md` under "Format history": 1.0 (2026-11-07 → 2026-11-10: packages, enrichment, comments, the `camera` method); 1.1 (this phase: `schema_minor`, the `context.*` observations, location extras, the six facet kinds). Every later minor adds a line.

The JSON Schemas keep their `-v1` names (the major) and gain `schema_minor` (integer ≥ 0, optional) and the new optional fields. Fixtures gain at least one package and one device enrichment document carrying every new signal, validated by `scripts/validate-fixtures.sh`; an existing 1.0 fixture stays untouched to prove old files still validate.

## 8. Documentation

- `docs/package-format.md` and `docs/enrichment-format.md`: titled "version 1.1", the version rules of §7, the new fields and facet kinds, the format history.
- **New `docs/context-signals.md`:** the registry. One row per signal: what it is, file, key or facet kind, value shape with units, provenance, which Settings switch gates it, since which minor, and what absence means. Plus a short "answering recall questions" section with worked examples (which facts suggest a car: `motion_activity` automotive, `context.audio_route` `car_audio`, `speed_meters_per_second` above walking pace), stated as hints to a reader, not rules the phone applies.
- **New `docs/folder-readme.md`:** written for an agent or developer who has only the synced folder. What Hippo is in two sentences; the directory layout (`captures/`, `enrichments/device/`, `enrichments/server/`, `logs/`, `format/`); the order to read things in; the format version; where it may write (only `enrichments/server/`) and that everything else is read-only.
- README: a short "Format and versioning" section pointing at these.

## 9. The self-describing folder

The destination gains:

```text
README.md                         (docs/folder-readme.md)
format/README.md                  (the same file)
format/package-format.md
format/enrichment-format.md
format/context-signals.md
format/schema/*.schema.json
```

- The files are the repo's own `docs/` and `schema/` files, bundled into the app at build time. One source of truth; no copies committed.
- Uploaded by the main app after a destination validates and at the start of a sync pass, only when the set differs from what that destination last received (compare a digest of the bundled set with one stored per destination). Upload order: `format/` files first, `README.md` last.
- These paths are replaced in place **(my call**, instead of the per-version directory I first described to Jorge: one current copy is simpler for a reader, and the format history covers older minors). `replaceFile` in both adapters additionally allows the exact path `README.md` and the prefix `format/`.
- The root `README.md` is only ever replaced when it is Hippo's own. `docs/folder-readme.md` begins with the marker line `<!-- Hippo folder README. Written by the Hippo app and replaced when the app updates. -->`. Before writing, the uploader inspects the destination: no file, write it; a file whose first line is the marker (read with a 64 KiB cap), replace it; anything else, leave it alone, log a fixed code, and do not try again until the bundled set changes **(my call)**. A copy is always written as `format/README.md`, so the folder still describes itself.
- Failure is logged with a fixed code and retried on a later pass. It never blocks or fails capture sync.
- Nothing the phone reads back (remote review, change detection, download, gold pull) may trip over these files: they are outside `captures/` and `enrichments/`. The builder checks each listing path and adds a test.
- "Delete everywhere" and package deletion do not touch them.

## 10. Testing and acceptance

- Unit tests: snapshot → observations mapping (every field, every omission); location extras with invalid values; `context.enabled`; decoding 1.0 files (no `schema_minor`) and files with an unknown higher minor and unknown keys; each new enricher against fakes (a fake motion history, canned Open-Meteo JSON through `HTTPFetching`, fixture images with a QR code, a fixture audio file); `replaceFile` prefixes in both adapters; format upload skipped when unchanged and retried after failure.
- The platform readers in `App/Shared` are thin and covered by device rows.
- `docs/acceptance.md` gains device rows: context recorded from the share sheet and from each in-app path; headphones and CarPlay or car Bluetooth routes; switch off means no `context.*` entries except `context.enabled`; motion permission flow and a walking capture; weather on a located capture; a QR code picture; a screenshot; a voice note with music; `README.md` and `format/` present in Dropbox; an old capture still opens.

## 11. To verify before building on it

Platform facts I believe but did not test; each has a safe fallback (omit the signal there):

1. `AVAudioSession.currentRoute` is readable in the Share Extension without activating a session.
2. `UIDevice` battery level and state are readable in the Share Extension.
3. A `CMMotionActivityManager` history query works from the enrichment runner whenever it runs, including background runs.
4. The built-in sound classifier accepts the m4a files Hippo records.
5. Open-Meteo's parameters and which endpoint serves which dates (§5.2).

## 12. Left to the builder

Type and file names; how the snapshot reaches each capture path; the previous-capture query; the Detail wording; log event names and codes (added to `docs/log-format.md`); how the docs are bundled (`project.yml` resources or a package resource); where the per-destination format digest is stored.
