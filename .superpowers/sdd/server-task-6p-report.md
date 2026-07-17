# Server Task 6P Report: Netboot-local Atomic JSON Storage

## Delivered

- Added `YellowDog.Netboot.ManagedStorage.AtomicJson` with `read/2-3` and
  `write/2-3` for JSON-object sidecars.
- Added a Netboot-local `FileOps` adapter with per-call `{module, context}`
  injection. No Application environment is used to choose file operations.
- Added a direct Netboot `Jason` dependency.

## Storage Guarantees

- Missing files return the supplied default object.
- Reads check the configured byte bound before decoding and return typed,
  path-free errors for malformed, non-object, oversized, and I/O data.
- Writes create an exclusive unique temporary file in the final file's
  directory, write, sync, close, and rename it into place.
- Write, sync, close, and rename failures best-effort close/remove only the
  caller-owned temporary file. The prior final file is never truncated or
  deleted by this module.

## Verification

- `devenv shell -- bash -lc 'cd apps/yellow_dog_netboot && mix test test/yellow_dog/netboot/managed_storage/atomic_json_test.exs'`
- `devenv shell -- bash -lc 'cd apps/yellow_dog_netboot && mix test'` (333 tests, 0 failures)
- `devenv shell -- bash -lc 'cd apps/yellow_dog_netboot && mix compile --warnings-as-errors'`
- `devenv shell -- bash -lc 'cd apps/yellow_dog_netboot && mix format --check-formatted'`
- `devenv shell -- bash -lc 'cd apps/yellow_dog_netboot && mix credo --strict'`

## Existing Warnings

The full Netboot test run still reports the existing unavailable TFTP-root and
missing EEx assign warnings from unrelated tests; the suite passes and this
task does not change those modules.
