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

## Important Review Finding Fix

`AtomicJson.read/3` previously enforced `:max_bytes` only against the metadata
returned by `size/2`. A file that grew or was replaced before `read/2` could
return larger bytes that were decoded without another bound check.

The read path now checks `byte_size(contents)` against the same `:max_bytes`
limit before calling `Jason.decode/1`. The focused regression injects
`size: {:ok, 2}` and a larger valid JSON response from `read/2`, then verifies
the public result is `{:error, :too_large}`.

## Fix Verification

- RED: `devenv shell -- bash -lc 'cd apps/yellow_dog_netboot && mix test test/yellow_dog/netboot/managed_storage/atomic_json_test.exs'`
  reproduced the defect with 11 tests, 1 failure: the expected
  `{:error, :too_large}` was `{:ok, %{"payload" => "abc"}}`.
- GREEN: `devenv shell -- bash -lc 'cd apps/yellow_dog_netboot && mix test test/yellow_dog/netboot/managed_storage/atomic_json_test.exs'`
  passed with 11 tests, 0 failures.
- `devenv shell -- bash -lc 'cd apps/yellow_dog_netboot && mix test'` passed
  with 334 tests, 0 failures.
- `devenv shell -- bash -lc 'cd apps/yellow_dog_netboot && mix compile --warnings-as-errors'`
  completed successfully.
- `devenv shell -- bash -lc 'cd apps/yellow_dog_netboot && mix format --check-formatted'`
  completed successfully.
- `devenv shell -- bash -lc 'cd apps/yellow_dog_netboot && mix credo --strict'`
  checked 39 source files and found no issues.

## Successful Replacement Coverage

The focused suite now distinguishes initial creation from successful
replacement. The replacement test first writes and reads a valid prior object
at the final sidecar path, calls `AtomicJson.write/3` with a different object,
verifies the final file decodes to exactly the replacement object, confirms
the prior bytes are gone, and verifies no caller-owned temporary files remain.
The existing production implementation passed this coverage unchanged.

## Replacement Coverage Verification

- `devenv shell -- bash -lc 'cd apps/yellow_dog_netboot && mix test test/yellow_dog/netboot/managed_storage/atomic_json_test.exs'`
  passed with 12 tests, 0 failures.
- `devenv shell -- bash -lc 'cd apps/yellow_dog_netboot && mix test'` passed
  with 335 tests, 0 failures.
- `devenv shell -- bash -lc 'cd apps/yellow_dog_netboot && mix compile --warnings-as-errors'`
  completed successfully.
- `devenv shell -- bash -lc 'cd apps/yellow_dog_netboot && mix format --check-formatted'`
  completed successfully.
- `devenv shell -- bash -lc 'cd apps/yellow_dog_netboot && mix credo --strict'`
  checked 39 source files and found no issues.
