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
- Mutable writes use same-directory exclusive stage files, write, file sync,
  close, atomic rename, and directory sync where the platform supports it.
- Immutable writes use the same durable stage protocol and no-replace hard-link
  promotion. Exact existing objects are idempotent; changed objects conflict.
- Every owned stage is removed after a phase failure. Prior mutable finals are
  untouched until successful rename.
- Timed storage calls reread the exact expected final and never retry a write
  blindly.

## Focused Coverage

`storage_test.exs` covers bounded/missing/corrupt/scalar reads, same-directory
staging, mutable replacement, immutable idempotency/collision, every injected
mkdir/open/write/sync/close/rename/link/directory-sync failure, staging cleanup,
prior-final preservation, and ambiguous post-rename timeout reconciliation.

## Verification

- `devenv shell -- mix cmd --app yellow_dog_server_agent mix test`
  - passed: 21 tests, 0 failures.
- `devenv shell -- mix cmd --app yellow_dog_server_agent mix compile --warnings-as-errors`
  - passed with no Server-agent compiler warnings.
- `devenv shell -- mix format --check-formatted` with all four owned Elixir
  paths explicitly listed
  - passed.
- `devenv shell -- mix cmd --app yellow_dog_server_agent mix credo --strict`
  - passed: 0 issues across 10 source files.

`mix cmd --app` currently emits a Mix 1.18 deprecation warning, independent of
the Server-agent source. The app has no local `.formatter.exs`, so a no-argument
app-level `mix format --check-formatted` cannot discover inputs; the explicit
root formatter check above is the scoped format verification.
