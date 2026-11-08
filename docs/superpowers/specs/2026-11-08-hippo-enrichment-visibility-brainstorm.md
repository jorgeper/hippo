# Enrichment visibility — brainstorm notes (handoff)

Status 2026-11-08: **brainstorming in progress, not a design yet.** Decisions below are Jorge's unless marked
*(my call)*. Next step: finish the brainstorm, write the design doc, run the builder check, get Jorge's
approval, then plan and build. Branch: `feat/enrichment-visibility` (from `main` after PR #4 merged).

## Why

On the first device test of the enrichment phase (PR #4), Jorge believed transcripts, link previews,
calendar dates and screenshot text "weren't working". Pulling the store off the phone showed every
enricher had run and the results were stored and readable; most "failures" were invisible results or
captures with nothing to find (a typed note with no time; "at 2" with no AM/PM). Three real bugs were
found and fixed in PR #4. The lesson: nothing in the app tells you **what was added, by which layer, or
whether work is still pending**, so "not done yet", "nothing to find" and "broken" look the same.

## What this batch adds (functionality)

1. **Layer stripes on Detail (decided).** A coloured bar down the left edge of each Detail section or row,
   by where it came from: **bronze** = captured (the package), **silver** = added on the phone,
   **gold** = added by the server. No legend row. A normal setting (not developer-only), **on by default**.
   Mockup: option C in `.superpowers/brainstorm/96850-1794154413/content/layer-badges.html` (gitignored,
   local only). Colours used in the mockup: bronze `#b0763c`, silver `#a2a9b0`, gold `#d4ab2a`.
2. **Progress indicators, always on (decided).** Whenever something is still being worked on, show it:
   a small spinner on timeline rows whose capture still has pending enrichment, gone when done. In Detail,
   a field that isn't ready shows a pending line (for example "Transcribing…") with a spinner. Not a setting.
   *(Where exactly, and the per-kind wording, are my call — confirm in the design.)*
3. **Per-capture Activity log (decided: option A).** Opened from an "Activity" entry at the bottom of each
   capture's Detail. Everything that happened to that capture, oldest first, with times: captured and saved
   (app or share sheet), each on-device enrichment step and its outcome (ok, nothing found, deferred and
   why, failed and why), silver upload, gold arriving or being skipped (and why), package sync steps.
   Same stripe colours, with sync in blue (`#5ac8fa`) *(my call)*.
   Mockup: option A in `.superpowers/brainstorm/96850-1794154413/content/capture-log.html`.
4. **Global developer log in Settings (decided).** Settings › Developer › Log for things that aren't about
   one capture: sync passes (start, end, result), background-task runs, gold pulls and cursor resets,
   enrichment passes (captures processed, early stops), switch changes and backfills.

*(My calls, played back to Jorge without objection — confirm in the design):*
- Activity and the global log sit behind a **Developer mode** switch in Settings, off by default.
- Both logs have a **Copy** button so a log can be pasted into a Claude session.
- Logs persist across app restarts, keep only the most recent entries (cap to be set in the design), and
  record outcomes and counts, **never** transcript, note or OCR text.

## Open questions for the design / builder check

- Is Developer mode available in release builds, or DEBUG only? (The Developer folder destination is DEBUG only.)
- Log storage: a table in the existing SQLite store (shared by app and share extension) vs a file; retention cap.
- The share extension must write "captured/saved" events: cross-process writes to the shared store.
- Which Detail rows/sections get which stripe when a field mixes layers (gold overrides silver per field).
- Do stripes also appear on timeline rows, or Detail only?
- Dark-mode colours for the stripes.
- What the pending state looks like per kind (link preview, place, transcript, text in image, found items).

## Candidates to fold in (not decided — ask Jorge)

Open follow-ups from the enrichment phase (end of `docs/superpowers/plans/2026-11-07-hippo-enrichment.md`
and the `hippo-enrichment-followups` memory):
- Relative dates ("tomorrow") resolve against enrichment run time, not capture time.
- Stale local gold survives a gold cursor reset.
- LinkPresentation may download video on cellular (acceptance row E15 decides).
- Dropbox adapter (Plan 3) must implement `replaceFile`, `listChanges`, `downloadFile`.
- Data detection misses bare times like "at 2" (Apple's detector; a heuristic could help).
- Device acceptance rows E1–E15 in `docs/acceptance.md` are still formally "not run" (confirmed informally
  on 2026-11-08: transcripts, Safari/Instagram/YouTube previews, screenshot text, places).

## Useful debugging recipes (from the 2026-11-08 session)

- `make diagnostics` → enrichment task counts by kind and status.
- List the store: `xcrun devicectl device info files --device <UDID> --domain-type appGroupDataContainer
  --domain-identifier group.com.jorgeper.hippo --subdirectory "Library/Application Support/Hippo"`.
- Copy a file: `xcrun devicectl device copy from ... --source "Library/Application Support/Hippo/<path>" --destination <local>`.
- Screenshot the phone: `xcrun devicectl device capture screenshot --device <UDID> --destination <png>`
  (phone must be unlocked; the lock screen shows a personal wallpaper, so delete those captures).
- Reproduce on the Mac: copy `hippo.sqlite*` + a capture + its enrichment doc into a scratch root and run
  `HippoStore.open(root:)` + `CaptureDetailModel.load()` in a throwaway test.

## Process

Same as the enrichment phase: superpowers brainstorming → design doc in
`docs/superpowers/specs/2026-11-08-hippo-enrichment-visibility-design.md` → builder check → Jorge approves →
superpowers:writing-plans → subagent-driven development → final review → device test → PR to `main`.
