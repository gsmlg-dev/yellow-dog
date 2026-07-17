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

## Review Fixes

This section supersedes the version-1 persistence and direct-ETS publication
details above. It resolves every finding in
`.superpowers/sdd/server-task-6b-review.md`.

### Durable Legacy Deletion

The managed envelope is now version 2:

```json
{
  "version": 2,
  "devices": [],
  "tombstones": [
    {"uuid": "legacy-device", "mac": "AA:BB:CC:DD:EE:FF"}
  ]
}
```

Each tombstone contains an explicit UUID value, which may be `null` for a
legacy device without a UUID, and a complete normalized MAC. Tombstones are
validated, deduplicated by the complete identity pair, stably sorted, and
loaded before legacy fallback merging. A legacy candidate is suppressed when
either its non-null UUID or normalized MAC matches a tombstone.

Both `delete/1` and `control_delete_device/1` add the deleted device identity
to the same durable candidate transaction. Explicit registration at a
tombstoned MAC removes that MAC tombstone. A control MAC re-key records the old
identity so an unrelated legacy record at the vacated MAC cannot appear after
restart.

Focused tests perform actual supervisor child termination/deletion/start for
both delete APIs and prove the legacy TOML record remains suppressed.

### Cold-Safe Complete State

Hardware information now accepts only bounded JSON-native maps:

- string keys up to 128 bytes
- depth up to 8
- up to 256 total nodes
- up to 64 values per map/list
- UTF-8 strings up to 4,096 bytes
- signed 64-bit integers
- finite floats in the range `-1.0e308..1.0e308`
- booleans, nulls, lists, and nested maps

Atoms, tuples, structs, non-string map keys, excessive depth, excessive
collection size, and oversized strings are rejected by `Device.validate/1`.
The mutation regression proves a nested unknown atom returns
`:invalid_snapshot` before changing either the sidecar bytes or runtime state.
The complete persistence round-trip covers every accepted scalar/container
kind.

Version-2 hardware values are stored directly as JSON and no sidecar decoder
uses `String.to_atom/1` or `String.to_existing_atom/1`. Version-1 sidecars remain
readable when their old tagged hardware maps decode to the accepted
JSON-native representation; old atom/tuple hardware terms are rejected without
creating atoms.

UTC ISO `DateTime` values are the only accepted timestamp representation,
state-history entries must contain exactly state/time, and the complete JSON
envelope is encoded and checked against the same `max_bytes` limit before
atomic replacement. A successful write therefore cannot create a sidecar that
the corresponding fresh load rejects as too large.

### Atomic Public Publication

All public registry readers now call the serialized owner. The owner keeps an
immutable complete device list and MAC lookup map in its GenServer state.
Candidate ETS keys are inserted before stale keys are removed, with normalized
MAC remaining the ETS key, but the candidate is not published to public
readers until the mutation callback returns its complete new owner state.

The existing apply hook is now the injected candidate-publication boundary:
the complete candidate is already durable and mirrored in ETS, while
concurrent public readers remain queued behind the owner. A blocking MAC
re-key regression proves the queued reader receives the complete candidate
only after publication and can never observe an empty, mixed, or partial
registry.

If publication fails, compensation writes the complete prior sidecar first and
then restores the complete prior runtime snapshot. If sidecar restoration
fails, the owner retains the complete candidate runtime matching the candidate
sidecar. If runtime restoration reports failure after the prior snapshot is
restored, the owner retains the complete prior runtime matching the restored
sidecar. Both cases return the distinct `:rollback_failed`.

### Control Delete Coverage

`control_delete_device/1` now has explicit coverage for:

- successful complete candidate persistence
- tombstone persistence and real restart suppression
- initial persistence failure leaving sidecar/runtime unchanged
- no failure broadcast
- apply failure observing the tombstoned candidate sidecar
- sidecar-first, prior-runtime-second compensation

The common every-public-mutation test covers both control deletion and
MAC-based deletion.

### Review TDD Evidence

The first valid review red run produced `116 tests, 13 failures`. Those
failures were the expected missing version-2 state API/tombstones, legacy
delete resurrection, arbitrary atom acceptance, version mismatch, and public
reader visibility at the blocked MAC re-key boundary.

A second red cycle produced `61 tests, 2 failures` for a non-round-trippable
timestamp representation and an oversized sidecar being written despite the
configured read limit.

The final focused device suite produced `118 tests, 0 failures`.

### Review Verification

All final commands ran through `devenv shell` from
`apps/yellow_dog_netboot`.

```text
mix test test/device/device_test.exs \
  test/device/persistence_test.exs \
  test/device/registry_test.exs
118 tests, 0 failures

mix test
405 tests, 0 failures

mix compile --warnings-as-errors
exit 0

mix format --check-formatted
exit 0

mix credo --strict
51 source files, 691 mods/funs, found no issues
```

The final full suite retains the expected unavailable TFTP-root warnings and
the ScriptEngine negative-path missing-assign warning.

During shared-tree verification, one compile attempt encountered incomplete
concurrent Task 6C asset helper edits, and one full-suite attempt produced two
DHCP integration failures while unrelated profile/asset state was changing.
No out-of-scope file was modified. After those owners' edits settled, the DHCP
integration file and the manifest-plus-DHCP and registry-plus-DHCP combinations
all passed with the failing seed; the final quiet-tree app compile and full
suite passed as recorded above.
