# Hippo Desk (desktop)

The desktop side of Hippo. It reads a synced Hippo folder, enriches each capture with a model (title, summary, tags, topic, people, picture descriptions) and rules (likely circumstances such as "in the car"), keeps a local index of everything, and lets you or a coding agent recall captures by association from the command line.

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

`hippo enrich` is the only command that calls a model and the only one that writes into the folder. Starting it on a real folder is a decision for the folder's owner (see [Privacy](#privacy)).

## Commands

| Command | What it does |
|---|---|
| `hippo enrich [--folder <path>] [--dry-run] [--no-model] [--limit n] [--provider name] [--model name]` | One pass over the folder. For each complete capture: works out the likely circumstances by rules, calls the model when what it would be shown has changed, and writes the capture's server enrichment document if its content differs. Then runs the index step. `--dry-run` lists the captures it would send to the model and the documents it would write, and does neither. `--no-model` writes only the rule-made circumstances. `--limit n` makes at most n model calls and leaves the rest for the next run. Ctrl-C finishes the calls in flight and stops; a second Ctrl-C quits at once. Exit code 3 when it stopped early (usage limit, not signed in, provider unavailable), 130 when interrupted. |
| `hippo index [--folder <path>] [--rebuild]` | Builds or updates the local index and thumbnails from the folder. No model, nothing written into the folder. `--rebuild` starts from empty tables. |
| `hippo status [--folder <path>]` | Captures by kind, how many are enriched, captures not yet complete in the folder (still syncing), enrichment failures, last runs. |
| `hippo search [filters] [--json]` | Finds captures. See [Search](#search). |
| `hippo show <id> [--json]` | Everything about one capture: every field, the evidence behind each circumstance, and the absolute path of every file (originals, comment audio, thumbnails). Takes a whole id or a unique prefix of 8 or more characters. |
| `hippo facets [--json]` | The vocabulary: kinds with counts, every topic, tag, person, site, locality and circumstance label with counts, and the date range. |

Every command takes `--folder <path>`; without it the remembered folder is used. Exit code 2 means a usage error (an unknown flag or a bad value, named in the message).

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

## Recall from a coding agent

[`skills/hippo-recall/SKILL.md`](skills/hippo-recall/SKILL.md) teaches an agent that can run `hippo` to recall by association: read the vocabulary with `hippo facets --json`, turn the person's words into a spec, search, refine, and answer with titles, dates and file paths. It tells the agent never to run `hippo enrich`.

- **Claude Code:** copy the folder to your skills directory, `mkdir -p ~/.claude/skills && cp -R skills/hippo-recall ~/.claude/skills/`. Claude Code picks it up by its description when you ask it to find something you saved.
- **Codex:** paste the body of `SKILL.md` (below the front matter) into your `AGENTS.md`, or into the instructions of the project you work in.
- **GitHub Copilot:** paste the same text into `.github/copilot-instructions.md` or your custom instructions.

The agent needs the `hippo` command on its PATH (`npm link`) and an index built for the folder.

## Providers

The model provider is used by `hippo enrich` only. Pick one with `--provider`, or set `"provider"` in the config file.

| Provider | Uses | Needs |
|---|---|---|
| `claude-cli` (default) | The signed-in `claude` command, so a Claude subscription | `claude` on PATH, signed in |
| `codex-cli` | The signed-in `codex` command, so a ChatGPT plan | `codex` on PATH, signed in |
| `anthropic-api` | The Anthropic API | `ANTHROPIC_API_KEY` |
| `openai-compatible` | Any OpenAI-compatible chat completions endpoint (OpenAI, OpenRouter) | `OPENAI_BASE_URL`, `OPENAI_API_KEY`, and an explicit `--model` |
| `fake` | Canned answers | Nothing; for tests |

The default model is the `haiku` alias (the small fast model); change it with `--model` or `"enrichModel"` in the config file.

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

In the folder, `hippo enrich` writes one document per capture, `enrichments/server/YYYY/MM/DD/<capture-id>/enrichment.json` (layer `server`, producer `hippo-desk`, format 1.2), through a temp file in the same directory that is renamed into place. A document is rewritten only when its facets would change, so a second run uploads nothing. Facets it owns: `summary`, `tags`, `display`, `image_description`, `people`, `circumstance`, and `hippo_desk_state`. Facets from other producers are kept as found.

### The `hippo_desk_state` facet

A private bookkeeping facet, not part of the enrichment format, which the phone ignores:

```json
"hippo_desk_state": { "version": 1, "status": "ok", "generated_at": "…", "provenance": "hippo-desk",
  "data": { "input_digest": "<sha256 hex>", "prompt_version": 1 } }
```

`input_digest` is a SHA-256 over exactly what the model was shown for the capture (its text fields, the hash of each picture sent, comment ids and text) plus the prompt version. On the next run the enricher computes the digest again and calls the model only when it differs or `prompt_version` changed. Because the facet lives in the folder, a rebuilt index or a second computer knows the capture is already enriched without calling the model. A server document without it, or with another digest, counts as not enriched.

## Privacy

Enrichment sends a capture's text and pictures (as JPEGs no larger than 1024 px) to the chosen model provider. That is the same exposure as pointing an agent at the folder. Run `hippo enrich --dry-run` first to see which captures would be sent and which documents written. The first `hippo enrich` on a real folder, which is also the first write into it, is for the folder's owner to start.

Development and tests run only on temporary copies of `fixtures/packages`, never on the tracked fixtures and never on a real folder.

## Development

```sh
npm test            # node --test over test/**/*.test.ts
npm run typecheck   # tsc --noEmit
```
