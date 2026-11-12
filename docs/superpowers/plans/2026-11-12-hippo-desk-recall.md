# Hippo Desk (recall on the desktop) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Node app in `desktop/` that enriches the synced Hippo folder (`hippo enrich`), answers recall questions in text (`hippo search`) and on a three.js desk (`hippo ui`), plus the phone showing the new server enrichment with a switch per tier.

**Architecture:** Four parts in order. A: format 1.2 (four new facet kinds) in documents, schema, fixture and Swift types. B: the desktop core, enricher, index, recall and local server, all testable from the command line. C: the desk page, which talks only to the local server. D: the phone's details screen. C and D depend on A and B's interfaces only, not on each other.

**Tech Stack:** TypeScript on Node 22.23 run directly (type stripping, no build), `node:sqlite` with FTS5 (confirmed present), `node --test`, `sharp` + `heic-decode` for thumbnails, `ajv` (draft 2020-12) in tests, Vite + three.js for the page, `@playwright/test` for one browser test, npm as package manager. Swift 6.2 / Swift Testing in `HippoKit`, SwiftUI in `App/Hippo`.

**Spec:** `docs/superpowers/specs/2026-11-12-hippo-desk-recall-design.md` (read it with this plan; section numbers below refer to it).

## Global Constraints

- Branch `feat/desktop-recall`. Commit per task. Never push. Commit messages end with the two attribution lines given in the session.
- Before every commit run `git diff --cached` and read all of it; stop and report if it holds a key, token, password, connection string, or personal data (email, phone, home address). Never read or touch the repo-root `.env`.
- Privacy: tests and development runs use only copies of `fixtures/packages` (copied to a temp dir) and folders made by `hippo sample`. Never write under the tracked `fixtures/` except through `hippo-fixtures` in Task A1. Never run `hippo enrich` or `hippo index` against Jorge's real Dropbox folder.
- The only thing the desktop app may write inside a Hippo folder is `enrichments/server/YYYY/MM/DD/<capture-id>/enrichment.json` (plus its temp file during the atomic replace, removed afterwards). No assets, no state file, no log.
- Index database and thumbnails live in the app-data directory: `~/Library/Application Support/hippo-desk/` on macOS, `%LOCALAPPDATA%\hippo-desk\` on Windows; the environment variable `HIPPO_DESK_HOME` overrides it (tests always set it to a temp dir).
- Node code uses only erasable TypeScript syntax (no `enum`, no parameter properties, no namespaces) and imports with explicit `.ts` extensions. No shell when spawning commands (`spawn` with an argument array), paths built with `node:path`, so it can run on Windows.
- Keys come only from the environment or a gitignored `.env`; the config file and the database never hold one.
- Format rules that every reader and writer here follows (`docs/package-format.md`, `docs/enrichment-format.md`): reject `schema_version` other than 1; accept any `schema_minor`; ignore unknown keys; omit unknown fields (never `null`, never empty string or empty array); timestamps are RFC 3339 UTC with milliseconds and `Z`; a capture is complete only when `complete.json` exists and every manifest file matches by size and SHA-256; package digest is the SHA-256 (lower-case hex) of the exact bytes of `complete.json`.
- Kinds: exactly `link`, `photo`, `screenshot`, `note`, `recording`, `video`, `file`. Circumstance labels: `in_car`, `walking`, `running`, `cycling`, `on_headphones`, `in_a_burst`, `daylight`, `dark`. Confidence: `low`, `medium`, `high`. Layouts: `kind`, `time`, `place`, `topic`, `person`.
- Shell notes for this machine: use `/bin/ls`; quote globs in zsh; do not run `find` over the whole repo.
- Swift tests: `make test`. Node tests: `cd desktop && npm test`. Fixture schema check: `scripts/validate-fixtures.sh`.

## Review Focus

Each line names the task whose tests pin it.

1. A half-synced capture (no `complete.json`, or a manifest file missing or with a different hash) and a folder path containing spaces: the capture is counted as pending and skipped, the pass continues, nothing is written for it. (Task B1)
2. Model output that breaks the contract (title over 60 characters, upper-case or too many tags, a description for an attachment id the capture does not have, an empty topic, a person with no source): it is clamped, normalised or dropped, and the document written still validates against the schema. (Task B5)
3. Search text containing quotes, `*`, `:`, `-`, parentheses or the words `AND`/`OR`/`NOT`: the search runs and matches literally, with no database error. (Task B7)
4. Dates are the capture's own local date, not the Mac's: a capture taken at 23:30 in `Europe/Lisbon` is found by that Lisbon date when the Mac is in `America/Los_Angeles`. (Tasks B2, B7)
5. An empty result, and items with no location in the place layout: the desk shows an empty-state line and the unlocated items sit in a "No location" pile beside the map, never at 0,0 and never dropped. (Tasks C1, C2)

---

## Part A: format 1.2

### Task A1: Format 1.2 documents, schema, Swift types and server fixture

**Files:**
- Modify: `docs/enrichment-format.md` (title to 1.2; new section "Facet kinds added in format 1.2"; `schema_minor` row says 1.2 writes `2`), `docs/package-format.md` (title, "This document is version 1.2", version table row), `docs/folder-readme.md` (server layer paragraph: who writes it and the kinds a reader will find), `docs/context-signals.md` (one sentence: readers may publish conclusions as the `circumstance` facet; the phone still records only facts)
- Modify: `schema/enrichment-v1.schema.json` (`$defs` `displayData`, `imageDescriptionData`, `peopleData`, `circumstanceData`, wired the same way the 1.1 kinds are wired in `allOf`)
- Modify: `HippoKit/Sources/CaptureCore/Enrichment/EnrichmentDocument.swift` (four `FacetKind` constants), `HippoKit/Sources/CaptureCore/Enrichment/FacetData.swift` (four payload types), `HippoKit/Sources/CaptureCore/Model/FormatVersion.swift` (`minor = 2`)
- Modify: `HippoKit/Sources/hippo-fixtures/main.swift` (new mode `server <root>`; the `context` mode pins minor 1 so package 7 stays byte-identical), `fixtures/README.md`
- Create (generated): `fixtures/packages/enrichments/server/2026/11/07/00000000-0000-4000-8000-000000000007/enrichment.json`
- Test: `HippoKit/Tests/CaptureCoreTests/EnrichmentFormatTests.swift`, `FixtureTests.swift`, `FormatVersionTests.swift`

**Interfaces:**
- Produces (JSON, snake_case; every field optional unless marked required):
  - `display`: `{title: string ≤ 60, topic: string, keywords: [{word: string (required), weight: number 0–1 (required)}] ≤ 12}`
  - `image_description`: `{items: [{attachment_id (required), text (required)}]}`
  - `people`: `{items: [{name (required), source (required: "user_note" | "shared_text" | "shared_title" | an attachment id | a comment id)}]}`
  - `circumstance`: `{items: [{label (required, open set), confidence (required: "low" | "medium" | "high", open set), evidence: [string]}]}`
- Produces (Swift, `CaptureCore`): `FacetKind.display`, `.imageDescription`, `.people`, `.circumstance`; `DisplayData {title: String?, topic: String?, keywords: [DisplayKeyword]?}`, `DisplayKeyword {word: String, weight: Double}`, `ImageDescriptionData {items: [ImageDescriptionItem]}`, `ImageDescriptionItem {attachmentID: String, text: String}`, `PeopleData {items: [PersonItem]}`, `PersonItem {name: String, source: String}`, `CircumstanceData {items: [CircumstanceItem]}`, `CircumstanceItem {label: String, confidence: String, evidence: [String]?}`. All `Codable, Sendable, Equatable`, public memberwise inits, coding keys in the style of the neighbouring types.
- Produces: the server fixture for capture 7, producer `hippo-fixtures`, `schema_minor: 2`, `generated_at` `2026-11-07T18:00:00.000Z`, `package_digest` of package 7's `complete.json`, facets:
  - `summary` `{text: "A cafe menu with a QR code for the specials."}`, provenance `server_model`
  - `tags` `{values: ["cafe", "menu", "food"]}`
  - `display` `{title: "Cafe menu with specials code", topic: "food", keywords: [{word: "menu", weight: 1}, {word: "cafe", weight: 0.8}, {word: "specials", weight: 0.6}]}`
  - `image_description` one item for attachment `00000000-0000-4000-8000-000700000001`: `"A printed cafe menu photographed on a table, with a QR code in the lower corner."`
  - `people` `{items: [{name: "Ana", source: "user_note"}]}` (invented; the note does not name her, the fixture only shows the shape, say so in `fixtures/README.md`)
  - `circumstance` provenance `rules`: `in_car` `high` evidence `["audio route was CarPlay", "motion at capture was automotive", "speed was 11.2 m/s"]`; `in_a_burst` `medium` evidence `["previous capture was 60 s earlier"]`; `daylight` `high` evidence `["weather lookup says daytime"]`

- [ ] **Step 1: Write the failing Swift tests**

In `EnrichmentFormatTests.swift` add `newKindsDecode` (decode the JSON shapes above into the four payload types and compare field by field; a payload with an extra unknown key still decodes; `CircumstanceItem` with no `evidence` decodes with `evidence == nil`). In `FormatVersionTests.swift` change the expectation to `FormatVersion.minor == 2`. In `FixtureTests.swift` add `serverFixtureCarriesEveryNewKind`: the document at the path above decodes, `schemaMinor == 2`, `layer == .server`, its `packageDigest` equals the SHA-256 of package 7's `complete.json`, and each of `.summary, .tags, .display, .imageDescription, .people, .circumstance` is present with status `ok`; the circumstance labels are exactly `["in_car", "in_a_burst", "daylight"]`. Keep `legacyFixturesHaveNoMinor` and `contextFixtureCarriesEverySignal` passing unchanged (package 7 and its device enrichment still carry minor 1).

- [ ] **Step 2: Run `make test`; expect the new tests to fail to compile or fail.**

- [ ] **Step 3: Add the kinds, payload types and `minor = 2`; make the `context` fixture mode pass `schemaMinor: 1` explicitly wherever it used `FormatVersion.minor`; add the `server` mode (`hippo-fixtures server <root>`, writes only the one file above, sorted keys like the other modes).**

Other tests that asserted a written minor of 1 for freshly written packages, comments or device enrichment move to 2. If more than about ten test files need changing, stop and report before continuing (spec section 12).

- [ ] **Step 4: Generate the fixture and check stability**

Run: `swift run --package-path HippoKit hippo-fixtures server fixtures/packages && git status --short fixtures/` — expect exactly one new file. Run it again: `git status` unchanged. Run `swift run --package-path HippoKit hippo-fixtures context fixtures/packages`: `git status --short fixtures/` still shows only the new file.

- [ ] **Step 5: Update the schema and the four documents.**

In `docs/enrichment-format.md` each new kind gets a subsection in the style of the 1.1 kinds: shape table, who writes it (a server-layer producer; by convention gold only), provenance (`rules` for `circumstance`, a model name for the others), and for `circumstance` the sentence "A conclusion, never a fact: show it as likely, with its evidence." State that a reader shows an unknown `label` as written. Version table row in `docs/package-format.md`: `| 1.2 | 2026-11-12 | The server facet kinds \`display\`, \`image_description\`, \`people\`, \`circumstance\`. Packages are unchanged. |`.

- [ ] **Step 6: Run `make test` and `scripts/validate-fixtures.sh`; both pass. Also confirm the schema rejects a `circumstance` item with no `label` (one throwaway `uvx check-jsonschema` run on a temp file; do not commit the temp file).**

- [ ] **Step 7: Commit** (`feat(format): format 1.2 adds display, image_description, people, circumstance`).

---

## Part B: desktop core, enricher, index, recall, server

Shared conventions for Part B tests: each test file copies `fixtures/packages` into `fs.mkdtempSync(...)` through a helper `copyFixtures(): string` in `desktop/test/helpers.ts` and sets `HIPPO_DESK_HOME` to another temp dir. No test reads or writes outside temp dirs. Fixture ids are written `…0001` to `…0007` below, meaning `00000000-0000-4000-8000-00000000000N`.

### Task B1: Scaffold `desktop/` and the folder reader

**Files:**
- Create: `desktop/package.json` (`"type": "module"`, `"engines": {"node": ">=22.18"}`, `"bin": {"hippo": "bin/hippo.mjs"}`, scripts `test` = `node --test "test/**/*.test.ts"`, `typecheck` = `tsc --noEmit`), `desktop/tsconfig.json` (`noEmit`, `strict`, `allowImportingTsExtensions`, `erasableSyntaxOnly`, `module` and `moduleResolution` `nodenext`), `desktop/.gitignore` (`node_modules/`, `ui/dist/`, `.env*`, `test-results/`), `desktop/bin/hippo.mjs` (plain JS, imports `../src/cli.ts`), `desktop/src/cli.ts` (command table; unknown command prints usage and exits 2)
- Create: `desktop/src/core/types.ts`, `desktop/src/core/paths.ts`, `desktop/src/core/folder.ts`, `desktop/test/helpers.ts`
- Test: `desktop/test/folder.test.ts`

**Interfaces:**
- Produces (`core/types.ts`):

