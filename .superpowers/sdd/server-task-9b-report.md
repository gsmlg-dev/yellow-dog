# Server Task 9B Report

Date: 2026-07-17

## Scope

Implemented the typed outbound Server client without changing Task 8/9A
owners, supervision, facades, Sync schemas, Console, ManagementCore, releases,
or Mix files.

Changed files:

- `apps/yellow_dog_server_agent/lib/yellow_dog/server_agent/client.ex`
- `apps/yellow_dog_server_agent/test/support/client_fake_clock.ex`
- `apps/yellow_dog_server_agent/test/support/client_fake_socket.ex`
- `apps/yellow_dog_server_agent/test/support/client_fake_timer.ex`
- `apps/yellow_dog_server_agent/test/yellow_dog/server_agent/client_test.exs`
- `.superpowers/sdd/server-task-9b-report.md`

The protected pre-existing Console and root Mix changes were not touched or
staged.

## Strict Boundary

`enabled: false` accepts only `:enabled` and optional `:name`, starts an inert
GenServer, and requires no network or owner configuration.

`enabled: true` requires:

- `:management_url`, `:token`, and canonical Server `:identity`
- owner refs `:command_journal`, `:config_applier`, and
  `:config_apply_store`
- `:dispatcher` and `:dispatcher_runtime_adapter`
- injected `:socket`, `:timer`, `:monotonic_clock`, and `:wall_clock` modules
- positive `:connection_poll_interval`, `:connect_timeout`, `:join_timeout`,
  `:push_timeout`, `:heartbeat_interval`, `:status_interval`,
  `:initial_backoff`, and `:max_backoff`

Options must be a duplicate-free keyword list with no unknown keys.
`connection_poll_interval <= connect_timeout` and
`initial_backoff <= max_backoff`.

The socket seam is:

- `start_link(url: ..., params: ...)`
- `connected?/1`
- `join/4`
- synchronous `push/4`
- `stop/1`

The production nested adapter uses `phoenix_socket_client` with library
reconnect disabled because the Client owns channel generation, cleanup, and
bounded rejoin.

## Wire And Lifecycle

- Converts an HTTPS base URL to exact
  `wss://<authority>/server/ws/websocket`.
- Uses exact params `%{"token" => token, "server_id" => server_id}` and topic
  `server:control:<server_id>`.
- Uses only event `sync` and exact payload keys `message` and
  `publication_sequence`.
- Canonically sends Hello then first Status and activates only after both
  receive exact `%{"accepted" => true}` replies.
- Uploads the terminal Journal projection and ordered ConfigState outbox only
  after activation.
- Validates exact ConfigState receipts and revisions before acknowledging the
  durable outbox head: delivery `1`, validation `2`, and apply/rollback `3`.
- Canonically decodes/re-encodes inbound Command, Query, and ConfigDelivery
  messages, checks concrete Server identity and current channel ownership, and
  delegates only through Dispatcher or ConfigApplier.
- Retries ConfigState publication from ConfigApplyStore without rerunning
  ConfigApplier.
- Uses synchronous pushes for every acknowledgement-bearing message.
- Uses generation-bound timers and
  `min(initial_backoff * 2^attempt, max_backoff)`, resetting attempts only
  after the complete Hello/Status handshake.

## Token Handling

The token is not stored in the inspectable GenServer state as a string or
params map. State retains only an opaque zero-arity params provider closure;
socket params are materialized inside `start_socket`. Tests inspect
`:sys.get_state/1` in active and authentication-failure paths and assert the
token is absent. The Client logs no token, payload, or raw failure reason.

## Task 8 Owner Gap

Task 8 exposes no safe API for changing an already-running CommandJournal
record to `unknown`. The Client therefore does not invent a terminal outcome
or modify Task 8. It uploads only `CommandJournal.wire_projection/1`, whose
owner implementation filters out non-terminal `received` and `running`
records. The focused test proves the upload makes no false `unknown` claim.

A future requirement to mark a live command unknown at disconnect needs a
Task 8 owner API that durably validates the request identity and permits only
the intended `running -> unknown` transition.

Task 8 Dispatcher also validates only `:command` envelopes. The Client routes
both Query and Command to its configured Dispatcher exactly once, but the
production Dispatcher currently returns the typed `invalid` error for Query
without journal or runtime side effects. A future functional Query requirement
needs either typed `:query` support in the Task 8 Dispatcher owner or a
separate approved Query owner API. Focused tests cover both the client routing
contract with an injected Dispatcher and the current production no-side-effect
fallback.

## Verification

- TDD red: focused suite failed because
  `YellowDog.ServerAgent.Client` was absent.
