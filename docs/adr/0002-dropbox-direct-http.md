# ADR 0002: Direct HTTP for the Dropbox adapter, not SwiftyDropbox

Status: accepted

## Context

The Dropbox adapter must meet the v0 design criteria (§3.1): no third-party dependencies in
HippoKit, everything testable with `swift test` on macOS, a provider-neutral upload checkpoint
(session ID and offset), and one token store shared safely by the app and the Share Extension.

SwiftyDropbox owns its own OAuth manager and Keychain layout. That would conflict with the
cross-process refresh lock and with the checkpoint the sync engine persists, and it would pull a
dependency (and UIKit) into a module that must stay buildable on macOS.

## Decision

Talk to the Dropbox HTTP API v2 directly with `URLSession`, inside the `DropboxAdapter` target.

- Auth is OAuth 2 code flow with PKCE and `token_access_type=offline`, so no app secret is shipped.
- Files up to 8 MiB use one `files/upload`; larger files use upload sessions in 8 MiB chunks
  (a multiple of Dropbox's 4 MiB alignment, far below the 150 MiB per-request cap).
- Integrity uses Dropbox's `content_hash`, implemented in `DropboxContentHash`.
- The adapter retries nothing itself except one token refresh after a 401; the sync engine's
  `RetryPolicy` owns backoff and honours `Retry-After`.

## Consequences

- No dependency to track; HippoKit stays dependency-free and testable on macOS.
- We own a small HTTP client, the token refresh and the error mapping.
- API behaviour changes are ours to notice; the facts below are what the adapter relies on.

## API facts the adapter relies on

Checked on 2026-11-08. "Verified" names the page actually fetched. The API reference page
(www.dropbox.com/developers/documentation/http/documentation) is a script-rendered page whose
endpoint sections could not be fetched, so facts that only live there are marked unverified and
should be checked in a browser before the adapter depends on them.

- Verified: `/files/upload` is meant for files under 150 MB (the docs say "MB"; Hippo treats it as
  150 MiB at most and uses it only up to 8 MiB). Larger files use `upload_session/start`,
  `append_v2` and `finish`.
  https://docs.dropboxapi.com/dropbox-api/docs/performance
- Verified: upload-session chunks should be multiples of 4 MB (Hippo uses 8 MiB, a multiple of
  4 MiB), sent mostly through `append_v2`.
  https://docs.dropboxapi.com/dropbox-api/docs/performance
- Verified (live run 2026-11-08): upload-session start, append and finish with offsets work, for a
  single chunk and for several 1 MiB chunks including a resume from a checkpoint. Still unverified:
  a wrong offset returns `incorrect_offset` carrying `correct_offset` (the adapter's adoption path
  was not exercised live); at most 150 MiB per `append_v2` request.
  https://www.dropbox.com/developers/documentation/http/documentation#files-upload_session-append_v2
- Verified: `content_hash` splits the file into 4 MiB (4,194,304-byte) blocks, SHA-256 of each,
  SHA-256 of the concatenated raw digests, hex; an empty file hashes an empty byte string.
  https://docs.dropboxapi.com/dropbox-api/docs/technical-reference/content-hash
- Verified (live run 2026-11-08): `list_folder/continue` with a garbage cursor takes the reset path
  (the run does not record whether Dropbox answers HTTP 400 or 409 `reset`), and
  `files/get_latest_cursor` on a missing path answers not_found, after which the adapter creates the
  folder and retries.
- Unverified: `files/list_folder` takes `limit` up to 2000 per page and continues with
  `list_folder/continue`. (The performance page confirms only the `/continue` pattern.)
  https://www.dropbox.com/developers/documentation/http/documentation#files-list_folder
- Verified: rate-limited responses carry `Retry-After` (seconds); `too_many_write_operations`
  can return 0.
  https://docs.dropboxapi.com/dropbox-api/docs/performance
- Verified: PKCE code exchange passes `code_verifier` to `/oauth2/token` without an app secret;
  `token_access_type=offline` on the authorize URL yields a refresh token; refresh is
  `grant_type=refresh_token` plus the `refresh_token`. The page does not say whether `client_id`
  is also sent on refresh; the adapter sends it, which Dropbox accepts for PKCE apps (verified, live run 2026-11-08:
  refresh with `client_id` and no secret succeeded).
  https://docs.dropboxapi.com/dropbox-api/docs/oauth
- Unverified: `auth/token/revoke` also invalidates the refresh token. The OAuth guide only says
  apps can revoke tokens they hold through that endpoint.
  https://www.dropbox.com/developers/documentation/http/documentation#auth-token-revoke

## Watch on the first live runs

Behaviour the adapter assumes but that only a run against real Dropbox shows. Check each, and
update the adapter or this list. The live run of 2026-11-08 (`runAdapterContract` and
`listChangesReportsDeletedFolder`) covered the checked items below; the unchecked ones need the
device or a case that run did not reach.

- [x] Upload sessions with 1 MiB chunks and a resume from a checkpoint; `mode add` and
  `strict_conflict` conflicts; `replaceFile` overwrite; `files/download` round trip; `delete_v2` on
  a missing path reports not found.
- [x] `list_folder/continue` with a garbage cursor resets; `get_latest_cursor` on a missing path.
- [x] `get_thumbnail_v2` for a PNG returns an image.
- [x] Token refresh with `client_id` and no secret.
- [x] Deleting a listed folder reaches the change detector as a deleted folder
  (`listChangesReportsDeletedFolder`).
- [ ] `files/list_folder/continue` after the listed root itself (`captures/`) was deleted: the adapter
  expects a 409 `path/not_found` (or `path_lookup/not_found`) and treats it as a cursor reset, so the
  change detector re-baselines and queues a review. If Dropbox instead returns `reset`, or keeps
  answering with an empty page, deleting the whole folder must still reach the review sheet (D5).
- [ ] Whether the `db-<APP KEY>://2/token` redirect URI must be registered in the App Console for the
  PKCE flow with a custom scheme, or is accepted unregistered.
- [ ] `files/get_thumbnail_v2` for videos and HEIC photos: whether it returns an image, and in which
  format, or an unsupported-extension error (the thumbnail is then omitted).
- [ ] `auth/token/revoke` called with an expired access token on Disconnect: whether it fails with 401
  (the refresh token then stays valid on Dropbox's side until it is revoked on dropbox.com) or
  revokes anyway.