```ts
export type Kind = 'link' | 'photo' | 'screenshot' | 'note' | 'recording' | 'video' | 'file';
export type Confidence = 'low' | 'medium' | 'high';
export interface Facet { version: number; status: string; generated_at: string; provenance: string; data?: unknown; [k: string]: unknown }
export interface EnrichmentDoc { schema_version: 1; schema_minor?: number; capture_id: string; layer: 'device' | 'server';
  package_digest: string; producer: { name: string; version: string; build: string }; generated_at: string;
  facets: Record<string, Facet>; [k: string]: unknown }
export interface CommentFile { id: string; added_at: string; text?: string; audioPath?: string }   // audioPath absolute
export interface RawCapture {
  id: string; dir: string;               // absolute capture directory
  datePath: string;                      // "2026/11/07"
  metadata: Record<string, any>;         // metadata.json as parsed
  packageDigest: string;
  noteBody?: string;                     // text of a typed note's text attachment
  comments: CommentFile[];               // sorted by added_at
  device?: EnrichmentDoc; deviceDir?: string;   // deviceDir holds verified assets
  server?: EnrichmentDoc; serverPath: string;   // where the server document is or would be
  serverUnreadable?: string;             // set when a server file exists and cannot be parsed or is not schema_version 1
}
export interface FolderScan { captures: RawCapture[]; pending: { id: string; reason: string }[] }
```

- Produces (`core/folder.ts`): `scanFolder(folder: string): Promise<FolderScan>` (captures sorted by `captured_at`), `readCapture(folder: string, datePath: string, id: string): Promise<RawCapture | { pending: string }>`, `sha256File(path: string): Promise<string>`, `assetPath(c: RawCapture, ref: { relative_path: string; byte_count: number; sha256: string }): Promise<string | undefined>` (absolute path only when size and hash match and the relative path stays inside `deviceDir`).
- Produces (`core/paths.ts`): `homeDir(): string`, `interface Config { folder?: string; provider: string; enrichModel: string; askModel: string; concurrency: number; mapTiles: boolean; theme: string }`, `loadConfig(): Config` (defaults `claude-cli`, `haiku`, `haiku`, `3`, `true`, `desk`), `saveConfig(c: Config): void`, `resolveFolder(flag?: string): string` (the flag, else the remembered one, else an error telling the person to pass `--folder`; a given flag is remembered), `indexPath(folder: string): string` (`<home>/index-<first 12 hex of sha256(absolute folder path)>.sqlite`), `thumbsDir(): string`.

- [ ] **Step 1: Write the failing tests** in `folder.test.ts`:

```ts
test('reads the seven fixture captures in time order', async () => {
  const s = await scanFolder(copyFixtures());
  assert.equal(s.captures.length, 7); assert.equal(s.pending.length, 0);
  assert.deepEqual(s.captures.map(c => c.id.slice(-1)), ['1','2','3','4','5','6','7']);
  const c2 = s.captures[1];
  assert.equal(c2.packageDigest, 'dcb65caedf824a4442f61c2aba5495f3cf04eeac0a84af3796fa8491fae4c04f');
  assert.equal(c2.server?.producer.name, 'hippo-fixtures'); assert.ok(c2.device);
  assert.equal(s.captures[3].comments.length, 2);
  assert.equal(s.captures[3].comments[0].text, 'Bought this one.');
  assert.ok(s.captures[3].comments[1].audioPath?.endsWith('.m4a'));
  assert.ok(s.captures[0].noteBody && s.captures[0].noteBody.length > 0);
});
```

Further tests, one each: a folder path containing a space works; deleting `complete.json` from capture 3 puts it in `pending` with reason `incomplete` and leaves 6 captures; appending one byte to capture 3's PNG gives reason `changed`; setting `schema_version` to 2 in capture 5's `complete.json` gives reason `unsupported version`; a server `enrichment.json` holding `{not json` sets `serverUnreadable` and still returns the capture; `assetPath` returns a path for capture 2's link thumbnail and `undefined` after the asset file is truncated; `indexPath` differs for two folders and sits under `HIPPO_DESK_HOME`.

- [ ] **Step 2: `cd desktop && npm install -D typescript @types/node && npm test`; expect failures (modules missing).**
- [ ] **Step 3: Implement `paths.ts`, `folder.ts`, `cli.ts`, `bin/hippo.mjs`.** Device and server documents are found by replacing `captures` with `enrichments/<layer>` in the capture's path. A device document with a different `package_digest` than the package is ignored.
- [ ] **Step 4: `npm test` and `npm run typecheck` pass; `node bin/hippo.mjs nonsense` exits 2 with usage.**
- [ ] **Step 5: Commit** (`feat(desktop): scaffold and folder reader`), including `package-lock.json`.

### Task B2: The capture record (everything derived without a model)

