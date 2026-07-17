# Server Task 8C Report

Date: 2026-07-17

## Implementation

- Added stateless `YellowDog.ServerAgent.Dispatcher.dispatch/2`.
- Validates dispatcher options, exact Server command envelopes, target identity,
  operation kind, and capability before journal access.
- Uses `CommandJournal.reserve/2` as the duplicate gate and returns succeeded,
  failed, and unknown terminal replays before runtime adapter checks.
- Marks new reservations running before dynamically checking and invoking the
  configured adapter once.
- Validates successful adapter results through `YellowDog.Sync.Operation`.
- Sanitizes typed errors to fixed public messages with empty details and maps
  unavailable, exceptional, malformed, and invalid outcomes to durable
  unsupported or internal failures.
- Gives terminal journal persistence failures precedence and catches journal
  process exits without retrying runtime work.
- Preserved heartbeat-only unconfigured startup.
- Added strict all-or-none durable configuration and exact
  Heartbeat/CommandJournal/ConfigStore child ordering under `:one_for_one`.
- Added distinct durable child names, optional supervisor naming, scoped child
  option seams, and rejection of shared-option overrides.

## Verification

- Focused dispatcher/supervisor tests:
  `16 tests, 0 failures`.
- Full `yellow_dog_server_agent` tests:
  `128 tests, 0 failures`.
- `mix compile --warnings-as-errors --force`:
  exit 0, no warnings.
- Scoped `mix format --check-formatted`:
  exit 0.
- `mix credo --strict`:
  19 source files, 513 mods/funs, no issues.
- `mix deps.tree`:
  no `yellow_dog` dependency; the only in-umbrella dependency is
  `yellow_dog_sync`.
- `mix xref graph --label compile`:
  exit 0 with no compile edges reported.
- `mix xref trace lib/yellow_dog/server_agent/dispatcher.ex`:
  only runtime calls to the four approved `CommandJournal` functions; no
  `YellowDog.Server.Control` reference.

## Scope And Guardrails

- Production changes are limited to the new dispatcher and Server-agent
  supervisor.
- Tests are limited to focused dispatcher/supervisor coverage and narrow test
  support.
- No sockets, outbound transport, Concord, generic Node abstraction, sync
  schema changes, protocol changes, console changes, mix-file changes, or
  compile-time dependency on `yellow_dog` were added.
- Protected dirty files were left untouched and unstaged.

## Residual Concerns

- The runtime adapter invocation and terminal journal write cannot be atomic.
  A crash between them remains conservatively recoverable as `unknown`, as
  required by the approved journal contract.
- In a standalone Server-agent release without `YellowDog.Server.Control`,
  new commands fail durably as `unsupported`; terminal journal replays remain
  available offline.
