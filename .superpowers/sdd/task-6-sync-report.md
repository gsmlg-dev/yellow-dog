# Task 6 Sync Wire-Contract Report

## Scope

- Base: `52516a4f1cd2f06c35966b9a4e603d78bb505bb7`
- Review follow-up parent: `01e5f9069cd5ca90ca1e97b4e71d9fe9a70db14a`
- Branch: `codex/service-node-remote-management`
- Ownership: `apps/yellow_dog_sync` contract modules and focused tests only
- No management-core, console, root configuration, protocol packet, or network changes were made.

## Contract Changes

- Added optional `Envelope.config_version`, encoded only when present.
- Required a positive config version for `:config` envelopes and rejected it for query/command envelopes.
- Changed ConfigState versions to positive JSON integers from `1` through `9_223_372_036_854_775_807`.
- Added coherent nullable `previous_version`/`previous_revision` pairs.
- Added positive nullable rollback `restored_version` and enforced successful/failed rollback field coherence.
- Coupled failure phases to pre-apply, apply, and rollback field requirements.
- Required every present previous version to be earlier than the current version.
- Made direct Envelope decoding exact: all base keys are required and only `config_version` is optional.
- Restricted agent config acknowledgements to `delivered`, `applying`, `applied`, and `failed`; `desired` remains management-owned.
- Preserved operation catalogs, target/digest fields, payload schemas, canonical bounds, atom safety, and stable invalid errors.

## TDD Evidence

RED command:

```sh
devenv shell -- bash -lc 'cd apps/yellow_dog_sync && mix test test/yellow_dog/sync/envelope_test.exs test/yellow_dog/sync/message_test.exs test/yellow_dog/sync/server_operation_test.exs test/yellow_dog/sync/netman_operation_test.exs'
```

Observed before implementation: `76 tests, 13 failures`.

The failures demonstrated the missing prerequisite: config delivery accepted no version, query accepted an injected version, integer ConfigState versions were rejected, desired acknowledgements were accepted, and previous/restored version fields were absent from the wire contract.

GREEN evidence after implementation:

- Focused contract files: `76 tests, 0 failures`
- Full `yellow_dog_sync`: `103 tests, 0 failures`
- `MIX_ENV=test mix compile --warnings-as-errors --force`: passed after compiling 11 files
- `mix format --check-formatted` on the seven owned Elixir files: passed
- Credo strict on Sync `lib/**/*.ex` and `test/**/*.exs`: checked 21 files, no issues

### Review Follow-up

Review RED used the same focused command and was observed before the corrective implementation: `79 tests, 4 failures`.

The failures demonstrated that direct Envelope decoding accepted missing/unknown keys and that equal previous/current versions were accepted. The Server and Netman matrices also contained the rejected phase/rollback combinations that required the same coherence implementation.

Review GREEN evidence:

- Focused contract files: `79 tests, 0 failures`
- Full `yellow_dog_sync`: `106 tests, 0 failures`
- `MIX_ENV=test mix compile --warnings-as-errors --force`: passed after compiling 11 files
- `mix format --check-formatted` on the seven owned Elixir files: passed
- Credo strict on Sync `lib/**/*.ex` and `test/**/*.exs`: checked 21 files, no issues

## Concerns

The umbrella `mix credo` alias dispatches into child apps that do not declare the root-only Credo dependency, so the alias reports `The task "credo" could not be found`. Credo was therefore loaded from the existing root build and run directly against `apps/yellow_dog_sync`; that scoped run passed with no issues. No product-code concern remains within the Sync prerequisite scope.
