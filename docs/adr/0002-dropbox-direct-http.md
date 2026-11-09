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
- Unverified: a wrong offset returns `incorrect_offset` carrying `correct_offset`; at most 150 MiB
  per `append_v2` request.
  https://www.dropbox.com/developers/documentation/http/documentation#files-upload_session-append_v2
- Verified: `content_hash` splits the file into 4 MiB (4,194,304-byte) blocks, SHA-256 of each,
  SHA-256 of the concatenated raw digests, hex; an empty file hashes an empty byte string.
  https://docs.dropboxapi.com/dropbox-api/docs/technical-reference/content-hash
- Unverified: `files/list_folder` takes `limit` up to 2000 per page and continues with
  `list_folder/continue`. (The performance page confirms only the `/continue` pattern.)
  https://www.dropbox.com/developers/documentation/http/documentation#files-list_folder
- Verified: rate-limited responses carry `Retry-After` (seconds); `too_many_write_operations`
  can return 0.
  https://docs.dropboxapi.com/dropbox-api/docs/performance
- Verified: PKCE code exchange passes `code_verifier` to `/oauth2/token` without an app secret;
  `token_access_type=offline` on the authorize URL yields a refresh token; refresh is
  `grant_type=refresh_token` plus the `refresh_token`. The page does not say whether `client_id`
  is also sent on refresh; the adapter sends it, which Dropbox accepts for PKCE apps (unverified).
  https://docs.dropboxapi.com/dropbox-api/docs/oauth
- Unverified: `auth/token/revoke` also invalidates the refresh token. The OAuth guide only says
  apps can revoke tokens they hold through that endpoint.
  https://www.dropbox.com/developers/documentation/http/documentation#auth-token-revoke
