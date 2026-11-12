# Hippo Desk: recall on the desktop (design)

Date: 2026-11-12. Status: design, awaiting Jorge's approval. Branch: `feat/desktop-recall`, cut from `feat/capture-context` (ef03980) because format 1.1 and its documents live there.

Each decision below is marked **(Jorge)** when he made it in conversation, or **(call)** when it is the designer's choice and open to change.

## 1. Intent

Hippo on the phone captures links, notes, pictures and recordings into a synced folder. Until now the only way to get them back out is to point a text agent at that folder. Jorge wants to recall things the way memory works, by association ("I was with this person, I was in this place, it was last week, I was in the car"), and to see the answer as things on a desk instead of as text.

This project is a proof of concept of that experience: type a sentence, and the matching captures arrive on a virtual desk as realistic objects in piles. Refine with another sentence, and the ones that no longer match leave while the rest regroup. Pick piles up, open them, flick things away, open one item and read everything about it.

It has three layers, kept separate on purpose **(Jorge)**:

1. **Indexer.** Reads the folder, derives what the raw captures lack (what a picture shows, a summary, topics, people mentioned, likely circumstances), and builds a searchable index.
2. **Recall.** A query interface over the index. Used in text by any coding agent through a command and a skill, and used by the visual app through a local endpoint.
3. **Desk.** A three.js page that turns questions into piles of objects.

Why now: the capture-context phase made every signal a documented fact. This is the first reader of those facts, and the first test of whether they are enough to recall by circumstance.

## 2. Goals, non-goals, anti-goals

### Goals

- One Node app that Jorge runs on his Mac **(Jorge)**, with three commands: `hippo index`, `hippo search`, `hippo ui` **(call)**.
- Layers 1 and 2 are useful with no UI: an agent (Claude Code, Codex, Copilot) can answer recall questions in text through the command and a skill **(Jorge)**.
- The desk answers the demo script in section 9 on Jorge's real folder and on a generated sample folder.
- The objects look attractive and physical: gloss and reflections on prints, soft shadows, natural motion **(Jorge)**. The desk surface itself is plain dark blue, not a realistic material **(Jorge)**.
- What is on the desk and how it is arranged are independent. The arrangement can be changed by typing or by a button **(Jorge)**.
- The look and the animations are a theme. Only the desk theme is built, but a second theme must be addable without changing the rest **(Jorge)**.
- Model access works through the subscriptions Jorge already has, by running the `claude` or `codex` command he is signed into, with API keys as a switchable alternative **(Jorge)**.
- Written so that it can run on Windows **(Jorge)**. It is not tested on Windows in this project **(call)**.

### Non-goals

- A hosted service, accounts, or anything that listens beyond the local machine.
- A native Mac or Windows app. The desk is a browser tab.
- Changes to the phone app or to the capture format.
- Editing, deleting or re-filing captures.
- Vector search. Text search over model-written descriptions and tags is enough at this size **(call)**.
- A physics engine. Motion is springs and scripted arcs **(call)**.
- A second theme (for example "Minority Report"). The seam is built; the theme is not. A minimal second theme is a stretch item, only after everything else works.
- Speech input. Jorge types, or dictates with his own transcription app **(Jorge)**.
- An MCP server. The command plus a skill reaches every agent he named **(call)**.

### Anti-goals (it has failed if)

- The desk is a thumbnail grid with a 3D coat of paint: objects that cannot be picked up, piled, opened or thrown.
- The model answers in prose what the desk could show. The model returns a search and an arrangement; the desk shows the captures.
- Refining a question feels like waiting for a web page. A typed question should change the desk in about three seconds; a button should change it at once.
- Anything in the folder other than `enrichments/server/` is created, changed or deleted.
- A capture is shown as "in a car" (or any conclusion) without the facts behind it being inspectable.

## 3. What exists today (findings)

Jorge's synced folder on 2026-11-12 holds 51 captures from five days:

| Kind | Count | Notes |
|---|---|---|
| Links | 15 | 8 are YouTube, with title, channel and thumbnail in the device `link_preview` facet |
| Notes | 14 | Typed or shared text |
| Pictures | 11 | PNG, JPEG and HEIC; 6 are flagged by the device `screenshot` facet |
| Recordings | 10 | Each has a device `transcript`; 6 audio files have `sound_classification`. Three more audio files are spoken comments on pictures |
| Video | 1 | |

