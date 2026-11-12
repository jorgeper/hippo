<!-- Hippo folder README. Written by the Hippo app and replaced when the app updates. -->
# Hippo folder

Hippo is an iPhone app that captures things you share or record: links, notes, photos, files, voice notes. It saves each one as a small package of plain files and copies it into this folder.

If you are an agent or a developer reading this folder, the files below tell you how to read everything here without the app.

## Layout

| Path | What it holds |
|---|---|
| `captures/YYYY/MM/DD/<capture-id>/` | One folder per capture: `metadata.json`, `content/` (the attachments), `comments/` (comments added later) and `complete.json`, which is written last. Ignore a folder without `complete.json`. |
| `enrichments/device/YYYY/MM/DD/<capture-id>/` | What the phone derived from a capture (text found in images, transcripts, weather, motion, and so on). |
| `enrichments/server/YYYY/MM/DD/<capture-id>/` | What a server or agent derived. The phone reads these. |
| `logs/<install-id>/` | Content-free event logs from each phone. |
| `format/` | The documents and JSON Schemas that describe all of the above. |
| `README.md` | This file. |

`enrichments/server/` has one writer at a time: a server, or a desktop program on the owner's computer (Hippo's own is `hippo-desk`). Besides `summary` and `tags`, a reader will find the kinds added in format 1.2: `display` (a short title, a topic and weighted keywords), `image_description` (what each picture shows), `people` (names mentioned, with where each was found) and `circumstance` (likely circumstances such as "in a car", each with a confidence and its evidence; a conclusion, not a fact). `format/enrichment-format.md` describes each one. Keep and ignore any other kind.

## What to read, in order

1. `format/package-format.md`: the capture package and the versioning rules.
2. `format/enrichment-format.md`: the enrichment files, facet by facet.
3. `format/context-signals.md`: every signal recorded about a capture's circumstances (audio route, battery, network, motion, weather, and others), where it lives, and what its absence means.
4. `format/schema/`: JSON Schemas for each file.

`format/README.md` is a copy of this file.

## Format version

Format version 1.2. The major part is `schema_version` (1); the minor part is the optional `schema_minor` (missing means 0). Accept any minor, ignore keys you do not know, and reject a major you do not know.

## Who may write here

Everything in this folder is read-only for you except `enrichments/server/`. You may write there, following `format/enrichment-format.md`. Do not change, rename or delete anything else: `captures/`, `enrichments/device/`, `logs/`, `format/` and this file belong to the phone, and the app replaces `README.md` and `format/` whenever it updates.

Weather data by Open-Meteo.com. Where weather appears in this folder it is licensed CC BY 4.0.
