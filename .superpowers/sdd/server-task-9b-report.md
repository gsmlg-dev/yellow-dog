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

## Strict Boundary (Historical, Superseded)

Historical/superseded: this section records the original direct
`Client.start_link/1` option contract. The final prepared-reference contract is
defined in `Prepared Credential Restart-MFA Contract` below.

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

## Token Handling (Historical, Superseded)

Historical/superseded: the initial Task 9B implementation did not store the
token in the inspectable GenServer state as a string or params map, but it did
retain an opaque zero-arity params provider closure and materialized params
inside `start_socket`. That closure design was first replaced by a sensitive
provider process and is now superseded again by the capability-authenticated,
fixed-endpoint provider described below. The Client still logs no token,
payload, or raw failure reason.

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

### Result Path Dependency (Historical, Superseded)

Historical/superseded: at the time of this review fix, the Client emitted the
canonical `Result` wrapper while end-to-end production Result correlation
remained an external Console dependency. The later Console correlated
management transport recorded in
`console-server-channel-prerequisite-report.md` has since landed. No Console
production behavior was edited by Task 9B.

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

## Important Credential-Owner Review Fix

Date: 2026-07-18

### Capability And Endpoint Ownership

- The sensitive provider stores the validated fixed WebSocket endpoint with
  the token and Server ID at bootstrap. Its socket-start operation accepts no
  URL or params from the Client; an extra URL option is rejected.
- Client state contains only an opaque `{provider_pid, capability_ref}`
  credential reference and non-secret validated configuration. The endpoint,
  token, and socket module are materialized before Client options are built;
  recursive state and nested-closure probes remain secret-free.
- Every provider request carries both the unguessable provider capability and
  a fresh request reference. The provider additionally verifies the bound
  caller PID, drops unauthenticated mailbox requests without replying, and
  forwards socket messages only to the bound Client.
- Pushes are restricted to the channel returned by the provider-owned join.
  The underlying adapter still receives the unchanged exact endpoint and
  params `%{"token" => token, "server_id" => server_id}`.

### Lifecycle Transfer

- Provider bootstrap installs a creator monitor before `start_owner/4`
  returns.
- Capability-authenticated bind installs the Client monitor before removing
  the creator monitor. A dead creator cannot complete transfer.
- Creator death before bind, failed bind followed by creator death, Client
  startup failure, failed socket start followed by Client death, and bound
  Client death all have deterministic provider/socket cleanup tests.
- Client state monitors the provider process behind the opaque capability
  reference. Provider or underlying socket death enters the existing bounded
  reconnect path without exposing credential material.

### Verification (Historical Pre-Prerequisite)

- TDD red:
  `devenv shell -- bash -lc 'cd apps/yellow_dog_server_agent && mix test test/yellow_dog/server_agent/client_test.exs'`
  reported `31 tests, 5 failures` for the old bare-PID provider,
  caller-supplied URL, missing creator monitor, and missing lifecycle cleanup.
- Focused and full tests:
  `devenv shell -- bash -lc 'cd apps/yellow_dog_server_agent && mix test test/yellow_dog/server_agent/client_test.exs && mix test'`
  reported `32 tests, 0 failures` and `236 tests, 0 failures`.
- Compile:
  `devenv shell -- bash -lc 'cd apps/yellow_dog_server_agent && mix compile --warnings-as-errors --force'`
  passed after compiling 13 files.
- Format:
  `devenv shell -- bash -lc 'mix format --check-formatted apps/yellow_dog_server_agent/lib/yellow_dog/server_agent/client.ex apps/yellow_dog_server_agent/test/yellow_dog/server_agent/client_test.exs'`
  passed.
- Strict Credo:
  `devenv shell -- bash -lc 'cd apps/yellow_dog_server_agent && mix credo --strict'`
  checked 32 source files and 1,305 modules/functions with no issues.
- Dependencies:
  `devenv shell -- bash -lc 'cd apps/yellow_dog_server_agent && mix deps'`
  reported all 10 direct/transitive entries available.
- Compile xref:
  `devenv shell -- bash -lc 'cd apps/yellow_dog_server_agent && mix xref graph --label compile'`
  passed with no compile edges reported.
