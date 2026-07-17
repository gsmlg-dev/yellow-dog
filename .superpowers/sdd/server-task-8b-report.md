# Server Task 8B Report

## Scope

Implemented `YellowDog.ServerAgent.ConfigStore` with focused tests. No
supervision, dispatcher, storage, Sync schema, console, or mix-file changes
were made.

## Behavior

- Requires an absolute data directory, concrete Server ID, concrete profile,
  isolated name, and optional bounded storage options.
- Stages immutable documents at
  `<data_dir>/server/versions/<version>-<digest>.json` and maintains only
  `current` and `previous` pointers in `<data_dir>/server/manifest.json`.
- Validates the fixed Server config envelope, exact target identity, positive
  version, digest, fixed config operation/payload, configured profile, expected
  revision, and deterministic `sent_at` publication time before writing.
- Advances pointers monotonically, preserves exact-current idempotency, and
  leaves an allowed orphan immutable document when manifest replacement fails.
- Exposes only `stage/2`, `current/1`, and `previous/1`; reads validate the
  exact manifest/document shapes, pointer-derived filename, identity, digest,
  config kind, profile, expected revision, and timestamp.
- Before staging a higher version, validates every non-nil current and
  previous pointer through the same strict immutable read path. Missing,
  corrupt, mismatched, or swapped history fails closed before the incoming
  immutable document or manifest can change.
- Defers all Task 9 runtime activation, applied-pointer, lifecycle, and
  rollback behavior.

## Verification

1. Focused ConfigStore tests: `18 tests, 0 failures`.
2. Full Server-agent tests: `106 tests, 0 failures`.
3. `mix compile --warnings-as-errors`: passed.
4. Scoped `mix format --check-formatted`: passed.
5. Scoped `mix credo --strict`: `417 mods/funs, found no issues`.