- Location: 43 captures have `capture_location` (median accuracy about 10 m) and a device `place` facet at city level.
- Circumstance: 4 captures carry the format 1.1 context observations (`context.audio_route`, `context.device`, `context.network`). None has a `motion_activity` or `weather` facet yet.
- People: nothing records who Jorge was with. A name can only come from text: a note, a transcript, recognized text, a comment.
- Picture content: only recognized text. Nothing says what a picture shows.
- `enrichments/server/` exists and is empty. The folder README reserves it for a server or agent to write.

Measured on Jorge's Mac (Claude Code 2.1.322, Node 22.23): a non-interactive `claude` call on his subscription, small model, JSON schema output, tools off, returns a structured search in about 2 seconds wall time. The same call with the Read tool describes an image file correctly in about 6 seconds. The exact flags are in section 6.

Consequences: the indexer is needed (picture descriptions, topics, people, circumstance conclusions). Real data is too small and too uniform to show big piles or circumstance questions, so a sample folder is part of the project.

## 4. Architecture

```text
synced Hippo folder (read-only except enrichments/server/)
        │
        ▼
┌───────────────┐   writes    enrichments/server/…/enrichment.json
│ 1. Indexer    │────────────▶ (derived facts, portable, in the folder)
│  read, derive │
│  enrich       │────────────▶ index database + thumbnails
└──────┬────────┘              (local app-data directory, rebuildable)
       │ model calls                      │
       ▼                                  ▼
┌───────────────┐              ┌──────────────────────┐
│ Providers     │◀─────────────│ 2. Recall            │
│ claude / codex│  ask only    │  search(spec)→results│
│ / API keys    │              │  CLI · skill · HTTP  │
└───────────────┘              └──────────┬───────────┘
                                          │ HTTP on 127.0.0.1
                                          ▼
                               ┌──────────────────────┐
                               │ 3. Desk (three.js)   │
                               └──────────────────────┘
```

Rules that keep the layers honest **(call)**:

- Recall reads only the index database and serves media files. It never parses the folder's JSON itself.
- The desk talks only to the HTTP endpoint. It never reads files.
- Providers are used by the indexer (to enrich) and by recall's "ask" endpoint (to turn a sentence into a search). Nothing else calls a model.
- The text path (`hippo search`) never calls a model. The agent using it is the model.

Code lives in `desktop/` in this repository **(call)**: TypeScript on Node 22 (run directly, no build step for the Node side), SQLite through Node's built-in `node:sqlite`, and a Vite-built three.js front end. Suggested shape, the builder may adjust:

```text
desktop/
  src/core/        folder reader, record model, circumstance rules
  src/index/       database, thumbnails, sample generator
  src/enrich/      model enrichment, write-back
  src/providers/   claude-cli, codex-cli, anthropic-api, openai-compatible, fake
  src/recall/      search spec, engine, ask
  src/server/      local HTTP server
  src/cli.ts       hippo index | search | show | facets | status | sample | ui
  ui/              three.js app (Vite)
  skills/hippo-recall/SKILL.md
  docs/server-facets.md
```

The builder must confirm early that `node:sqlite` on Node 22 includes full-text search (FTS5). If not, use `better-sqlite3`.

## 5. Layer 1: the indexer

### What it reads

Every capture directory that has `complete.json`, per `docs/package-format.md`: `metadata.json`, `content/`, `comments/`, and the device `enrichment.json` with its assets, per `docs/enrichment-format.md`. It follows the format's reader rules: reject an unknown `schema_version`, accept any `schema_minor`, ignore unknown keys, treat a missing key as unknown, trust an asset only when size and SHA-256 match. The seven packages in `fixtures/packages/` are the test set.

Dropbox may keep files online-only; reading them makes Dropbox download them. That is acceptable.

### What it derives without a model

One record per capture:

- **Kind**, exactly one of `link`, `photo`, `screenshot`, `note`, `recording`, `video`, `file`. It decides the object and the pile. A capture with mixed content takes the first that applies **(call)**:
  1. `video`, when it has a video attachment.
  2. `screenshot` or `photo`, when it has a picture. The first picture attachment decides: `screenshot` when the device `screenshot` facet names it, otherwise `photo`. Audio beside a picture is treated as a spoken comment on it.
  3. `recording`, when it has audio.
  4. `file`, when it has a PDF or other file.
  5. `link`, when `urls` is not empty and the capture method is not `typed_note`.
  6. `note` otherwise (a typed note that contains a URL is a note).

  The `kinds` filter matches this one kind. What else a capture holds is found with `has`. The object shows the first picture and a small "+2" mark when there are more attachments; the opened item shows all of them.
