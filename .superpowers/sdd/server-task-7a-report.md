# Server Task 7A Report: Identity Owner Facade

Date: 2026-07-17

## Status

COMPLETE

Task 7A adds Identity-owned canonical public snapshots and serialized control
operations without exposing Registry state, host/token structs, token hashes,
raw token secrets, audit details, or persistence paths to the future Server
adapter.

## Owned Changes

- `apps/yellow_dog_identity/lib/yellow_dog_identity.ex`
- `apps/yellow_dog_identity/lib/yellow_dog_identity/registry.ex`
- `apps/yellow_dog_identity/test/yellow_dog_identity/control_facade_test.exs`
- `.superpowers/sdd/server-task-7a-report.md`

`token.ex` did not require a change. No Server adapter, Dispatcher, Config,
console, root Mix, Netboot, protocol, Mnesia, Concord, or protected file was
modified for this task.

## Public Owner Contract

The following `YellowDogIdentity` APIs return only fixed-field public maps:

- `control_list_hosts/0`
- `control_list_approvals/0`
- `control_list_tokens/0`
- `control_list_audit/0`
- `control_host/1`
- `control_token/1`
- `control_approve_host/1`
- `control_revoke_host/1`
- `control_delete_host/1`
- `control_revoke_token/1`

Host snapshots contain `host_id`, `name`, `state`, and a deterministic
SHA-256 revision. Approval snapshots contain `approval_id`, `host_id`, and
`state`; the one approval aggregate for a host uses the stable host ID as its
approval ID. Token snapshots contain only `token_id`, `label`, and `state`.
Because the durable token model has no label, the stable token ID is also used
as the display label; no existing token field is reinterpreted as a caller
label.

All public lists are sorted by their fixed identifier and bounded to 100 items.
Token state is projected as `active` or `expired`; only a successful revoke
result can project `revoked`.

## Serialized Mutations

Registry now owns one-call serialized control operations for host approval,
host revocation, host deletion, and token revocation.

- Approve and revoke persist the resulting host before updating Registry state
  or returning prior/resulting snapshots.
- Both operations use the fixed actor `yellow_dog_server_control`.
- Host delete snapshots the stored host inside Registry, durably removes its
  file, updates owner state, and only then returns the prior public snapshot.
- Token revoke snapshots the stored token inside Registry, durably removes its
  file, updates owner state, and only then returns prior and revoked public
  snapshots.
- Filesystem deletion failure now returns the existing documented error shape
  and leaves Registry state unchanged. Missing files remain compatible and are
  treated as already durably absent.

Existing registration, approval, revocation, host/token CRUD, token creation,
token consumption, and TOML persistence formats remain compatible.

## Audit Projection

`control_list_audit/0` accepts only the supported existing host actions:

- `host.registered`
- `host.approved`
- `host.revoked`
- `host.deleted`

Each public event contains only `audit_id`, `action`, `subject_id`, and
`occurred_at`. Audit IDs are deterministic SHA-256 identifiers derived from
the action, subject, and normalized UTC timestamp. Invalid timestamps,
unbounded/invalid subject IDs, unsupported actions, malformed lines, and raw
details are omitted. The public result is bounded to 100 entries.

## TDD Evidence

The focused test was written first and initially failed with 9 failures because
the new owner functions were absent. After the minimal owner implementation:

```text
mix test test/yellow_dog_identity/control_facade_test.exs
9 tests, 0 failures
```

Coverage includes:

- exact host, approval, token, and audit projection
- stable host revision across Registry restart
- token raw-secret/hash redaction
- deterministic bounded audit projection with raw-detail omission
- fixed control actor
- serialized concurrent approval
- prior/resulting approval and revocation snapshots
- host delete ordering and durable failure
- token revoke durability, restart compatibility, and durable failure

## Verification

All commands ran through the repository devenv.

```text
cd apps/yellow_dog_identity
mix test test/yellow_dog_identity/control_facade_test.exs
# 9 tests, 0 failures

mix test
# 397 tests, 0 failures

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
# 437 mods/funs, found no issues
```

`unbuffer` was unavailable inside devenv, so the same Mix commands were run
directly.

## Unsupported Boundaries

- Token creation remains unsupported for the later Server adapter. The current
  API still generates its own ID, has no durable label, accepts relative TTL,
  and returns the raw token only once.
- Identity policy update remains unsupported. Approval Engine policies are
  config-derived and have no lossless fixed policy aggregate or durable writer.
- No public policy coercion or writer was added.

## Concerns For Task 7C

- The adapter should consume these `control_*` maps directly and must not
  inspect Registry state or Identity structs.
- The adapter remains responsible for fixed result-envelope validation,
  observed timestamps, list revisions, pagination, expected-revision handling,
  sanitized error mapping, and honest `unsupported` results.
- Token ID as display label is deliberately deterministic and non-secret; it
  is not a durable user-supplied label and must not be accepted as evidence
  that token create can support the fixed caller label.
