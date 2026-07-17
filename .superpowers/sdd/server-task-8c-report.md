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

## Independent Review Fixes

- Removed the `{:validated, children}` `Supervisor.init/1` bypass. `start_link/1`
  now passes the original keyword configuration, and `init/1` independently
  rebuilds and validates the child set.
- Made direct `init/1` total over malformed terms and non-keyword lists,
  returning `:ignore` without calling `Keyword.keys/1` on unchecked input.
- Restricted supervisor and child registrations to non-nil local atoms,
  `{:global, term}`, or `{:via, module, term}` with a non-nil module.
  `supervisor_name: nil` remains the explicit unnamed-supervisor case.
- Restricted Dispatcher journal references to the approved `GenServer.server/0`
  forms, including non-nil atoms for both elements of remote `{name, node}`
  references.
- Assigned fixed child-spec role IDs `:heartbeat`, `:command_journal`, and
  `:config_store`, independent of registered names.
- Matched Dispatcher Server-ID validation to CommandJournal: bounded and
  nonempty, not `.`/`..`, no slash/backslash or Windows drive prefix,
  NFKC-stable, and free of Unicode control characters.
- Added regression coverage for direct-init bypass attempts, malformed OTP
  names and journal refs, unsafe Server IDs, the reported registered-name/
  child-ID collision, Heartbeat restart isolation, malformed typed errors, and
  omitted default-adapter terminal replay.

## Verification

- Focused dispatcher/supervisor tests:
  `24 tests, 0 failures`.
- Full `yellow_dog_server_agent` tests:
  `136 tests, 0 failures`.
- `mix compile --warnings-as-errors --force`:
  exit 0, no warnings.
- Scoped `mix format --check-formatted`:
  exit 0.
- `mix credo --strict`:
  19 source files, 514 mods/funs, no issues.
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

## Final Sanitizer Follow-up

- Isolated normal runtime-adapter returns under `{:adapter_return, value}`.
  The dispatcher's caught `{:dispatcher_failure, ...}` marker is now
  internal-only and cannot be forged by an adapter return value.
- Only wrapped `{:ok, result}` and typed `{:error, %Error{}}` adapter values
  are accepted. All other wrapped values, including a forged
  `{:dispatcher_failure, %Error{}}`, persist the fixed internal error with
  empty details.
- Added a regression test that returns a forged internal marker containing a
  secret and proves both the immediate dispatch result and durable replay use
  the fixed error without the secret.

### Follow-up Verification

- Focused forged-marker regression: `1 test, 0 failures`.
- Full dispatcher test file: `16 tests, 0 failures`.
- Full `yellow_dog_server_agent` tests: `137 tests, 0 failures`.
- `mix compile --warnings-as-errors --force`: exit 0, no warnings.
- Scoped `mix format` and `mix format --check-formatted`: exit 0.
- `mix credo --strict`: 19 source files, 514 mods/funs, no issues.
- `mix xref graph --label compile` and dispatcher trace: exit 0; the trace
  reports only the four runtime `CommandJournal` calls.
