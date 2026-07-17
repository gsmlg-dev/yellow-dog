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
  - Result: 18 tests, 0 failures.
- Full Server-agent tests:
  - `devenv shell -- bash -lc 'cd apps/yellow_dog_server_agent && mix test'`
  - Result: 91 tests, 0 failures.
- Warnings-as-errors compile:
  - `devenv shell -- bash -lc 'cd apps/yellow_dog_server_agent && mix compile --warnings-as-errors'`
  - Result: success.
- Owned-path format:
  - `devenv shell -- mix format --check-formatted` with the CommandJournal
    production, support, and test files.
  - Result: success.
- Owned-path strict Credo:
  - `devenv shell -- bash -lc 'cd apps/yellow_dog_server_agent && mix credo suggest --strict ...'`
  - Result: no issues.
- Guardrail scan:
  - No generic Node abstraction, direct `Concord.*`, raw `:gen_udp`, or
    dependency reference to management core, Store, or Netman in owned files.

## Owned Files

- `apps/yellow_dog_server_agent/lib/yellow_dog/server_agent/command_journal.ex`
- `apps/yellow_dog_server_agent/test/support/command_journal_support.ex`
- `apps/yellow_dog_server_agent/test/yellow_dog/server_agent/command_journal_test.exs`
- `.superpowers/sdd/server-task-8a-report.md`
