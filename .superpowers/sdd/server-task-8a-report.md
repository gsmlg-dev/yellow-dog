# Server Task 8A Report: Durable Command Journal

Date: 2026-07-17

## Status

DONE

## Implemented

- Added configurable `YellowDog.ServerAgent.CommandJournal` GenServer with:
  - absolute canonical `data_dir`;
  - concrete Server identity;
  - validated capability set;
  - hard `max_records` capacity;
  - injectable UTC clock;
  - injectable nonrecursive local directory scanner;
  - configurable process name and explicit process argument on every public API.
- Added the exact local layout
  `<data_dir>/server/journals/<canonical-request-id>.json`.
- Added strict startup validation for filenames, file types, JSON keys,
  normalized command envelopes, Server identity, fingerprints, timestamps,
  operation results, and sanitized Sync errors.
- Added durable `received -> running -> succeeded | failed | unknown`
  transitions using `Storage.create/3` and `Storage.replace/3`.
- Reconciled every failed `Storage.replace/3` by strictly reading and decoding
  the durable record once:
  - exact intended evidence advances memory and returns the intended result;
  - exact prior evidence preserves memory and returns the typed storage error;
  - different, malformed, missing, or otherwise inconsistent evidence stops
    the GenServer with `:command_journal_inconsistent_persistence`.
- Applied the same exact prior/intended reconciliation to startup pending
  recovery without retrying writes.
- Added lstat-based containment for the owned
  `<data_dir>/server/journals` path chain before startup scanning and record
  creation. Existing symlinks and non-directories are rejected; missing owned
  directories are created one component at a time and revalidated.
- Added exact final-path lstat checks around record creation, transition
  persistence, and reconciliation. New request paths must be absent before
  creation; durable record paths must remain regular non-symlink files before
  the journal claims a reservation or transition. Transition path violations
  fail-stop with `:command_journal_inconsistent_persistence`.
- Revalidated every startup and reconciliation read at the exact final journal
  path. The journal now captures the regular file type, device, and inode
  immediately before `Storage.read/2`, requires the same identity immediately
  afterward, and rejects changed or symlinked paths before decoding or
  accepting the returned document.
- Added regression coverage for exact-content symlinks inserted before reserve,
  symlinks swapped after startup scanning or before a transition,
  post-persistence symlink swaps, and file identity changes immediately after
  startup reads. These cases neither replay outside evidence, modify outside
  files, nor advance in-memory journal state.
- Capped `max_records` at `YellowDog.Sync.Bounds.max_list_entries/0` so every
  accepted full journal remains wire-projectable.
- Added exact terminal replay, request/fingerprint conflicts, pending conflicts,
  and a secondary idempotency-key index that rejects cross-request reuse.
- Added conservative startup recovery that durably replaces `received` and
  `running` records with `unknown` before the GenServer serves calls.
- Added terminal-only, request-ID-sorted, round-trip-validated
  `YellowDog.Sync.Message.Journal` projection.
- Added dedicated test support without changing the shared `test_helper.exs`.

## Verification

- Focused CommandJournal tests:
  - `devenv shell -- bash -lc 'cd apps/yellow_dog_server_agent && mix test test/yellow_dog/server_agent/command_journal_test.exs'`
  - Result: 33 tests, 0 failures.
- Full Server-agent tests:
  - `devenv shell -- bash -lc 'cd apps/yellow_dog_server_agent && mix test'`
  - Result: 112 tests, 0 failures.
- Warnings-as-errors compile:
  - `devenv shell -- bash -lc 'cd apps/yellow_dog_server_agent && mix compile --warnings-as-errors'`
  - Result: success.
- Owned-path format:
  - `devenv shell -- mix format --check-formatted` with the CommandJournal
    production, support, and test files.
  - Result: success.
- Owned-path strict Credo:
  - `devenv shell -- bash -lc 'cd apps/yellow_dog_server_agent && mix credo --strict ...'`
  - Result: no issues.
- Guardrail scan:
  - No generic Node abstraction, direct `Concord.*`, raw `:gen_udp`, or
    dependency reference to management core, Store, or Netman in owned files.

## Residual Concern

- Because `Storage.read/2` owns the descriptor open, path-level lstat checks
  cannot detect the narrow case where an attacker swaps in a symlink for the
  descriptor open and restores the original same-identity file before the
  post-read lstat. Closing that race requires descriptor-level no-follow open
  and identity verification inside Storage.

## Owned Files

- `apps/yellow_dog_server_agent/lib/yellow_dog/server_agent/command_journal.ex`
- `apps/yellow_dog_server_agent/test/support/command_journal_support.ex`
- `apps/yellow_dog_server_agent/test/yellow_dog/server_agent/command_journal_test.exs`
- `.superpowers/sdd/server-task-8a-report.md`
