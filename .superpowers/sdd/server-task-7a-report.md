# Server Task 7A Report: Identity Owner Facade

Date: 2026-07-17

## Status

COMPLETE

This report supersedes the earlier Task 7A report. The revised implementation
removes the fabricated approval ID and token label projections and follows the
revised authoritative brief.

Identity now owns transport-safe host snapshots, serialized host control
mutations, and sanitized audit snapshots. Unsupported approval and token
control surfaces return a stable typed result without reading or mutating
Registry persistence.

## Owned Changes

- `apps/yellow_dog_identity/lib/yellow_dog_identity.ex`
- `apps/yellow_dog_identity/lib/yellow_dog_identity/registry.ex`
- `apps/yellow_dog_identity/test/yellow_dog_identity/control_facade_test.exs`
- `.superpowers/sdd/server-task-7a-report.md`

`token.ex` did not require a change. No Server adapter, Dispatcher, Config,
console, root Mix, Netboot, protocol, Mnesia, Concord, or protected file was
modified for Task 7A.

## Supported Owner Contract

The following `YellowDogIdentity` owner APIs remain supported:

- `control_list_hosts/0`
- `control_host/1`
- `control_approve_host/1`
- `control_revoke_host/1`
- `control_delete_host/1`
- `control_list_audit/0`

Each public host snapshot contains exactly:

- `host_id`
- `name`
- `state`
- `revision`

No host struct, key material, trust evidence, metadata, previous key, raw
filesystem reason, or persistence path is returned.

## Canonical Host Revision

Host revisions are calculated by
`YellowDog.Server.Control.Revision.calculate/1`, the same canonical normalized
JSON digest path consumed by Server Dispatcher revision checks. The local
Erlang external-term digest helper was removed.

The regression test calculates the revision independently with the Server
helper against the same public host resource, both with and without its
embedded `revision` field, and requires exact equality. It also verifies the
snapshot remains identical after a Registry restart.

## Unsupported Boundaries

These owner surfaces now always return `{:error, :unsupported}`:

- `control_list_approvals/0`
- `control_list_tokens/0`
- `control_token/1`
- `control_revoke_token/1`

They do not contact Registry, expose structs, reveal raw token secrets or
hashes, or mutate token persistence. Approval ID is not substituted with host
ID, and token label is not substituted with token ID or hostname pattern.

The exhausted-token regression persists and consumes a max-use token, then
proves that list/get/revoke remain unsupported and that Registry state and the
token file are unchanged. No token projection remains that can incorrectly
report an exhausted token as active.

Server token create remains unsupported. The existing Identity token creation
API still generates its own ID, has no durable label, accepts relative TTL, and
returns the raw token only once. Identity policy update also remains
unsupported; no policy writer or fixed-policy coercion was added.

## Serialized Host Mutations

Registry remains the serialized durable owner for host approve, revoke, and
delete:

- Approve and revoke persist the resulting host before updating Registry state
  or returning prior/resulting snapshots.
- Approve and revoke use the fixed actor `yellow_dog_server_control`.
- Delete snapshots the host in Registry, durably removes its file, updates
  Registry state, and only then returns the prior public snapshot.
- Audit, telemetry, webhook, and PubSub work remains best effort after a
  successful durable mutation and cannot replace a successful public result
  with an exception.

Existing registration, host/token CRUD, token creation, token consumption, and
TOML persistence formats remain compatible. The prior internal control token
revoke operation was removed; the existing non-control `revoke_token/1` API is
unchanged.

## Sanitized Failures

Registry persistence now uses non-bang directory creation and a narrow,
injectable file-operation boundary. Write operations retain the existing
copy-validate-replace sequence. Directory, write, read-back, rename, and delete
errors or exceptions are reduced to `{:error, :persistence_failed}` before they
leave Registry.

The file-operation boundary catches raise, throw, and exit. Failed writes clean
up the temporary file without replacing the prior durable file. Failed writes
and deletes do not update Registry state.

Supported facade calls catch owner raise, throw, and exit and return
`{:error, :apply_failed}`. Expected bounded domain errors remain:

- `:not_found`
- `:already_revoked`
- `:persistence_failed`
- `{:invalid_status, :pending | :approved | :revoked}`

All other owner reasons become `:apply_failed`; no raw path or reason can escape
the control facade.

## Audit Projection

`control_list_audit/0` accepts only:

- `host.registered`
- `host.approved`
- `host.revoked`
- `host.deleted`

Each public event contains exactly `audit_id`, `action`, `subject_id`, and
`occurred_at`. Audit IDs use a deterministic canonical digest of the supported
action, bounded subject ID, and normalized UTC timestamp. Invalid timestamps,
invalid or unbounded subject IDs, unsupported actions, malformed lines, and raw
details are omitted. The result is bounded to 100 entries.

## TDD Evidence

The revised regression suite was run before the implementation changes:

```text
mix test test/yellow_dog_identity/control_facade_test.exs
# 11 tests, 7 failures
```

The failures covered canonical revision mismatch, fabricated approval/token
surfaces, exhausted token misreporting and mutation, leaked owner exits, and
unsanitized persistence failures.

After the focused implementation:

```text
mix test test/yellow_dog_identity/control_facade_test.exs
# 11 tests, 0 failures
```

Coverage includes canonical host revision parity and restart compatibility,
fixed host fields, fixed actor mutations, concurrent serialization, successful
delete ordering, typed unsupported boundaries, audit bounds/redaction,
directory/write/rename/delete failures, raise/throw/exit sanitation, and
state/disk coherence after failure.

## Verification

All commands ran through the repository devenv.

```text
cd apps/yellow_dog_identity
mix test test/yellow_dog_identity/control_facade_test.exs
# 11 tests, 0 failures

mix test
# 399 tests, 0 failures

mix compile --warnings-as-errors
# exit 0

cd ../..
mix format --check-formatted \
  apps/yellow_dog_identity/lib/yellow_dog_identity.ex \
  apps/yellow_dog_identity/lib/yellow_dog_identity/registry.ex \
  apps/yellow_dog_identity/test/yellow_dog_identity/control_facade_test.exs
# exit 0

cd apps/yellow_dog_identity
mix credo --strict
# 454 mods/funs, found no issues
```

## Adapter Concerns

- The later Server adapter must consume these owner maps directly and must not
  inspect Registry state or Identity structs.
- Approval list, token list/get/create/revoke, and policy update must be
  translated to the fixed wire `unsupported` result by that adapter.
- The adapter remains responsible for result-envelope validation, observed
  timestamps, list revisions, pagination, expected-revision handling, and its
  own fixed transport error mapping.
