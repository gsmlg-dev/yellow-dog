# Server Task 7B Report: Durable `YellowDog.Config.Manager`

## Status

Complete. `YellowDog.Config.Manager` is the console-independent serialized
owner for durable service-scoped configuration reads, versions, activation,
and rollback.

## Owned Changes

- Added `YellowDog.Config.Manager` with effective/source/revision/validation
  reads and update/apply/rollback owner operations.
- Added local durable storage primitives for unique same-directory temporary
  writes, file sync, close, atomic rename, directory sync where supported,
  immutable history creation, and safe rereads.
- Added `YellowDog.Config.Application` supervision for the production Manager.
- Added `YellowDog.Config.Writer.encode_config/2` so the Manager uses the
  existing TOML encoder without delegating installation ownership.
- Added focused Manager and Writer tests.
- Added only `:crypto` as an OTP extra application; no umbrella application or
  management-core dependency was introduced.

## Transaction And History Model

- Mutations lock on the canonical expanded config path across Manager
  processes and are also serialized by each Manager GenServer.
- The complete original TOML bytes and exact prior Config Agent map are
  captured before mutation.
- The complete TOML is decoded, merged with `Schema.defaults/0`, updated only
  for the selected service, and validated as a full candidate.
- Each service receives a durable positive baseline version. Immutable version
  records retain exact snapshot bytes and a stable SHA-256 digest. Lifecycle
  changes are append-only records, so failed versions remain evidence but
  never become the next operation's prior applied version.
- Installation uses a unique same-directory temporary file followed by write,
  sync, close, atomic rename, directory sync where supported, and exact
  reread/full-schema validation.
- The Config Agent is replaced only from the validated installed reread.
  Activation runs afterward through an injected concrete owner. `applied` is
  recorded only after activation succeeds.
- Any failure after durable version creation compensates by atomically
  restoring exact prior bytes, restoring the exact prior Agent map, and
  reactivating prior runtime state. Failure and rollback reasons are bounded
  and sanitized. Incomplete compensation returns distinct `rollback_failed`.

## Public Safety

- Effective reads return recursively typed entries and redact credential,
  material, local-path, raw-body, and unsupported compound values.
- Source reads return only `managed`, `local`, or `default`.
- Revision reads return only the normalized selected-service digest.
- Validation reads return bounded field/message documents without parser
  exceptions or local paths.
- No API returns the config path, history path, raw TOML, snapshots, secrets,
  file handles, PIDs, or raw exceptions.
- Durable revisions do not use `YellowDog.Config.get_version/0`.
- Generic reload and update/apply/rollback without a concrete activation owner
  return typed `unsupported`.

## Verification

- Focused Manager/Writer:
  `cd apps/yellow_dog_config && mix test test/yellow_dog/config/manager_test.exs test/yellow_dog/config/writer_test.exs`
  - 23 tests, 0 failures.
- Full Config app: `cd apps/yellow_dog_config && mix test`
  - 105 tests, 0 failures.
- Compile:
  `cd apps/yellow_dog_config && mix compile --warnings-as-errors --force`
  - 10 files compiled, no warnings.
- Format: root `mix format --check-formatted` with the owned Config file list.
  - Passed.
- Credo: `cd apps/yellow_dog_config && mix credo --strict`
  - 17 files checked, no issues.

## Concerns And Integration Notes

- Task 7B intentionally does not invent generic service activation. Production
  update/apply/rollback remains unsupported until a later integration supplies
  a concrete activation owner for that service.
- Generic reload remains unsupported by design.
- The Manager stores immutable sidecar history beside the configured TOML by
  default; deployments may set `:history_dir` in the Manager application
  options when a dedicated durable location is required.
- Unrelated console, root Mix, Netboot control, and other worktree changes were
  not modified or staged.
