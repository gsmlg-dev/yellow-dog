# Server Task 9C Report

Date: 2026-07-18

## Scope

Integrated local Server-agent state and supervision without changing Client,
ConfigApplier, ConfigApplyStore, ConfigStore, CommandJournal, Dispatcher,
Sync, Console, runtime configuration, releases, protocol code, or Mix files.

Changed files:

- `apps/yellow_dog_server_agent/lib/yellow_dog/server_agent/heartbeat.ex`
- `apps/yellow_dog_server_agent/lib/yellow_dog/server_agent/status.ex`
- `apps/yellow_dog_server_agent/lib/yellow_dog/server_agent/supervisor.ex`
- `apps/yellow_dog_server_agent/lib/yellow_dog/server_agent.ex`
- `apps/yellow_dog_server_agent/test/yellow_dog/server_agent/heartbeat_status_test.exs`
- `apps/yellow_dog_server_agent/test/yellow_dog/server_agent/supervisor_test.exs`
- `apps/yellow_dog_server_agent/test/yellow_dog/server_agent_test.exs`
- `.superpowers/sdd/server-task-9c-report.md`

The protected pre-existing Console/root Mix changes and the concurrent
out-of-scope Client test change were not modified or staged.

## Design

### Startup Modes And Supervision

The supervisor validates duplicate-free keyword options before starting any
child and rejects unknown or partial durable/outbound configuration.

- No durable configuration starts only Heartbeat and performs no outbound
  work.
- Complete durable configuration starts, in exact order, Heartbeat,
  CommandJournal, ConfigStore, ConfigApplyStore, and ConfigApplier.
- Complete durable plus complete outbound configuration appends Client last.
- The strategy is `:one_for_one`, so restarting Heartbeat, either apply owner,
  or Client leaves unrelated durable owners running.
- ConfigApplyStore is always an explicit durable child before ConfigApplier.
- Named Heartbeat, Journal, ConfigStore, ConfigApplyStore, ConfigApplier, and
  Client references are injected consistently and must be distinct.

The outbound group includes the management URL/token, Server name/version,
config revision, and reconnect bounds. Client child options cannot override
identity, credentials, owner references, or its registered name. Supervisor
supplies every option required by the strict Client enabled contract,
including dispatcher/runtime adapter, owner references, socket/timer/clocks,
all timing values, and backoff bounds. No Client child is present when the
outbound group is absent, so durable-only and default startup cannot start a
socket.

### Concrete Server Identity

Supervisor builds exactly one `%YellowDog.Sync.Identity.Server{}` from the
validated Server ID, name, version, profile, unique string capabilities, and
digest config revision. A canonical Hello encode/decode round trip validates
the concrete identity before it reaches Client. Heartbeat `agent_id` must
equal that Server ID. No generic target or Netman abstraction was introduced.

### Heartbeat And Status

Heartbeat remains a local-only GenServer and the sole owner of `agent_id`,
`started_at`, and `last_heartbeat_at`. It adds only the bounded connection
states `disabled`, `connecting`, `handshaking`, `active`, `backoff`, and
`unavailable`; it performs no network, runtime, persistence, or socket work.

Configured Status validates the concrete Server identity and projects only:

- bounded Heartbeat state and timestamps
- safe Server identity fields, profile, capabilities, and config revision
- bounded Client connection state
- allowlisted local apply runtime/status/version evidence

Status omits management URL/token, data paths, config payloads, failure
details, raw errors, and process internals. Missing or restarting local owners
produce bounded fallback values rather than leaking exit reasons. The facade
exposes only status, connected-state, and connection-state inspection.

Supervisor passes raw credential input only to
`Client.prepare_credentials/1`, before OTP receives a long-lived supervisor
argument. Heartbeat, Status, Client state, supervisor restart MFAs, and the
public facade retain only bounded non-secret state plus the opaque credential
reference.

## Tests

Focused coverage proves:

- heartbeat-only default startup and no socket activity
- exact durable and outbound child order
- ConfigApplyStore before ConfigApplier
- complete explicit Client options and named owner references
- partial, duplicate, unknown, and child-override rejection
- concrete Server identity, capabilities, and config revision propagation
- named-process isolation and cross-wired identity rejection
- safe status/apply projection with secret, payload, path, and raw-error
  suppression
- bounded connection states and facade inspection only
- Heartbeat, ConfigApplyStore, ConfigApplier, and Client restart boundaries
- status safety when Heartbeat exits between snapshot and state recording

Self-review found one Heartbeat restart race in Status after the initial green
implementation. A one-shot Heartbeat regression test first reproduced the
`GenServer.call/3` exit; Status now treats the best-effort connection-state
record as unavailable local state and returns the already safe snapshot.

