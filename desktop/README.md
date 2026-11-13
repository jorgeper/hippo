# Hippo Desk (desktop)

The desktop side of Hippo. It reads a synced Hippo folder, enriches each capture with a model (title, summary, tags, topic, people, picture descriptions) and rules (likely circumstances such as "in the car"), keeps a local index of everything, and lets you recall captures by association: on a desk in the browser (`hippo ui`), from the command line, or through a coding agent.

Design: [`docs/superpowers/specs/2026-11-12-hippo-desk-recall-design.md`](../docs/superpowers/specs/2026-11-12-hippo-desk-recall-design.md).

## Install

Needs Node 22.18 or later (TypeScript runs directly; there is no build step).

```sh
cd desktop
npm install
npm link        # puts the `hippo` command on your PATH
```

Without `npm link`, run `node bin/hippo.mjs <command>` from `desktop/`.

## First run

Point it at your Hippo folder once (the folder that holds `captures/` and `enrichments/`); the path is remembered. Look before you enrich:

```sh
hippo enrich --folder /path/to/Hippo --dry-run   # which captures it would send and write; writes nothing
hippo enrich                                     # enrich, then update the index
hippo status
hippo search --text "banana" --kind link
```

Two things write into the folder: `hippo enrich` and the Update button on the desk, which runs the same pass. They, and questions typed into the desk, are also the only things that call a model. Starting the first enrichment on a real folder is a decision for the folder's owner (see [Privacy](#privacy)).

## Commands