**Files:**
- Create: `desktop/src/core/record.ts`, `desktop/src/core/resolve.ts` (the format's override rule), `desktop/src/core/circumstance.ts`
- Test: `desktop/test/record.test.ts`, `desktop/test/circumstance.test.ts`

**Interfaces:**
- Consumes: `RawCapture`, `assetPath` (B1).
- Produces (`core/record.ts`):

```ts
export interface Circumstance { label: string; confidence: Confidence; evidence: string[] }
export interface AttachmentRef { id: string; type: 'picture' | 'audio' | 'video' | 'file' | 'text';
  path: string; uti: string; name?: string; sha256: string; byteCount: number; durationSeconds?: number;
  isSpokenComment?: boolean }
export interface CommentRef { id: string; added_at: string; text?: string; audioPath?: string; transcript?: string }
export interface CaptureRecord {
  id: string; kind: Kind; method: string;
  captured_at: string; timezone: string; local_date: string; local_time: string;   // "2026-11-07", "09:07"
  weekday: 'mon'|'tue'|'wed'|'thu'|'fri'|'sat'|'sun'; part_of_day: 'morning'|'afternoon'|'evening'|'night';
  title: string; summary?: string; topic?: string; tags: string[];
  people: { name: string; source: string }[]; keywords: { word: string; weight: number }[];
  image_descriptions: { attachment_id: string; text: string }[];
  circumstances: Circumstance[];
  text: string;                          // everything searchable, newline-joined (spec section 5 "Text")
  body?: string;                         // what the opened item shows: note text or first transcript
  urls: string[]; site?: string; source_app?: string;
  link?: { url: string; title?: string; site_name?: string; channel?: string; description?: string; thumbPath?: string };
  place?: { lat: number; lon: number; accuracy_m?: number; locality?: string; sub_locality?: string; nearby?: string };
  attachments: AttachmentRef[]; comments: CommentRef[];
  has: ('picture' | 'audio' | 'comment' | 'location' | 'link')[];
  context: Record<string, unknown>;      // the raw context.* observation values and location extras, for the back of the item
  enriched: boolean;                     // server document carries display from producer hippo-desk
}
export function buildRecord(c: RawCapture): Promise<CaptureRecord>
export function deriveKind(c: RawCapture): Kind
```

- Produces (`core/circumstance.ts`): `deriveCircumstances(c: RawCapture): Circumstance[]` (reads only the raw capture and the device document, never the server one).
- Produces (`core/resolve.ts`): `resolved(c: RawCapture)` returning link previews by url, places by target, recognized text and transcripts by attachment id, summary, tags, source app, and the four 1.2 kinds, with gold winning per item and per field only when the gold facet is `ok` and the field is present and non-blank.

Rules the tests pin:
- Kind precedence exactly as spec section 5. `site` is the first URL's host without a leading `www.`. Local fields use the capture's `timezone_identifier` (fall back to `utc_offset_seconds`), never the machine's zone. Part of day by local hour: 5–11 morning, 12–16 afternoon, 17–21 evening, otherwise night.
- Title, first non-blank of: `display.title`; resolved link title; `shared_title`; first line of the note body (cut at 60 characters on a word boundary, with `…`); first eight words of the first transcript; the first attachment's original filename; then `"<Kind> · <local_date>"`.
- `circumstances`: the server document's `circumstance` facet is ignored; the record always carries `deriveCircumstances(c)`.

Circumstance rules (each returns nothing when its inputs are absent):

| Label | Evidence and confidence |
|---|---|
| `in_car` | Signals: (a) an audio output with `port_type` `car_audio` → "audio route was <port_name or car audio>"; (b) `motion_activity.at_capture.activities` contains `automotive` → "motion at capture was automotive"; (c) `capture_location.speed_meters_per_second` > 3 → "speed was <x> m/s" (one decimal). `high` when (a), or (b) with motion confidence `high`, or any two signals; `medium` when (b) alone; `low` when (c) alone. Speed alone above 3 with `walking`, `running` or `cycling` at capture yields no `in_car` |
| `walking`, `running`, `cycling` | `at_capture.activities` contains it → "motion at capture was <activity>"; confidence is the motion sample's confidence |
| `on_headphones` | An output with `port_type` `headphones` or `bluetooth_le` → `high`, "audio route was <port_name>"; `bluetooth_a2dp` or `bluetooth_hfp` → `medium`, unless (a) of `in_car` holds, then none |
| `in_a_burst` | `context.burst.seconds_since_previous` < 60 → `high`; < 180 → `medium`; evidence "previous capture was <n> s earlier" |
| `daylight` / `dark` | `weather` facet `ok` with `is_day` true / false → `high`, "weather lookup says daytime" / "weather lookup says night" |

- [ ] **Step 1: Write the failing tests.** `record.test.ts`: kinds of fixtures 1 to 7 are `note, link, photo, photo, video, recording, screenshot`; capture 7's audio attachment has `isSpokenComment === true` and `has` includes `picture`, `audio`, `location`; capture 2's title is `"Example Domain (server)"` (gold link title wins) and `site === 'example.com'`; capture 4 `has` includes `comment` and `link` and its `text` contains `Bought this one.` and `Trail for next weekend`; capture 1 `local_date === '2026-11-07'`, `local_time === '09:01'`, `weekday === 'sat'`, `part_of_day === 'morning'`; a synthetic capture with `captured_at` `2026-11-07T23:30:00.000Z` and zone `Europe/Lisbon` has `local_date` `2026-11-07`, and one at `2026-11-08T07:30:00.000Z` in `America/Los_Angeles` has `2026-11-07`, `part_of_day` `night`; a typed note whose text holds a URL stays `note`; with the Task A1 server fixture present capture 7 has `topic === 'food'`, one image description, `enriched === false` (producer is not `hippo-desk`). `circumstance.test.ts`: capture 7 yields `in_car` `high` with evidence including `audio route was CarPlay` and `speed was 11.2 m/s`, `in_a_burst` `medium` (60 s), `daylight` `high`, and no `on_headphones`; capture 1 yields `[]`; one synthetic case per table row, including speed 9 with `cycling` giving `cycling` and no `in_car`, and a `failed` weather facet giving neither `daylight` nor `dark`.
- [ ] **Step 2: `npm test`; expect failures.**
- [ ] **Step 3: Implement `resolve.ts`, `circumstance.ts`, `record.ts`.**
- [ ] **Step 4: `npm test` and `npm run typecheck` pass.**
- [ ] **Step 5: Commit** (`feat(desktop): capture record, override rule, circumstance rules`).

### Task B3: Providers and configuration

**Files:**
- Create: `desktop/src/providers/types.ts`, `fake.ts`, `claude-cli.ts`, `codex-cli.ts`, `anthropic-api.ts`, `openai-compatible.ts`, `index.ts`, `desktop/src/core/env.ts` (reads `desktop/.env` and the process environment; never logs a value), `desktop/.env.example` (placeholders only: `ANTHROPIC_API_KEY=`, `OPENAI_API_KEY=`, `OPENAI_BASE_URL=`)
- Test: `desktop/test/providers.test.ts`

**Interfaces:**
- Produces:

```ts
export interface ModelRequest { system: string; prompt: string; images?: string[]; schema: object; model: string; timeoutMs?: number }
export type ProviderErrorCode = 'usage_limit' | 'not_signed_in' | 'timeout' | 'bad_output' | 'unavailable' | 'failed';
export class ProviderError extends Error { code: ProviderErrorCode; constructor(code: ProviderErrorCode, message: string) }
export interface Provider { name: string; complete(req: ModelRequest): Promise<{ value: unknown; model: string }> }
export function makeProvider(name: string, env?: Record<string, string | undefined>): Provider   // throws ProviderError('unavailable') for an unknown name
export function fakeProvider(handler?: (req: ModelRequest) => unknown): Provider   // default handler: see Task B5 and B8
```

- `claude-cli`: flags exactly as spec section 6, working directory a fresh empty temp dir, command resolved by searching `PATH` (also `claude.cmd`/`claude.exe` on Windows) and spawned without a shell; with images adds `--tools Read --add-dir <dir of each image> --permission-mode dontAsk` and lists the absolute paths in the prompt; reads `structured_output` from the JSON result. Never `--bare`. Default timeout 120 s. A result whose text mentions a usage or rate limit maps to `usage_limit`; "not logged in" style output to `not_signed_in`; missing command to `unavailable`; unparsable output or missing `structured_output` to `bad_output`.
- `codex-cli`: `codex exec` non-interactive with an output schema file and images; confirm the exact flags with `codex exec --help` (codex-cli 0.166.0 is installed) before writing it.
- `anthropic-api` and `openai-compatible`: plain `fetch`, structured output through the provider's documented mechanism, pictures as base64 JPEG. Take model ids from the provider's current documentation (for Anthropic, load the `claude-api` skill); when the configured model is the alias `haiku`, `anthropic-api` maps it to the current small model id. `openai-compatible` requires `OPENAI_BASE_URL`, `OPENAI_API_KEY` and an explicit model name, else `unavailable` naming what is missing.

- [ ] **Step 1: Write the failing tests.** With a stub executable written to a temp dir and put first on `PATH` (a small Node script named `claude` that prints its argv and a canned JSON result): the argument list contains every flag from spec section 6 and not `--bare`; the working directory is empty and is not the repo; `structured_output` is returned as `value`; with `images` the three image flags appear and the prompt names the path; a stub printing `{"is_error":true,"result":"You've hit your usage limit"}` raises `usage_limit`; a stub that sleeps past `timeoutMs: 200` raises `timeout` and the child is killed; no `claude` on `PATH` raises `unavailable`. `anthropic-api` with no key raises `unavailable` and the message does not contain an environment value. `fakeProvider(h)` returns `h(req)`. `env.ts` parses `KEY=value`, quoted values and comments, and process environment wins over the file.
- [ ] **Step 2: `npm test`; expect failures.**
- [ ] **Step 3: Implement the providers and `env.ts`.**
- [ ] **Step 4: `npm test` passes. Then one live check of `claude-cli` on invented text only** (`node -e` calling `makeProvider('claude-cli').complete({system: 'Reply in JSON.', prompt: 'Name one fruit.', schema: {type:'object',properties:{fruit:{type:'string'}},required:['fruit']}, model: 'haiku'})`): prints an object with `fruit`. Record the wall time in the commit body. If the live call fails for sign-in reasons, report it and continue; the tests are the gate.
- [ ] **Step 5: Commit** (`feat(desktop): model providers`).

### Task B4: Thumbnails

**Files:**
- Create: `desktop/src/index/thumbs.ts`
- Test: `desktop/test/thumbs.test.ts`

**Interfaces:**
- Produces: `ensureThumbs(srcPath: string, sha256: string): Promise<{ display: string; small: string }>` writing `<thumbsDir()>/<sha256>-1024.jpg` and `-256.jpg` (long side at most 1024 / 256, never enlarged, EXIF orientation applied, JPEG quality 82), skipping work when both exist; throws `Error` with a message naming the file's type when it cannot decode. HEIC and HEIF go through `heic-decode` to raw pixels, then `sharp`; everything else straight through `sharp`.

- [ ] **Step 1: Write the failing tests:** capture 3's PNG yields two JPEG files whose long sides are ≤ 1024 and ≤ 256 (read back with `sharp().metadata()`); capture 7's 1170 x 2532 PNG yields 473 x 1024 (±1) and 118 x 256 (±1); a second call does not rewrite the files (same mtime); a file of random bytes named `.heic` rejects with a message containing `heic`; a real HEIC made in the test with `sips -s format heic <png> --out <tmp>.heic` (skip the test when `sips` is absent) yields both sizes.
- [ ] **Step 2: `npm install sharp heic-decode && npm test`; expect failures.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: `npm test` passes.**
- [ ] **Step 5: Commit** (`feat(desktop): thumbnails with HEIC`).

### Task B5: The enricher (`hippo enrich`)

**Files:**
- Create: `desktop/src/enrich/prompt.ts` (system prompt, user prompt builder, output schema, `PROMPT_VERSION = 1`), `desktop/src/enrich/digest.ts`, `desktop/src/enrich/normalize.ts`, `desktop/src/enrich/serverdoc.ts`, `desktop/src/enrich/enrich.ts`, `desktop/src/enrich/state.ts` (the local failures table)
- Modify: `desktop/src/cli.ts` (`enrich`), `desktop/src/providers/fake.ts` (default enrichment answers)
- Test: `desktop/test/enrich.test.ts`, `desktop/test/serverdoc.test.ts`, `desktop/test/normalize.test.ts`

**Interfaces:**
- Consumes: `scanFolder`, `RawCapture` (B1); `buildRecord`, `deriveCircumstances`, `Circumstance` (B2); `Provider`, `ProviderError` (B3); `ensureThumbs` (B4).
- Produces:

```ts
export interface ModelEnrichment { title: string; summary?: string; image_descriptions: { attachment_id: string; text: string }[];
  tags: string[]; topic: string; people: { name: string; source: string }[]; keywords: { word: string; weight: number }[] }
export function inputDigest(c: RawCapture, pictureHashes: string[]): string            // digest.ts; sha256 hex
export function normalize(raw: unknown, c: RawCapture, knownTopics: string[]): ModelEnrichment | undefined   // normalize.ts
export const OWNED_KINDS = ['summary','tags','display','image_description','people','circumstance','hippo_desk_state'] as const;
export function composeServerDoc(c: RawCapture, parts: { model?: { value: ModelEnrichment; provenance: string; digest: string };
  circumstances: Circumstance[]; now: Date }): EnrichmentDoc | undefined   // undefined: nothing to write and nothing existing
export function facetsDiffer(a: EnrichmentDoc | undefined, b: EnrichmentDoc | undefined): boolean
export function writeServerDoc(c: RawCapture, doc: EnrichmentDoc): Promise<void>      // temp file in the same directory, then rename
export interface EnrichOptions { folder: string; provider?: Provider; model?: string; noModel?: boolean; dryRun?: boolean;
  limit?: number; concurrency?: number; now?: () => Date; onProgress?: (e: { done: number; total: number; id: string; what: string }) => void }
export interface EnrichReport { captures: number; pending: number; modelCalls: number; written: number; unchanged: number;
  failed: { id: string; reason: string }[]; skippedAfterRetries: number; stoppedBy?: 'usage_limit'; wouldCall: string[]; wouldWrite: string[] }
export function enrichFolder(o: EnrichOptions): Promise<EnrichReport>   // does not run the index step; the CLI does (Task B6)
```

Decisions:
- What the model sees for a capture, and therefore what the digest covers: kind, method, local date and time, site, shared title, shared text, user note, note body (first 6,000 characters), resolved link title and description, recognized text and transcripts by attachment id, comments (id, text, and audio transcript), the list of pictures with their attachment ids (display JPEGs from `ensureThumbs`, at most 4 pictures), and the list of topics already in use. The digest is SHA-256 over canonical JSON (sorted keys) of all of that except the topic list, plus `PROMPT_VERSION` and the SHA-256 of each picture file sent. A capture with no text at all and no picture (for example a silent recording with no transcript) gets no model call.
- Topics in use start from every existing server document's `display.topic` and grow as answers arrive in this run.
- `normalize`: title trimmed and cut to 60 characters on a word boundary, or the capture dropped as `bad_output` when blank; tags lower-cased, de-duplicated, blanks removed, at most 8 (fewer than 3 is accepted); topic lower-cased and trimmed, blank falls back to the first tag, else `"other"`; image descriptions kept only for picture attachment ids the capture has; people kept only with a non-blank name and a `source` that is `user_note`, `shared_text`, `shared_title`, or one of the capture's attachment or comment ids, de-duplicated by lower-cased name; keywords at most 12, weight clamped to 0–1, kept only for kinds `note` and `recording`. A non-object answer returns `undefined`.
- `composeServerDoc`: starts from the existing server document's facets, removes the seven owned kinds, then adds the new ones. `summary` only when there is one. `circumstance` only when there is at least one item, provenance `rules`. Model-made facets carry provenance `"<provider name>:<model>"`. `hippo_desk_state` `{input_digest, prompt_version}` provenance `hippo-desk`. When no model result is supplied, the existing document's `summary`, `tags`, `display`, `image_description`, `people` and `hippo_desk_state` facets are carried over unchanged, whoever wrote them (so `--no-model` and unchanged captures never lose them); only `circumstance` is recomputed. Document fields: `schema_version: 1`, `schema_minor: 2`, `layer: "server"`, producer `{name: "hippo-desk", version: <package.json version>, build: "1"}`, `package_digest` of the capture, `generated_at` now; each new facet `version: 1`, `status: "ok"`, `generated_at` now. Keys sorted, two-space indent, trailing newline.
- `facetsDiffer` compares per kind `status`, `provenance` and `data` (deep), ignoring `generated_at`; a kept facet reuses the old facet object so its `generated_at` does not move. No difference means no write.
- A capture with `serverUnreadable` is reported in `failed` with reason `existing server document is unreadable` and never overwritten. A composed document over 1 MiB is a failure, not a write.
- Failures: table `enrich_failures(capture_id primary key, input_digest, attempts, last_error, last_at)` in the index database file (`indexPath(folder)`). A capture with 3 attempts for the same digest is skipped and counted in `skippedAfterRetries`; a changed digest resets it; success deletes the row. `usage_limit` stops new calls, lets in-flight ones finish, records no failure for the stopped captures, and sets `stoppedBy`. `not_signed_in` and `unavailable` stop the run the same way, with the error as the reason.
- The fake provider's default handler for an enrichment request returns: title = the first 6 words of the capture's text or `"Untitled <kind>"`, summary `"Fake summary."`, one description `"Fake description of <attachment id>."` per picture id named in the prompt, tags `["fake", <kind>]`, topic `"fake"`, people `[]`, keywords `[]`. It recognises an enrichment request by a marker line the prompt builder writes (`TASK: enrich`).
- CLI: `hippo enrich [--folder p] [--no-model] [--dry-run] [--limit n] [--provider name] [--model name]` prints one line per capture acted on and a summary (`51 captures · 12 model calls · 12 written · 39 unchanged · 0 failed`); exit code 0 unless stopped by sign-in or usage limit (exit 3, with how far it got).

- [ ] **Step 1: Write the failing tests.**

`normalize.test.ts`, one test per rule above with these exact inputs: a 90-character title is cut to ≤ 60 and ends on a whole word; tags `["Food", "food", " ", "A","b","c","d","e","f","g","h"]` become 8 lower-case unique values; a description for attachment `nope` is dropped; a person `{name: "Ana"}` with no source is dropped; topic `""` with tags `["cafe"]` becomes `cafe`; weights `2` and `-1` become `1` and `0`; the string `"hello"` returns `undefined`. After each, the composed document validates against `schema/enrichment-v1.schema.json` with `ajv/dist/2020` (Review Focus 2).

`serverdoc.test.ts`: for capture 2 (existing `hippo-fixtures` document with `link_preview`, `summary`, `tags`), composing with a model result keeps `link_preview` byte-for-byte equal in parsed form, replaces `summary` and `tags`, and adds `display` and `hippo_desk_state`; composing for capture 1 with no model result and no circumstances returns `undefined`; `facetsDiffer` is false for two documents that differ only in `generated_at`; `writeServerDoc` leaves exactly one file in the directory and its bytes end with `\n`.

`enrich.test.ts`, with the fake provider on a fixture copy:

```ts
test('first run enriches, second run does nothing', async () => {
  const folder = copyFixtures(); const before = snapshot(folder);          // helper: relative path -> sha256 for every file
  const r1 = await enrichFolder({ folder, provider: fakeProvider(), now: () => new Date('2026-11-12T10:00:00Z') });
  assert.equal(r1.captures, 7); assert.equal(r1.failed.length, 0);
  assert.equal(r1.modelCalls, 5);        // 1 note, 2 link, 3 photo, 4 mixed, 7 context; 5 (video, no text) and 6 (silent audio) have nothing to send
  const after = snapshot(folder);
  for (const [p, h] of Object.entries(before)) if (!p.startsWith('enrichments/server/')) assert.equal(after[p], h);
  for (const p of Object.keys(after)) if (!(p in before)) assert.match(p, /^enrichments\/server\/\d{4}\/\d\d\/\d\d\/[0-9a-f-]{36}\/enrichment\.json$/);
  const r2 = await enrichFolder({ folder, provider: fakeProvider(() => { throw new Error('must not be called'); }) });
  assert.equal(r2.modelCalls, 0); assert.equal(r2.written, 0); assert.deepEqual(snapshot(folder), after);
});
```

If the fixture count of 5 turns out wrong because a fixture has text this plan did not foresee (for example a transcript on capture 6), correct the number in the test and say so in the report; the rule, not the number, is the requirement. Further tests: `noModel: true` on the untouched fixture copy writes nothing (the rules reproduce the Task A1 fixture's `circumstance` facet exactly; if they do not, the rule table or the fixture is wrong, report which), and after deleting capture 7's server document first it writes a document only for capture 7, holding `circumstance` and nothing model-made; `dryRun: true` returns non-empty `wouldCall` and `wouldWrite` and changes no file; changing capture 4's comment text makes the next run call the model for capture 4 only; adding a `weather` facet to capture 3's device document causes no model call; a provider that always throws `ProviderError('failed')` records failures, a fourth run makes no call for them and reports `skippedAfterRetries`; a provider that throws `usage_limit` on its third call yields `stoppedBy === 'usage_limit'` with at most `concurrency` calls beyond it and no failure rows; a capture made pending (Task B1) is skipped and nothing is written for it; a capture with `serverUnreadable` keeps its bytes; concurrency never exceeds 3 (count in the fake handler); every document written validates against the schema.

- [ ] **Step 2: `npm install -D ajv && npm test`; expect failures.**
- [ ] **Step 3: Implement the modules and the `enrich` command.** The prompt asks for JSON only, tells the model to reuse a listed topic when one fits, to name people only when a name appears in the text it was given and to say where, and to describe a screenshot's app or site. Pictures are named by attachment id in the prompt.
- [ ] **Step 4: `npm test` and `npm run typecheck` pass.**
- [ ] **Step 5: Live check on a fixture copy only:** `cp -R fixtures/packages <tmp>` then `HIPPO_DESK_HOME=<tmp2> node desktop/bin/hippo.mjs enrich --folder <tmp> --limit 3`. Read the three documents written; the title, description and tags should be sensible for invented fixture content. Report wall time per call.
- [ ] **Step 6: Commit** (`feat(desktop): hippo enrich writes server enrichment per capture`).

### Task B6: The index (`hippo index`, `hippo status`)

**Files:**
- Create: `desktop/src/index/db.ts`, `desktop/src/index/build.ts`
- Modify: `desktop/src/cli.ts` (`index`, `status`; `enrich` runs the index step at the end unless `--dry-run`)
- Test: `desktop/test/index.test.ts`

**Interfaces:**
- Consumes: `scanFolder` (B1), `buildRecord`, `CaptureRecord` (B2), `ensureThumbs` (B4), `indexPath` (B1).
- Produces:

```ts
export interface IndexDb { raw: import('node:sqlite').DatabaseSync; close(): void }
export function openIndex(folder: string): IndexDb                       // creates tables when missing; schema version in user_version
export interface IndexReport { captures: number; added: number; updated: number; removed: number; thumbnails: number; thumbFailures: { id: string; reason: string }[] }
export function buildIndex(folder: string, opts?: { rebuild?: boolean }): Promise<IndexReport>
export interface Status { folder: string; total: number; byKind: Record<Kind, number>; enriched: number; pending: number;
  failures: { id: string; attempts: number; error: string }[]; lastEnrichAt?: string; lastIndexAt?: string }
export function status(folder: string): Status
```

Decisions:
- One row per capture holding the whole `CaptureRecord` as JSON plus the columns the search filters on (kind, captured_at, local_date, local hour, weekday, part_of_day, lat, lon, locality, site, topic, method, enriched), child tables for tags, people, circumstances (label, confidence rank 1–3) and `has`, a media table (`capture_id`, `ref`, absolute `path`, `mime`) that is the only source of servable paths, and an FTS5 table (`tokenize = 'porter unicode61 remove_diacritics 2'`) over title, summary, text, image descriptions, tags, topic, people names, site and circumstance labels in words ("in a car"). Media refs: an attachment id (the original file), `thumb-<attachment id>`, `display-<attachment id>`, `link-thumb`, `comment-<comment id>`.
- A capture is re-indexed when a fingerprint of its inputs changed (package digest, device and server document bytes, comment file list); captures gone from the folder are removed; `rebuild` drops everything except `enrich_failures` first. A thumbnail failure is recorded in the report and the capture is still indexed without that thumbnail.
- `meta` table rows `last_index_at`, `last_enrich_at`, `folder`.
- `hippo status` prints counts by kind, enriched of total, pending, failures with their reasons, last runs.

- [ ] **Step 1: Write the failing tests:** indexing a fixture copy gives 7 captures, `byKind` `{note:1, link:1, photo:2, video:1, recording:1, screenshot:1, file:0}`; the row JSON for capture 7 round-trips to the `buildRecord` result; a second `buildIndex` reports `added: 0, updated: 0`; after `enrichFolder` with the fake provider, `buildIndex` reports 5 or more updated and `status().enriched` equals the number of captures with `display` from `hippo-desk`; removing a capture directory from the copy removes its rows; `rebuild: true` yields rows deep-equal to the rows before; deleting the database file and rebuilding gives the same rows (spec "Done means" 11), with a provider that throws if called; the index file is under `HIPPO_DESK_HOME` and a `snapshot(folder)` taken before and after `buildIndex` is identical; a corrupt picture (random bytes in capture 3's PNG, with `complete.json`'s size and hash updated to match so the capture stays complete) is indexed with one `thumbFailures` entry; the media table has `thumb-…` and `display-…` rows for capture 3 and `link-thumb` for capture 2.
- [ ] **Step 2: `npm test`; expect failures.**
- [ ] **Step 3: Implement `db.ts`, `build.ts`, the two commands, and the index step at the end of `hippo enrich`.**
- [ ] **Step 4: `npm test` and `npm run typecheck` pass (the `ExperimentalWarning` for SQLite is silenced in `bin/hippo.mjs`, not in tests).**
- [ ] **Step 5: Commit** (`feat(desktop): local index and status`).

### Task B7: Recall in text (`hippo search`, `show`, `facets`) and the skill

**Files:**
- Create: `desktop/src/recall/spec.ts`, `desktop/src/recall/engine.ts`, `desktop/src/recall/format.ts` (readable output), `desktop/skills/hippo-recall/SKILL.md`, `desktop/README.md`
- Modify: `desktop/src/cli.ts` (`search`, `show`, `facets`)
- Test: `desktop/test/spec.test.ts`, `desktop/test/engine.test.ts`, `desktop/test/cli.test.ts`

**Interfaces:**
- Consumes: `openIndex`, `IndexDb` (B6), `CaptureRecord` (B2).
- Produces:

```ts
export type LayoutName = 'kind' | 'time' | 'place' | 'topic' | 'person';
export interface SearchSpec {
  kinds?: Kind[];
  text?: string[];                        // each entry a word or a phrase; any may match
  tags?: string[]; topics?: string[]; people?: string[]; sites?: string[];
  time?: { from?: string; to?: string; weekdays?: string[]; parts_of_day?: string[] };   // local dates "YYYY-MM-DD", inclusive
  place?: { localities?: string[]; near?: { lat: number; lon: number; radius_m: number } };
  circumstances?: { labels: string[]; min_confidence?: Confidence };                     // default low
  has?: ('picture' | 'audio' | 'comment' | 'location' | 'link')[];   // all listed must hold
  include_ids?: string[]; exclude_ids?: string[];
  sort?: 'newest' | 'oldest' | 'relevance'; limit?: number;          // defaults newest, 500
}
export function validateSpec(input: unknown): { ok: true; spec: SearchSpec } | { ok: false; errors: string[] }
export interface SearchResult { total: number; items: CaptureRecord[] }
export function search(db: IndexDb, spec: SearchSpec): SearchResult
export interface Facets { total: number; kinds: Record<string, number>; topics: { value: string; count: number }[];
  tags: { value: string; count: number }[]; people: { value: string; count: number }[]; sites: { value: string; count: number }[];
  localities: { value: string; count: number }[]; circumstances: { value: string; count: number }[];
  date_range?: { from: string; to: string } }
export function facets(db: IndexDb): Facets
export function show(db: IndexDb, id: string): CaptureRecord | undefined   // also accepts a unique id prefix of 8 or more characters
```

Decisions:
- Fields combine with AND, values within a field with OR, except `has` (all). `tags`, `topics`, `people`, `sites` and `localities` match case-insensitively on the whole value; `sites` also matches a parent domain (`youtube.com` matches `m.youtube.com`). `include_ids` are returned even when they do not match the rest (pinned items); `exclude_ids` are removed last. `total` counts matches before `limit`.
- `text`: every entry is quoted for FTS5 as a phrase with inner double quotes doubled, entries joined with `OR`, so no user character is ever FTS syntax. A one-word entry also matches as a prefix (`"banan"*`). `relevance` sorts by `bm25`; without `text` it falls back to `newest`.
- `validateSpec` rejects unknown top-level keys, unknown kinds, labels that are not strings, dates not `YYYY-MM-DD`, `limit` outside 1–5000, each error naming the field (`time.from: expected YYYY-MM-DD`). Unknown circumstance labels and tags are allowed (they match nothing).
- CLI flags: `--kind` `--tag` `--topic` `--person` `--site` `--locality` `--circumstance` `--has` (each repeatable or comma-separated), `--text "<words>"` (split on whitespace into words), `--phrase "<exact phrase>"` (repeatable), `--from` `--to` `--weekday` `--part-of-day` `--near lat,lon,radius_m` `--min-confidence` `--sort` `--limit`, or `--spec '<json>'`; `--json` prints `{total, items}`. The readable form is one block per capture: local date and time, kind, title, then indented summary, place, tags, circumstances with confidence, and the path of the first attachment. `hippo show <id>` prints every field, the evidence lines, and all absolute file paths; `--json` prints the record. `hippo facets [--json]`. None of the three constructs a provider (a test asserts the `providers` module is never imported by them).
- `SKILL.md` (Agent Skills format: front matter `name: hippo-recall`, `description` saying when to use it): the loop is `hippo facets --json` → build a spec from the person's words using only values that exist, plus synonyms in `text` → `hippo search … --json` → narrow or widen → answer with titles, local dates, places and file paths; never invent a capture; circumstances are likely, say so; use `hippo show <id>` before quoting. Includes three worked examples, one of them "the YouTube shorts from last week" with the date arithmetic spelled out. `README.md`: install (`npm install`, `npm link`), the eight commands, where the index lives, the `hippo_desk_state` facet, providers and `.env`, how to install the skill for Claude Code (`~/.claude/skills/hippo-recall/`), Codex and Copilot (paste as instructions), and the privacy note from spec section 5.

- [ ] **Step 1: Write the failing tests.** `spec.test.ts`: the validation cases above. `engine.test.ts` on an enriched (fake provider) fixture copy: `{kinds:['screenshot']}` returns capture 7 only; `{circumstances:{labels:['in_car']}}` returns capture 7, and with `min_confidence:'high'` still 7, while `{circumstances:{labels:['walking']}}` returns none; `{has:['comment']}` returns capture 4; `{sites:['example.com']}` returns captures 2 and 4 (`site` is set for every capture with a URL, whatever its kind); `{text:['cafe']}` returns 7 and `{text:['cafes']}` also returns 7 (stemming); `{text:['"quoted" AND (x:y) -z *']}` runs and returns 0 with no throw (Review Focus 3); `{time:{from:'2026-11-07',to:'2026-11-07'}}` returns 7 and `{time:{from:'2026-11-08'}}` returns 0; a synthetic capture at `2026-11-08T07:30:00.000Z` in `America/Los_Angeles` is found by `from/to` `2026-11-07` and not by `2026-11-08` (Review Focus 4); `{place:{near:{lat:37.7749,lon:-122.4194,radius_m:500}}}` returns the captures at that point and a 1 m radius a kilometre away returns none; `{include_ids:[id1], kinds:['video']}` returns capture 5 and capture 1; `{exclude_ids:[id5], kinds:['video']}` returns none; `limit: 2` returns 2 items with `total` 7; `sort: 'oldest'` starts with capture 1. `facets` returns `total: 7`, `date_range` `2026-11-07` to `2026-11-07`, and `circumstances` containing `in_car`. `cli.test.ts` (spawns `node bin/hippo.mjs`): `search --kind screenshot --json` prints valid JSON with one item; `search --site example.com` prints a readable block containing `Example Domain (server)`; `show <first 8 characters of id 7>` prints `audio route was CarPlay`; `facets --json` parses; `search --limit 0` exits 2 naming `limit`.
- [ ] **Step 2: `npm test`; expect failures.**
- [ ] **Step 3: Implement, then write `SKILL.md` and `README.md`.**
- [ ] **Step 4: `npm test` and `npm run typecheck` pass.**
- [ ] **Step 5: Commit** (`feat(desktop): recall engine, search/show/facets commands, agent skill`).

### Task B8: The sample folder (`hippo sample`)

**Files:**
- Create: `desktop/src/index/sample.ts`, `desktop/src/index/sample-data.ts` (invented titles, notes, transcripts, names, places), `desktop/assets/sample/clip.mov` (a copy of fixture 5's 1 s video, the only binary asset)
- Modify: `desktop/src/cli.ts` (`sample`)
- Test: `desktop/test/sample.test.ts`

**Interfaces:**
- Consumes: `composeServerDoc`, `writeServerDoc` (B5), `deriveCircumstances` (B2), `scanFolder` (B1).
- Produces: `writeSample(opts: { out: string; count?: number; seed?: number; end?: string }): Promise<{ captures: number }>` (defaults 300, seed 1, `end` today as a local date; refuses a non-empty `out`).

Decisions:
- Everything invented. Time zone `Europe/Lisbon`; captures spread over the 42 days ending at `end`, denser on some days, at plausible hours. Five place clusters at real Lisbon coordinates with invented neighbourhood names (`sub_locality`) and locality `Lisboa`; about 15% of captures have no location.
- Mix (of `count`): links 30% (a third `youtube.com`, some of them `youtube.com/shorts/…`, at least 8 YouTube captures within the last 7 days and at least 3 of those shorts; also news, recipe, shop and map sites), photos 20%, screenshots 15%, notes 17%, recordings 12%, videos 3%, files 3% (a small text or PDF-like file with an original filename).
- About 12% carry in-car signals (CarPlay `car_audio` output, `automotive` motion, speed over 8 m/s), 12% walking, 8% headphones, some bursts (a run of 3–5 captures within a minute), and all located captures a `weather` facet with `is_day` matching the hour. At least 3 of the last-7-days YouTube captures are in-car (demo step 6).
- Six invented first names appear in notes, comments and transcripts; about 25% of captures mention one or two.
- Pictures are drawn with `sharp` from generated SVG (photos: simple scenes with shapes and gradients, about 1200 x 900 JPEG; screenshots: 1170 x 2532 PNG with a status bar, a title and rows of text; link thumbnails: 480 x 270 JPEG stored as device enrichment assets with size and hash). Recordings are 2–4 s sine-tone WAV files (UTI `com.microsoft.waveform-audio`), each with a device `transcript`. Videos are the bundled `clip.mov`.
- Every package follows `docs/package-format.md` (metadata, content, `complete.json` with a correct manifest, `schema_minor: 2`), and every device and server `enrichment.json` follows `docs/enrichment-format.md`. Server documents are written through `composeServerDoc` with provenance `sample`, hand-made model fields (title, summary, descriptions matching the drawn picture, 10 topics, tags, people, keywords) and rule-made circumstances from `deriveCircumstances`, including `hippo_desk_state` computed with the real `inputDigest`, so `hippo enrich --no-model` on a sample folder writes nothing.
- Same seed, count and end give byte-identical folders.

- [ ] **Step 1: Write the failing tests** (count 60, `end: '2026-11-12'`, seed 1): `scanFolder` returns 60 captures and 0 pending; every `metadata.json`, `complete.json` and `enrichment.json` validates against the repository schemas with `ajv`; all seven kinds occur after `buildIndex`; `search({sites:['youtube.com'], time:{from:'2026-11-06', to:'2026-11-12'}})` returns ≥ 8 and adding `circumstances:{labels:['in_car']}` returns ≥ 3; `facets().people.length === 6` and `topics.length` is between 5 and 10; a second `writeSample` into another directory gives an identical `snapshot`; `enrichFolder({noModel: true})` on it reports `written: 0`; `enrichFolder` with a provider that throws reports `modelCalls: 0`; writing into a non-empty directory rejects; the text of the generated folder contains none of the strings `jorge`, `pereira`, `@` (case-insensitive scan of all JSON and text files).
- [ ] **Step 2: `npm test`; expect failures.**
- [ ] **Step 3: Implement.** Use a small seeded generator (`mulberry32`) for every random choice, including ids (UUID v4 shaped from the generator).
- [ ] **Step 4: `npm test` passes; `node bin/hippo.mjs sample --out <tmp>/sample && HIPPO_DESK_HOME=<tmp2> node bin/hippo.mjs index --folder <tmp>/sample && node bin/hippo.mjs status` shows 300 captures, all enriched. Open three of the drawn pictures and look at them; fix anything unreadable.**
- [ ] **Step 5: Commit** (`feat(desktop): seeded sample folder`).

### Task B9: The local server and ask (`hippo ui`)

**Files:**
- Create: `desktop/src/recall/ask.ts`, `desktop/src/server/server.ts`, `desktop/src/server/media.ts`, `desktop/src/server/wire.ts` (record → what the page receives)
- Modify: `desktop/src/cli.ts` (`ui`), `desktop/src/providers/fake.ts` (default ask answers)
- Test: `desktop/test/ask.test.ts`, `desktop/test/server.test.ts`

**Interfaces:**
- Consumes: `search`, `facets`, `show`, `validateSpec`, `SearchSpec`, `LayoutName` (B7); `Provider` (B3); `enrichFolder` (B5); `buildIndex`, `status` (B6); `loadConfig`, `saveConfig` (B1).
- Produces:

```ts
export interface AskInput { sentence: string; spec: SearchSpec; layout: LayoutName; history: { sentence: string; reply: string }[];
  now: Date; timezone: string }
export interface AskOutput { spec: SearchSpec; layout: LayoutName | 'keep'; reply: string }   // reply may contain "{count}"
export function ask(provider: Provider, model: string, f: Facets, input: AskInput): Promise<AskOutput>   // throws ProviderError; 'bad_output' when the spec does not validate
export interface DeskItem {                      // wire.ts; what the page gets for each capture
  id: string; kind: Kind; title: string; summary?: string; topic?: string; tags: string[];
  people: { name: string; source: string }[]; keywords: { word: string; weight: number }[];
  captured_at: string; local_date: string; local_time: string; weekday: string; part_of_day: string; timezone: string;
  place?: { lat: number; lon: number; locality?: string; sub_locality?: string; nearby?: string };
  circumstances: Circumstance[]; site?: string; url?: string; is_video_link?: boolean; body_excerpt?: string;   // first 280 characters
  thumb?: string; display?: string; media?: string; media_type?: 'picture' | 'audio' | 'video' | 'file';     // URLs under /media
  duration_seconds?: number; file_name?: string; more_count: number; has: string[];
}
export function startServer(opts: { folder: string; port?: number; provider: Provider; uiDir?: string; devOrigin?: string }):
  Promise<{ url: string; port: number; token: string; close(): Promise<void> }>
```

Routes (all JSON unless noted; every one requires the token):

| Route | Does |
|---|---|
| `GET /?t=<token>` | Serves `ui/dist/index.html` and sets cookie `hippo_t=<token>; HttpOnly; SameSite=Strict; Path=/`. Other files under `ui/dist` are served with the cookie |
| `GET /api/boot` | `{facets, status, settings: {provider, askModel, enrichModel, mapTiles, theme}, today, timezone}` |
| `POST /api/search` `{spec, pinned?, dismissed?}` | `{total, items: DeskItem[]}`; the server adds `pinned` to `include_ids` and `dismissed` to `exclude_ids` |
| `POST /api/ask` `{sentence, spec, layout, history, pinned?, dismissed?}` | One model call, then the search: `{spec, layout, reply, total, items}` with `{count}` in the reply replaced by `total`; on failure HTTP 502 `{error: <code>, message}` and nothing else changes |
| `GET /api/capture/:id` | `{item: DeskItem, detail}` where `detail` has the full text, every attachment and comment with media URLs, `context`, circumstances with evidence, method, source app, and absolute file paths |
| `GET /media/:id/:ref` | The file for that capture and ref from the index's media table, with `Content-Type`, `Range` support and `Cache-Control: private, max-age=3600`; anything not in the table is 404 |
| `POST /api/enrich` | Starts one `enrichFolder` + `buildIndex` pass in the background (409 when one is running); `GET /api/enrich` returns `{running, done, total, report?}` |
| `POST /api/settings` | Accepts `provider`, `askModel`, `enrichModel`, `mapTiles`, `theme`; saves them with `saveConfig`; never accepts or returns a key |

Decisions:
- Binds `127.0.0.1` only; default port 4477, next free port when taken. The token is 32 random bytes hex, new per run. A request passes when its token (cookie `hippo_t` or header `X-Hippo-Token`) matches by constant-time compare, its `Host` is `127.0.0.1:<port>` or `localhost:<port>`, and its `Origin`, when present, is that same origin (or `devOrigin`, used with the Vite dev server). Otherwise 403 with an empty body. Request bodies over 1 MiB are 413.
- `ask` prompt: the vocabulary from `facets` (topics, people, sites, localities, circumstance labels, kinds with counts, date range; tags capped at the 150 most frequent), today's local date, weekday and time zone, the current spec and layout, the last 6 turns, and the sentence. It asks for a complete new spec, a layout or `keep`, and one line of at most 80 characters using `{count}` for the number of results. Rules stated in the prompt: a correction replaces the field it corrects and keeps the rest; "start over" returns an empty spec; "last week" is the previous Monday-to-Sunday week; put synonyms and singular/plural forms in `text`; choose `place` when the sentence is about where, `time` when about when, `person` when about who, `topic` for broad sets over about 40, otherwise `kind`; never invent vocabulary values. The output schema is the `SearchSpec` shape (without `include_ids`, `exclude_ids`) plus `layout` and `reply`.
- The fake provider's default answer to an ask request (marker line `TASK: ask`) starts from the current spec and applies, by lower-cased substring of the sentence: `start over` → empty spec, layout `kind`; `youtube` → `kinds: ['link']`, `sites: ['youtube.com']`; `screenshot` → `kinds: ['screenshot']` and `sites` removed; `last week` → `time` set to the previous Monday–Sunday from the date in the prompt; `car` → `circumstances: {labels: ['in_car']}`; `by place` → layout `place`; `by time` → `time`; `by topic` → `topic`; `by person` → `person`; otherwise layout `keep`. Reply `"{count} found"`.
- `hippo ui [--folder p] [--port n] [--no-open] [--provider name] [--dev]`: runs `buildIndex` first when the index is empty, starts the server, prints the URL with the token, opens the default browser (`open` on macOS, `start` on Windows, `xdg-open` elsewhere) unless `--no-open`. `--dev` sets `devOrigin` to `http://localhost:5173` and prints that URL instead.

- [ ] **Step 1: Write the failing tests.** `ask.test.ts`: the fake rules above, in sequence on one conversation (youtube → screenshot → last week with `now` `2026-11-12` gives `time` `2026-11-02` to `2026-11-08` and keeps `kinds: ['screenshot']`); a provider returning `{spec: {kinds: ['spaceship']}, layout: 'kind', reply: 'x'}` raises `bad_output`; the prompt given to the provider contains the vocabulary's sites and today's date and does not contain any capture text. `server.test.ts` (fixture copy, enriched and indexed, fake provider, `uiDir` a temp dir with an `index.html`): no token → 403; right token with `Host: evil.example` → 403; right token and host with `Origin: http://evil.example` → 403; `GET /?t=<token>` sets the cookie and returns the page, and a later `/api/boot` with only the cookie is 200 with `facets.total === 7`; `/api/search` with `{spec: {kinds: ['screenshot']}}` returns one `DeskItem` whose `thumb` URL fetches a JPEG; `dismissed: [id7]` makes it 0 and `pinned: [id1]` adds capture 1; `/api/ask` with `"show me the screenshots"` returns `spec.kinds` `['screenshot']`, `total: 1`, reply `"1 found"`; with a provider that throws `ProviderError('timeout')` it is 502 `{error: 'timeout'}`; `/media/<id7>/../../etc/passwd` and `/media/<id7>/nope` are 404; a `Range: bytes=0-99` request on capture 5's video returns 206 with 100 bytes; `/api/capture/<id7>` detail contains the evidence line `audio route was CarPlay`; `POST /api/settings {mapTiles: false}` persists and `{apiKey: 'x'}` is rejected with 400; an invalid spec is 400 naming the field; the server's address is `127.0.0.1`.
- [ ] **Step 2: `npm test`; expect failures.**
- [ ] **Step 3: Implement.** `node:http` only, no framework.
- [ ] **Step 4: `npm test` and `npm run typecheck` pass. Live check of ask speed on the sample folder with the real `claude-cli` provider (sample data is invented): three sentences from spec section 10 through `curl` or a small script; report the wall time of each. If over about 4 s, trim the vocabulary sent (spec section 12) and report what was trimmed.**
- [ ] **Step 5: Commit** (`feat(desktop): local server, ask endpoint, hippo ui`).

---

## Part C: the desk

The behaviour reference is `.superpowers/brainstorm/84327-1794492073/content/pivots-prototype-v3.html` (untracked, a flat sketch: it defines gestures and arrangement, not appearance). Read spec section 8 in full before any Part C task. Load the `frontend-design:frontend-design` skill for the controls and overlay. Development runs against a sample folder: `hippo sample --out <tmp>/sample`, `hippo ui --folder <tmp>/sample --dev --provider fake`, and `npm run dev` in `desktop/ui`. Appearance is judged by looking: each Part C task ends by taking screenshots with the Playwright tools and reading them, at 1440 x 900.

Units: desk units are centimetres on the surface (x right, y away from the viewer, z up). A photo print is 15 x 10, a screenshot 7 x 15, a link card 12 x 9, a note slip 9 x 9, a cassette 10 x 6.4, a video print 15 x 9, a file sheet 10.5 x 14.

### Task C1: Page scaffold, pure layout core, and the theme seam

**Files:**
- Create: `desktop/ui/index.html`, `desktop/ui/vite.config.ts` (root `ui`, `build.outDir` `dist`, dev proxy of `/api` and `/media` to `http://127.0.0.1:4477`), `desktop/ui/src/main.ts`, `desktop/ui/src/api.ts`, `desktop/ui/src/state.ts`
- Create: `desktop/ui/src/layout/types.ts`, `layout/kind.ts`, `layout/time.ts`, `layout/topic.ts`, `layout/person.ts`, `layout/place.ts`, `layout/index.ts`, `layout/pile.ts` (shared pile stacking), `desktop/ui/src/reconcile.ts`, `desktop/ui/src/themes/types.ts`, `desktop/ui/src/themes/index.ts`
- Modify: `desktop/package.json` (deps `three`, dev deps `vite`, `@types/three`; scripts `dev` = `vite ui`, `build` = `vite build ui`; `test` also globs `ui/test/**/*.test.ts`), `desktop/tsconfig.json` (include `ui/src`, `lib` adds `DOM`)
- Test: `desktop/ui/test/layout.test.ts`, `desktop/ui/test/reconcile.test.ts`, `desktop/ui/test/state.test.ts` (pure modules only: no DOM, no three.js import)

**Interfaces:**
- Consumes: `DeskItem`, the routes of Task B9, `SearchSpec`, `LayoutName` (types imported from `../../src/...` with `import type`).
- Produces:

```ts
// layout/types.ts
export interface Size { w: number; h: number }
export type SizeTable = Record<Kind, Size>;
export interface View { width: number; height: number }           // usable desk area in desk units, centred on 0,0
export interface Placement { id: string; x: number; y: number; order: number; rot: number; pile: string }   // order 0 is the bottom of its pile; rot in radians
export interface PileInfo { key: string; label: string; count: number; x: number; y: number; ids: string[] }  // ids top first
export type Backdrop =
  | { type: 'columns'; columns: { label: string; x: number; width: number }[]; top: number; bottom: number }
  | { type: 'map'; x: number; y: number; width: number; height: number; zoom: number; centerLat: number; centerLon: number;
      labels: { text: string; x: number; y: number }[] };
export interface LayoutResult { placements: Placement[]; piles: PileInfo[]; backdrop?: Backdrop; empty?: string }
export type LayoutFn = (items: DeskItem[], view: View, sizes: SizeTable) => LayoutResult;
export const layouts: Record<LayoutName, LayoutFn>;                // layout/index.ts
// reconcile.ts
export function reconcile(prev: string[], next: string[]): { leave: string[]; stay: string[]; arrive: string[] }
// state.ts
export interface DeskState { spec: SearchSpec; layout: LayoutName; items: DeskItem[]; total: number; reply: string;
  pinned: string[]; dismissed: string[]; history: { sentence: string; reply: string }[]; sentences: string[] }
export function createStore(api: Api): Store   // ask(sentence), setLayout(name), dismiss(id), restore(id), pin(ids), unpin(id), undo(), startOver(), subscribe(fn)
// themes/types.ts
export interface Motions {                                         // each returns spring targets or a scripted arc; durations in ms
  arrive(index: number, from: Edge): MotionSpec; leave(index: number, to: Edge): MotionSpec; move(index: number): MotionSpec;
  lift: MotionSpec; flip: MotionSpec; thinking: { period: number; amplitude: number } }
export interface Theme { name: string; sizes: SizeTable;
  setupStage(stage: StageContext): void;                           // surface, lights, environment, vignette
  buildObject(item: DeskItem, lod: 'small' | 'full'): import('three').Object3D;
  buildPileLabel(text: string, count: number): import('three').Object3D;
  buildThickness(count: number, size: Size): import('three').Object3D | undefined;   // the block under a capped pile
  buildBackdrop(b: Backdrop, opts: { mapTiles: boolean }): import('three').Object3D;
  motions: Motions }
export const themes: Record<string, () => Promise<Theme>>;         // themes/index.ts; only 'desk'
```

Decisions:
- Every layout is deterministic: jitter (position ±0.4, rotation ±4°) comes from a hash of the capture id. Piles stack newest on top. `layout/pile.ts` places a pile's items at the pile's point with that jitter and `order` by time.
- `kind`: fixed slots in a 4 + 3 grid in the order link, photo, screenshot, note / recording, video, file; a kind with no items leaves its slot empty so piles never move between questions.
- `time`: one column per local date when the range is ≤ 14 days, per ISO week ≤ 16 weeks, else per month; oldest left; y from local time of day (morning at the far edge, night nearest); items in the same column closer than 60% of their height form a small pile.
- `topic`: one pile per topic, largest first, row-major, label the topic; items with no topic in "Other". `person`: one pile per first-named person, largest first, then "Nobody mentioned"; `PileInfo.label` the name.
- `place`: fits the located items' bounds (padded 15%) to a map rectangle occupying the left 80% of the view using Web Mercator at the integer zoom that fits; items closer than 6 units cluster into a pile at their centroid labelled with the commonest `sub_locality` or `locality`; unlocated items form one pile "No location" in the right 20%; with no located items the backdrop is omitted and everything is in "No location" (Review Focus 5).
- Any layout given `[]` returns `{placements: [], piles: [], empty: 'Nothing matches. Try fewer words, or say "start over".'}`.
- `state.ts`: `ask` posts to `/api/ask`, pushes the previous `{spec, layout, items, total, reply}` on an undo stack (depth 30), and on an error keeps the state and sets `reply` to the error message. `setLayout` never calls the network. `dismiss`/`restore`/`pin`/`unpin` update the lists and call `/api/search` with the current spec. `startOver` clears spec, pinned and dismissed. `sentences` keeps the last 50 for the Up key.

- [ ] **Step 1: Write the failing tests.** `layout.test.ts` with 40 synthetic `DeskItem`s built by a helper: every layout returns exactly one placement per item and the same output on a second call; `kind` puts all links at one point (±0.4) and the link pile is at the same point when only 5 links are given; `time` over 3 dates gives 3 columns left to right in date order, and over 40 dates gives week columns; `topic` gives one pile per distinct topic with counts summing to 40; `person` puts an item naming `["Ana","Rui"]` in pile `Ana`; `place` puts two items 20 m apart in one pile and two items 5 km apart in different piles, keeps every placement inside the view, and puts the 6 unlocated items in a pile labelled `No location` with x > 0.3 × view width; `place` with no located items has no backdrop; `[]` gives the empty line for all five. `reconcile.test.ts`: `reconcile(['a','b','c'], ['b','c','d'])` is `{leave:['a'], stay:['b','c'], arrive:['d']}`. `state.test.ts` with a stub `Api`: `ask` then `undo` restores the earlier items and spec; a rejected `ask` leaves items untouched and sets `reply`; `setLayout('place')` makes no API call; `dismiss(id)` sends `dismissed: [id]` on the next search and `startOver` clears it; pinned ids are sent with every ask.
- [ ] **Step 2: `npm install three && npm install -D vite @types/three && npm test`; expect failures.**
- [ ] **Step 3: Implement the pure modules, `api.ts` (same-origin `fetch`, JSON, throws `Error(message)` on non-2xx), and a `main.ts` that boots, calls `/api/boot`, and for now lists the item count in the page.**
- [ ] **Step 4: `npm test`, `npm run typecheck`, `npm run build` pass; `hippo ui --folder <sample> --no-open --provider fake` serves the built page and the count shows.**
- [ ] **Step 5: Commit** (`feat(desk): page scaffold, layouts, reconcile, state, theme seam`).

### Task C2: The scene, the desk theme, and arrival/leave motion

**Files:**
- Create: `desktop/ui/src/scene/stage.ts` (renderer, camera, zoom to pointer, pan, picking, frame loop, quality switch), `scene/spring.ts`, `scene/objects.ts` (one persistent object per capture id; small textures until approached), `scene/arrange.ts` (applies a `LayoutResult` + `reconcile` with the theme's motions; pile caps, thickness and labels; empty-state line), `scene/textures.ts` (canvas drawing helpers, image loading with a cache and a concurrency limit)
- Create: `desktop/ui/src/themes/desk/index.ts`, `desk/surface.ts`, `desk/objects/{photo,screenshot,link,note,recording,video,file}.ts`, `desk/labels.ts`, `desk/motions.ts`, `desk/palette.ts`
- Modify: `desktop/ui/src/main.ts`
- Test: `desktop/ui/test/spring.test.ts`, `desktop/ui/test/arrange.test.ts` (the pure planning part of `arrange.ts`: which ids are drawn in a capped pile, stagger order)

**Interfaces:**
- Consumes: everything Task C1 produces.
- Produces: `createStage(canvas: HTMLCanvasElement, theme: Theme): Stage` with `setItems(items: DeskItem[], layout: LayoutResult): void` (animated, interruptible), `setThinking(on: boolean)`, `resetView()`, `pick(clientX, clientY): { id?: string; pile?: string } | undefined`, `objectOf(id): Object3D | undefined`, `on(event, handler)` for `frame`; `planPile(ids: string[], cap = 12): { drawn: string[]; hidden: number }`; `step(spring, dt)` in `spring.ts` (critically damped by default; stable for `dt` up to 1/20 s).

Decisions (all within spec section 8; colours and timings live only under `themes/desk/`):
- Surface: a large plane, dark blue `#0f2038` to `#0a1626` vignette, no texture detail. One soft key light from the upper left casting soft shadows (PCF soft shadow map, 2048), a dim fill, and a small procedural environment map for reflections (`RoomEnvironment` or a drawn gradient; no downloaded HDR).
- Camera: perspective, looking down tilted about 18° from vertical. Wheel or pinch zooms toward the pointer between 0.5x and 6x; dragging empty desk pans; both eased.
- Objects are thin rounded boxes with a canvas texture on the face: **photo** white border, picture, `MeshPhysicalMaterial` with clearcoat 1 and low clearcoat roughness; **screenshot** phone-shaped, rounded corners, dark bezel, slight gloss; **link** matte card, thumbnail on the top 60%, title and site below, a play mark when `is_video_link`; **note** cream paper, word cloud from `keywords` (size by weight) or the first lines of `body_excerpt` when there are fewer than 4 keywords; **recording** a cassette (shell, window with two reels, a label with the first words of `body_excerpt` in a handwriting-style font stack and the length as `m:ss`); **video** print with the display picture or the video's first frame (a `<video>` element seeked to 0.1 s, drawn to canvas) and a play mark; **file** white sheet with a folded corner and `file_name`. A "+N" mark in a corner when `more_count` > 0. A small mark on person-layout items that name more than one person.
- Textures: `small` LOD is 256 px on the long side (the `thumb` URL), built for everything; `full` (the `display` URL, 1024 px) is swapped in when an object covers more than about 300 screen pixels or is lifted, and released when it no longer does. At most 6 image loads at once.
- Piles draw at most 12 objects; the rest are hidden and replaced by a block under the pile whose height grows with the hidden count (capped), plus the theme's handwritten label with the count.
- Motion (`desk/motions.ts`): arrivals are dealt from the nearest off-desk edge on an arc with a little spin, 28 ms stagger, settle with a small overshoot; leavers are swept off the nearest edge, 14 ms stagger, then hidden (objects are kept for reuse); stayers glide with a lift of about 1.5 units at mid-path. All are spring targets, so a new `setItems` mid-flight redirects from current positions. Thinking: a slow breathing of the key light and a pulsing dot beside the ask bar; input stays enabled.
- Scale: one draw path, no per-frame allocation in the loop, shadows only from the top 3 objects of each pile, shadow map updated only while something moves. Target 60 fps at 300 items on the sample; at 2,000 items it must stay interactive (≥ 30 fps while idle and panning).

- [ ] **Step 1: Write the failing tests.** `spring.test.ts`: a spring from 0 to 1 is within 0.001 of 1 after 2 s of 1/60 steps, never exceeds 1.05 at default damping, and does not blow up with `dt` 0.05. `arrange.test.ts`: `planPile` of 40 ids draws the 12 top ids and hides 28; of 5 draws 5; stagger order for arrivals is by distance from the dealing edge.
- [ ] **Step 2: `npm test`; expect failures.**
- [ ] **Step 3: Implement the stage, the desk theme and the arrangement; `main.ts` shows the whole sample folder in the `kind` layout on load.**
- [ ] **Step 4: Look at it.** With the fake provider on the 300-item sample, take screenshots of the `kind`, `time`, `topic` and `person` layouts and one close-up of each of the seven objects; read every screenshot; fix what looks wrong (unreadable titles, clipping, z-fighting, flat lighting, objects off the desk). Measure frame time with `performance.now()` over 300 frames while a layout change animates, at 300 items and at 2,000 (`hippo sample --count 2000`); put both numbers in the commit body. If 300 items is under 60 fps, fix before committing.
- [ ] **Step 5: Check the seam:** `grep -rnE "#[0-9a-fA-F]{6}|MeshPhysicalMaterial|clearcoat" desktop/ui/src --include='*.ts' | grep -v "themes/desk/"` prints nothing.
- [ ] **Step 6: Commit** (`feat(desk): scene, desk theme objects, arrival and leave motion`).

### Task C3: Controls, asking, and the map sheet

**Files:**
- Create: `desktop/ui/src/controls/askbar.ts`, `controls/layoutbar.ts`, `controls/toolbar.ts` (count, undo, reset view, update, settings), `controls/settings.ts`, `desktop/ui/src/styles.css`, `desktop/ui/src/themes/desk/map.ts` (the paper map backdrop and the column backdrop), `desktop/ui/src/layout/mercator.ts` (if not already split out in C1)
- Modify: `desktop/ui/src/main.ts`, `desktop/ui/index.html`
- Test: `desktop/ui/test/mercator.test.ts`

**Interfaces:**
- Consumes: `Store` (C1), `Stage` (C2), `Backdrop` (C1), routes `/api/ask`, `/api/enrich`, `/api/settings` (B9).
- Produces: DOM hooks the browser test uses: `[data-testid="ask"]` (the input), `[data-testid="reply"]`, `[data-testid="count"]`, `[data-testid="layout-<name>"]` (five buttons, the active one has `aria-pressed="true"`), `[data-testid="undo"]`, `[data-testid="reset-view"]`, `[data-testid="update"]`, `[data-testid="settings"]`, and `window.__desk = { ids(): string[]; layout(): string; settled(): boolean }` for tests; `tileUrl(z, x, y): string`, `lonLatToTile(lon, lat, z): { x: number; y: number }`, `tilesFor(b: Backdrop & { type: 'map' }): { z: number; x: number; y: number; px: number; py: number }[]`.

Decisions:
- Ask bar centred at the bottom: Enter sends, Up and Down walk earlier sentences, Escape clears. The reply line sits just above it. While a question is out, the pulsing dot shows and typing still works; a second question sent before the first returns supersedes it (the first answer is ignored).
- Layout buttons at the top right in the order Kind, Time, Place, Topic, Person; clicking one calls `store.setLayout` and re-arranges at once. When an ask returns a layout other than `keep`, the button state follows.
- Count at the top left ("83 on the desk · 4 set aside"). Update button posts `/api/enrich`, shows progress from `GET /api/enrich` every second, then re-boots facets and re-runs the current spec. Settings panel: theme (only Desk), provider and the two model names, map tiles on/off; saved through `/api/settings`.
- Controls are HTML over the canvas, quiet and small, legible on the dark surface; they take their colours from CSS variables the theme sets.
- Map sheet: a paper-coloured sheet on the desk sized to the backdrop rectangle, unfolding (two folds opening over about 600 ms) when the place layout arrives and folding away when it leaves. With tiles on, OpenStreetMap raster tiles (`https://tile.openstreetmap.org/{z}/{x}/{y}.png`, at most 24 tiles, `crossOrigin = 'anonymous'`) are drawn into one canvas texture, desaturated and multiplied with a paper tint; the attribution "© OpenStreetMap contributors" is drawn on the sheet's lower edge. With tiles off or when a tile fails to load: the plain sheet with the backdrop's place labels. Column backdrop for the time layout: faint ruled columns with handwritten date labels.

- [ ] **Step 1: Write the failing test** `mercator.test.ts`: `lonLatToTile(-9.1393, 38.7223, 12)` is `{x: 1944, y: 1569}` (floor, standard slippy-map formula); `tilesFor` on a backdrop covering central Lisbon at zoom 13 returns between 1 and 24 tiles, all at `z` 13, covering the rectangle with no gaps.
- [ ] **Step 2: `npm test`; expect failure.**
- [ ] **Step 3: Implement controls, wiring and the two backdrops.**
- [ ] **Step 4: Look at it** on the sample with the fake provider: type "show me the youtube videos", "no, actually it was a screenshot", "from last week", "sort these by place"; click Kind; click Undo twice. Screenshot each state and read them. Check that the map shows Lisbon streets under the piles with attribution, and that turning tiles off in settings gives the plain sheet. Then once with the real `claude-cli` provider on the sample (invented data): the same four sentences; note each round-trip time.
- [ ] **Step 5: Commit** (`feat(desk): ask bar, layout buttons, settings, map sheet`).

### Task C4: Handling (piles, lift, flip, drag, throw, pin)

**Files:**
- Create: `desktop/ui/src/interact/pointer.ts` (one pointer state machine: press, drag threshold 4 px, release with velocity), `interact/pile.ts` (open, spread, riffle, gather), `interact/item.ts` (lift, flip, drag, throw), `interact/setaside.ts` (the set-aside pile and taking things back), `interact/keep.ts` (the "maybe these" pile and pin marks), `desktop/ui/src/overlay/detail.ts` and `overlay/detail.css` (front and back of a lifted item as HTML)
- Modify: `desktop/ui/src/main.ts`, `scene/arrange.ts` (extra piles: set aside, kept)
- Test: `desktop/ui/test/interact.test.ts` (pure parts: spread positions, throw decision, riffle order)

**Interfaces:**
- Consumes: `Stage`, `Store`, `Theme.motions.lift/flip`, `GET /api/capture/:id` (B9).
- Produces: `spreadPositions(count: number, view: View, size: Size): { x: number; y: number }[]` (a grid that fits the view, scrolling rows when more than fit), `isThrow(velocity: { x: number; y: number }, pos: { x: number; y: number }, view: View): boolean` (speed over 60 units/s heading toward the nearest edge, or released within 4 units of an edge), `riffle(ids: string[], steps: number): string[]` (rotates the pile's top), and `[data-testid="detail"]`, `[data-testid="flip"]`, `[data-testid="open-link"]`, `[data-testid="close-detail"]` on the overlay.

Decisions, following spec section 8 "Handling" exactly:
- Click a pile: it spreads to `spreadPositions`, the rest of the desk dims and slides aside; Escape or a click outside gathers it. Wheel over an open pile scrolls its rows; wheel over a closed pile riffles (top goes to the bottom).
- Click an item (in an open pile or loose): it lifts toward the camera to fill about 70% of the view height and the detail overlay fades in over it showing the thing itself: picture at full resolution (the original through `/media`), note text, recording with an `<audio controls>` player and transcript, link with title, description, site and an "Open in browser" button (`window.open(url, '_blank', 'noopener')`), video with `<video controls>`, file with its name and path. All attachments and comments are listed below the main one.
- Flip (button, or F, or clicking the lifted object's edge): the object turns over (theme `flip` motion) and the overlay shows the back: when (local date, time, weekday), where (place names, coordinates), capture method and source app, device context, circumstances each with confidence and evidence lines under the heading "Likely", tags, topic, people with where each was found, comments, and absolute file paths. Escape or the close button puts it back where it was.
- Drag an item anywhere; it stays where it is dropped until the next arrangement. Drag a pile by its label to move the whole pile.
- Throw (per `isThrow`): the item flies off and lands in the "Set aside" pile in the lower right corner; `store.dismiss(id)`. Opening that pile and clicking an item, or dragging it back onto the desk, calls `store.restore(id)`.
- Keep: dropping an item on empty desk while holding Shift, or dropping it on the "Maybe these" pile (created at the first such drop, lower left), pins it (`store.pin`); pinned items carry a small pin mark and stay through new questions; dragging one out of the pile and throwing it unpins and dismisses. Start over clears pins.
- Undo button and Cmd/Ctrl+Z call `store.undo()`.

- [ ] **Step 1: Write the failing tests** `interact.test.ts`: `spreadPositions(30, {width: 120, height: 70}, {w: 15, h: 10})` returns 30 non-overlapping positions inside the view; `isThrow({x: 90, y: 0}, {x: 10, y: 0}, view)` is true, `isThrow({x: 10, y: 0}, {x: 0, y: 0}, view)` is false, a slow release 2 units from the right edge is true; `riffle(['a','b','c'], 1)` is `['b','c','a']`.
- [ ] **Step 2: `npm test`; expect failures.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Walk spec "Done means" steps 8 and 9 by hand with the Playwright tools on the sample**: open a pile, riffle, close; throw an item and take it back; pin two items and ask a new question (they stay); lift, flip, open a link (assert the popup URL). Screenshot the lifted front and back of each kind and read them; text must be sharp and scrollable.
- [ ] **Step 5: Commit** (`feat(desk): piles, lift and flip, drag, set aside, pin, undo`).

### Task C5: Browser test and the desktop wrap-up

**Files:**
- Create: `desktop/playwright.config.ts`, `desktop/e2e/desk.spec.ts`, `desktop/e2e/global-setup.ts` (writes a 120-capture sample to a temp dir with `end` today, indexes it with a temp `HIPPO_DESK_HOME`, builds the page, starts `startServer` with the fake provider)
- Modify: `desktop/package.json` (script `e2e` = `playwright test`), `desktop/README.md` (running the desk, the demo script, gestures, settings, troubleshooting sign-in), `docs/roadmap.md` (one entry for Hippo Desk), root `README.md` if it lists components
- Test: `desktop/e2e/desk.spec.ts`

**Interfaces:**
- Consumes: the `data-testid` hooks and `window.__desk` (C3, C4), `startServer` (B9), `writeSample` (B8).

- [ ] **Step 1: Write the browser test** (spec "Done means" steps 3 to 5 with the fake provider):

```ts
test('ask, correct, refine', async ({ page }) => {
  await page.goto(url);                                              // includes the token
  await page.waitForFunction(() => window.__desk.settled());
  const all = await page.evaluate(() => window.__desk.ids().length);
  await ask(page, 'show me the youtube videos');
  const videos = await ids(page); expect(videos.length).toBeGreaterThanOrEqual(8); expect(videos.length).toBeLessThan(all);
  await ask(page, 'no, actually it was a screenshot');
  const shots = await ids(page); expect(shots.some(id => videos.includes(id))).toBe(false); expect(shots.length).toBeGreaterThan(0);
  await ask(page, 'from last week');
  const recent = await ids(page); expect(recent.length).toBeLessThanOrEqual(shots.length); expect(recent.every(id => shots.includes(id))).toBe(true);
  await page.getByTestId('layout-place').click();
  expect(await page.evaluate(() => window.__desk.layout())).toBe('place'); expect(await ids(page)).toEqual(recent);
  await expect(page.getByTestId('reply')).toContainText('found');
});
```

`ask` types into `[data-testid="ask"]`, presses Enter and waits for `settled()`. A second test: a request to `/api/boot` without the cookie is 403. A third: no console errors during the first test.
- [ ] **Step 2: `npm install -D @playwright/test && npx playwright install chromium && npm run e2e`; fix until it passes.**
- [ ] **Step 3: Whole-desktop check.** `npm test`, `npm run typecheck`, `npm run build`, `npm run e2e` all pass. On a fresh fixture copy run the demo's command-line steps (spec "Done means" 1, 10, 11) by hand and paste the outputs into the task report.
- [ ] **Step 4: Finish `desktop/README.md`.** It must let Jorge run his own folder: `hippo enrich --dry-run --folder "<path>"`, then `hippo enrich`, then `hippo ui`, with the note that the first real run is the first write into his Dropbox and what it writes.
- [ ] **Step 5: Commit** (`test(desk): browser test; docs`).

---

## Part D: the phone

Part D needs only Task A1. Read spec section 9 first. Existing pieces it builds on: `ResolvedEnrichment` and `ServerOrigin` (`HippoKit/Sources/HippoPresentation/Enrichment/ResolvedEnrichment.swift`), `EnrichmentSearchText` (`CaptureCore/Enrichment`), `CaptureDetail`, `CaptureDetailModel`, `TitledText`, `DetailRow`, `Layer` (`HippoPresentation/Detail`), `GoldSample`, `ActivityModel` and `LogLineRow` (`HippoPresentation/Log`), views `App/Hippo/Detail/CaptureDetailView.swift`, `EnrichmentSections.swift`, `LayerStripe.swift`, `ActivityView.swift`, settings `HippoPresentation/Settings/AppSettings.swift`.

### Task D1: Merge, search text and sample document for the new kinds

**Files:**
- Modify: `HippoKit/Sources/HippoPresentation/Enrichment/ResolvedEnrichment.swift`, `HippoKit/Sources/CaptureCore/Enrichment/EnrichmentSearchText.swift`, `HippoKit/Sources/HippoPresentation/Enrichment/GoldSample.swift`
- Create: `HippoKit/Sources/CaptureCore/Enrichment/CircumstanceWording.swift`
- Test: `HippoKit/Tests/HippoPresentationTests/ResolvedEnrichmentTests.swift`, `GoldSampleTests.swift`, `HippoKit/Tests/CaptureCoreTests/` (the existing search-text test file, plus `CircumstanceWordingTests.swift`)

**Interfaces:**
- Consumes: the Task A1 kinds and payload types; the server fixture for capture 7.
- Produces:
  - `ResolvedEnrichment` gains `title: String?`, `topic: String?`, `imageDescriptions: [String: String]` (by attachment id), `people: [PersonItem]`, `circumstances: [CircumstanceItem]`; `.empty` and the initialiser gain them with empty defaults. `ServerOrigin` gains `title`, `topic`, `people`, `circumstances: Bool` and `imageDescriptions: Set<String>`.
  - `ResolvedEnrichment.make(device:server:assetURL:)` fills them by the same rule as `summary` and `tags`: the gold value when its facet is `ok` and the value is present and non-blank, else the device value if a device document ever carries the kind. People with a blank name and circumstance items with a blank label are dropped. A facet that does not decode is skipped and the rest of the document still resolves.
  - `CircumstanceWording.text(for label: String) -> String`: `in_car` "In a car", `walking` "Walking", `running` "Running", `cycling` "Cycling", `on_headphones` "On headphones", `in_a_burst` "Several captures in a row", `daylight` "In daylight", `dark` "After dark"; any other label is returned as written. `CircumstanceWording.confidence(_ value: String) -> String`: "Low confidence", "Medium confidence", "High confidence"; any other value as written.
  - `EnrichmentSearchText.make` appends, after tags: title, topic, each image description, each person's name, and for each circumstance both `CircumstanceWording.text(for:)` and the raw label. Keywords are not added.
  - `GoldSample.make` also writes `display` (title "Sample title from server", topic "sample", two keywords), `image_description` (one item per picture attachment of the capture: "Sample description of this picture."; the facet is omitted when the capture has no picture), `people` (`{name: "Sample Person", source: "user_note"}`), `circumstance` (`in_car` `medium` with evidence `["sample evidence line"]`, and an unknown label `on_a_boat` `low` with no evidence), and sets `schemaMinor` to `FormatVersion.minor`.

- [ ] **Step 1: Write the failing tests.** Resolved: with capture 7's device and server fixtures, `title == "Cafe menu with specials code"`, `topic == "food"`, `imageDescriptions` has one entry keyed by `00000000-0000-4000-8000-000700000001`, `people == [PersonItem(name: "Ana", source: "user_note")]`, `circumstances.map(\.label) == ["in_car", "in_a_burst", "daylight"]`, every matching `fromServer` flag is set and `usesServer` is true; with `server: nil` all five are empty and the flags false; a server document whose `people` facet data is the string `"oops"` still resolves the title; a `display` facet with status `failed` yields no title; a title of `"  "` yields nil. Wording: the eight labels above, `on_a_boat` → `"on_a_boat"`, confidence `certain` → `"certain"`. Search text for the capture 7 fixtures contains the lines `Cafe menu with specials code`, `food`, the description sentence, `Ana`, `In a car` and `in_car`, and does not contain `specials` as a line of its own (keywords are excluded). Gold sample: for a metadata with one picture and one URL the document has all of `summary, tags, link_preview, display, image_description, people, circumstance`; for a text-only metadata `image_description` is absent; the encoded document validates by decoding back equal.
- [ ] **Step 2: `make test`; expect failures.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: `make test` passes.**
- [ ] **Step 5: Commit** (`feat(phone): resolve, search and sample the format 1.2 server kinds`).

### Task D2: Details screen sections for the new kinds

**Files:**
- Modify: `HippoKit/Sources/HippoPresentation/Detail/CaptureDetail.swift` (and `CaptureDetailModel.swift` only if it must pass something new), `App/Hippo/Detail/EnrichmentSections.swift`
- Test: `HippoKit/Tests/HippoPresentationTests/DetailTests.swift`

**Interfaces:**
- Consumes: Task D1.
- Produces, on `CaptureDetail`: `title: String?` and `titleLayer: Layer`; `topic: String?` and `topicLayer: Layer`; `imageDescriptions: [TitledText]`; `people: [PersonRow]`; `likely: [LikelyRow]`; with

```swift
public struct PersonRow: Equatable, Sendable, Identifiable { public var id: String; public var name: String; public var foundIn: String; public var layer: Layer }
public struct LikelyRow: Equatable, Sendable, Identifiable { public var id: String; public var text: String; public var confidence: String; public var evidence: [String]; public var layer: Layer }
```

Decisions:
- Layers: `.gold` when the matching `fromServer` flag says so, else `.silver`.
- `imageDescriptions` are in attachment order, titled the way "Text in image" entries are titled (same helper), one per picture that has a description.
- `PersonRow.foundIn`: `user_note` → "In your note", `shared_text` → "In the shared text", `shared_title` → "In the shared title", an attachment id of this capture → "In attachment N" (1-based position), a comment id of this capture → "In a comment", anything else → "" (the row shows the name alone). `id` is the lower-cased name.
- `LikelyRow.text` and `.confidence` come from `CircumstanceWording`; `id` is the label.
- Screen order inside `EnrichmentSections`: **Title** (new, first; one row), Link previews, Summary, **Topic** (new; one row directly before Tags), Tags, **People** (new; name with `foundIn` as secondary small text), **Likely** (new; each row a `DisclosureGroup` whose label is the text with the confidence as secondary text and whose content is the evidence lines; a row with no evidence is a plain row; section footer "Worked out from signals. Likely, not certain."), Found in this capture, Transcript, Text in image, **In the picture** (new; same disclosure style as Text in image). Every new row uses `.layerStripe(layer, shown: showsStripes)`. A section with nothing to show is not built.

- [ ] **Step 1: Write the failing tests** in `DetailTests.swift` using capture 7's fixtures through the existing test helpers: `detail.title == "Cafe menu with specials code"` with `titleLayer == .gold`; `topic == "food"`; `imageDescriptions.count == 1` and its layer is `.gold`; `people == [PersonRow(id: "ana", name: "Ana", foundIn: "In your note", layer: .gold)]`; `likely.map(\.text) == ["In a car", "Several captures in a row", "In daylight"]`, the first has `confidence == "High confidence"` and three evidence lines; with no server document all five are nil or empty; a person whose source is the capture's second attachment id reads "In attachment 2"; an unknown label `on_a_boat` gives `text == "on_a_boat"`.
- [ ] **Step 2: `make test`; expect failures.**
- [ ] **Step 3: Implement the model fields and the five sections.**
- [ ] **Step 4: `make test` passes; `make sim` builds. In the simulator, use the debug "Write sample server enrichment" button (Settings, developer section), sync, open the newest capture and take a screenshot (`xcrun simctl io booted screenshot`); read it: all five sections show with the gold stripe, "on_a_boat" is shown as written.**
- [ ] **Step 5: Commit** (`feat(phone): show title, topic, picture descriptions, people and likely circumstances`).

### Task D3: Tier switches and the Log section

**Files:**
- Create: `HippoKit/Sources/HippoPresentation/Detail/TierVisibility.swift`, `App/Hippo/Detail/TierSwitches.swift`
- Modify: `HippoKit/Sources/HippoPresentation/Settings/AppSettings.swift`, `HippoKit/Sources/HippoPresentation/Detail/CaptureDetailModel.swift`, `CaptureDetail.swift`, `App/Hippo/Detail/CaptureDetailView.swift`, `EnrichmentSections.swift` (only where a section needs the filtered data)
- Test: `HippoKit/Tests/HippoPresentationTests/TierVisibilityTests.swift`, `SettingsTests.swift`, `DetailTests.swift`

**Interfaces:**
- Consumes: Tasks D1 and D2; `ActivityModel`, `LogLineRow`.
- Produces:

```swift
public struct TierVisibility: Equatable, Sendable {
    public var raw = true, phone = true, server = true, sync = true, log = false
    public static let standard = TierVisibility()
    public func shows(_ layer: Layer) -> Bool          // bronze→raw, silver→phone, gold→server, sync→sync
}
extension AppSettings { public var tierVisibility: TierVisibility { get nonmutating set } }   // keys tier_raw, tier_phone, tier_server, tier_sync, tier_log; unset means the default above
extension CaptureDetail { public func filtered(by v: TierVisibility) -> CaptureDetail }
// CaptureDetailModel
public var visibility: TierVisibility                    // read from settings at init
public func setVisibility(_ v: TierVisibility) async     // saves to settings, reloads
public private(set) var logLines: [LogLineRow]           // loaded only while visibility.log is on
```

Decisions:
- **Server off** is done at the source: `load()` resolves the capture with `server: nil` (and no gold arrival line in Status), so the phone's own values come back wherever gold had replaced them. No separate hiding of gold rows is then needed, but `filtered` still removes anything marked `.gold` so the rule holds for every row.
- `filtered(by:)` removes every row, entry or section whose layer is hidden: `DetailRow`s in `captured`, `context` and each `attachments` group by their `layer`; raw sections (`sharedTitle`, `sharedText`, `links`, comment bodies) under Raw; `linkCards` (a card from the server is gold, else silver), `transcripts`, `recognizedText`, `found`, `summary`, `tags`, a comment's `transcript`, the D2 fields, and pending lines under their layers; `sync`, `storage`, `changedPaths`, `unrestorableNote` and the sync rows of `status` under Sync; `status` lines otherwise by their own layer. `preview` and `exportURLs` are never removed. With Raw off a comment whose transcript is still visible keeps a row with the transcript only.
- The switches: a horizontal row of five small capsule toggles ("Raw", "Phone", "Server", "Sync", "Log") in their own list row directly under the preview, each with a dot in its stripe colour (`Layer.stripeColor`; Log uses `.secondary`), filled when on, outlined when off; one tap toggles; accessibility identifiers `tier-raw`, `tier-phone`, `tier-server`, `tier-sync`, `tier-log` and an accessibility value of "on" or "off". The row stays visible whatever is switched off.
- **Log** on: a "Log" section at the bottom of the same screen listing this capture's lines with the existing `LogLineRow` view, with the same "older lines may have been removed" note `ActivityView` shows when `mayBePruned`. It does not need developer mode. The developer-mode "Activity" link stays as it is.
- The setting is app-wide: every details screen reads it on appear, so a change made on one capture holds on the next and after relaunch.

- [ ] **Step 1: Write the failing tests.** `SettingsTests`: a fresh `UserDefaults` suite gives `TierVisibility.standard` (raw, phone, server, sync on; log off); setting `server = false, log = true` reads back the same from a new `AppSettings` on the same suite. `TierVisibilityTests`: `shows` maps the four layers as above. `DetailTests`, on capture 7 with both fixture documents and on capture 2 with its fixtures: Server off (detail built with `server: nil`, then filtered) has `title == nil`, `people.isEmpty`, `likely.isEmpty`, and capture 2's link card title is the device title, not `"Example Domain (server)"`; Phone off on capture 2 keeps the server's summary and removes the device-only source-app row and any silver link card; Raw off removes `sharedTitle`, `links` and every `.bronze` row but keeps `preview` unchanged; Sync off empties `sync` and `storage`; all five off still returns a detail with the same `preview`; `standard` returns a detail equal to the unfiltered one.
- [ ] **Step 2: `make test`; expect failures.**
- [ ] **Step 3: Implement the type, the setting, the filter, the model changes and the views.**
- [ ] **Step 4: `make test` passes; `make sim` builds. In the simulator on a capture with sample server enrichment, screenshot and read four states: default; Server off (gold sections gone, phone values back); Phone off; Log on (lines at the bottom). Reopen another capture and confirm the switches kept their state.**
- [ ] **Step 5: Commit** (`feat(phone): show or hide each tier in a capture's details, with its log`).

### Task D4: Acceptance rows, folder documents, device build

**Files:**
- Modify: `docs/acceptance.md` (rows `R1`–`R9` in the existing table style, status `not run`), `docs/roadmap.md`
- Check, and modify only if a test shows a gap: `HippoKit/Sources/SyncEngine/FormatBundle.swift` / `FormatUploader.swift` (the 1.2 documents and schema reach `format/` in the folder)
- Test: `HippoKit/Tests/SyncEngineTests/` (the existing format upload tests)

**Interfaces:**
- Consumes: Parts A and D.

Rows to add (reference "Design (desk) §9"):

| ID | Step | Expected |
|---|---|---|
| R1 | Settings → developer → "Write sample server enrichment", sync, open the newest capture | Title, Topic, People, Likely and (for a picture) In the picture show with the gold stripe; "on_a_boat" shows as written |
| R2 | On the Mac run `hippo enrich` on the real folder; wait for Dropbox; sync the phone; open an enriched capture | Its title, topic, summary, tags, picture description, people and likely circumstances match the Mac's `enrichment.json` |
| R3 | Search the timeline for a word that appears only in a picture description | The capture is found |
| R4 | Switch Server off in that capture's details | Every gold element goes; a link title the server had replaced shows the phone's title again |
| R5 | Switch Phone off | Phone-derived elements go; raw content and the server's additions stay |
| R6 | Switch Raw off | Raw sections go; the preview stays |
| R7 | Switch Log on | This capture's log lines show at the bottom, without developer mode |
| R8 | Change the switches, open another capture, then relaunch the app | The switches are as left |
| R9 | Open a capture with no server enrichment | It looks as before this build, plus the switch row |

- [ ] **Step 1: Add or extend a `SyncEngineTests` test asserting the bundled `enrichment-format.md` contains `Facet kinds added in format 1.2` and the bundled schema contains `circumstanceData`; run `make test`.** If the bundle is a copied resource that is out of date, fix how it is refreshed (for example `make generate`) rather than editing the copy by hand, and say what was done.
- [ ] **Step 2: Add the acceptance rows and the roadmap entry.**
- [ ] **Step 3: `make test` passes; `make device` installs the build on Jorge's iPhone** (free Personal Team signing; if the phone is not connected or signing fails, report the exact output and leave the step for Jorge).
- [ ] **Step 4: Commit** (`docs: acceptance rows for server tier and tier switches`).

---

## After the last task

- Whole-branch review against the spec's "Done means" list and anti-goals; `make test`, `scripts/validate-fixtures.sh`, and in `desktop/`: `npm test`, `npm run typecheck`, `npm run build`, `npm run e2e`.
- Confirm with `git status` and `git log --stat` that nothing under `fixtures/` changed except the one Task A1 file and `fixtures/README.md`, and that no `.env`, key or personal data was committed.
- Hand Jorge: the demo on the sample folder, the three commands for his own folder (`hippo enrich --dry-run`, `hippo enrich`, `hippo ui`), the phone build, and the `R` rows to walk.