- **Layers merged by the format's override rule**: where device and server enrichment both describe the same item, the reader resolves it field by field as `docs/enrichment-format.md` specifies.
- **Text**: note body, shared title and text, user note, link titles and descriptions, recognized text, transcripts, comments (typed text and audio transcripts).
- **Time**: `captured_at`, local date, local hour, weekday, part of day (morning 5–12, afternoon 12–17, evening 17–22, night otherwise).
- **Place**: latitude and longitude, plus locality, sub-locality and nearby name from the `place` facet.
- **Source**: site host for links, guessed app, capture method.
- **Circumstances**: conclusions computed by fixed rules from the hints in `docs/context-signals.md`, each stored with a confidence (`low`, `medium`, `high`) and the list of facts that produced it. First set **(call)**: `in_car`, `walking`, `running`, `cycling`, `on_headphones`, `in_a_burst` (several captures in a row), `daylight` or `dark` (from weather `is_day`). Rules, not a model, because they must be explainable and testable. A missing signal yields no conclusion, never a negative one.

### What it derives with a model

One model call per capture that has something to say, returning one JSON object:

| Field | For | Meaning |
|---|---|---|
| `title` | all | Short display title, at most 60 characters |
| `summary` | all with text or a picture | One sentence |
| `image_descriptions` | each picture | What it shows, two or three sentences, including visible objects, setting and any app or site it is a screenshot of |
| `tags` | all | 3 to 8 lower-case topic words |
| `topic` | all | Exactly one pile-worthy topic. The call is given the topics already in use and must reuse one when it fits, so piles stay coherent |
| `people` | all | Names of people mentioned, each with where it was found |
| `keywords` | notes and recordings | Up to 12 words with weights, for the word cloud drawn on the object |

Pictures are sent as a JPEG no larger than 1024 px on the long side (the thumbnail step below makes it), so HEIC works and calls stay cheap. Video content is not described; a video gets its text-based fields only.

