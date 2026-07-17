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
- Every FileOps return is shape-checked and sanitized. Default bounded reads
  and directory syncs preserve close failures rather than discarding them.
- Documents are compared in normalized JSON form, including atom-keyed input;
  structs and non-JSON-native values are rejected.
- Every owned stage is removed after a phase failure, and immutable promotion
  cannot report success when owned-stage cleanup fails. Prior mutable finals
  remain untouched until successful rename.
- Timeouts are synchronous FileOps phase results, not process timers. An
  ambiguous timeout rereads the exact normalized final and can return success
  only after a subsequent directory sync succeeds; no write is retried.

## Focused Coverage

`storage_test.exs` covers bounded/missing/corrupt/scalar reads, injected
oversized successful reads, atomic stage ownership races, same-directory
staging, mutable replacement, JSON-normalized immutable idempotency/collision,
unsupported structs, every injected phase failure, malformed returns from all
FileOps callback families, result-aware cleanup, prior-final preservation,
close-result preservation, typed read/pre-ownership timeouts, synchronous
timeout non-mutation, and durability-confirmed timeout reconciliation.

## Verification

- `devenv shell -- mix cmd --app yellow_dog_server_agent mix test test/yellow_dog/server_agent/storage_test.exs`
  - passed: 42 tests, 0 failures.
- `devenv shell -- mix cmd --app yellow_dog_server_agent mix test`
  - passed: 44 tests, 0 failures.
- `devenv shell -- mix cmd --app yellow_dog_server_agent mix compile --warnings-as-errors`
  - passed with no Server-agent compiler warnings.
- `devenv shell -- mix format --check-formatted apps/yellow_dog_server_agent/lib/yellow_dog/server_agent/storage.ex apps/yellow_dog_server_agent/test/support/storage_file_ops.ex apps/yellow_dog_server_agent/test/yellow_dog/server_agent/storage_test.exs apps/yellow_dog_server_agent/test/test_helper.exs`
  - passed.
- `devenv shell -- mix cmd --app yellow_dog_server_agent mix credo --strict`
  - passed: 147 mods/funs, 0 issues across 10 source files.
- `devenv shell -- git diff --check -- .superpowers/sdd/server-task-8p-report.md apps/yellow_dog_server_agent/lib/yellow_dog/server_agent/storage.ex apps/yellow_dog_server_agent/test/support/storage_file_ops.ex apps/yellow_dog_server_agent/test/yellow_dog/server_agent/storage_test.exs apps/yellow_dog_server_agent/test/test_helper.exs`
  - passed.

`mix cmd --app` currently emits a Mix 1.18 deprecation warning, independent of
the Server-agent source. The app has no local `.formatter.exs`, so a no-argument
app-level `mix format --check-formatted` cannot discover inputs; the explicit
root formatter check above is the scoped format verification.
