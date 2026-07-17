# Server Task 6B Report: Durable Netboot Devices

## Scope Delivered

- Updated `YellowDog.Netboot.Device` to retain registration hardware metadata
  and validate complete device snapshots, normalized MAC addresses, lifecycle
  state, timestamps, IP addresses, tags, state history, slots, rescue state,
  and JSON-safe hidden runtime terms.
- Replaced lossy TOML writes with a versioned `managed_devices.json` snapshot
  using the approved Netboot-local `ManagedStorage.AtomicJson`.
- Retained the previous TOML decoder as `Persistence.load_legacy/1`.
- Replaced the debounced mutation path with one serialized
  validate/persist/apply/broadcast transaction used by every public registry
  mutation.
- Added UUID-based control snapshot, put, and delete ownership.
- Added focused test support so the default test registry sidecar is isolated
  under the system temporary directory.

No Supervisor, Mix, profile, asset, FileIndex, TFTP/iPXE, packet/socket,
server-adapter, console, or root Mix files were modified for Task 6B.

## Identity And Control APIs

The normalized MAC remains the ETS key and UUID remains the immutable wire
device ID.

```text
control_snapshot/0
control_put_device(device_id, profile_id, mac)
control_delete_device(device_id)
```

Control mutations return `{:ok, prior_snapshot, resulting_snapshot}`.
Control put finds an existing device by UUID, changes only MAC and profile,
and preserves all hidden runtime fields. A MAC re-key removes the old ETS key
as part of complete snapshot activation. Duplicate UUID or normalized MAC
ownership returns `{:error, :conflict}`. Re-registration may fill a previously
missing UUID but cannot replace an existing UUID.

## Persistence And Startup

The managed envelope is:

```json
{"version": 1, "devices": []}
```

Every `Device` field is encoded and decoded, including IPv4/IPv6 tuples,
microsecond timestamps, history entries, hardware metadata with typed nested
terms, slot atoms, rescue state, attempts, errors, architecture, and hostname.
Snapshots are deterministically sorted by normalized MAC and reject duplicate
UUID/MAC ownership.

The default managed path is
`<YellowDog data root>/netboot/managed_devices.json`. Owner start options accept
`managed_devices_path`, `legacy_devices_path`, and `storage_opts`; the existing
config `persist_path` remains the legacy TOML path.

Startup validates and loads managed JSON first. Legacy TOML devices are then
added only when neither their UUID nor normalized MAC conflicts with a device
already selected from managed state or an earlier fallback.

## Transaction And Rollback

Each public mutation:

1. Builds and validates the complete candidate snapshot.
2. Atomically writes, syncs, closes, and renames the managed sidecar.
3. Replaces ETS and updates the registry persistent-term store reference.
4. Broadcasts only after successful activation.

Initial persistence failure returns `:persistence_failed` without changing ETS
or broadcasting. Activation failure restores the prior sidecar before restoring
the prior ETS snapshot. Successful compensation returns `:apply_failed`; a
failed sidecar or ETS restoration returns the distinct `:rollback_failed`.
When durable restoration fails, the candidate remains active so runtime and the
committed sidecar stay aligned.

## TDD Evidence

The first compilable red run produced `63 tests, 29 failures`. The failures
were the expected missing JSON format, complete-field round trip, atomic
failure injection, UUID conflict behavior, control APIs, startup precedence,
persist-before-apply ordering, and rollback semantics.

The first green focused device run produced `103 tests, 0 failures`. A further
red/green cycle added explicit owner option names; the final focused suite is
`104 tests, 0 failures`.

## Verification

All commands ran through `devenv shell` from
`apps/yellow_dog_netboot`.

```text
mix test test/device/device_test.exs \
  test/device/persistence_test.exs \
  test/device/registry_test.exs
104 tests, 0 failures

mix test
371 tests, 0 failures

mix compile --warnings-as-errors
exit 0

mix format --check-formatted
exit 0

mix credo --strict
49 source files, 586 mods/funs, no issues
```

The full test run still emits the existing expected EEx missing-assign warning
from the ScriptEngine negative-path test and unavailable test TFTP-root
warnings; neither produces a failure.