| Command | What it does |
|---|---|
| `hippo enrich [--folder <path>] [--dry-run] [--no-model] [--limit n] [--provider name] [--model name]` | One pass over the folder. For each complete capture: works out the likely circumstances by rules, calls the model when what it would be shown has changed, and writes the capture's server enrichment document if its content differs. Then runs the index step. `--dry-run` lists the captures it would send to the model and the documents it would write, and does neither. `--no-model` writes only the rule-made circumstances. `--limit n` makes at most n model calls and leaves the rest for the next run. Ctrl-C finishes the calls in flight and stops; a second Ctrl-C quits at once. Exit code 3 when it stopped early (usage limit, not signed in, provider unavailable), 130 when interrupted. |
| `hippo index [--folder <path>] [--rebuild]` | Builds or updates the local index and thumbnails from the folder. No model, nothing written into the folder. `--rebuild` starts from empty tables. |
| `hippo status [--folder <path>]` | Captures by kind, then where each one stands, each counted once: enriched, nothing to describe (no text or picture: a video, a recording without a transcript), not described yet (waiting for `hippo enrich`), or failed (with the reason; a failure counts here even over an older enrichment). Those add up to the number of captures. Also: captures not yet complete in the folder (still syncing, not counted in the total), last runs. |
| `hippo search [filters] [--json]` | Finds captures. See [Search](#search). |
| `hippo show <id> [--json]` | Everything about one capture: every field, the evidence behind each circumstance, and the absolute path of every file (originals, comment audio, thumbnails). Takes a whole id or a unique prefix of 8 or more characters. |
| `hippo facets [--json]` | The vocabulary: kinds with counts, every topic, tag, person, site, locality and circumstance label with counts, and the date range. |
| `hippo ui [--folder <path>] [--port n] [--no-open] [--provider name] [--dev]` | Starts the desk: a server on 127.0.0.1 and the page in your browser. See [The desk](#the-desk). |
| `hippo sample --out <dir> [--count 300] [--seed 1] [--end YYYY-MM-DD]` | Writes a new folder of invented captures, already enriched. See [The sample folder](#the-sample-folder). |

Every command except `sample` takes `--folder <path>`; without it the remembered folder is used. Exit code 2 means a usage error (an unknown flag or a bad value, named in the message).

`search`, `show` and `facets` read the index only. They call no model, need no network and write nothing. They need an index: run `hippo index` (or `hippo enrich`) first.

## Search

A search is a spec: fields combine with AND, values within a field with OR, except `has`, where all must hold.

| Field | Flag | Meaning |
|---|---|---|
| `kinds` | `--kind` | `link`, `photo`, `screenshot`, `note`, `recording`, `video`, `file` |
| `text` | `--text "<words>"`, `--phrase "<exact phrase>"` | Matched against titles, summaries, all text, picture descriptions, tags, topic, people, site and circumstances. `--text` adds each word (also as a prefix: `banan` finds "banana"); `--phrase` adds one exact phrase. Matched literally: quotes, `*`, `:`, `-`, parentheses and words like `AND` or `NEAR` are just text. |
| `tags`, `topics`, `people`, `sites` | `--tag`, `--topic`, `--person`, `--site` | Whole values, case-insensitive. A site also matches its subdomains (`youtube.com` finds `m.youtube.com`). |
| `time` | `--from`, `--to`, `--weekday`, `--part-of-day` | Local dates `YYYY-MM-DD`, inclusive, in the capture's own time zone (where it was taken), not the computer's. Weekdays `mon` … `sun`; parts of day `morning`, `afternoon`, `evening`, `night`. |
| `place` | `--locality`, `--near lat,lon,radius_m` | A locality name, or a point and radius in meters. |
| `circumstances` | `--circumstance`, `--min-confidence` | Labels such as `in_car`, `walking`, `on_headphones`, `daylight`; minimum confidence `low` (default), `medium`, `high`. |
| `has` | `--has` | `picture`, `audio`, `comment`, `location`, `link` |
| `include_ids`, `exclude_ids` | (spec only) | Captures always included (never cut by the limit) or always left out. |
| `sort` | `--sort` | `newest` (default), `oldest`, `relevance` (best text match first) |
| `limit` | `--limit` | 1 to 5000, default 500 |

List flags are repeatable or comma-separated (`--kind link,video`). The same search as JSON: `hippo search --spec '{"kinds":["link"],"sites":["youtube.com"],"time":{"from":"2026-11-02","to":"2026-11-08"}}'`; `--spec` is not mixed with filter flags. `--json` prints `{"total": n, "items": [...]}`, where `total` counts every match before the limit and each item is the full capture record.

## The sample folder

`hippo sample` writes a complete Hippo folder of invented captures, so you can try `hippo index`, `hippo search`, `hippo facets` and later the desk without a phone or a real folder. Everything in it is made up: the notes, transcripts, titles and channels, six first names, the neighbourhood names. Links use real well-known sites (YouTube, news, recipe, shop and map sites) with invented paths and ids; locations are public places in Lisbon (squares, gardens, viewpoints).

```sh
hippo sample --out ~/hippo-sample              # 300 captures over the 42 days ending today
hippo index --folder ~/hippo-sample
hippo search --site youtube.com --circumstance in_car
```

What it makes: links (a third of them YouTube, some shorts), photos and screenshots drawn from simple shapes, typed notes, short voice recordings with transcripts, videos and files, in `Europe/Lisbon` time, with the phone's context signals (audio route, motion, speed, weather) and comments. It writes the device enrichment and the server enrichment `hippo enrich` would write (display, summary, tags, picture descriptions, people, circumstances and `hippo_desk_state`), so `hippo enrich` on it calls no model and writes nothing. The same `--seed`, `--count` and `--end` give a byte-identical folder.

`--out` must be a new or empty directory. It refuses a directory inside a Hippo folder (one with `captures/`) and inside this repository's `fixtures/`.

## The desk

`hippo ui` shows the index as a desk of things you can pick up. You ask in plain words ("the youtube videos from last week"), the captures that match lie on the desk in piles, and you handle them: open a pile, lift one, turn it over, set it aside, pin it.

```sh
npm run build          # once, in desktop/: builds the page into ui/dist
hippo ui               # starts the server and opens the page in your browser
```

`hippo ui` builds the index first when it is empty. The server listens on 127.0.0.1 only, on port 4477 or the next free one (`--port` picks another). The address it prints holds a token that only that run knows; open that address, not the bare one. The page asks the model (the provider below) only when you ask a question or press Update; arranging, opening and lifting use no model. Update runs the same pass as `hippo enrich`. When that pass would send captures to the model, Update first says how many, to which provider, and how many files it would write into which folder, and waits for "Send and update". "Not now" sends and writes nothing. When nothing would go to the model, Update runs at once. The pass that runs is the one the question described: if the provider or model changed, or more captures arrived, in the meantime, Update asks again with the new numbers. Opening or saving Settings closes an open question.

To work on the page itself, run `hippo ui --dev` and `npm run dev` in `desktop/`. The page then comes from Vite on http://localhost:5177, which sends `/api` and `/media` to the server. If `hippo ui` had to take another port, start Vite as `HIPPO_PORT=<port> npm run dev`.

### Running it on your own folder

Replace `"<path>"` with the folder that holds `captures/`. The first `hippo enrich` is the first write into that folder: it adds one `enrichments/server/YYYY/MM/DD/<capture-id>/enrichment.json` per capture and nothing else (no assets, no log, no state file; the only other thing it does there is remove its own leftover temp files from an interrupted run), and it sends each capture's text and pictures to the provider you chose. Look first:

```sh
hippo enrich --dry-run --folder "<path>"   # lists what would be sent and written; writes nothing
hippo enrich                               # enriches, then updates the index
hippo ui
```

After that, each question you type into the desk goes to the provider to be turned into a search (see [Privacy](#privacy) for what it carries); the captures it finds come from the local index. The Update button on the desk runs the same pass as `hippo enrich`, and asks before it sends anything.

### Try it without a folder of your own

```sh
hippo sample --out ~/hippo-sample          # 300 invented captures, ending today
hippo ui --folder ~/hippo-sample --provider fake
```

The `fake` provider answers by simple rules and calls no model. It understands, among others: "show me the youtube videos", "no, actually it was a screenshot", "from last week", "in the car", "by place", "by time", "by topic", "by person" and "start over". A short run:

1. Ask "show me the youtube videos". The desk narrows to the YouTube links.
2. Ask "no, actually it was a screenshot". The correction replaces the kind and keeps the rest.
3. Ask "from last week". The time limit is added to the screenshots.
4. Press the Place button. The same captures lie on a map, and captures with no location sit in a "No location" pile beside it.
5. Press Undo until the desk shows everything again.

### Gestures

- **Open a pile:** click it. The pile fans out. Scroll to riffle through it. Escape, or a click outside, gathers it.
- **Lift:** click an item. It comes up to read. "Turn over" or F turns it to its back, which shows the details and the evidence behind each guess; "Turn back" returns. "Put back" or Escape sets it down.
- **Set aside:** throw an item toward an edge of the desk. Thrown items collect in a pile in a corner; open it and click one to take it back.
- **Pin:** drop an item with Shift held, or drop it on the "Maybe these" pile. A pinned item stays on the desk whatever you ask next.
- **Move:** drag an item to put it down somewhere else. Drag the empty desk to pan. The wheel, or a pinch on a trackpad, zooms toward the pointer.
- **Undo:** the Undo button, or Cmd/Ctrl+Z. It steps back one action at a time, newest first: a throw, a take-back, a pin or an unpin is undone before the question it was made under. "Start over" clears the desk and what you set aside.
- **Layouts:** the buttons at the top right arrange the same captures by kind, time, place, topic or person. Asking can change the layout too ("by place").
- **Ask bar:** Enter sends; Up and Down walk through earlier sentences; Escape clears it.

### Settings

The settings panel has the theme, the provider and the two model names (one for questions, one for enrichment), and map tiles. Saving writes the same config file the command line uses. It never shows or stores a key.

Map tiles come from OpenStreetMap, which then sees the area you are looking at. Turn "Map tiles" off and the place layout draws a plain sheet with the places as pins; nothing is fetched from outside this machine.

### When the model says it is not signed in

The desk shows the provider's message in the reply line, and nothing on the desk changes.

- `claude-cli` or `codex-cli`: run `claude` or `codex` once in a terminal and sign in there, then ask again. The desk uses whatever that command is signed in as.
- `Stopped early (unavailable): the claude command was not found on PATH` (or `the codex command ...`): the command is not on the PATH of the terminal you started `hippo` from. Install it or fix the PATH, then run again. Nothing was written for the captures that were not reached.
- API providers: set the key in the environment or in `desktop/.env` (see [Providers](#providers)) and restart `hippo ui`. The page never takes a key.
- To look around without a model, run `hippo ui --provider fake`.

## Recall from a coding agent

[`skills/hippo-recall/SKILL.md`](skills/hippo-recall/SKILL.md) teaches an agent that can run `hippo` to recall by association: read the vocabulary with `hippo facets --json`, turn the person's words into a spec, search, refine, and answer with titles, dates and file paths. It tells the agent never to run `hippo enrich`.

- **Claude Code:** copy the folder to your skills directory, `mkdir -p ~/.claude/skills && cp -R skills/hippo-recall ~/.claude/skills/`. Claude Code picks it up by its description when you ask it to find something you saved.
- **Codex:** paste the body of `SKILL.md` (below the front matter) into your `AGENTS.md`, or into the instructions of the project you work in.
- **GitHub Copilot:** paste the same text into `.github/copilot-instructions.md` or your custom instructions.

The agent needs the `hippo` command on its PATH (`npm link`) and an index built for the folder.

## Providers

The model provider is used by `hippo enrich` and the desk's Update button to describe captures, and by the desk to turn a question into a search. Pick one with `--provider`, or set `"provider"` in the config file.

| Provider | Uses | Needs |
|---|---|---|
| `claude-cli` (default) | The signed-in `claude` command, so a Claude subscription | `claude` on PATH, signed in |
| `codex-cli` | The signed-in `codex` command, so a ChatGPT plan | `codex` on PATH, signed in |
| `anthropic-api` | The Anthropic API | `ANTHROPIC_API_KEY` |
| `openai-compatible` | Any OpenAI-compatible chat completions endpoint (OpenAI, OpenRouter) | `OPENAI_BASE_URL`, `OPENAI_API_KEY`, and an explicit `--model` |
| `fake` | Canned answers | Nothing; for tests |

The default model is the `haiku` alias (the small fast model); change it with `--model` or `"enrichModel"` in the config file.

Capture text can hold pages other people wrote: shared articles, link descriptions, text read from screenshots. Such text could try to tell the model what to do. `claude-cli`, the default, runs with its tools off for text, and for pictures it may only read the picture thumbnails. `codex-cli` runs an agent that can read files on this Mac: its read-only sandbox stops it writing, not reading. For a folder that holds shared web content, use `claude-cli`. Whatever the provider answers, a summary is kept to 600 characters and a picture description to 1,200.

Keys come from the environment or from `desktop/.env`, which is gitignored: copy [`.env.example`](.env.example) to `.env` and fill in only the providers you use. A value set in the environment wins over the file. Keys are never written to the config file, the index or the folder. Keys from `.env` are not passed to the `claude` and `codex` commands, so they keep using the signed-in plan.

## Where things live

Nothing but enrichment documents is written into the Hippo folder. Everything else is in the app-data directory:

- macOS: `~/Library/Application Support/hippo-desk/`
- Windows: `%LOCALAPPDATA%\hippo-desk\`
- Linux: `$XDG_DATA_HOME/hippo-desk/` (default `~/.local/share/hippo-desk/`)
- Anywhere: set `HIPPO_DESK_HOME` to override it (the tests do).

In it:

- `config.json`: the remembered folder, provider, model and concurrency (default 3 calls at a time). No keys.
- `index-<hash>.sqlite`: the index for one folder (the hash is of the folder path). It also records enrichment failures, retried up to three times per capture. Delete it at any time and run `hippo index --rebuild` to get the same results back with no model call.
- `thumbs/`: a 256 px and a 1024 px JPEG of each picture, HEIC included, named by the picture's SHA-256.

In the folder, `hippo enrich` (and Update on the desk) writes one document per capture, `enrichments/server/YYYY/MM/DD/<capture-id>/enrichment.json` (layer `server`, producer `hippo-desk`, format 1.2), through a temp file in the same directory that is renamed into place. A document is rewritten only when its facets would change, so a second run uploads nothing. Facets it owns: `summary`, `tags`, `display`, `image_description`, `people`, `circumstance`, and `hippo_desk_state`. Facets from other producers are kept as found.

### The `hippo_desk_state` facet

A private bookkeeping facet, not part of the enrichment format, which the phone ignores:

```json
"hippo_desk_state": { "version": 1, "status": "ok", "generated_at": "…", "provenance": "hippo-desk",
  "data": { "input_digest": "<sha256 hex>", "prompt_version": 1 } }
```

`input_digest` is a SHA-256 over exactly what the model was shown for the capture (its text fields, the hash of each picture sent, comment ids and text) plus the prompt version. On the next run the enricher computes the digest again and calls the model only when it differs or `prompt_version` changed. Because the facet lives in the folder, a rebuilt index or a second computer knows the capture is already enriched without calling the model. A server document without it, or with another digest, counts as not enriched.

## Privacy

What leaves this machine, and when:

- **Enrichment** (`hippo enrich`, or Update on the desk) sends each capture's text and pictures (as JPEGs no larger than 1024 px) to the chosen model provider, and writes one `enrichment.json` per capture into the folder. That is the same exposure as pointing an agent at the folder. A note's body, transcripts, text read from pictures and link descriptions are each cut to 6,000 characters before they are sent. With `claude-cli`, the prompt also names the picture files by their absolute paths in the app-data directory, and those paths hold your Mac user name.
- **Update on the desk** is the same pass as `hippo enrich`. Before it sends anything it asks, with the number of captures, the provider and the folder; "Not now" sends nothing.
- **A question typed into the desk** sends the question, the last few questions and replies, today's date and time zone, the current search, and the folder's vocabulary: its topics, tags, people's names, sites, places and circumstance labels, each with a count. It sends no capture text and no pictures.
- **Map tiles**, when on, ask openstreetmap.org for the map of the area you are looking at (see [Settings](#settings)).

Run `hippo enrich --dry-run` first to see which captures would be sent and which documents written. The first enrichment of a real folder, which is also the first write into it, is for the folder's owner to start.

Development and tests run only on temporary copies of `fixtures/packages`, never on the tracked fixtures and never on a real folder.

## Development

```sh
npm test            # node --test over test/**/*.test.ts and ui/test/**/*.test.ts
npm run typecheck   # tsc --noEmit for the server, the page (ui/) and the browser test (e2e/)
npm run build       # builds the page into ui/dist
npm run e2e         # the browser test (Playwright, headless Chromium)
```

`npm run e2e` needs the browser once: `npx playwright install chromium`. It writes a 120-capture sample folder to a temp directory with its own `HIPPO_DESK_HOME` (map tiles off), builds the page, starts the server on a free port with the fake provider, asks three questions and checks which captures came back, undoes them, lifts and turns over one item, checks that the server refuses a request with no token, and checks that Update asks before it sends captures to the model ("Not now" sends nothing, "Send and update" runs the pass). No test may reach a host other than this machine. It removes everything it made. `test-results/` and `playwright-report/` are git-ignored. `npm test` does not run it.
