# Server Task 8P Report

## Scope

Implemented only the Server-agent local storage primitive, its direct runtime
dependencies, and focused test support. No journal, config store, dispatcher,
supervisor, facade, status, Sync, Server-control, console, protocol, root Mix,
or release files were changed.

## Implementation

- Added direct `yellow_dog_sync`, `Jason`, and `phoenix_socket_client`
  dependencies to `yellow_dog_server_agent`.
- Added `YellowDog.ServerAgent.Storage` with injectable `FileOps` callbacks.
- Reads are raw-size bounded and accept JSON objects only; missing, corrupt,
  oversized, and I/O failures return sanitized `YellowDog.Sync.Error` values.
- Stage ownership is established only by a successful exclusive open. An
  `:eexist` race retries without removing the foreign path, and cleanup is
  attempted only for a stage this call proved it owns.
- Mutable writes use same-directory owned stage files, write, file sync, close,
  atomic rename, and directory sync where the platform supports it.
- Immutable writes use the same durable stage protocol and no-replace hard-link
  promotion. Exact existing objects are idempotent; changed objects conflict.
- Encoded writes are bounded before parent or stage creation by the same
  configured/default `max_bytes` contract used for reads.
- Every FileOps return, error, exception, throw, and exit is shape-checked and
  converted to a fixed Storage error with empty details. Callback-supplied
  Sync errors and structured reasons cannot cross the boundary.
- Default bounded reads and directory syncs preserve close failures rather
  than discarding them. Default directory sync handles platform `:enotsup`;
  a custom FileOps without `sync_dir/1` is an internal failure.
- Documents are compared in normalized JSON form, including atom-keyed input;
  structs and non-JSON-native values are rejected.
- Every owned stage is removed after a phase failure, and immutable promotion
  cannot report success when owned-stage cleanup fails. Prior mutable finals
  remain untouched until successful rename.
- FileOps failures retain internal phase provenance for mkdir, open, write,
  file sync, close, rename, link, stage cleanup, directory sync, and read.
- Pre-promotion timeouts never reconcile against a preexisting exact final.
  Rename timeout reconciliation requires an absent owned source after the
  synchronous callback. Link timeout reconciliation requires the final and
  owned stage to be the same filesystem identity. Both also require an exact
  normalized final and confirmed directory sync.
- An exact immutable `:eexist` is successful only after directory sync. A
  directory-sync timeout verifies the exact final and retries directory sync
  once; write, rename, and link are never retried.

## Focused Coverage

`storage_test.exs` covers bounded/missing/corrupt/scalar reads, injected
oversized successful reads, atomic stage ownership races, same-directory
staging, mutable replacement, JSON-normalized immutable idempotency/collision,
unsupported structs, every injected phase failure, malformed returns from all
FileOps callback families, secret-bearing callback errors, callback
exceptions/throws/exits, result-aware cleanup, prior-final preservation,
close-result preservation, typed read/pre-ownership/pre-promotion timeouts,
rename source-consumption proof, link filesystem-identity proof, synchronous
timeout non-mutation, and exact-final directory-sync retry without mutation
retry.

## Verification

- `devenv shell -- bash -lc 'cd apps/yellow_dog_server_agent && mix test test/yellow_dog/server_agent/storage_test.exs'`
  - passed: 59 tests, 0 failures.
- `devenv shell -- bash -lc 'cd apps/yellow_dog_server_agent && mix test'`
  - passed: 61 tests, 0 failures.
- `devenv shell -- bash -lc 'cd apps/yellow_dog_server_agent && mix compile --warnings-as-errors'`
  - passed with no Server-agent compiler warnings.
- `devenv shell -- mix format --check-formatted apps/yellow_dog_server_agent/lib/yellow_dog/server_agent/storage.ex apps/yellow_dog_server_agent/test/support/storage_file_ops.ex apps/yellow_dog_server_agent/test/yellow_dog/server_agent/storage_test.exs apps/yellow_dog_server_agent/test/test_helper.exs`
  - passed.
- `devenv shell -- bash -lc 'cd apps/yellow_dog_server_agent && mix credo --strict'`
  - passed: 172 mods/funs, 0 issues across 10 source files.
- `devenv shell -- git diff --check -- .superpowers/sdd/server-task-8p-report.md apps/yellow_dog_server_agent/lib/yellow_dog/server_agent/storage.ex apps/yellow_dog_server_agent/test/support/storage_file_ops.ex apps/yellow_dog_server_agent/test/yellow_dog/server_agent/storage_test.exs apps/yellow_dog_server_agent/test/test_helper.exs`
  - passed.

The app has no local `.formatter.exs`, so a no-argument app-level
`mix format --check-formatted` cannot discover inputs; the explicit root
formatter check above is the scoped format verification.
