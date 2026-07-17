# Server Task 5A Report: mDNS Service Registry Durability

## Scope

Implemented only the Task 5A-owned mDNS service registry/store paths and the
focused registry tests. No Server adapter, MessageCache, responder, handler,
client, packet, socket, multicast, goodbye, or console behavior was changed.

## Implementation

- Added control-safe registry APIs for stable snapshots and serialized
  register, update, delete, toggle, and complete-snapshot commits.
- Canonical service IDs are derived from the registry normalization rules:
  `name.normalized_type.local`. Control registration and updates reject an ID
  that does not exactly match that derivation.
- Control registration builds only the fixed service fields and uses the
  existing registry defaults for host, addresses, enabled state, and normal
  registration state.
- Control updates replace only name, type, port, and TXT fields. Host,
  addresses, enabled, source, state, and registration timestamps remain from
  the prior runtime record. Toggle changes the persisted internal `enabled`
  field, so returned snapshots retain the revision-relevant hidden state.
- Every control mutation constructs the complete candidate snapshot inside the
  registry GenServer call. It validates through `ServiceStore`, saves the full
  candidate file first, replaces registry contents second, then emits the
  existing service-change notification.
- On activation failure, rollback saves the previous file before restoring the
  previous registry snapshot. Owner results distinguish `:apply_failed` from
  `:rollback_failed`; control persistence, malformed snapshot, and absent
  registry failures are typed and do not expose process or filesystem details.
- `ServiceStore.save_services/3` now validates the complete list before
  formatting/writing, and TXT maps require string keys and values so saved TOML
  remains representable.

## Test Coverage

Focused registry/store tests cover:

- Canonical ID acceptance/rejection and service-type normalization.
- Stable prior/resulting snapshots for register, update, toggle, and delete.
- Hidden-field preservation on update.
- Candidate persistence before activation.
- Initial persistence failure without registry/file mutation.
- Apply rollback ordering, file restoration, and distinct rollback failure.
- Typed absent-registry and malformed-snapshot outcomes.

## Verification

Executed through `devenv shell` from `apps/yellow_dog_mdns`:

```text
mix test test/yellow_dog/mdns/service_registry_test.exs test/yellow_dog/mdns/service_store_test.exs
58 tests, 0 failures

mix test
330 tests, 0 failures, 2 skipped

mix compile --warnings-as-errors
exit 0

mix credo --strict
399 mods/funs, found no issues

mix format --check-formatted ...
git diff --check
exit 0
```

## Residual Concerns

- The full pre-existing mDNS suite still prints its existing unreachable
  `terminate/2` test-clause warning in `handler_test.exs`; it is outside Task
  5A scope and did not affect the passing suite.
- A parallel worker has independent, unstaged MessageCache changes. They were
  not modified, staged, or included in this Task 5A work.
