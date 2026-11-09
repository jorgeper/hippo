# Hippo Dropbox phase: brainstorm notes (handoff)

Status, 2026-11-08: the brainstorm has started, and Q1 and Q2 are answered (see "Decided this session"). Nothing below is approved for building yet. These notes are where to resume: settle the open questions with Jorge, write the design doc (`docs/superpowers/specs/YYYY-MM-DD-hippo-dropbox-design.md`), run the builder check, get approval, then write the plan and build with subagent-driven development, as in the enrichment and visibility phases.

Background reading, in this order:
- `docs/superpowers/specs/2026-11-07-hippo-v0-design.md` §3.1 already specifies most of the Dropbox adapter: auth, uploads, integrity, errors, SDK-vs-HTTP choice. It still stands unless something below reopens it.
- `HippoKit/Sources/SyncEngine/StorageAdapter.swift`: the provider-neutral contract the Dropbox adapter implements. The Developer-folder `FilesystemAdapter` is the reference implementation, and the shared AdapterContract tests apply to both.
- `docs/package-format.md`, `docs/enrichment-format.md` and `docs/log-format.md`: what lands in the folder.

## What Jorge described (2026-11-08)

In his words, lightly cleaned up:

- **Connecting.** "When I go to the app, I have a way to configure Dropbox that basically opens some auth flow that gives access to my Dropbox to this app. And in it I choose the folder for Hippo."
- **What's in the folder.** "In that folder, I'm gonna have the logs, I'm gonna have all this data along with the metadata."
- **Syncing.** "As I use Hippo, basically you will go and sync to Dropbox." He was unsure what an iPhone allows in the background, and asked that it at least sync every time he opens the app.
- **Why.** "When I open Dropbox, I will see all my files in there. And ultimately what I want to do is to use this information to connect it to maybe an AI agent that can read from that and use all these memories in whichever way." The folder is the product; the phone is intake. This matches the `hippo-product-direction` memory.
- **Deletes and the new-phone case.** "If I delete things from Dropbox, then they'll delete from the phone and vice versa." Then he qualified it: "We need to be careful … I don't want it to keep a perfect mirror, because if I get a new phone … I don't want it to basically go and wipe everything out in the backend. So maybe the way to think about this is the Dropbox folder has everything and the phone could have a subset, but every time I sync the phone to Dropbox, it'll make sure the work on the phone is in the Dropbox."

## Played back, and Jorge said "this all looks great"

- **Connecting:** Settings has a Dropbox connect button. Dropbox's sign-in opens, Jorge grants access, and he picks the folder. Which folder is still open (Q2).
- **Folder contents:** every capture package with its metadata, the enrichment layers (silver, gold), and the logs. This is the same layout the Developer folder gets today.
- **Sync timing:** this mostly exists already. Hippo syncs on launch, on returning to the foreground, while open, and in iOS background tasks, which iOS grants now and then. Dropbox plugs into the same scheduling. The v0 design adds background `URLSession` uploads, so a started upload can finish after the app is suspended. Timing is never promised.
- **Two copies:**
  - Dropbox is the full set, and the phone holds a subset.
  - Every sync makes sure everything on the phone is in Dropbox.
  - **A capture missing from the phone never means "delete it in Dropbox".** A new or wiped phone must never remove anything remotely.
  - A delete made in Dropbox removes the capture from the phone too. That's new: today nothing flows from Dropbox to the phone except gold.
- **Today's delete:** "Delete from iPhone…" removes only the phone's copy, and its prompt says uploaded copies stay where they are.

## Decided this session (2026-11-08, after the playback)

- **Delete everywhere (Q1, Jorge):** Detail offers "Delete everywhere" alongside today's "Delete from iPhone". The design still needs the mechanics. Recommendation: a tombstone that the next sync applies in Dropbox, so it works offline, and absence alone never deletes.
- **Folder choice (Q2, Jorge):** the user chooses at connect time between:
  - **Hippo's own folder** (`Apps/Hippo`, App folder access), and
  - **broader access**, where they pick any folder (Full Dropbox access).
  - Picking broader access must make it plain that Hippo can then see and change everything in their Dropbox, not just the chosen folder.
  - Dropbox fixes an app's access type at registration (confirmed in Dropbox forum answers by Dropbox staff), so this means **two registered Dropbox apps**, one per access type. Hippo signs in through whichever one the user picks.
  - Folder picking needs a folder browser, using `files.metadata.read` listing.