- Focused Client suite: `19 tests, 0 failures`.
- Full Server-agent suite: `213 tests, 0 failures`.
- `mix compile --warnings-as-errors --force`: passed, 13 files compiled.
- Scoped `mix format --check-formatted`: passed.
- Full `mix credo --strict`: 31 files checked, no issues.
- `mix app.tree --format plain`: only Sync, Jason,
  `phoenix_socket_client`, and runtime dependencies; no YellowDog Server,
  ManagementCore, or Console dependency.
- Compile xref forbidden-dependency scan: clean.
- Forbidden-reference scan for ManagementCore, Console, config env access,
  raw logging, `:gen_udp`, and `Concord`: clean.
- Scoped `git diff --check`: passed.

Commit SHA is reported after the conventional commit is created.

## Blocking Review Fixes

Date: 2026-07-18

All four blocking Client review findings were addressed within the Task 9B
ownership boundary.

### Sensitive Credential Ownership

- Replaced the inspectable socket-params closure with a dedicated sensitive
  credential provider process.
- Client state retains only the opaque provider PID. Recursive state probes,
  including nested function environments, contain no raw token.
- The provider has no `GenServer`/`:sys` state surface, is marked as an Erlang
  sensitive process, sanitizes adapter failures, and is destroyed with the
  Client.
- Provider operations are restricted to the bound Client PID, so a process
  that obtains the opaque reference cannot redirect authentication to another
  endpoint.
- The provider owns underlying socket creation and passes the unchanged exact
  params `%{"token" => token, "server_id" => server_id}`. The underlying
  socket PID is not retained in Client state.
- Production-shaped unsolicited socket messages are forwarded through the
  provider with the real channel PID, preserving inbound routing.

### Explicit Enabled Configuration

Enabled mode now requires every option explicitly except optional `:name`.
There are deletion tests for all 21 required keys, including Dispatcher,
runtime adapter, owner refs, injected socket/timer/clocks, and every timing
value. No production module or timing default remains in enabled validation.
The disabled-only `:enabled`/optional-`:name` gate is unchanged.

### Strict Management URL

Management URLs now use `URI.new/1` plus structured `:uri_string.parse/1`
authority validation. Only HTTPS URLs with a valid DNS/IP host, no
userinfo/query/fragment, and a port in `1..65535` are accepted. Empty,
alphabetic, zero, and out-of-range explicit ports are rejected, including the
empty-port form that `URI.new/1` otherwise normalizes. Host names are
canonicalized to lowercase and the endpoint is derived exactly as
`wss://<authority>/server/ws/websocket`.

### ConfigState Failure Classes

- Timeout, closed, raised/exited, and other socket push failures retain the
  durable outbox head, clean the current channel/socket, and enter the existing
  bounded reconnect/backoff path.
- Malformed or mismatched receipts and local acknowledgement failures retain
  the head while keeping the active transport and scheduling only the
  generation-bound local publication retry.
- Neither path reruns ConfigApplier or fabricates transport/local success.

### Result Path Dependency

The Client still emits the canonical `Result` wrapper returned by Dispatcher
through the fixed `sync` event. End-to-end production Result correlation on
the receiving side remains owned by the separate Console worker and is still
an external dependency until that worker lands. No Console behavior was edited
or locally worked around in this fix.

### Fix Verification

- TDD red evidence: focused failures proved the token closure capture, missing
  explicit Dispatcher requirement, alpha/empty-port URL acceptance,
  ConfigState timeout local retry, provider message drop, and unauthorized
  provider redirect.
- Focused Client suite: `26 tests, 0 failures`.
- Token/state probes: recursive Client state and closure-environment scan,
  opaque provider `:sys` timeout, sanitized authentication failure, log scan,
  and unauthorized provider-call rejection all passed.
- `mix compile --warnings-as-errors --force`: passed, 13 files compiled.
- Scoped `mix format --check-formatted`: passed.
- `mix credo --strict`: 32 files checked, no issues.
- `mix deps`: all 10 direct/transitive entries available.
- `mix xref graph --label compile`: passed with no compile edges reported.
- Dependency tree remains limited to Sync, Jason, `phoenix_socket_client`, and
  runtime dependencies.
- Forbidden-reference and scoped `git diff --check` scans: clean.
- Full Server-agent suite currently reports `227 tests, 5 failures`. All five
  are in the concurrently edited, out-of-scope `SupervisorTest`, whose new
  durable/outbound expectations currently receive
  `{:error, :invalid_configuration}` from the unchanged Supervisor
  implementation. No owned Client test fails, and those protected files were
  not modified by this fix.
