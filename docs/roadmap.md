# Hippo roadmap

What comes after Plan 3 (Dropbox, merged 2026-11-09). Items are not ordered yet; each becomes a brainstorm → design → plan when it is picked. Decided means Jorge wants it; considered means it came up and was not chosen yet.

## Close out V0

- Run the device acceptance rows that are still "not run" (`docs/acceptance.md`: D1–D13, and the upload halves of rows 1–24) on a Dropbox-connected build and record the results.

## Decided: capture features

- **Done: Camera button (2026-11-09, [design](superpowers/specs/2026-11-09-hippo-camera-voice-comment-design.md)).** Next to the Record button, a button that opens the camera to take a picture or record a video and saves it as a capture (`capture_method` to be chosen, e.g. `camera`). Same note/comment flow as a recording.
- **Done: Comments on any capture (2026-11-10, [design](superpowers/specs/2026-11-10-hippo-comments-design.md)).** Note or Record on a capture adds a typed or spoken comment after the fact, stored in `comments/` inside the package and synced. The share-sheet mic (hand-off to the app) was built on 2026-11-09, tried, found too clunky and removed.
- **One-tap intent chips.** Optional chips on the share sheet and in-app capture flows (for example: read later, buy, idea, todo, for someone). Off by default; a Settings toggle turns them on, and the chip set is editable there. Chosen chips are recorded as observations, never required.

## Decided: capture context (all behind Settings toggles and the relevant permission)

**Done (2026-11-10, [design](superpowers/specs/2026-11-10-hippo-capture-context-design.md)).** Built: the signals below, a major.minor format version, a signal registry, and a self-describing destination folder. The purpose sharpened to recall by circumstance: "the pictures I shared last week while I was in a car".

Purpose: record factual signals at capture time so that, later, Hippo or the desktop can infer an activity ("looks like you were running", "in the car", "on headphones") and ask the user to confirm it. Everything lands as `metadata_observations` entries (with provenance) or device-layer enrichment facets, omitted when unknown; inference happens later, not at capture time.

- **Cheap and permission-free, captured in the moment:**
  - Audio route from `AVAudioSession`: CarPlay, AirPods, car or other Bluetooth, wired headphones, speaker; port type and name.
  - Device state: battery level and charging, Low Power Mode, dark mode, orientation, Wi-Fi or cellular, constrained or expensive network, locale and 12/24-hour setting, thermal state.
  - Capture burst: previous capture ID and seconds since it.
  - Location extras already on the `CLLocation` fix: altitude, speed, course.
  - On-device content detectors: barcodes and QR codes in images (a QR code becomes a URL), language of text and speech, sound classification of recordings (traffic, music, crowd, birds), screenshot detection.
- **Motion activity, backfilled by the main app** from Core Motion's seven-day history at the capture timestamp: stationary, walking, running, cycling, automotive. The share extension never asks for the permission.
- **Weather, backfilled by the main app** at the capture's location and time: temperature, conditions, daylight or dark. Open-Meteo's historical endpoint until the paid developer program makes WeatherKit available. Later: swap Open-Meteo for WeatherKit.
- **Later: the offline indexer.** A separate project that reads the synced folder and builds a rebuildable index over these signals; the phone does no search or filtering by context.

Dropped for now: Health (heart rate, workout in progress, sleep). Judged too hard for the value.

## Considered, not scheduled

- Calendar event in progress or just ended at capture time (EventKit, backfilled).
- Safari share preprocessing JavaScript: selected text, canonical URL, author, publish date, article snapshot (defeats paywalls and link rot).
- Photos library link for shared images (album names, favorite, Live Photo pairing) via limited library access.
- Document properties for shared files (PDF title/author/page count).
- Wi-Fi network name (needs the Access Wi-Fi Information entitlement; unclear on a Personal Team).
- Leave alone: clipboard contents, proximity to contacts' addresses, Focus mode.

## Parked from earlier phases

- Timeline date filter uses the phone's current zone while day headers use the recorded local day.
- No recovery UI for a recording orphaned by an app kill mid-recording (intake is swept after 24 h).
- 10k-capture scale check: Save space estimates read one `metadata.json` per eligible capture; the timeline reads up to two enrichment documents per row.
- Dropbox features the design deferred: broader access with a folder picker, a second provider (Google Drive or OneDrive implement `StorageAdapter`), restoring a capture deleted everywhere.
- Known race: a background upload finishing seconds after "Delete everywhere" leaves a marker-less file in Dropbox (README, Known limits).
- Enrichment follow-ups: relative dates resolve against enrichment time, stale gold survives a cursor reset, LinkPresentation may fetch subresources uncapped.
- Editing or deleting a comment.
- A desktop reader must list `comments/` on rescan (the package digest does not change).
- Download from Dropbox should also fetch `comments/` so comments come back to a new phone.

## Hippo Desk (desktop recall)

**Built on the desktop (2026-11-12, [design](superpowers/specs/2026-11-12-hippo-desk-recall-design.md), [plan](superpowers/plans/2026-11-12-hippo-desk-recall.md), [README](../desktop/README.md)).** The first part of the desktop reader: a Node app in `desktop/` that reads the synced folder, enriches each capture with a model (title, summary, tags, topic, people, picture descriptions) and rules (likely circumstances), and keeps a local index. Writes only `enrichments/server/…/enrichment.json` into the folder. Recall three ways: the `hippo` command line (`search`, `show`, `facets`), a skill for coding agents, and the desk, a browser page (`hippo ui`) where a plain-words question lays the matching captures out as piles on a table that can be opened, lifted, turned over, set aside, pinned and arranged by kind, time, place, topic or person. Tested in a browser on a generated sample folder with a fake provider. Not yet run on the real Dropbox folder: starting that is Jorge's.

- Phone side: nothing yet. Later phone work on this feature is added here.

## Later: ask and browse (an idea, not scheduled)

Jorge's idea (2026-11-10): agents are text in, text out. Build a surface where the question goes in as text and the answer comes back as a set of captures to look at: a list, a grid, or piles on a table, which he can then zoom into, filter and sort by hand. Talk to the agent and browse, both. Definitely on the desktop; interesting on the phone too, with a model running against the phone's own data.

What it needs from the data, already true or coming: every signal a queryable fact with a stable key (capture context phase), captures addressable by `capture_id`, thumbnails available locally. The agent's answer would be capture IDs plus a grouping, rendered by native views, so the model never has to describe what the screen can show.

## The desktop reader (separate project)

The phone is intake; the synced folder is the product. The reader scans `~/Dropbox/Apps/Hippo`, indexes packages by `capture_id` and digest (`docs/package-format.md`), reads device-layer enrichment and writes server-layer enrichment (`docs/enrichment-format.md`), and hosts the weekend review and agents. Activity inference and the "confirm with the user" step from the context items above may live here or on the phone.
