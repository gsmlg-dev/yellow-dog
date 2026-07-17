# Server Task 9A1 Report: Durable Config Apply Store

Date: 2026-07-17

## Status

DONE

## Implementation

- Added `YellowDog.ServerAgent.ConfigApplyStore` with the exact public
  `start_link`, `snapshot`, `preflight`, `transition`,
  `pending_publications`, and `acknowledge_publication` interface.
- Persists only `<data_dir>/server/apply_state.json` with the fixed schema,
  concrete Server identity, known-good evidence, runtime status, one attempt,
  monotonic publication counters, and a maximum-three ConfigState outbox.
- Validates exact keys, enums, nullable pairs, revisions, digests, canonical UTC
  timestamps, attempt/checkpoint combinations, publication order, and
  ConfigState encode/decode round trips.
- Implements every fixed transition event and predecessor from the approved
  table, including `uncertain_after_side_effect`, exact duplicate idempotency,
  and conflicting transition rejection.
- Implements non-mutating preflight admission, pure-checkpoint resume,
  terminal/unknown replay, side-effect blocking, expected-revision CAS, and
  fresh-agent fail-closed behavior before ConfigStore staging.
- Requires delivered candidates to be the exact immutable string-key document
  returned by and currently selected in ConfigStore.
- Copies rollback evidence only from ConfigApplyStore known-good state and
  never from ConfigStore delivery history.
- Generates each ConfigState with one injected UTC timestamp, round-trips it
  through `Message.encode/1` and `Message.decode/1`, and persists the encoded
  message atomically with the transition.
- Supports ordered head-only acknowledgement, idempotent old acknowledgements,
  future/non-head conflicts, and publication replay without changing runtime
  evidence.
- On startup, strictly validates the document and active ConfigStore staging
  for pure resumable, side-effect, and unknown attempts. Completed terminal
  evidence is independent of the current ConfigStore pointer. Valid source
  side-effect checkpoints are atomically converted to `unknown` without
  publishing a fabricated terminal state.
- Reconciles every typed `Storage.replace/3` error with one strict
  identity-checked read:
  - exact intended content commits;
  - exact prior content returns the original typed error without changing
    memory;
  - missing, corrupt, different, or identity-changed content fail-stops under
    `{:config_apply_inconsistent_persistence, phase}`.
- Applies lstat-based directory/final-file containment before operations,
  rejects symlinks and non-regular files, and verifies regular-file device and
  inode identity before and after every owned read.
- Returns only stable bounded Sync errors with empty details; storage paths,
  payloads, tokens, and raw reasons are not exposed.

## Independent Review Fixes

- Completed terminal attempts no longer require `ConfigStore.current/1` to
  still select their candidate during startup. A drained terminal candidate 1
  survives a crash after ConfigStore stages candidate 2, allowing candidate 2
  to be admitted, idempotently restaged, and delivered after restart.
- Delivered `staged`/`before_validate` documents now require runtime status to
  match the known-good state before startup can preserve them, and
  same-candidate preflight defensively enforces the same gate.
- `before_install` and `before_activate` source documents now require both
  exact previous/known-good evidence and matching known/unconfigured runtime
  status before startup recovery can normalize the checkpoint to `unknown`.

## Consolidation Review

The production module remains intentionally large because Task 9A1 combines a
fixed transition table, exact durable codec, restart coherence validator,
outbox message validator, persistence reconciliation, and path containment in
one exclusively owned file. The critical review consolidated mechanical
duplication in timestamped publish commits, fixed event-attribute validation,
and enum decoding. The transition and durable-coherence pattern clauses remain
explicit because they directly mirror the normative contract and are the
primary fail-closed audit surface.

## Tests

Focused coverage includes:

- exact start options and initial snapshot;
- every transition family, alternate legal predecessors, and representative
  illegal predecessors/attrs;
- delivered, applying, applied, validation-failed, apply-failed, rollback
  success, and rollback-failed ConfigState round trips;
- expected-revision/known-good gates and fresh-agent rejection;
- non-mutating preflight admission, safe resume, terminal/unknown replay, and
  side-effect blocking;
- delivered and startup staging mismatch/missing/corrupt handling;
- every checkpoint restart and all terminal restart behavior;
- terminal restart after ConfigStore advances to an undelivered next candidate;
- corrupt unknown runtime status at pure and pre-side-effect checkpoints;
- defensive same-candidate pure preflight runtime gating;
- outbox ordering, sequence continuity, capacity, acknowledgement idempotency,
  and conflicts;
- exact duplicate and conflicting transitions;
- replace timeout/error reconciliation for intended, prior, missing, corrupt,
  and other content;
- path-chain/final symlinks, non-directories, and read identity swaps;
- corrupt JSON, unknown keys, invalid nullability, incoherent state, invalid
  sequence, and corrupt encoded messages.

## Verification

- Test-first red run:
  - `devenv shell -- bash -lc 'cd apps/yellow_dog_server_agent && mix test test/yellow_dog/server_agent/config_apply_store_test.exs'`
  - Result: `25 tests, 3 failures`, covering the three missing review
    behaviors.
- Focused ConfigApplyStore tests:
  - `devenv shell -- bash -lc 'cd apps/yellow_dog_server_agent && mix test test/yellow_dog/server_agent/config_apply_store_test.exs'`
  - Result: `25 tests, 0 failures`.
- Full Server-agent tests:
  - `devenv shell -- bash -lc 'cd apps/yellow_dog_server_agent && mix test'`
  - Result: `162 tests, 0 failures`.
- Warnings-as-errors compile:
  - `devenv shell -- bash -lc 'cd apps/yellow_dog_server_agent && mix compile --warnings-as-errors --force'`
  - Result: exit 0, 10 files compiled, no warnings.
- Scoped format check:
  - `devenv shell -- mix format --check-formatted apps/yellow_dog_server_agent/lib/yellow_dog/server_agent/config_apply_store.ex apps/yellow_dog_server_agent/test/yellow_dog/server_agent/config_apply_store_test.exs apps/yellow_dog_server_agent/test/support/config_apply_store_support.ex`
  - Result: exit 0.

## Scope

Owned files:

- `apps/yellow_dog_server_agent/lib/yellow_dog/server_agent/config_apply_store.ex`
- `apps/yellow_dog_server_agent/test/support/config_apply_store_support.ex`
- `apps/yellow_dog_server_agent/test/yellow_dog/server_agent/config_apply_store_test.exs`
- `.superpowers/sdd/server-task-9a1-report.md`

Protected dirty console and root Mix files were left untouched and unstaged.
No ConfigApplier, RuntimeAdapter, Client, Supervisor, Task 8, Sync schema,
runtime app, release, console, or mix file was modified.

## Residual Concerns

- As with the approved Task 8 journal, path-level lstat checks cannot detect the
  narrow race where an attacker swaps a symlink only for the descriptor open
  inside `Storage.read/2` and restores the original same-identity file before
  the post-read lstat. Closing that race requires descriptor-level no-follow
  open and identity verification inside Storage, which is outside Task 9A1
  ownership.
- Task 9A1 intentionally does not supervise this store or invoke runtime
  callbacks. RuntimeAdapter and ConfigApplier sequencing belong to Task 9A2.
