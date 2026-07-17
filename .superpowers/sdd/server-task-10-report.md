# Server Task 10 Report

Date: 2026-07-18
Task 10 base commit: `39a29cd7`
Async lifecycle follow-up base: `dab3b47a`

## Result

Task 10 keeps `yellow_dog_server_agent: :load`. `YellowDog.Application` remains
the sole profile-driven owner of the Server agent lifecycle; the agent OTP
application is never made permanent or explicitly started.

The long-lived child stored by `YellowDog.Supervisor` has ID
`YellowDog.ServerAgent` and the secret-free start MFA:

```elixir
{YellowDog.Application, :start_server_agent, [module]}
```

At initial start and restart, the MFA reads current `YellowDog.Config` state
and sanitized runtime application configuration, rebuilds all options, and
dynamically invokes the selected module's `start_link/1`. The child spec stores
no management URL, credential, socket, configuration map, or function.

Modern `[yellow_dog_server]` is the only source that may start the agent.
Disabled custom profiles, legacy `[core]`, and missing modules remain
non-fatal during application boot.

## Review Findings

### Public lifecycle

`YellowDog.Application.start_service_supervisor/2` now has a dedicated
`:server_agent` path. It requires a modern profile and a selected module that
is loaded and exports `start_link/1`, then installs the same late-bound child
used at boot. Legacy profiles return `{:error, :unsupported_profile}` and
missing modules return `{:error, :module_not_available}`, allowing
`YellowDog.ServiceManager` to restore its attempted config flag.

Public start, stop, and start-after-stop preserve child ID
`YellowDog.ServerAgent`. The old permissive ServiceManager tests were replaced
with strict lifecycle assertions while the real `YellowDog.Supervisor` runs.

### Async lifecycle reconciliation

Async startup resolves current `YellowDog.Config` after the supervisor is
running and immediately before service selection. A stop completed before
selection therefore prevents the stale boot configuration from selecting the
agent.

The shared agent child installer treats `{:ok, :undefined}` as an intermediate
state, not a successful start. It rechecks the current profile flag and either
deletes the ignored child spec or restarts it when a concurrent enable won the
race. Public agent start recovers an already-present ignored or stopped spec
with `Supervisor.restart_child/2`; bounded retries reconcile `:running`,
`:not_found`, and concurrent start/delete races without exposing raw reasons.
An unresolved race deletes only an observed `:undefined` child entry. A
`:restarting` entry is boundedly re-observed until it becomes deletable or a
live PID wins the race. If it remains in progress, the runtime returns a fixed
pending success so ServiceManager preserves the enabled flag; a later start can
retry reconciliation and an explicit stop remains responsible for removal.

### Capability contract

Capabilities remain sorted, unique, bounded strings derived from
`YellowDog.Sync.ServerOperation.all/0`. Runtime capabilities are advertised;
DNS, DHCP, mDNS, Netboot, and Identity capabilities require both an enabled
service and an available production module.

Settings capabilities are not advertised. The production
`YellowDog.Server.Control` module is loaded in the contract test and is proven
not to implement the ConfigApplier callbacks required for config application.
The test also proves `settings.config.write` and the other wholly unsupported
settings capabilities are absent.

### Identity refresh

After a successful public mutation of any non-agent service, the existing
Server agent child is best-effort terminated and restarted from its stored
late-bound spec. This rebuilds config revision and capabilities from the
post-mutation config before subsequent status publication or reconnect.

The public operation remains authoritative: an agent refresh failure never
rolls back or changes the result of a target service mutation. Missing and
racing children are harmless. Refresh telemetry contains only fixed atoms and
the triggering service name; raw refresh failures are never inspected.
Agent start failures likewise use the registry service atom so injected module
failures remain sanitized.

### Release barrier

The disabled release VM starts only the telemetry dependency, attaches a
handler before `Application.ensure_all_started(:yellow_dog)`, and waits for the
startup-selection event whose skipped-service metadata contains
`SERVER_AGENT`. It then detaches the handler and asserts that neither the named
agent process nor the YellowDog child exists. The fixed sleep was removed.

The enabled and disabled checks still run in separate release eval VMs with
separate TOMLs. Neither VM explicitly starts the Server agent application.

## Runtime Behavior

- Runtime configuration is the sole reader of the six management environment
  values.
- Blank values are trimmed to `nil`; malformed retry integers fail closed
  without raising during boot.
- Retry defaults are `1_000` and `30_000` milliseconds only when both values
  are absent. Bounds must be positive, ordered, and no greater than one day.
- Runtime Server ID and agent data directory override profile values.
- A concrete Server ID enables durable local state using the base YellowDog
  data directory; the agent owns its `server/` subdirectory.
- No concrete ID starts heartbeat-only.
- Incomplete outbound identity, management configuration, or retry bounds keep
  durable local state but omit the Client and socket.
