---
name: hippo-recall
description: Find things the person saved with Hippo (links, photos, screenshots, notes, voice recordings, videos, files) by recalling them the way they remember them, such as "that YouTube short from last week", "the screenshot I took in the car" or "the recipe with bananas". Use it whenever the person asks to find, list or open something they captured, saved or shared to Hippo, and the `hippo` command is available.
---

# Recall from Hippo

People remember a capture by association: roughly when, where, what kind of thing it was, what it was about, what they were doing. The `hippo` command searches a local index of their captures by all of those. You turn their words into a search, run it, refine it, and answer with what was found.

`hippo search`, `hippo show` and `hippo facets` only read the local index. They call no model and change nothing.

## The loop

1. **Learn the vocabulary.** Run `hippo facets --json` once per conversation. It lists the kinds with counts, and every topic, tag, person, site, locality and circumstance label in use, each with a count, and the date range. Use only values that appear there for `tags`, `topics`, `people`, `sites`, `localities` and circumstance `labels`. A value that is not in the vocabulary matches nothing.
2. **Build a spec** from the person's words (fields below). Put what they describe in words into `text`, with your own synonyms and related words as separate entries: for "bananas", `["banana", "bananas", "fruit", "smoothie"]`. Entries combine with OR, so more synonyms widen the search.
3. **Search.** Run `hippo search --spec '<json>' --json`, or use flags (below). The output is `{"total": n, "items": [...]}`, newest first. `total` counts every match, including any cut by `limit`.
4. **Narrow or widen.** Too many results: add a field (a kind, a tighter date range, a site). None: drop the least certain field, widen the dates by a few days, or add synonyms to `text`. People misremember the kind (a "video" may be a link to one; a "photo" may be a screenshot), so try the neighbouring kind before giving up.
5. **Check before quoting.** Run `hippo show <id>` (or `--json`) on a capture before you quote its content or name its files. It prints every field, the evidence behind each circumstance, and the absolute path of every file.
6. **Answer** with each capture's title, local date and time, place when there is one, and the file path or URL the person can open. Say how many matched when you list only some.

Rules:

- Never invent a capture, a title, a date or a path. Report only what `hippo` returned. If nothing matches, say so and say what you tried.
- Circumstances (`in_car`, `walking`, `daylight`, and so on) are worked out by rules from phone signals, each with a confidence. They are likely, not certain: say "probably in the car", not "in the car".
- Dates are the capture's own local date, where it was taken. Use local dates (`YYYY-MM-DD`) in the spec.
- Never run `hippo enrich` yourself, not even with `--dry-run`. Enrichment sends the person's captures to a model provider and writes into their synced folder; it is theirs to start. If captures lack titles or summaries, tell them `hippo enrich` would add them. `hippo index` calls no model and writes nothing into the folder; when `hippo` says there is no index yet, ask the person before running it.

## The spec

All fields are optional. Different fields combine with AND; the values inside one field combine with OR, except `has`, where every value must hold. An empty list is the same as leaving the field out.

| Field | Meaning |
|---|---|
| `kinds` | Any of `link`, `photo`, `screenshot`, `note`, `recording`, `video`, `file`. Each capture has exactly one kind. |
| `text` | Words and phrases matched against titles, summaries, all text, picture descriptions, tags, topic, people, site and circumstances. Each entry is matched literally; a one-word entry also matches as a word prefix and plural forms (`cafe` finds "cafes"); a multi-word entry is an exact phrase. |
| `tags`, `topics`, `people`, `sites` | Whole values from the vocabulary, case does not matter. A site also matches its subdomains: `youtube.com` finds `m.youtube.com`. |
| `time` | `from` and `to` as local dates `YYYY-MM-DD`, both inclusive; `weekdays` (`mon` … `sun`); `parts_of_day` (`morning` 5–12, `afternoon` 12–17, `evening` 17–22, `night`). |
| `place` | `localities` (whole names from the vocabulary), or `near: {lat, lon, radius_m}`. |
| `circumstances` | `{labels: [...], min_confidence: "low" | "medium" | "high"}`; the default minimum is `low`. Labels: `in_car`, `walking`, `running`, `cycling`, `on_headphones`, `in_a_burst` (several captures in a row), `daylight`, `dark`. |
| `has` | `picture`, `audio`, `comment`, `location`, `link`. All listed must hold. |
| `include_ids`, `exclude_ids` | Captures always to include, or always to leave out. |
| `sort` | `newest` (default), `oldest`, `relevance` (best text match first; needs `text`). |
| `limit` | 1 to 5000, default 500. |

