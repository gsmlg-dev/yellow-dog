# Server Task 5C Report: mDNS Server Control Adapter

## Scope

Added `YellowDog.Server.Control.Mdns` with focused Server-control tests and
test-only mDNS owner fakes. No mDNS owner, protocol, responder, handler,
client, socket, console, root Mix, or protected file was changed.

## Implementation

- Uses fixed `Module.concat/1` production module names for ServiceRegistry,
  MessageCache, and NetworkMonitor, with validated test-only dependency
  overrides. `yellow_dog` retains no compile-time dependency on
  `yellow_dog_mdns`.
- Validates every adapter payload/result via `ServerOperation` and `Operation`
  before calling owners. Owner exits/unexpected results are sanitized.
- Implements canonical, sorted, bounded, paginated service and discovery
  reads with stable revisions and observed timestamps. Discovery canonicalizes
  tuple and string addresses, de-duplicates exact `{name, address}` identities
  before sorting/bounding/revision calculation, and omits malformed/no-address
  entries.
- Implements `cache.get` from sorted/bounded canonical MessageCache entries.
  `current/2` for cache clear returns the same canonical `%{"entries" => ...}`
  object used by `cache.get`.
- Implements register/update/delete/toggle plus `current/2` revision support.
  Register/update/toggle revisions use only the public resource and enabled
  state. Delete returns a validated `mdns_service` resource reference.
- Implements cache clear with the exact owner-returned removed count.
- Monitor validates its list query then returns typed unsupported without any
  monitor owner call.
- Invalid clock values return a sanitized typed `:apply_failed` error for both
  service and discovery list reads; no public adapter path leaks bare `:error`.

## Test Coverage

The focused adapter suite covers service, discovery, monitor, and cache reads;
all service/cache mutations; create/mutation current state; stable revision
sources; pagination; duplicate registration; immutable identity; owner absence
and error sanitization; malformed snapshots; invalid payload short-circuiting;
Dispatcher-to-real-adapter service availability/profile gates; and real
Dispatcher invalid-payload rejection before service-gate or owner invocation.

The discovery coverage includes repeated tuple addresses, equivalent tuple and
string addresses, repeated string-only addresses, canonical IPv6 projection,
and revision calculation over the unique canonical collection.

No test invokes protocol, handler, responder, client, or socket code.

## Review Fix TDD Evidence

The focused adapter test was run after adding the three review regressions and
before changing production code:

```text
13 tests, 2 failures
```

The failures were the expected duplicate/string-address discovery result and
bare `:error` clock result. The real Dispatcher invalid-payload regression
passed against the existing validation order. After the minimal adapter fix:

```text
13 tests, 0 failures
```

## Verification

Executed through `devenv shell`:

```text
cd apps/yellow_dog && mix test test/yellow_dog/server/control/mdns_test.exs test/yellow_dog/server/control/dispatcher_test.exs
38 tests, 0 failures

cd apps/yellow_dog && mix test
366 tests, 0 failures

cd apps/yellow_dog_mdns && mix test
344 tests, 0 failures, 2 skipped

mix compile --warnings-as-errors
exit 0

cd apps/yellow_dog && mix format --check-formatted <owned adapter/test files>
exit 0

cd apps/yellow_dog && mix credo --strict
1214 mods/funs, found no issues

git diff --check
exit 0
```

## Concerns

The pre-existing full mDNS suite emits its unreachable `terminate/2` test
clause warning and a supervised listener shutdown log. Both were present
outside this task's owned surface; the suite passed.
