# Server Task 10 Report

Date: 2026-07-18

## Result

Task 10 is implemented with `yellow_dog_server_agent: :load` unchanged.
`YellowDog.Application` is the sole profile-driven lifecycle owner.

The Server agent child stored by `YellowDog.Supervisor` contains only:

```elixir
{YellowDog.Application, :start_server_agent, [module]}
```

Its child ID remains `YellowDog.ServerAgent`, matching the service registry and
`YellowDog.ServiceManager.stop_service/1` contract even when tests inject a
different implementation module.

At every initial start or supervisor restart, that function reads the current
`YellowDog.Config` state and `:yellow_dog_server_agent, :runtime` application
configuration, derives fresh options, and dynamically calls the available
facade module's `start_link/1`. The stored child spec contains no management
URL, credential, socket, configuration map, or function.

Keeping the agent application loaded-only avoids an unconditional application
start, duplicate named supervisors, and activation under disabled or legacy
profiles. Modern `[yellow_dog_server]` is the only source that may select the
agent. Disabled custom profiles, legacy `[core]`, and missing modules remain
non-fatal.

## Runtime Behavior

- Runtime configuration owns all six Server management environment reads.
- Blank values are trimmed to `nil`; malformed retry integers become invalid
  sentinels without raising during boot.
- Retry defaults are `1_000` and `30_000` milliseconds only when both values
  are absent. Values must be positive, ordered, and no greater than one day.
- Runtime Server ID and agent data directory override profile/config values.
- A concrete Server ID enables durable local state using the base YellowDog
  data directory. The agent continues to own its `server/` subdirectory.
- No concrete ID starts heartbeat-only. Incomplete outbound identity,
  management configuration, or retry bounds keep durable local state but omit
  the Client configuration.
- Capabilities are sorted unique strings derived from
  `YellowDog.Sync.ServerOperation.all/0`: runtime/settings are always
  advertised, while DNS, DHCP, mDNS, Netboot, and Identity capabilities require
  both an enabled profile service and an available service module.
- Startup telemetry tracks the registry service name (`:server_agent`) rather
  than the injected implementation module. Agent start failures are reduced to
  bounded atoms before telemetry emission.

## Files

- `apps/yellow_dog/lib/yellow_dog/application.ex`
- `apps/yellow_dog/test/support/application_agent_fake.ex`
- `apps/yellow_dog/test/yellow_dog/application_test.exs`
- `config/runtime.exs`
- `config/test.exs`
- `scripts/e2e/release_smoke.sh`
- `.superpowers/sdd/server-task-10-report.md`

No root `mix.exs`, protected console file, or ServerAgent production/test file
was edited or staged by Task 10.

## Verification

Red phase:

```text
devenv shell -- mix cmd --app yellow_dog mix test test/yellow_dog/application_test.exs
```

Result: failed on the missing late-bound APIs and the old controlled-invalid
direct ServerAgent child, establishing the requested behavior before
production edits.

The focused suite also starts the real dynamically loaded
`YellowDog.ServerAgent` with complete outbound configuration, isolated
temporary durable data, and an unavailable loopback endpoint. YellowDog and
the agent supervision tree remain alive while the Client reconnects in the
background. No reconnect sleep is used by the assertion.

Passing tests and compiles:

```text
devenv shell -- mix cmd --app yellow_dog mix test test/yellow_dog/application_test.exs
9 tests, 0 failures

devenv shell -- mix cmd --app yellow_dog mix test
416 tests, 0 failures

devenv shell -- mix cmd --app yellow_dog mix compile --warnings-as-errors
passed

devenv shell -- mix cmd --app yellow_dog_server_agent mix compile --warnings-as-errors
passed

devenv shell -- mix cmd --app yellow_dog_server_agent mix test
253 tests, 0 failures
```

Release:

```text
devenv shell -- scripts/e2e/release_smoke.sh yellow_dog_server
release built; enabled eval passed; disabled eval passed
```

The Server smoke uses two separate TOMLs and release eval VMs. The enabled VM
starts `:yellow_dog`, verifies the agent application itself was not started,
verifies the YellowDog-owned durable agent and configured Server ID, and
verifies no Client exists without management credentials. The disabled VM
verifies both the named agent supervisor and YellowDog child are absent.
Existing management-core and Netman module-boundary assertions remain.

Static checks:

```text
devenv shell -- mix format --check-formatted apps/yellow_dog/lib/yellow_dog/application.ex apps/yellow_dog/test/support/application_agent_fake.ex apps/yellow_dog/test/yellow_dog/application_test.exs config/runtime.exs config/test.exs
passed

devenv shell -- mix cmd --app yellow_dog mix credo --strict
58 files, no issues

devenv shell -- mix cmd --app yellow_dog mix xref trace lib/yellow_dog/application.ex
passed; only declared runtime dependencies reported

bash -n scripts/e2e/release_smoke.sh
passed

git diff --check -- apps/yellow_dog/lib/yellow_dog/application.ex apps/yellow_dog/test config/runtime.exs config/test.exs scripts/e2e/release_smoke.sh
passed
```

Forbidden scans for protocol-library changes, added `:gen_udp`, protocol-path
files, and direct `Concord.*` calls all returned no matches.

## Tooling Notes

- `mix xref warnings` is not supported by Elixir 1.18; the supported scoped
  `mix xref trace` command was used instead.
- `shellcheck` is unavailable in the devenv; `bash -n` passed.
- `mix cmd --app` emits an upstream deprecation warning recommending
  `mix do --app`; the requested commands still execute successfully.
- The first final ServerAgent suite run had one unchanged
  `ConfigApplierTestAdapter.clear/0` teardown race (253 tests, 1 failure). The
  exact test passed in isolation, and the immediate full-suite rerun passed all
  253 tests. No ServerAgent file was changed.
