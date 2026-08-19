# Hippo — Product Requirements Document

**Status:** Draft v0.1 · August 2026
**Platform:** iOS (iPhone-first)
**One-liner:** Email-yourself, evolved. Capture anything in under 2 seconds with zero decisions; recall it naturally by asking or wandering.

---

## 1. The problem

People with lots of ideas and inputs — videos, emails, articles, whiteboard photos, shower thoughts — have no fast way to keep them. The most common real-world workaround is **emailing yourself**, because it's the only capture method with truly zero decisions: no folder, no tags, no app to choose.

Every existing tool (Notes, Notion, Pocket, Readwise) fails the same way: **capture is cheap but recall is bankrupt.** They make you organize at capture time (friction kills the habit) and browse folders at recall time (the archive becomes a landfill you never revisit).

### The core bet

> You should never make a single organizational decision at capture time, and never browse folders at recall time. **Capture is a reflex; recall is a conversation.**

Asymmetric effort is the design principle: **dumb-fast capture → smart-slow processing → natural-language recall.** Existing apps get this backwards by making the human do the organizing.

### Why "Hippo"

The hippocampus is the brain organ that does exactly what this app does: it doesn't *store* memories, it *indexes* them for retrieval and replays them for consolidation. Friendly, memorable, billboard-ready, great icon.

The recall assistant persona inside the app is **the Librarian** — a Snow Crash homage: the calm software daemon that has read everything you ever threw at it and just answers, conversationally, with sources.

---

## 2. Capture (the reflex)

**One rule: every path into Hippo takes under 2 seconds and asks zero questions.** Nothing is filed. Everything lands in one undifferentiated stream.

| Path | Behavior |
|---|---|
| **Private email address** (`you@hippo.app`) | The trojan horse. Forward emails, subscribe newsletters to it. The user's existing email-yourself habit keeps working on day one — zero behavior change to start. |
| **Share sheet** | YouTube video, tweet, article, TikTok: two taps, no confirmation screen. Swallows it and closes. |
| **Action button / lock screen widget → camera** | Whiteboard captured before the meeting room empties. |
| **Voice mode** | Hold button, speak ("idea: what if the FTP client auto-resumed…"), release. Done. |
| **Screenshot vacuum** (opt-in) | Notices new screenshots; asks once, in a batch, later — never in the moment. |

Capture also silently records **episodic context** the user would never write down: location, time, what was captured just before. Human memory is episodic — people remember "I was at the airport and it was about pricing," not the article title.

---

## 3. Enrichment (the invisible magic)

While the user sleeps, Hippo reads everything:

- **Whiteboard/photos** → OCR; diagrams described ("architecture sketch with three boxes labeled ingest, index, recall")
- **Videos** → transcript fetched or generated; summarized
- **Articles/emails** → full text extracted; summarized
- **Voice memos** → transcribed
- **Everything** → embedded for semantic search; auto-linked to related items ("this whiteboard photo relates to that voice memo from March about the backup CLI")
- **Visual card generated at ingest** for anything without a strong image — browse mode depends on every item having a visual representation

**On-device first:** Apple's on-device models handle OCR, transcription, and embeddings locally — private, free to run, works offline. Cloud LLM is used only for synthesis queries.

---

## 4. Recall (the conversation)

No folders. No tag browser. A chat/search box — the Librarian — that speaks how memory actually works:

- *"that video about pricing psychology, maybe 2 months ago"*
- *"the whiteboard from the meeting with the three-box diagram"*
- *"everything I've saved about FTP or backups"* → returns a **synthesized brief with sources**, not 40 links
- **Resurface mode:** a daily/weekly digest — "you saved these 5 things about app ideas this month; three of them connect" — so the archive pushes back instead of rotting.

Trust constraint: recall quality must be genuinely good in the first week or trust dies instantly.

---

## 5. Browse (reminiscence)

Search only works when you know you're looking for something. Much of the archive's value is **re-encountering things you forgot you saved — you can't query for what you don't remember exists.** Recall is *retrieval*; browse is *reminiscence*. Browse is not a secondary feature; it is the other half of memory.

"Natural" browsing cannot mean folders or an infinite reverse-chron list (that's the landfill again). It exploits how human memory is actually indexed:

### 5.1 Time scrubber (episodic browsing)
A fast, fluid timeline flicked through like the Photos scrubber. Every item shows as its **most visual** representation: whiteboard photo, video thumbnail, article hero image, waveform card for voice memos. Zoomed out, days collapse into auto-named "chapters": *"Mid-March — the packrat backup idea week."* People remember eras, not dates.

### 5.2 Self-forming clusters (semantic browsing)
Embeddings make the map free: items self-organize into gravity wells — "app ideas," "pricing stuff," "home renovation." Wandering into a cluster juxtaposes everything across formats (video next to whiteboard next to email) — where the "oh right, THAT" moments live. **These are not folders:** nothing was filed, the structure is recomputed, it never goes stale, the user never maintains it.

### 5.3 Shuffle / walk mode (serendipity browsing)
Deliberately aimless: full-screen cards, one at a time, swiped like a slot machine of your own brain. Weighted toward things unseen in a while and things related to *recent* captures (old stuff becomes newly relevant). The waiting-in-line mode — two minutes beats doomscrolling and occasionally pays off huge.

### 5.4 Pivot browsing (connective tissue)
From any item: "more like this" — one tap to its semantic neighbors. Browse stops being a mode and becomes something that happens from anywhere, including from search results. **Search finds the trailhead; pivoting is the hike.**

### Design convictions

1. **Browsing must be visual and fast above all.** The dopamine loop of flicking through Photos is the bar. A list of titles is dead on arrival.
2. **No browse-tab ghetto.** The home screen *is* the browse surface (scrubber + clusters); search/chat is an overlay pulled down over it. Capture-first apps get this backwards by opening on an input box.
3. **Browsing generates signal.** Lingering, pivoting, and re-opening teach the recall engine what matters — improving search and the resurfacing digest without a single explicit rating.

---

## 6. Why this wins (and isn't another Notion)

1. **The email address is the trojan horse** — zero behavior change required; it upgrades a habit the user already has.
2. **Asymmetric effort** — dumb-fast capture, smart-slow processing, natural-language recall.
3. **On-device first** — private, free to run, offline-capable; cloud only for synthesis.
4. **Browse as reminiscence** — the archive pushes back at you; it never rots.

---

## 7. Scope

### MVP (v1)
- Email ingestion (private address)
- Share sheet capture
- Photo capture + OCR
- One stream, semantic search over it (the Librarian, basic)
- Time scrubber home screen with visual cards

### v2
- Voice capture + transcription
- Video transcript extraction + summarization
- Clusters view, pivot browsing
- Resurface digest
- Screenshot vacuum

### Later
- Shuffle/walk mode
- Auto-named chapters
- Synthesized multi-source briefs
- Cross-device / web capture

---

## 8. Risks & open questions

- **Video transcript extraction across platforms is whack-a-mole** (YouTube, TikTok, Instagram all fight scraping).
- **First-week recall quality is existential** — if the Librarian whiffs early, trust never recovers.
- **Email deliverability/abuse** on the private-address ingestion path.
- Name/trademark check for "Hippo" in the App Store still to do.
- Business model TBD (likely subscription; on-device processing keeps marginal cost near zero).