A spec with an unknown field, an unknown kind or a malformed date is rejected with exit code 2 and a message naming the field.

The same search as flags, each list flag repeatable or comma-separated:

```sh
hippo search --kind link --site youtube.com --from 2026-11-02 --to 2026-11-08 --circumstance in_car --text "banana fruit" --json
```

`--text "a b"` adds each word as its own entry; `--phrase "a b"` adds one exact phrase. Others: `--tag`, `--topic`, `--person`, `--locality`, `--has`, `--weekday`, `--part-of-day`, `--near lat,lon,radius_m`, `--min-confidence`, `--sort`, `--limit`. `--spec` cannot be mixed with filter flags.

## Worked examples

The values below are invented; use the ones `hippo facets --json` gives you.

### "Find the YouTube shorts from last week"

Today is Wednesday 2026-11-11. "Last week" is the previous Monday-to-Sunday week: this week's Monday is 2026-11-09, so last week ran from Monday 2026-11-02 to Sunday 2026-11-08. The facets list `youtube.com` among the sites. A short is a video on YouTube, but the person shared it as a link, so its kind is `link`; "shorts" goes into `text`, because the URL and title usually say so.

```sh
hippo search --spec '{"kinds":["link"],"sites":["youtube.com"],"time":{"from":"2026-11-02","to":"2026-11-08"},"text":["shorts","short"]}' --json
```

If that returns nothing, drop `text` (not every short says so in its title) and look at the URLs: `/shorts/` in a link's URL marks a short. If the person meant "in the last seven days" rather than the calendar week, use 2026-11-04 to 2026-11-11 instead and say which you used. Answer, for example: "Two YouTube shorts from last week: 'Folding a paper crane in 30 seconds', Tuesday 2026-11-03 at 21:14 (https://m.youtube.com/shorts/…), and 'Sourdough scoring', Saturday 2026-11-07 at 08:40 (…)."

### "The screenshot I took in the car, something about a menu"

The facets list the circumstance `in_car` and the kind `screenshot`. The person is sure of the kind and the subject; "in the car" is a circumstance, which is only likely.

```sh
hippo search --kind screenshot --circumstance in_car --text "menu specials cafe restaurant" --json
```

One result, capture `00000000-0000-4000-8000-000000000007`. Before describing it, check it:

```sh
hippo show 00000000-0000-4000-8000-000000000007
```

It shows the evidence for `in_car (high)`: "audio route was CarPlay", "motion at capture was automotive". Answer: "Probably this one: 'Cafe menu with specials code', a screenshot from Saturday 2026-11-07 at 09:07; you were most likely in the car (the audio was going to CarPlay). The picture is at /…/content/00000000-0000-4000-8000-000700000001.png."

### "That note about the plumber, I think it was in the morning"

No kind is certain (it could be a typed note or a voice recording), so leave `kinds` out and use the words with synonyms, plus the part of day:

```sh
hippo search --spec '{"text":["plumber","plumbing","sink","leak"],"time":{"parts_of_day":["morning"]},"sort":"relevance"}' --json
```

If nothing comes back, drop `time` first: the person was only guessing about the morning. Answer with the title and the note's text from `hippo show`, for example: "'Call the plumber about the upstairs', a note from Saturday 2026-11-07 at 09:01: 'Call the plumber about the upstairs sink.'"