## Verification

All Mix commands ran through `devenv shell`.

```sh
devenv shell -- bash -lc \
  'cd apps/yellow_dog_server_agent && mix compile --warnings-as-errors --force'
```

Result: passed; 13 files compiled with no warnings.

```sh
devenv shell -- bash -lc \
  'cd apps/yellow_dog_server_agent && mix test test/yellow_dog/server_agent/heartbeat_status_test.exs test/yellow_dog/server_agent/supervisor_test.exs test/yellow_dog/server_agent_test.exs'
```

Result: passed; 21 tests, 0 failures.

```sh
devenv shell -- bash -lc \
  'cd apps/yellow_dog_server_agent && mix test'
```

Result: passed; 230 tests, 0 failures. Expected fail-stop persistence tests
emitted supervised GenServer termination logs while still passing.

```sh
devenv shell -- mix format --check-formatted \
  apps/yellow_dog_server_agent/lib/yellow_dog/server_agent.ex \
  apps/yellow_dog_server_agent/lib/yellow_dog/server_agent/heartbeat.ex \
  apps/yellow_dog_server_agent/lib/yellow_dog/server_agent/status.ex \
  apps/yellow_dog_server_agent/lib/yellow_dog/server_agent/supervisor.ex \
  apps/yellow_dog_server_agent/test/yellow_dog/server_agent_test.exs \
  apps/yellow_dog_server_agent/test/yellow_dog/server_agent/supervisor_test.exs \
  apps/yellow_dog_server_agent/test/yellow_dog/server_agent/heartbeat_status_test.exs
```

Result: passed.

```sh
devenv shell -- bash -lc \
  'cd apps/yellow_dog_server_agent && mix credo --strict'
```

Result: passed; 32 source files and 1,295 modules/functions checked with no
issues.

```sh
devenv shell -- bash -lc \
  'cd apps/yellow_dog_server_agent && mix deps'
devenv shell -- bash -lc \
  'cd apps/yellow_dog_server_agent && mix deps.tree --only prod'
devenv shell -- bash -lc \
  'cd apps/yellow_dog_server_agent && mix app.tree --format plain'
```

Result: passed; all 10 direct/transitive dependencies are available. The
application tree is limited to `yellow_dog_sync`, Jason,
`phoenix_socket_client`, and their runtime dependencies.

```sh
devenv shell -- bash -lc \
  'cd apps/yellow_dog_server_agent && mix xref graph --label compile'
devenv shell -- bash -lc \
  'cd apps/yellow_dog_server_agent && mix xref trace lib/yellow_dog/server_agent/supervisor.ex --include-siblings'
devenv shell -- bash -lc \
  'cd apps/yellow_dog_server_agent && mix xref trace lib/yellow_dog/server_agent/status.ex --include-siblings'
```

Result: passed. The compile graph reported no compile edges. Traces contain
only Server-agent siblings and fixed `yellow_dog_sync` validation modules; the
literal Server runtime adapter produces no compile-time Server dependency.

