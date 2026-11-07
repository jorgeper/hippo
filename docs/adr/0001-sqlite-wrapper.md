# ADR 0001: Thin wrapper over the system SQLite

Status: accepted

## Context

The local index (captures, FTS, destinations, sync jobs) lives in one SQLite file
that the main app and the Share Extension open from separate processes. HippoKit
has a no-third-party-dependencies rule, and the needed surface is small: execute,
query, transaction, and versioned migrations.

## Decision

Use the system `SQLite3` module through a small `Database` class instead of GRDB.

- One connection per `Database`, opened with `FULLMUTEX` and serialized by an internal lock.
- `journal_mode=WAL`, `busy_timeout=5000` and `foreign_keys=ON` on every open. WAL lets
  readers and a writer coexist across processes; the busy timeout absorbs short writer contention.
- Transactions use `BEGIN IMMEDIATE` so the write lock is taken up front rather than
  failing on a lock upgrade. They are not reentrant; nesting throws.
- Migrations run in `BEGIN IMMEDIATE` and re-read `PRAGMA user_version` under the lock,
  so two processes opening a fresh file apply v1 exactly once.
- Values are always bound, never interpolated; error messages come from `sqlite3_errmsg`
  and contain no bound values.

## Consequences

- No dependency to track, and the same code builds on macOS and iOS.
- We own the (small) wrapper: no query builder, no record mapping, no observation.
- `SQLITE_BUSY` after 5 seconds surfaces as `DatabaseError.sqlite`; callers decide whether to retry.
- Schema changes are new numbered steps in `Migrations`, each bumping `user_version`.