- Dependency tree:
  `devenv shell -- bash -lc 'cd apps/yellow_dog_server_agent && mix app.tree --format plain'`
  remains limited to Sync, Jason, `phoenix_socket_client`, and runtime
  dependencies.
- Bounded lifecycle/state checks are included in the focused suite for invalid
  capability, endpoint substitution rejection, creator death before bind,
  failed bind/start cleanup, bound-Client death, exact socket URL/params,
  recursive state inspection, and sensitive-provider `:sys` rejection.
- Scoped `git diff --check` and forbidden-reference scans for caller-supplied
  socket URLs, params closures, config environment access, ManagementCore,
  Console, raw UDP, and Concord references passed.

## Prepared Credential Restart-MFA Contract

Date: 2026-07-18

The independent Task 9C review found that creating the provider inside
`Client.start_link/1` was too late: Supervisor and outer application child
restart MFAs could already retain the raw management URL and token. The final
Task 9B contract moves credential materialization ahead of Client child-option
construction.

### Public Preparation Boundary

- `Client.prepare_credentials/1` accepts exactly `:management_url`, `:token`,
  `:server_id`, and `:socket`. It strictly validates the fixed HTTPS authority,
  bounded nonempty token and Server ID, and complete socket callback module.
- Successful preparation returns only an opaque
  `{provider_pid, capability_ref}`. It creates the sensitive provider with the
  validated fixed WebSocket endpoint, token, Server ID, and socket module.
- `Client.release_credentials/1` capability-authenticates creator-owned
  cleanup when Supervisor preparation or child construction fails. It returns
  only `:ok` or `:error`.
- An unclaimed provider monitors its creator and also expires after the bounded
  five-second claim interval. Neither release nor timeout starts a socket.

### Client Construction Boundary

- Enabled `Client.start_link/1` accepts `:credential_ref` instead of
  `:management_url`, `:token`, or `:socket`; all three legacy keys are unknown
  and rejected.
- `Client.child_spec/1` therefore retains no URL, token, socket params,
  credential-bearing function, or socket module. Its restart MFA contains only
  the opaque credential reference and non-secret explicit Client options.
- Capability-authenticated bind also checks that the prepared Server ID equals
  the canonical Client identity ID. A reference can bind to exactly one Client.
- Bind installs the Client monitor first, then atomically removes the creator
  monitor using `Process.demonitor/2` with `:info`; a creator death that wins
  that transfer causes provider cleanup.
- Socket start remains parameterless from Client and uses only the provider's
  stored endpoint and exact params.

### Final Verification

- TDD red:
  `devenv shell -- bash -lc 'cd apps/yellow_dog_server_agent && mix test test/yellow_dog/server_agent/client_test.exs'`
  reported `36 tests, 35 failures` because preparation/release were absent and
  enabled Client options still required raw credential fields.
- Focused Client suite:
  `devenv shell -- bash -lc 'cd apps/yellow_dog_server_agent && mix test test/yellow_dog/server_agent/client_test.exs'`
  reported `38 tests, 0 failures`.
- Full Server-agent suite:
  `devenv shell -- bash -lc 'cd apps/yellow_dog_server_agent && mix test'`
  reported `242 tests, 2 failures`. Both are concurrent, out-of-scope Task 9C
  integration failures in `SupervisorTest`: line 206
  (`complete outbound configuration adds Client last...`) and line 445
  (`one_for_one restarts Client...`). Both fail to start child `:client` with
  `:invalid_options` because the current Supervisor still builds the legacy
  raw `management_url`/`token`/`socket` Client options. No owned Client test
  failed, and Supervisor/facade files were not modified.
- Compile:
  `devenv shell -- bash -lc 'cd apps/yellow_dog_server_agent && mix compile --warnings-as-errors --force'`
  passed after compiling 13 files.
- Format:
  `devenv shell -- bash -lc 'mix format --check-formatted apps/yellow_dog_server_agent/lib/yellow_dog/server_agent/client.ex apps/yellow_dog_server_agent/test/yellow_dog/server_agent/client_test.exs'`
  passed.