- **Scope of the folder choice (Jorge, later the same day):** start with **Hippo's own folder only** (`Apps/Hippo`, one App-folder registration). Broader access, with the folder picker and the warning, comes later. Design the connect screen so that option can be added without rework.
- **Registration (Jorge):** he accepts registering in the Dropbox App Console. He'd rather keep it minimal, and wants a guided script.
  - **The "Hippo Dev" test app from v0 §3.1 is dropped.** Real-Dropbox integration tests write to a clearly named test subfolder (for example `Apps/Hippo/_hippo-test/`) or run only on request. The design decides which.
  - Jorge was told and agreed that the alternative, writing through the Dropbox iPhone app via Files, gives weaker guarantees: no verification, sync timing set by the Dropbox app, and unreliable background writes.

## Open questions, most important first

Ask one at a time. Each has my recommendation, which Jorge has not confirmed.

1. **Deleting on the phone.** Should a delete on the phone also delete the capture in Dropbox, or only free up the phone, as today?
   - Jorge's "and vice versa" suggests both ways.
   - His new-phone worry is about absence, not explicit deletes.
   - Recommendation: two explicit actions in Detail, "Delete from iPhone" (today's) and "Delete everywhere". The second writes a tombstone that a later sync applies in Dropbox, so it works offline.
   - Absence still never deletes anything.
2. **Which folder.** v0 §3.1 decided Dropbox's **App folder** access type: Hippo can only see `Apps/Hippo/`, the narrowest permission, and Dropbox creates the folder itself. Jorge now says "I choose the folder", and that needs full-Dropbox access.
   - Recommendation: keep the App folder, maybe with an optional subfolder name inside it.
   - Ask whether he needs it somewhere else, for example so the AI agent reads an existing folder.
3. **What counts as "deleted in Dropbox".** Recommendation:
   - A capture is deleted remotely only when its whole package folder is gone, or its `complete.json` is.
   - A single missing or edited attachment doesn't delete anything. It's ignored, or shown as "changed in Dropbox".
   - Moves or renames inside the folder count as a delete.
   - This needs `listChanges` deletion entries, which the gold pull's adapter call already has a cursor for.
4. **Safety valve for mass disappearance.** If Jorge deletes or renames the whole folder, or disconnects, or a cursor reset makes everything look gone, the phone must not wipe itself.
   - Recommendation: if more than a small threshold disappears in one pass (for example 20 captures or 10%), apply nothing and show a "Dropbox looks different, review?" prompt.
   - A capture the phone hasn't finished uploading is never deleted by a remote change.
5. **New phone.** Should a new install only upload its own captures, or also show older captures from Dropbox, as titles only or downloaded on demand?
   - v0 says a new install doesn't rebuild the library from Dropbox. Jorge's "the phone could have a subset" fits that.
   - Recommendation: no restore this phase. Note it as a possible later phase.
6. **Sync timing.** Is "on open, while open, plus iOS background time and background uploads" enough? Or does he want a visible "Sync now" and a last-synced line? The line already exists from the visibility batch.
7. **Disconnect and switching accounts.**
   - v0 §3.1 and V5: jobs are bound to the Dropbox `account_id`.
   - Captures saved before connecting upload after connecting.
   - Nothing bound to account A is uploaded to account B.
   - Confirm that disconnecting keeps local captures and stops sync, and doesn't delete anything.

## Raised by Jorge, in discussion: reading from the Hippo folder into the phone

Jorge's idea: a setting that picks N days, weeks or months, and the phone downloads captures in that window from the Hippo folder, so the sync is explicit about what the phone holds. This is the answer to Q5 (new phone).

My view, given to Jorge:
- **Worth doing.** It turns "the phone is a subset" into a defined subset, and a new phone gets recent memories instead of starting empty.
- **Cost:**
  - Downloading whole packages: attachments can be large videos, so Wi-Fi by default, with big files fetched on tap.
  - Validating each package against `package-format.md` before indexing it.
  - Marking downloaded captures as already in Dropbox, so they're never re-uploaded.
  - Making it play well with remote deletes and Delete everywhere.
- **Sizing:** it's a second substantial feature next to connect, upload and deletes. Recommendation: design both together, but build the download window as its own follow-on plan, or as the last tasks of this one if it stays small.

Open: whether the window also **removes** older captures from the phone to save space, or only **fetches** missing ones. Removing touches the "never lose a capture that isn't safely in Dropbox" rule.

## Raised by Jorge, in discussion: pointers instead of copies

Jorge asked whether the phone could keep a pointer to the original instead of copying everything into Hippo's store, for example a pointer to a picture in Photos.

My view, given to Jorge:
- **Pointing at Photos isn't reliable from the share sheet.**
  - The share extension receives the image's bytes or a temporary file, not its Photos identifier.
  - An identifier comes only from Hippo's own photo picker in the main app, or from matching the image against the whole library, which needs full Photos access and is slow and unreliable.
  - The original can also be deleted, edited, or held only in iCloud ("Optimize iPhone Storage").
- **It weakens the save guarantee.** "✓ Saved on this iPhone" means the bytes are safe even if the original goes away. And the folder is the product, so Dropbox needs the real bytes anyway.
- **The alternative proposed:** point at the Dropbox copy instead. Once a capture's upload is verified, the phone may drop its large attachment bytes and keep the metadata, enrichment and a thumbnail, downloading the original on tap.
  - This saves the same space without the fragility.
  - It's the same machinery as the download window.
  - It's the "remove older captures" half of that question.

Open: confirm that phone storage space is what this is for.

## Already decided: from v0 §3.1 and the parked follow-ups

These carry into the design unless Jorge reopens them.

- **Auth and storage:** OAuth 2 PKCE as a public client with `token_access_type=offline` in `ASWebAuthenticationSession`. Tokens are stored in the shared Keychain access group. Background and extension code never shows UI; an expired login moves the job to `needs_authentication`.
- **Scopes:** `files.content.write`, `files.content.read`, `files.metadata.read`, `account_info.read`. The `files.content.write` scope covers deletes too.
- **App keys:**
  - App keys go in the gitignored `Config/Secrets.xcconfig`, with a committed `Secrets.example.xcconfig`.
  - Integration-test credentials, if any, go in a gitignored `.env` with a committed `.env.example`, and the tests are skipped when they're absent.
  - The separate Hippo Dev app is dropped (see "Decided this session").
- **Uploads:**
  - Small files use single-request upload; large ones use upload sessions with the checkpoint persisted (session IDs are sensitive and never logged).
  - Writes use `mode: add` and `autorename: false`. On a conflict, a matching size and `content_hash` counts as success; otherwise the job is blocked as a content conflict and nothing is overwritten.
  - `content_hash` is computed locally (SHA-256 per 4 MB block, then SHA-256 of the concatenated digests) and verified before `complete.json` is written.
  - One round-trip download is checked by SHA-256 in integration.
- **Errors:** expired or revoked token, offline, `429` with `Retry-After`, `insufficient_space` (blocked, user action), 5xx, and expired upload session (restart that file).
- **Background transfers:** use a background `URLSession` with the App Group `sharedContainerIdentifier` for upload-from-file, and refresh the access token first.
- **SDK or direct HTTP:** check SwiftyDropbox against PKCE refresh in a shared Keychain, background upload-from-file, extension use and checkpoint persistence. Prefer the SDK if it covers all four; otherwise use `URLSession` directly. Record the choice in an ADR, and keep the SDK inside the adapter.
- **Parked follow-ups** (memory `hippo-core-parked-followups`) that must land in this phase:
  - The adapter honours Task cancellation within `BackgroundActivity.expiryGrace` (2 s), so a long upload can't outlive the background assertion (0xdead10cc risk).
  - `replaceFile` uses upload mode overwrite and is allowed only under `enrichments/` and `logs/`, matching the FilesystemAdapter rule.
  - `listChanges` uses `list_folder` recursive plus `continue`, and a `reset` maps to `cursorReset`.
  - `downloadFile` is implemented.
  - The shared AdapterContract tests run against real Dropbox, in a test subfolder.
  - Log uploads are throttled on cellular. Today's log file re-uploads on every pass, so limit it to at most every 15 minutes or Wi-Fi only.
- **Also parked, worth considering with sync:**
  - No foreground retry timer for `next_attempt_at`.
  - No refresh when connectivity returns in the foreground.
  - Dropbox makes both more visible.

## Jorge has to do these before the build (not before the design)

- Create the Dropbox app(s) in the App Console with Scoped access and the four scopes, using a guided script the build provides:
  - "Hippo" with App folder access;
  - plus, for the broader-access option, a second app with Full Dropbox access.
  - Their app keys go in `Config/Secrets.xcconfig`. The README documents the steps.
- Keys never go into git and never get pasted in full into chat. Show only the first and last four characters.

## Device acceptance to plan for

`docs/acceptance.md` rows 1–24 are still "not run". Several of them have upload halves that waited for Dropbox (offline screenshot, round trip, voice note, backlog drain, background sync). The design should add Dropbox rows covering:
- connect and disconnect;
- first upload of the backlog;
- delete in Dropbox reaching the phone;
- a new phone not wiping anything;
- the safety valve;
- the switch-account case from V5.