```sh
bash -lc 'files=(apps/yellow_dog_server_agent/lib/yellow_dog/server_agent.ex apps/yellow_dog_server_agent/lib/yellow_dog/server_agent/heartbeat.ex apps/yellow_dog_server_agent/lib/yellow_dog/server_agent/status.ex apps/yellow_dog_server_agent/lib/yellow_dog/server_agent/supervisor.ex); if rg -n "YellowDog\.(ManagementCore|Console|NetmanAgent|Netman)|Concord|:gen_udp|Application\.(get_env|fetch_env)|System\.get_env|Logger\." "${files[@]}"; then echo "forbidden production module/API reference found"; exit 1; else echo "forbidden production module/API scan: clean"; fi'
bash -lc 'files=(apps/yellow_dog_server_agent/lib/yellow_dog/server_agent.ex apps/yellow_dog_server_agent/lib/yellow_dog/server_agent/heartbeat.ex apps/yellow_dog_server_agent/lib/yellow_dog/server_agent/status.ex apps/yellow_dog_server_agent/lib/yellow_dog/server_agent/supervisor.ex); if rg -n "^[[:space:]]*(alias|import|require)[[:space:]]+YellowDog\.Server(\.|$)|%YellowDog\.Server\.|YellowDog\.Server\.[A-Za-z_][A-Za-z0-9_!?]*\(" "${files[@]}"; then echo "compile-time YellowDog.Server reference found"; exit 1; else echo "compile-time YellowDog.Server reference scan: clean"; fi'
bash -lc 'if rg -n "\{:(yellow_dog|yellow_dog_management_core|yellow_dog_console|yellow_dog_netman_agent|yellow_dog_netman|concord|yellow_dog_store)([,[:space:]}])" apps/yellow_dog_server_agent/mix.exs; then echo "forbidden application dependency found"; exit 1; else echo "forbidden application dependency scan: clean"; fi'
bash -lc 'files=(apps/yellow_dog_server_agent/lib/yellow_dog/server_agent.ex apps/yellow_dog_server_agent/lib/yellow_dog/server_agent/heartbeat.ex apps/yellow_dog_server_agent/lib/yellow_dog/server_agent/status.ex apps/yellow_dog_server_agent/lib/yellow_dog/server_agent/supervisor.ex); if rg -n "YellowDog\.Sync\.Identity\.(Netman|Node|Target)|YellowDog\.Netman|Generic(Target|Agent)|target_abstraction" "${files[@]}"; then echo "generic target or Netman reuse found"; exit 1; else echo "generic target/Netman reuse scan: clean"; fi'
bash -lc 'files=(apps/yellow_dog_server_agent/lib/yellow_dog/server_agent.ex apps/yellow_dog_server_agent/lib/yellow_dog/server_agent/status.ex); if rg -n "management_(token|url)|\btoken\b|\bdata_dir\b|\bpayload\b|raw_(error|reason)|Process\.(info|list|dictionary)" "${files[@]}"; then echo "sensitive or process-internal status/facade reference found"; exit 1; else echo "sensitive status/facade field scan: clean"; fi'
```

Result: all forbidden module/API, compile-time Server, application dependency,
generic target/Netman, and sensitive status/facade scans passed.

```sh
git diff --check
```

Result: passed.

## Commit And Concerns

Base recorded before Task 9C: `6bab5c2e`.

Required Client fix read before final supervision integration:
`1b485b43369c79a3ec84c843543c4474a71940a5`.

The final Task 9C commit SHA is returned in the task response. A tracked report
cannot contain the hash of the same commit that first contains that report
without changing that commit's hash.

Concerns: none.

## Integrated Task 9B/9C Final Fix

Date: 2026-07-18

### Scrubbed Supervision Boundaries

- Direct `ServerAgent.Supervisor.start_link/1` preserves raw-option
  compatibility but validates and prepares credentials before calling OTP
  `Supervisor.start_link/2,3`. Its callback argument contains no URL, token,
  socket option, params map, or credential-bearing closure.
- Direct startup claims the provider from inside the actual
  `ServerAgent.Supervisor` process before constructing any long-lived Client
  child spec. The Client restart MFA contains only scrubbed options, the
  opaque capability, and the non-secret owner PID.
- `YellowDog.ServerAgent.child_spec/1` and
  `ServerAgent.Supervisor.child_spec/1` are side-effect-free. Heartbeat-only
  and durable-local options return ordinary local `start_link/1` specs; raw
  outbound options return controlled `start_invalid/0` specs with no fallback
  arguments and create no provider.
- Outbound whole-agent supervision uses a late-bound lifecycle owner. The
  focused regression supplies an explicit test-owned start helper that
  prepares and claims in the actual outer parent, then reuses the scrubbed
  capability when the complete YellowDog.ServerAgent child restarts.
- A bounded pre-start name-release wait handles the OTP race after a brutal
  whole-agent kill, where old named grandchildren can outlive the dead inner
  supervisor briefly. Child declaration order and `:one_for_one` isolation
  remain unchanged.
- Ordinary unclaimed direct preparations expire after the provider claim
  timeout or creator death. The detached retained-provider state is removed.
  Supervisor names are validated before preparation; failed direct starts
  after preparation explicitly release providers. A provider claimed by a
  failed supervisor exits through its installed owner monitor.

### Safe Facade

- `YellowDog.ServerAgent.connected?/1` returns `true` only for the exact
  successful term `true`; every other reply is `false`.
- `YellowDog.ServerAgent.connection_state/1` allows only `:disabled`,
  `:connecting`, `:handshaking`, `:active`, `:backoff`, and `:unavailable`.
  Every other successful reply becomes `:unavailable`.
- Cross-wired fake owners returning arbitrary maps and tuples prove neither
  facade delegate can pass through an untrusted successful term.

### Final Tests And Verification

- Focused Client/Supervisor/facade suite: `59 tests, 0 failures`.
- Full Server-agent suite: `248 tests, 0 failures`. Expected fail-stop
  persistence tests emitted supervised termination logs while passing.
