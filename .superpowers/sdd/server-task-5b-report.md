# Server Task 5B: mDNS MessageCache Control Ownership

## Scope

Implemented only the Task 5B MessageCache owner boundary:

- `apps/yellow_dog_mdns/lib/yellow_dog/mdns/message_cache.ex`
- `apps/yellow_dog_mdns/test/yellow_dog/mdns/message_cache_test.exs`

No Server adapter, ServiceRegistry, ServiceStore, NetworkMonitor, protocol
handling, sockets, Sync dependency, console, or root Mix changes were made.

## Owner API

- `control_snapshot/0` is a synchronous `GenServer.call/2` and returns either
  `{:ok, entries}` or `{:error, :cache_absent | term()}`.
- The snapshot runs after prior cache casts in the same MessageCache mailbox.
  It scans only active answer, authority, and additional record entries and
  returns copied fixed-wire maps with exactly `name`, `type`, and `values`.
- Projection explicitly accepts only the actual legacy test shapes and the
  ExDns producer shapes for A, AAAA, PTR, SRV, and TXT. It validates canonical
  text/domain data and omits every malformed or unrepresentable entry. No
  arbitrary data inspection or fallback stringification is used.
- A and AAAA use `:inet.ntoa/1`; PTR preserves the validated target; TXT keeps
  ordered validated nonempty segments; SRV is exactly
  `priority weight port target`, including the valid unavailable-service root
  target `.`.
- A TXT record containing a zero-length segment remains valid mDNS protocol
  data but is omitted because the fixed Sync cache schema requires each value
  to be `nonempty_text`.
- `control_clear/0` is a synchronous owner call that reads ETS physical size,
  deletes all objects in that same call, and returns `{:ok, count}`. This count
  includes expired, question, unsupported, and malformed objects.
- If the named ETS table is absent while the MessageCache process is alive,
  both control calls return `{:error, :cache_absent}` without terminating or
  restarting the owner and without recreating the table.
- Existing `clear/0` behavior and periodic cleanup are preserved.

## Tests Added

- Exact projection of all five types from `DNS.Message.Record.Data.*` structs.
- Exact projection of legacy primitive/map shapes already used by cache tests.
- Exact SRV root-target projection and explicit zero-length TXT omission.
- Omission of questions, expired entries, unsupported records, and malformed
  address data.
- Serialization of a prior asynchronous `cache_message/3` cast before the
  owner snapshot.
- Exact clear count across active, question, expired, and unsupported ETS
  objects, with an empty table after the call.
- Typed `:cache_absent` result for both owner APIs when either the process or
  its named table is absent.
- Live-process/table-absence tests prove both calls retain the original owner
  PID and do not recreate the table.

## TDD Evidence

The focused test file was run after adding the new tests and before adding
production APIs:

```text
devenv shell -- bash -lc 'cd apps/yellow_dog_mdns && mix test test/yellow_dog/mdns/message_cache_test.exs'
28 tests, 6 failures
```

All six failures were the expected missing `control_snapshot/0` and
`control_clear/0` functions. After implementation, the same test file passed.

For the review fixes, four focused tests were added before production changes:

```text
devenv shell -- bash -lc 'cd apps/yellow_dog_mdns && mix test test/yellow_dog/mdns/message_cache_test.exs'
32 tests, 3 failures
```

The three expected failures were the omitted SRV root target and untyped
crash/restart behavior for snapshot and clear when the table was absent. The
zero-length TXT test passed before the fix, documenting that the existing
omission matches the clarified fixed-schema boundary. After the minimal owner
checks and SRV exception, all 32 tests passed.

## Verification

```text
devenv shell -- bash -lc 'cd apps/yellow_dog_mdns && mix test test/yellow_dog/mdns/message_cache_test.exs'
32 tests, 0 failures

devenv shell -- bash -lc 'cd apps/yellow_dog_mdns && mix test'
339 tests, 0 failures, 2 skipped

devenv shell -- mix compile --warnings-as-errors
passed

devenv shell -- mix format --check-formatted \
  apps/yellow_dog_mdns/lib/yellow_dog/mdns/message_cache.ex \
  apps/yellow_dog_mdns/test/yellow_dog/mdns/message_cache_test.exs
passed

devenv shell -- bash -lc 'cd apps/yellow_dog_mdns && mix credo --strict'
405 mods/funs, found no issues

git diff --check
passed
```

The full mDNS test run emitted pre-existing warnings in handler tests and an
expected supervised listener shutdown log; it completed successfully.

## Concerns

None introduced by Task 5B. The later Server adapter remains responsible for
its own stable pagination, bounding, and revision calculation over the
canonical owner snapshot. The shared worktree contained concurrent
ServiceRegistry/ServiceStore and protected console/root Mix edits; none are
owned or staged by this task.