- Management unavailability cannot fail YellowDog boot; reconnect remains a
  background concern.

## Test Coverage

Focused application coverage proves:

- modern enabled startup occurs once after `YellowDog.Supervisor` exists;
- disabled custom, legacy, and missing-module selections do not start;
- public start/stop/start uses the late-bound child and stable module ID;
- async selection uses current configuration rather than captured boot state;
- stop before async selection leaves no ignored child and a later public start
  succeeds;
- public start repeatedly recovers an already-present `:undefined` child spec
  without sleeps;
- legacy and missing-module public starts restore the attempted service flag;
- option derivation, runtime overrides, data directory, revision, and
  capabilities;
- unsupported settings capabilities are absent;
- missing outbound fields and invalid retries create no Client or socket;
- complete configuration with an unavailable endpoint starts the real
  dynamically loaded `YellowDog.ServerAgent` successfully using isolated
  temporary state and no reconnect sleeps;
- child specs recursively exclude URLs, credentials, sockets, maps, and
  closures;
- status, errors, and practical telemetry metadata remain sanitized;
- a real safe service start changes revision/capabilities and stop restores
  both;
- refresh failure cannot reverse a completed target-service mutation.

## Files

Task 10 total owned surface:

- `apps/yellow_dog/lib/yellow_dog/application.ex`
- `apps/yellow_dog/test/support/application_agent_fake.ex`
- `apps/yellow_dog/test/support/application_service_fake.ex`
- `apps/yellow_dog/test/yellow_dog/application_test.exs`
- `apps/yellow_dog/test/yellow_dog/service_manager_test.exs`
- `config/runtime.exs`
- `config/test.exs`
- `scripts/e2e/release_smoke.sh`
- `.superpowers/sdd/server-task-10-report.md`

No root `mix.exs`, protected Console file, or ServerAgent production/test file
was edited or staged by Task 10.

## Verification

Red phase:

```text
devenv shell -- mix cmd --app yellow_dog mix test test/yellow_dog/application_test.exs
15 tests, 7 failures
```

The public lifecycle regression reproduced the confirmed controlled-invalid
failure: `invalid_configuration` containing the
`{YellowDog.ServerAgent, :start_invalid, []}` child start, with no child
installed. The remaining failures covered settings over-advertisement and the
missing identity refresh.

The lifecycle follow-up added the deterministic startup-selection barrier
before production reconciliation:

```text
devenv shell -- mix cmd --app yellow_dog mix test test/yellow_dog/application_test.exs
17 tests, 2 failures
```

One regression observed the stale ignored child exactly as
`{YellowDog.ServerAgent, :undefined, :supervisor, [YellowDog.Application]}`.
The other reproduced public start returning `{:error, :already_present}`.

Green tests:

```text
devenv shell -- mix cmd --app yellow_dog mix test test/yellow_dog/application_test.exs
17 tests, 0 failures

devenv shell -- mix cmd --app yellow_dog mix test test/yellow_dog/application_test.exs test/yellow_dog/service_manager_test.exs
73 tests, 0 failures

devenv shell -- mix cmd --app yellow_dog mix test
422 tests, 0 failures

devenv shell -- bash -lc 'mix cmd --app yellow_dog_server_agent mix compile --warnings-as-errors && mix cmd --app yellow_dog_server_agent mix test'
253 tests, 0 failures
```

Compiles:

```text
devenv shell -- mix cmd --app yellow_dog mix compile --warnings-as-errors
passed

devenv shell -- mix cmd --app yellow_dog_server_agent mix compile --warnings-as-errors
passed
```

Release:

```text
devenv shell -- scripts/e2e/release_smoke.sh yellow_dog_server
release built; enabled eval passed; disabled telemetry-barrier eval passed
```

Static checks:

```text
devenv shell -- mix format --check-formatted <Task 10 Elixir files>
passed

devenv shell -- mix cmd --app yellow_dog mix credo --strict
59 files, no issues

devenv shell -- mix cmd --app yellow_dog mix xref trace lib/yellow_dog/application.ex
passed; only declared runtime dependencies reported

bash -n scripts/e2e/release_smoke.sh
passed

git diff --check -- <Task 10 files>
passed
```

Forbidden scans found no added `:gen_udp`, direct `Concord.*` calls, production
ServerAgent alias/direct calls, protocol-path changes, or ServerAgent file
changes.

## Tooling Notes

- `mix cmd --app` emits the Elixir 1.18 deprecation warning recommending
  `mix do --app`; all requested commands execute successfully.
- `mix xref warnings` is unsupported by Elixir 1.18, so the supported scoped
  `mix xref trace` command was used.
- `shellcheck` is unavailable in the devenv; `bash -n` passed.
- The first telemetry-barrier smoke attempt reached the disabled VM before the
  telemetry application was running. Starting only that dependency before
  handler attachment fixed the barrier; the subsequent full build and both
  isolated evals passed.