- Direct and outer restart tests prove Client reconnection, same provider
  reuse, whole-agent restart, and provider exit when the durable owner dies.
- Recursive outer and inner supervisor-state scans inspect stored child restart
  MFAs and reject the URL, token, socket/params keys, and all functions.
- Exact child order, heartbeat-only default, strict partial/unknown option
  rejection, distinct names, `:one_for_one` sibling isolation, and no socket
  start without complete configuration remain covered.
- `mix compile --warnings-as-errors --force`, scoped
  `mix format --check-formatted`, `mix credo --strict`, `mix deps`,
  `mix deps.tree --only prod`, `mix app.tree --format plain`, compile xref and
  trace commands, forbidden-reference scans, and scoped `git diff --check`
  passed through `devenv shell`.

The final conventional commit SHA is returned in the task response because a
tracked report cannot contain the hash of the commit that first contains the
report without changing that hash.

## Side-Effect-Free Child-Spec Final Review Fix

Date: 2026-07-18

This section supersedes the retained child-spec lifetime design from the
preceding review iteration.

### Discardable Module Specs

- `YellowDog.ServerAgent.child_spec/1` and
  `YellowDog.ServerAgent.Supervisor.child_spec/1` do not prepare credentials or
  spawn a provider. Complete raw outbound options are deliberately rejected
  with fixed credential-free `start_invalid/0` MFAs.
- Heartbeat-only and complete durable-local specs remain valid, pure module
  child specs. Partial, duplicate, unknown, and malformed options remain
  controlled invalid specs.
- The removed `Client.retain_credentials/1` path no longer detaches a provider
  from its creator or disables bounded claim cleanup. A direct unclaimed
  preparation is erased on creator death or after five seconds.
- This intentionally drops arbitrary delayed-start and exited-builder handoff.
  Task 10 `YellowDog.Application` must provide the production late-bound
  lifecycle owner for outbound module supervision.

### Direct And Explicit Lifecycle Starts

- Raw compatibility remains at both public direct `start_link/1` boundaries.
  Supervisor-name validation runs before credential preparation. Startup then
  prepares and claims before OTP retains any outbound child MFA or state;
  failures after preparation release the provider.
- The test-only lifecycle store/start helper demonstrates the required Task 10
  boundary without adding a production resolver. Its start MFA contains only a
  store PID, resolves raw options in the actual outer parent, replaces them
  with scrubbed prepared options, and reuses the same provider when the entire
  Server-agent child restarts.
- Client death and normal termination still clear the one active lease and
  transport while preserving the provider under its owner. Outer owner death
  erases the provider and socket.
- `Client.child_spec/1` retains its hardened validation: every raw, malformed,
  unknown, or otherwise invalid option set returns only
  `{Client, :start_invalid, []}`.
- Recursive checks over generated specs, outer and inner supervisor state, and
  Client restart MFAs reject the management URL, token, socket/params keys, and
  credential-bearing functions.

### Final Verification

- TDD behavioral red: the selective Supervisor regressions reported
  `17 tests, 3 failures, 13 excluded` for provider-spawning raw child specs and
  the non-local facade start path.
- Focused Client/Supervisor/facade suite: `63 tests, 0 failures`.
- Full Server-agent suite: `252 tests, 0 failures`; expected fail-stop
  persistence cases emitted supervised termination logs while passing.
- Deterministic caller process tracing proves discarded/rejected outbound
  facade and Supervisor specs spawn no process. Direct raw startup and the
  explicit late-bound test boundary prove inner Client and complete agent-child
  restart with the same opaque provider, followed by cleanup on owner death.
- Warnings-as-errors compiled 13 files. Strict Credo checked 32 source files
  and 1,422 modules/functions with no issues. `mix deps`,
  `mix deps.tree --only prod`, `mix app.tree`, compile xref,
  Client/Supervisor/facade traces, forbidden-reference scans, scoped format,
  and `git diff --check` passed through `devenv shell`.

### Invalid Supervisor-Name Cleanup Polish

- Direct `ServerAgent.Supervisor.start_link/1` now validates its OTP supervisor
  name before calling `prepare_options/1`. An invalid name therefore returns
  the controlled error without spawning a credential provider; post-preparation
  start failures continue to release their provider immediately.
- The focused regression first reported `18 tests, 1 failure, 17 excluded` at
  the sanitized `refute spawned?` assertion. After the reorder, the same run
  reported `18 tests, 0 failures, 17 excluded`.
- The final Client/Supervisor/facade run reported `64 tests, 0 failures`.
  Scoped format passed, and warnings-as-errors compiled all 13 Server-agent
  files.
