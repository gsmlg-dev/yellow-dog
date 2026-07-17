# Server Task 5A Report: mDNS Service Registry Durability

## Scope

Implemented only the Task 5A-owned mDNS service registry/store paths and the
focused registry/store tests. No Server adapter, MessageCache, responder,
handler, client, packet, socket, multicast, goodbye, or console behavior was
changed.

## Implementation

- Control register, update, delete, requested-state toggle, and complete
  snapshot commits execute as one serialized `ServiceRegistry` owner call.
  Each call builds and validates the complete candidate, persists it through
  `ServiceStore`, replaces the registry snapshot, and only then notifies.
- Canonical identity is immutable. The supplied ID must exactly equal
  `name.normalized_type.local`; update rejects name or normalized service-type
  changes as `:immutable_identity` and changes only port and TXT while
  preserving all identity and hidden runtime fields.
- Control registration uses the existing hidden-field defaults and rejects an
  existing canonical ID as `:already_exists` without replacing or persisting
  the duplicate.
- `control_toggle_service/2` takes the requested boolean and writes it
  idempotently. The ID-only control toggle API is not exported; the existing
  legacy public `toggle_service/1` API remains unchanged.
- `ServiceStore` now exposes strict control-only validation/save functions for
  string-key/string-value TXT maps. Existing public load, validation, and save
  paths retain support for previously TOML-representable non-string TXT
  values.
- TOML basic strings now quote keys and escape quotes, backslashes, newlines,
  tabs, carriage returns, and other control characters. Exact control TXT maps
  round-trip through the durable file, including dotted and escaped keys.
- The activation failure seam runs after registry replacement. Successful
  rollback restores the prior file first and the prior registry second. If
  durable restoration fails, the owner does not restore the prior registry;
  it best-effort aligns runtime to the durable candidate and returns
  `:rollback_failed`.
- Persistence and activation failures do not notify. Successful notification
  is observed only after registry replacement. The control path contains no
  multicast, goodbye, client, packet, or socket operation.

## Test Coverage

Focused registry/store tests cover:

- Canonical ID acceptance/rejection, immutable name/type rejection, mutable
  port/TXT updates, and identity/hidden-field preservation.
- Duplicate registration rejection with unchanged registry and durable file.
- Requested-state toggle idempotency across repeated disable/enable calls.
- Strict control TXT rejection while legacy non-string TXT load/save remains
  compatible.
- Exact TOML control TXT round-trips for dots, quotes, backslashes, newlines,
  tabs, and carriage returns in keys and values.
- Candidate durability before activation, post-replacement activation failure,
  successful file-first rollback, and candidate alignment when durable
  rollback fails.
- Notification order and notification absence on persistence/apply failure.
- Typed absent-registry and malformed-snapshot outcomes.

## Verification

Executed through `devenv shell` from `apps/yellow_dog_mdns`:

```text
mix test test/yellow_dog/mdns/service_registry_test.exs test/yellow_dog/mdns/service_store_test.exs
68 tests, 0 failures

mix test
344 tests, 0 failures, 2 skipped

mix compile --warnings-as-errors
compiled 2 files; exit 0

mix credo --strict
420 mods/funs, found no issues

mix format --check-formatted <owned registry/store source and test files>
exit 0

git diff --check
exit 0
```

## Residual Concerns

- The full pre-existing mDNS suite still prints its existing unreachable
  `terminate/2` test-clause warning in `handler_test.exs`; it is outside Task
  5A scope and did not affect the passing suite.
- Protected console/root Mix changes remain in the worktree and are not part of
  this Task 5A commit.
