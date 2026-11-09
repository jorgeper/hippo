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

Each is from the Dropbox HTTP documentation and should be re-checked at the linked page when the
adapter changes. These were recorded from knowledge of the docs, not fetched at writing time.

- A single `files/upload` request carries at most 150 MiB.
  https://www.dropbox.com/developers/documentation/http/documentation#files-upload
- Upload-session chunks should be multiples of 4 MiB (except the last); a wrong offset returns
  `incorrect_offset` with the `correct_offset`. At most 150 MiB per `append_v2` request.
  https://www.dropbox.com/developers/documentation/http/documentation#files-upload_session-append_v2
- `content_hash` is SHA-256 of each 4 MiB block, then SHA-256 of the concatenated digests, hex.
  https://www.dropbox.com/developers/documentation/http/documentation#content-hash
- `files/list_folder` accepts `limit` up to 2000 entries per page and continues with
  `list_folder/continue` using the cursor.
  https://www.dropbox.com/developers/documentation/http/documentation#files-list_folder
- Rate limiting answers 429 (or 503) with a `Retry-After` header in seconds.
  https://www.dropbox.com/developers/documentation/http/documentation#error-handling
- PKCE refresh needs no app secret: `grant_type=refresh_token` with `refresh_token` and `client_id`.
  https://www.dropbox.com/developers/documentation/http/documentation#oauth2-token
- `auth/token/revoke` revokes the access token and also the refresh token it came from.
  https://www.dropbox.com/developers/documentation/http/documentation#auth-token-revoke
