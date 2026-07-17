# Server Task 9B Management Receipts Report

Date: 2026-07-17

## Status

Implemented the ManagementCore prerequisite for durable exact-replay
`ConfigState` acknowledgements. No Sync schema, `ConfigVersion`, database,
Console, or Server-agent changes are part of this work.

## Persistence Representation

- Existing lifecycle schema v1 remains the exact five-key document:
  `schema_version`, `counter`, `desired_version`, `applied_version`, and
  `versions`.
- Lifecycle schema v2 adds `publication_high_water` and
  `publication_receipts`.
- Each receipt is stored under its canonical decimal sequence and has exactly:
  `sequence`, `encoded_message`, `version`, `state`, `operation`, `digest`, and
  `resulting_state_revision`.
- A clean v1 lifecycle upgrades to v2 only in the same commit that accepts its
  first publication. Any v1 lifecycle containing a non-desired version or a
  non-zero state revision rejects publication acceptance.

## Implemented Contract

- Added
  `YellowDog.ManagementCore.accept_config_state_publication/4` for registered
  servers with the exact public string-key receipt shape.
- Publications are decoded with `YellowDog.Sync.Message.decode/1`, restricted
  to `ConfigState`, re-encoded, and required to match the original bytes.
- Target identity, bounded sequence, desired version, operation, digest,
  acknowledgement fields, transition phase, and expected lifecycle revision
  are validated using the existing lifecycle validators.
- Durable replay lookup precedes current-desired and transition eligibility.
  Exact replay returns the stored receipt without a transition or manifest
  write. Sequence reuse, sequence gaps, and duplicate transition subjects
  conflict.
- New publications commit the lifecycle transition, sequence high-water, exact
  encoded message, and durable receipt in one
  `ManifestStore.commit_section/6` operation.
- V2 reads validate exact keys, canonical contiguous sequences, exact message
  round-trips, target and version coherence, unique transition subjects,
  transition origin, lifecycle timestamps, and resulting revision. Corruption
  fails closed for all lifecycle APIs.
- Existing direct transition APIs preserve v2 receipt state without creating
  receipts or advancing the publication high-water.
- Persisted v2 lifecycle documents require a positive publication high-water
  and a nonempty contiguous receipt ledger. The temporary zero/empty upgrade
  shape exists only in memory inside the atomic first-receipt commit.
- Receipt validation walks canonical numeric sequences and threads the prior
  `{version, resulting_state_revision}` position. Versions cannot move
  backward, and receipts for the same version require strictly increasing
  lifecycle revisions while still permitting a later version to begin at
  revision one.
- Persisted v2 publication state is accepted only for Server targets. Netman
  lifecycle schema v1 remains publishable and readable without receipt state.

## Verification

- TDD review red:
  - Focused ConfigVersions suite: `52 tests, 4 failures`.
  - The failures reproduced v2/zero/empty acceptance, same-version receipt
    swapping, cross-version receipt reordering, and coherent forged Netman v2
    acceptance.
- Focused receipt and existing lifecycle tests:
  `52 tests, 0 failures`.
- Full `yellow_dog_management_core` tests:
  `157 tests, 0 failures`.
- `mix compile --warnings-as-errors --force`: passed after compiling 21 files.
- Scoped `mix format --check-formatted`: passed.
- Changed-file `mix credo diff --strict --from-git-ref HEAD`: one production
  file analyzed, no added issues.
- Full strict Credo scan: 13 existing findings in `commands.ex` and
  `config_version.ex`; none targets the changed receipt implementation.
- Scoped `git diff --check`: passed.

## Scope

Changed production files:

- `apps/yellow_dog_management_core/lib/yellow_dog/management/config_versions.ex`
- `apps/yellow_dog_management_core/lib/yellow_dog/management_core.ex`

Changed tests:

- `apps/yellow_dog_management_core/test/yellow_dog/management/config_versions_test.exs`

The review fixes changed only `ConfigVersions`, its existing focused test file,
and this report. No facade, `ConfigVersion`, Server-agent, Console, Sync, mix,
or protected dirty file change was required.
