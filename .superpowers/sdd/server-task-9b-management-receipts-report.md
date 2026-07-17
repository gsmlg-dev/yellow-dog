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

## Verification

- Focused receipt and existing lifecycle tests:
  `48 tests, 0 failures`.
- Full `yellow_dog_management_core` tests:
  `153 tests, 0 failures`.
- `mix compile --warnings-as-errors --force`: passed.
- Scoped `mix format --check-formatted`: passed.
- `mix credo --strict`: 13 existing findings outside the changed receipt
  implementation; no finding targets either changed production module.
- Scoped `git diff --check`: passed.

## Scope

Changed production files:

- `apps/yellow_dog_management_core/lib/yellow_dog/management/config_versions.ex`
- `apps/yellow_dog_management_core/lib/yellow_dog/management_core.ex`

Changed tests:

- `apps/yellow_dog_management_core/test/yellow_dog/management/config_versions_test.exs`

No `ConfigVersion` change was required.
