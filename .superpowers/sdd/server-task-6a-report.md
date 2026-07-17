# Server Task 6A Report: Managed Netboot Profiles

## Scope Delivered

- Added `YellowDog.Netboot.Manifest.ManagedProfile`, a wire-native managed
  profile containing exactly `profile_id`, `name`, `boot_asset_id`, and ordered
  string `arguments`.
- Updated `YellowDog.Netboot.Manifest.Store` to keep managed and configured
  runtime profiles in separate state maps while maintaining the existing ETS
  lookup surface. Managed records take precedence; deleting one reveals a
  configured profile with the same ID.
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
rejection, restart-sidecar load, managed precedence, configured fallback after
delete, malformed/duplicate/oversized sidecars, write/sync/rename failures,
activation rollback, rollback failure, default-profile compatibility, and
legacy sidecar isolation.

## External Blockers

- Full `apps/yellow_dog_netboot` tests cannot start because the unrelated
  `YellowDog.Netboot.Device.Registry` calls unavailable
  `YellowDog.Netboot.Device.Persistence.load/1`.
- `mix compile --warnings-as-errors` is blocked by the corresponding unrelated
  undefined `Device.Persistence.load/1` and `save/2` warnings in
  `device/registry.ex`.
- App-wide `mix format --check-formatted` reports unrelated unformatted
  device, asset, and TFTP files. The owned files are formatted.

No device, asset, TFTP, console, supervisor, Mix, or root configuration files
were modified for Task 6A.
