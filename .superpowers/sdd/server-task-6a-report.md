# Server Task 6A Report: Managed Netboot Profiles

## Scope Delivered

- Added `YellowDog.Netboot.Manifest.ManagedProfile`, a wire-native managed
  profile containing exactly `profile_id`, `name`, `boot_asset_id`, and ordered
  string `arguments`.
- Updated `YellowDog.Netboot.Manifest.Store` to keep managed and configured
  profiles in separate state maps. Existing `get_profile/1` and
  `list_profiles/0` calls expose configured `Boot.Profile` values only.
  Managed-first precedence is available through explicit
  `get_control_profile/1` and `list_control_profiles/0` APIs; deleting a
  managed record reveals a configured control fallback with the same ID.
- Added a versioned JSON sidecar (`version: 1`) using the approved
  Netboot-local `ManagedStorage.AtomicJson`. The default location is
  `<YellowDog.Config.get_service_data_dir(:netboot)>/managed_profiles.json`;
  `managed_profiles_path` and storage options can be supplied in Store start
  options/config.
- Added managed snapshot, put, and delete APIs. Mutations atomically persist a
  complete candidate before activation. Activation failure writes the previous
  sidecar before restoring the prior visible state; a second persistence or
  restore failure returns a distinct `{:rollback_failed, ...}` result.
- Kept `put_profile/1`, `delete_profile/1`, `reload/0`, and default-profile
  behavior on the configured side isolated from the managed sidecar.

## TDD Evidence

The initial focused red run failed because `ManagedProfile.from_wire/1` and
the managed Store APIs did not exist: 12 tests, 12 failures. After the minimal
model and Store implementation, the focused managed suite passed: 12 tests,
0 failures. An additional oversized-sidecar regression was then added and
verified with the combined profile/store suite.

## Tests

Passed through `devenv shell`:

```text
cd apps/yellow_dog_netboot && mix test \
  test/yellow_dog/netboot/manifest/managed_profile_test.exs \
  test/yellow_dog/netboot/manifest/managed_store_test.exs \
  test/yellow_dog/netboot/manifest/store_test.exs
34 tests, 0 failures

cd apps/yellow_dog_netboot && mix credo --strict
430 mods/funs, no issues

cd apps/yellow_dog_netboot && mix format --check-formatted <owned files>
exit 0

git diff --check
exit 0
```

The focused coverage includes exact wire round trips, scalar-argument
rejection, managed precedence, configured fallback after delete,
malformed/duplicate/oversized sidecars, write/sync/rename failures, activation
rollback, rollback failure, default-profile compatibility, and legacy sidecar
isolation.

## Review Fixes

- Runtime boot compatibility: the ETS-visible runtime collection now contains
  configured `Boot.Profile` values only. Managed wire records are returned only
  by the serialized control lookup/list calls, so BootController and iPXE
  callers retain the existing kernel/initrd/kernel-args representation without
  any coercion.
- Activation containment: callback and visible-store replacement calls convert
  normal errors, raises, throws, and exits into bounded typed atoms. Candidate
  activation failures restore the previous sidecar first and the exact prior
  visible runtime snapshot second. Sidecar and state rollback failures remain
  explicitly distinct.
- Mutation bounds: public managed put/delete encode the complete candidate
  envelope and enforce the configured `max_bytes` before calling
  `AtomicJson.write/3` or activation. An oversized candidate cannot replace the
  prior sidecar or enter managed state.
- Restart coverage: the test now persists through the public API, terminates
  the supervised registered Store, starts a new Store process with explicit
  `managed_profiles_path` and configured fallback options, and verifies
  init-time durable load plus runtime/control precedence.

## Review TDD Evidence

The review regressions were run before the Store correction:

```text
cd apps/yellow_dog_netboot && mix test \
  test/yellow_dog/netboot/manifest/managed_store_test.exs
18 tests, 16 failures
```

The failures demonstrated the managed value escaping through `get_profile/1`,
undefined control-facing APIs, Store exits for callback exceptions/exits,
unsanitized normal activation errors, ignored partial visible mutations, and a
successful oversized public put. After the Store correction and correction of
fallback expectations in the tests:

```text
cd apps/yellow_dog_netboot && mix test \
  test/yellow_dog/netboot/manifest/managed_store_test.exs
18 tests, 0 failures
```

## Final Verification

Executed through `devenv shell` after the parallel device and asset work
settled:

```text
cd apps/yellow_dog_netboot && mix test \
  test/yellow_dog/netboot/manifest/managed_profile_test.exs \
  test/yellow_dog/netboot/manifest/managed_store_test.exs \
  test/yellow_dog/netboot/manifest/store_test.exs --seed 0
42 tests, 0 failures

cd apps/yellow_dog_netboot && mix test
380 tests, 0 failures

cd apps/yellow_dog_netboot && mix compile --warnings-as-errors
exit 0

cd apps/yellow_dog_netboot && mix format --check-formatted
exit 0

cd apps/yellow_dog_netboot && mix credo --strict
612 mods/funs, found no issues
```

The full suite continues to emit its expected unavailable-TFTP-root and missing
EEx-assign warnings from existing negative-path tests; there are no failures.

No device, asset, TFTP, console, supervisor, Mix, or root configuration files
were modified for Task 6A.
