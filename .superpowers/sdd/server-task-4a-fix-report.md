# Server Task 4A DHCPv4 Fix Report

## Status

Important findings I1 and I2 from `server-task-4a-review.md` are fixed on
branch `codex/service-node-remote-management`. This repair started from
`599b21623caf5982cbc14cd7d3794c8807ff662c`.

The common DHCP facade and Dispatcher integration identified as C1 remain
outside this repair and are reserved for the coordinator's Task 4C.

## Scope

Owned implementation and test files:

- `apps/yellow_dog_dhcpv4/lib/yellow_dog/dhcpv4/pool_store.ex`
- `apps/yellow_dog_dhcpv4/test/yellow_dog/dhcpv4/pool_store_test.exs`
- `apps/yellow_dog/test/yellow_dog/server/control/dhcpv4_test.exs`
- `.superpowers/sdd/server-task-4a-fix-report.md`

No DHCPv4 adapter or LeaseManager production change was needed. The shared DHCP
facade, Dispatcher, DHCPv6 files, protected console files, and root `mix.exs`
were not edited or staged by this repair.

## Finding I1

`PoolStore.control_validate_pool/1` now requires the CIDR address to equal the
network address for its prefix. Host-address CIDRs such as `192.0.2.7/24` return
exactly `{:error, :invalid}`. `control_persist_snapshot/1` validates every pool
through that same boundary before creating directories or writing files.

Focused coverage proves:

- `192.0.2.7/24` is rejected by control validation.
- The same snapshot is rejected by control persistence.
- No index is created and the durable snapshot remains empty.
- The adapter maps owner `{:error, :invalid}` to the exact Sync
  `%Error{code: :invalid, message: "invalid value", details: %{}}` result
  without calling persistence.

## Finding I2

Control snapshots now use immutable generations under
`data/dhcpv4/.pool-snapshots/{snapshot}/pools/`. Persistence:

1. Validates the complete candidate.
2. Writes every candidate pool into a new generation.
3. Reads every staged file back strictly.
4. Atomically replaces `pools.toml` with the generation pointer and pool index.

The index replacement is the only commit point. A staging or index-write
failure removes the candidate generation and leaves the previous index and all
files it references untouched. Snapshot readers continue to support legacy
indexes; existing `save_pool/1`, `remove_pool/1`, and `save_all_pools/1`
preserve generation mode after the first control snapshot.

The fault test first commits an original snapshot, then creates a directory at
the atomic index temporary-file path. This forces the index commit to fail
after candidate files have been staged and verified. The test proves the index
bytes are unchanged and `control_snapshot/0` still returns the original range
and lease time.

## TDD Evidence

The focused PoolStore test was run after adding regressions and before changing
production code:

```text
cd apps/yellow_dog_dhcpv4 && mix test test/yellow_dog/dhcpv4/pool_store_test.exs
22 tests, 2 failures

Failure 1: failed persistence exposed candidate range_start "192.0.2.40"
instead of original "192.0.2.20".

Failure 2: control_validate_pool/1 returned :ok for "192.0.2.7/24".
```

After implementation:

```text
cd apps/yellow_dog_dhcpv4 && mix test test/yellow_dog/dhcpv4/pool_store_test.exs
22 tests, 0 failures

cd apps/yellow_dog && mix test test/yellow_dog/server/control/dhcpv4_test.exs
11 tests, 0 failures
```

## Verification

All Elixir commands ran through `devenv shell`.

```text
cd apps/yellow_dog_dhcpv4 && mix test
420 tests, 0 failures, 15 excluded

cd apps/yellow_dog && mix test
347 tests, 0 failures

cd apps/yellow_dog_dhcpv4 && mix compile --warnings-as-errors
exit 0

cd apps/yellow_dog_dhcpv4 && mix credo --strict
44 source files, 567 mods/funs, found no issues

mix format --check-formatted \
  apps/yellow_dog_dhcpv4/lib/yellow_dog/dhcpv4/pool_store.ex \
  apps/yellow_dog_dhcpv4/test/yellow_dog/dhcpv4/pool_store_test.exs \
  apps/yellow_dog/test/yellow_dog/server/control/dhcpv4_test.exs
exit 0

git diff --check
exit 0
```

## Concerns

- Task 4 remains incomplete until the coordinator lands and reviews Task 4C
  for the shared DHCP facade and Dispatcher integration.
- Successful immutable generations are retained so a reader that already
  loaded an older index cannot race with generation deletion. A separate,
  reader-aware retention policy may be added later if snapshot accumulation
  becomes operationally significant.