- Strict Credo:
  `devenv shell -- bash -lc 'cd apps/yellow_dog_server_agent && mix credo --strict'`
  checked 32 source files and 1,315 modules/functions with no issues.
- Dependencies:
  `devenv shell -- bash -lc 'cd apps/yellow_dog_server_agent && mix deps'`
  reported all 10 direct/transitive entries available.
- Compile xref:
  `devenv shell -- bash -lc 'cd apps/yellow_dog_server_agent && mix xref graph --label compile'`
  passed with no compile edges reported.
- Dependency tree:
  `devenv shell -- bash -lc 'cd apps/yellow_dog_server_agent && mix app.tree --format plain'`
  remains limited to Sync, Jason, `phoenix_socket_client`, and runtime
  dependencies.
- Bounded state/lifecycle coverage includes child restart-MFA inspection,
  legacy raw-option rejection, mismatched Server ID, invalid capability,
  endpoint substitution, explicit release, unclaimed timeout, creator death,
  failed bind/start cleanup, bound-Client death, exact socket URL/params,
  recursive state inspection, and sensitive-provider `:sys` rejection.
- Scoped `git diff --check` and forbidden-reference scans for Client-state URL,
  caller-supplied socket URL, params closures, config environment access,
  ManagementCore, Console, raw UDP, and Concord references passed.

## Integrated Credential-Retention Final Fix

Date: 2026-07-18

This section supersedes the earlier one-Client ownership wording. Credential
preparation, durable ownership, and active Client use are now separate
capability-authenticated phases.

### Preparation And Durable Ownership

- `Client.prepare_credentials/1` remains the only boundary that accepts or
  materializes the raw management URL, token, Server ID, and socket module.
  It validates the fixed endpoint, creates no socket, and returns only the
  opaque `{provider_pid, capability_ref}`.
- Provider bootstrap monitors its creator and starts a bounded five-second
  claim timer. `Client.claim_credentials/1` installs the claiming owner's
  monitor before removing the creator monitor and cancelling that timer.
  A creator death that wins the transfer prevents the claim.
- A repeated claim from the same owner is idempotent for outer child restart.
  A claim from any different process is rejected even with the capability.
- The provider remains sensitive and non-GenServer. It owns the fixed endpoint,
  token, socket adapter, socket PID, and channel lease until the claimed owner
  dies or explicitly releases it. Owner death stops the socket, clears
  transport state, and erases the provider process.

### Renewable Client Lease

- Enabled Client options remain strict and accept only the opaque
  `:credential_ref` plus its non-secret `:credential_owner`; raw
  `:management_url`, `:token`, and `:socket` keys are rejected.
- A provider allows one active Client lease for the prepared Server ID and
  claimed owner. Concurrent and different-owner binds are rejected.
- Client normal termination explicitly unbinds after transport cleanup.
  Monitor-based cleanup handles killed Clients. Both paths stop/demonitor the
  socket, demonitor and clear the channel, clear the Client lease, and keep the
  provider alive while its owner remains alive.
- Same-owner bind retries only the provider's explicit `:busy` result for a
  bounded interval. This closes the OTP restart race while preserving
  rejection of a genuinely concurrent Client.
- A replacement Client binds the same capability, starts a new socket with the
  provider-owned endpoint and params, and reconnects without exposing raw
  credentials to Client state or restart options.

### Integrated Verification

- TDD red: the focused Client/Supervisor/facade run reported `56 tests,
  36 failures` for the missing owner claim, renewable lease, scrubbed outer
  start path, and facade normalization.
- Focused final run: `59 tests, 0 failures`.
- Full Server-agent run: `248 tests, 0 failures`.
- Recursive Client and supervisor state/MFA tests prove the token, management
  authority, socket option/params keys, and credential-bearing functions are
  absent. The sensitive provider still rejects `:sys` inspection.
- Lifecycle tests prove creator timeout/death cleanup, owner-death cleanup,
  normal and killed Client lease cleanup, same-reference Client restart, and
  whole-agent restart under an outer supervisor.
- Warnings-as-errors compile, scoped format, strict Credo, dependencies,
  production dependency tree, compile xref/trace, forbidden references, and
  scoped `git diff --check` passed.