A capture is enriched once **(call)**. The indexer computes an input digest over exactly what the model is shown (the capture's text fields, the SHA-256 of each picture sent, comment ids and text) plus its own prompt version. It calls the model again only when that digest changes. A new device facet the model does not see (weather, motion, a place) therefore costs no model call. The rule-made facets (`circumstance`) and the index record are recomputed on every run from whatever the folder holds, which is cheap.

Failures are recorded and retried on the next run, at most three times.

### Where results go

1. **Server enrichment in the folder** **(Jorge agreed to this in outline)**: `enrichments/server/YYYY/MM/DD/<capture-id>/enrichment.json`, `layer: "server"`, producer name `hippo-desk`, following the write order and atomic replace in `docs/enrichment-format.md`. Facets:
   - `summary` `{text}` and `tags` `{values}`: the kinds the format already names.
   - New kinds **(call)**: `display` `{title, topic, keywords: [{word, weight}]}`, `image_description` `{items: [{attachment_id, text}]}`, `people` `{items: [{name, source}]}`, `circumstance` `{items: [{label, confidence, evidence: [string]}]}`.
   - The new kinds are documented in `desktop/docs/server-facets.md`, not yet in `docs/enrichment-format.md`. The format allows unknown kinds; promoting them to the format (and bumping its minor) waits until the prototype settles **(call)**.
   - One bookkeeping kind **(call)**: `hippo_desk_state` `{input_digest, prompt_version}`. It is how a rebuilt index, or a second computer, knows a capture is already enriched without calling the model. A server document without it, or with a different digest, counts as not enriched.
   - Model-made facets carry `provenance` naming the provider and model. Rule-made facets carry `provenance: "rules"`.
   - When a server document already exists, the indexer replaces the kinds it owns (the seven above) and keeps every other facet as it found it, including ones from another producer. The fixture `url-only` has such a document and is the test.
   - Stay under the limits the phone enforces on server enrichment (1 MiB per document); the indexer writes no assets.
   - Write-back can be turned off (`--no-write-back`); the index then holds the only copy.
2. **The index database**, in the per-user app-data directory (`~/Library/Application Support/hippo-desk/` on macOS, `%LOCALAPPDATA%\hippo-desk\` on Windows), never in the synced folder. It can be deleted and rebuilt with `hippo index --rebuild`, which re-reads the folder and reuses server enrichment already written instead of calling the model again.
3. **Thumbnails**, beside the database: for each picture a display JPEG (long side 1024 px) and a small one (256 px). Link thumbnails come from the device enrichment assets. HEIC must be handled on both platforms; a pure JavaScript decoder is acceptable. Videos need no thumbnail: the desk shows their first frame itself.

### Commands

- `hippo index [--folder <path>] [--no-enrich] [--no-write-back] [--rebuild] [--limit n]`: one pass, prints what it did. The folder path is remembered after first use.
- `hippo status`: counts by kind, how many are enriched, failures, last run.
- `hippo sample --out <dir> [--count 300]`: writes a valid format 1.1 folder of invented captures: links with drawn thumbnails, pictures and screenshots drawn procedurally, notes, recordings with transcripts, places around a few invented neighbourhoods, motion, audio route and weather. It also writes the server enrichment, so the sample needs no model calls and is the same every time (seeded). No real personal data.

A watch mode is not built; rerun `hippo index` (the desk has a button that does it) **(call)**.

### Privacy

Enrichment sends a capture's text and pictures to the chosen model provider, the same exposure as pointing an agent at the folder. During development and tests, the indexer runs only on fixtures and the sample folder. The first enrichment run on Jorge's real folder, and the first write-back into his Dropbox, are his to start.

## 6. Model access (providers)

One interface: given a system prompt, a user prompt, optional image file paths and a JSON schema, return an object that fits the schema, or a typed error. Providers:

| Provider | Uses | Status |
|---|---|---|
| `claude-cli` | The signed-in `claude` command, so the Claude subscription | Must work; the default |
| `codex-cli` | The signed-in `codex exec` command, so the ChatGPT plan | Should work |
| `anthropic-api` | `ANTHROPIC_API_KEY` | Should work |
| `openai-compatible` | A base URL and key, covering OpenAI and OpenRouter | Should work |
| `fake` | Canned answers | For tests |

`claude-cli`, as measured: run from an empty working directory with `-p --output-format json --json-schema <schema> --model <alias> --system-prompt <text> --tools "" --strict-mcp-config --disable-slash-commands --no-session-persistence --setting-sources ""`, and read `structured_output` from the JSON result. For pictures use `--tools Read --add-dir <thumbnail dir> --permission-mode dontAsk` and name the file path in the prompt. Do not use `--bare`: it disables subscription sign-in. On Windows the command may be `claude.cmd`; resolve it without relying on a shell.

Defaults **(call)**: the small fast model (`haiku` alias) for both enrichment and asking; each is a setting. For the API providers the builder takes current model IDs from the provider's documentation, not from memory.

Keys are read from the environment or a gitignored `.env`, never written to the config file or the database. The config file holds the provider name, model names, folder path and switches only.

Enrichment runs a few calls at a time (default 3) and stops cleanly on a usage-limit error, reporting how far it got.

## 7. Layer 2: recall

### The search spec

Everything that asks for captures uses one JSON shape. All fields optional; fields combine with AND, values within a field with OR.

| Field | Meaning |
|---|---|
| `kinds` | Any of the seven kinds |
| `text` | Words and phrases matched against all text, descriptions, tags and titles. The caller supplies synonyms (for "bananas": banana, fruit) |
| `tags`, `topics`, `people`, `sites` | Exact values from the index vocabulary |
| `time` | `from` and `to` as local dates, and optionally weekdays and parts of day |
| `place` | Locality names, or a point and radius in meters |
| `circumstances` | Labels from section 5, with a minimum confidence |
| `has` | Any of `picture`, `audio`, `comment`, `location`, `link` |
| `include_ids`, `exclude_ids` | Pinned and dismissed captures |
| `sort` | `newest` (default), `oldest`, `relevance` |
| `limit` | Default 500 |

A result is the capture record: id, kind, title, summary, times, place, tags, topic, people, circumstances with evidence, and references to its thumbnails and media. `hippo facets` returns the vocabulary: kinds with counts, topics, tags, people, sites, localities, circumstance labels, and the date range. That is how an agent or the ask step knows which values exist.

### In text, for agents

- `hippo search` takes the spec as flags (`--kind link --site youtube.com --from 2026-11-03 --to 2026-11-09 --circumstance in_car --text "banana fruit"`) or as `--spec '<json>'`, and prints a readable list, or JSON with `--json`.
- `hippo show <id>` prints everything about one capture, including file paths an agent can open.
- `hippo facets` as above.
- `desktop/skills/hippo-recall/SKILL.md` teaches an agent the loop: read the vocabulary, translate the person's words into a spec, search, refine, answer with titles, dates and paths. Written in the Agent Skills format that Claude Code reads; the same text works as instructions for Codex and Copilot. How to install it for each agent goes in `desktop/README.md`.

### For the desk: ask

`POST /api/ask` receives the typed sentence, the current spec, the current arrangement, and the last few turns. It makes one model call that is given the vocabulary, today's date and time zone, and those inputs, and returns:

- a complete new spec (not a patch), so "no, actually it was a screenshot" replaces the kind while keeping the rest, and "start over" clears it;
- an arrangement: one of the layouts in section 8, or "keep the current one";
- one short line to show the person ("8 YouTube videos, 5 from last week").

The server runs the spec and returns the results with the arrangement. Pinned and dismissed ids are added by the server, not trusted to the model. If the model call fails or returns a spec that does not validate, the desk keeps its state and shows the error in the reply line.

Buttons do not call the model: switching layout, undo, dismiss, restore and pin go to `POST /api/search` with a spec, or are handled in the page.

### The local server

`hippo ui` starts an HTTP server bound to 127.0.0.1 and opens the browser. Because any web page can send requests to localhost, every request must carry a per-run token (given in the opened URL, then kept by the page), and the server checks the `Host` and `Origin` headers. Media is served only for paths recorded in the index, never from a path supplied by the request.

## 8. Layer 3: the desk

A clickable sketch of the arrangement and gestures, approved by Jorge as the direction, is kept (untracked) at `.superpowers/brainstorm/84327-1794492073/content/pivots-prototype-v3.html`. It is a flat DOM sketch with pretend data; it defines behaviour, not appearance.

### Scene

- A camera looking down at a slight tilt on a plain dark blue surface with a soft vignette **(Jorge)**. No wood, no clutter.
- Objects are thin 3D things lit by one soft key light with soft shadows, plus an environment for reflections **(Jorge: reflections and shadows)**. How each kind looks **(call, Jorge said "be creative")**:
  - **Photo**: a glossy print with a white border. Clear-coat reflection that moves as it moves.
  - **Screenshot**: a phone-shaped print with rounded corners and a dark bezel.
  - **Link**: a card with the thumbnail on top, title and site below; a play mark when it is a video link.
  - **Note**: a paper slip showing its key words as a small word cloud, or its first lines when short **(Jorge: word cloud or top words)**.
  - **Recording**: a cassette, with the first words of the transcript handwritten on the label and the length **(Jorge: "like a tape")**.
  - **Video**: a print showing the first frame with a play mark.
  - **File**: a sheet of paper with a folded corner and the file name.
- A pile shows at most a dozen sheets plus a thickness that hints at the rest, and a small handwritten label with a count.

### What is on the desk, and how it is arranged

These are separate **(Jorge)**. The set comes from the spec. The arrangement is a layout:

| Layout | Arrangement |
|---|---|
| By kind | One pile per kind, always in the same places |
| By time | A column per day (per week or month when the range is long), items placed by time of day |
| By place | A paper map sheet unfolds on the desk and items sit where they were captured, clustered into small piles **(Jorge asked for a map; paper sheet is a call)** |
| By topic | One pile per topic, labelled |
| By person | One pile per person mentioned, plus "nobody mentioned". A capture is one object, so one that mentions several people sits in the pile of the first named and carries a small mark for the others. Asking for a person by name still finds every capture that mentions them **(call)** |

The model picks a layout that suits each question and the person can override it with the buttons or by typing ("sort these by place") **(Jorge: both ways; the model picking a default is a call)**. A layout is a function from items and viewport to positions, labels and an optional backdrop, so adding one is adding a file.

The map uses real map tiles (OpenStreetMap, with attribution), tinted to look like paper. This tells the tile server which area is being viewed. A setting turns tiles off, leaving a plain sheet with place names **(call)**.

### Motion

Each capture is one persistent object. When the set changes, the desk works out who leaves, who stays and who arrives, and animates each group with the theme's motions: by default leavers are swept off the nearest edge, stayers glide to their new place with a slight lift, arrivals are dealt in from off the desk and settle **(Jorge: natural animations, leaving and arriving, configurable later)**. While a question is with the model, the desk shows it is thinking without blocking the person. Motion is staggered and interruptible: a new question mid-animation redirects objects from where they are.

### Handling (approved by Jorge as described)

- **Zoom and pan**: scroll or pinch zooms toward the pointer; dragging empty desk pans. Titles become readable as you get close.
- **Open a pile**: click it and it spreads so every item is visible, with the rest of the desk dimmed and moved aside; Escape or a click outside gathers it. Scrolling inside an open pile riffles through it.
- **Lift an item**: click one and it rises to full size.
- **Open an item** **(Jorge: see all its details; the flip is a call)**: the lifted item shows the thing itself (the picture at full resolution, the note text, the recording with a player and transcript, the link with a button that opens it in the browser, the video playing). Flipping it shows the back: when, where, capture method, device context, circumstances with their evidence, tags, people, comments, and file paths. Long text and players are HTML laid over the lifted object so they are sharp and scrollable.
- **Move**: drag an item anywhere; drag a pile by its label.
- **Dismiss**: throw an item toward an edge. It lands in a small "set aside" pile in a corner, which can be opened to take things back. Dismissed items stay out through refinements until the person starts over.
- **Keep**: drag items to an empty spot to make a pile of their own ("maybe these"). Pinned items stay on the desk when the question changes.
- **Undo**: step back to the previous question.

### Controls

A single ask bar at the bottom (Enter sends, Up recalls earlier sentences), the model's one-line reply above it, layout buttons at the top right, a count of what is on the desk, and small controls for undo, reset view, re-index and settings (theme, provider, map tiles).

### Themes

A theme is one module that supplies: the surface and lighting, a builder for each kind of object, the label style, and the motion set (arrive, leave, move, lift, flip, thinking). Nothing outside `ui/themes/desk/` may name a desk-specific material, colour or timing. The theme is chosen by a setting. Only `desk` is built.

### Scale

Smooth (60 frames per second on Jorge's Mac) with 300 captures on the desk. Up to 2,000 must remain usable: piles cap what they draw, and textures are made at small size until an item is approached.

## 9. Done means

The demo script, on the sample folder and on Jorge's folder after he has run the indexer:

1. `hippo index` on a fresh folder finishes, `hippo status` shows every capture enriched or a named failure, and a second run does nothing.
2. In a coding agent with the skill installed, "find the YouTube shorts from last week" returns the right captures as text.
3. `hippo ui` opens the desk. "show me the YouTube videos" deals them onto the desk.
4. "no, actually it was a screenshot" sweeps the videos off and deals the screenshots in.
5. "from last week" removes the others; the rest regroup.
6. "while I was in the car" works on the sample folder (and on real captures once they carry motion or car audio).
7. "sort these by place" unfolds the map with the same items on it; the By kind button puts them back in piles without a model call.
8. A pile opens, riffles, and closes. An item is thrown away and taken back. Two items are pinned and survive a new question.
9. An item is lifted, opened, flipped, and its link opens in the browser.
10. Nothing under the folder changed except `enrichments/server/`.

Tests: the reader, rules, index and search engine against the fixtures and the sample folder; the enricher and ask step against the fake provider; one browser test that loads the desk on the sample folder and walks steps 3 to 5 with the fake provider. Appearance is judged by Jorge looking at it.

## 10. Left to the builder

- Database schema, module boundaries inside each layer, and the exact prompts.
- How objects are modelled and textured, the lighting recipe, spring constants, and any post-processing, within section 8.
- Thumbnail and HEIC libraries, the Vite setup, the port number, the test runner.
- The order of work, provided layers 1 and 2 are usable from the command line before the desk depends on them, and the desk can be developed against the sample folder.

## 11. Risks and open points

- **Usage limits.** Enrichment is one call per capture on a subscription. Fine at 51; at thousands it needs batching or an API key. The indexer stops cleanly and resumes.
- **Speed of asking.** Two seconds was measured for a trivial question. The real prompt carries the vocabulary and history; if it passes about four seconds, trim the vocabulary or keep one model process open between questions.
- **People.** "Who I was with" is not recorded by the phone. Until it is, person recall only finds names that appear in text. A phone-side signal is a separate project.
- **Circumstance on real data.** Only four real captures have context observations and none has motion. Recall by circumstance will be thin on real data until newer captures accumulate.
- **Topic drift.** Asking the model to reuse topics keeps piles coherent only roughly. A later pass could merge near-duplicates.
- **One writer per layer.** The format allows a single writer for `enrichments/server/`. Running the indexer on two computers against the same folder would make two; the last one wins. Acceptable for a prototype.
- **Windows.** Designed for, not verified.
