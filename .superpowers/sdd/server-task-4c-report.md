# YellowDog Server Task 4C Report

## Implementation

Added `YellowDog.Server.Control.Dhcp`, the fixed DHCP family facade used by the
existing single `:dhcp` Dispatcher route.

- Routes only exact `"ipv4"` to the fixed `Dhcpv4` module and exact `"ipv6"`
  to the fixed `Dhcpv6` module.
- Uses `Module.concat/1` for production family module names, so the core app
  remains compile-safe without a direct dependency on either family app.
- Delegates the operation and payload unchanged to `dispatch/2` and `current/2`.
- Missing or unknown direct-facade family returns `YellowDog.Sync.Error` code
  `:invalid` without invoking an adapter.
- A known family whose module is unavailable or lacks the requested callback
  returns code `:unsupported`.
- Test-only overrides are enabled only in `Mix.env() == :test`, permit only the
  two fixed family keys, and cannot select a route from caller payload fields.

No Dispatcher production edit was required. Its existing `:dhcp` route,
family-specific `:dhcpv4`/`:dhcpv6` availability checks, and Dispatcher-owned
revision handling already provide the required integration boundary.

## Coverage

- Added direct facade coverage for IPv4/IPv6 `dispatch/2` and `current/2`,
  unchanged operation/payload forwarding, invalid-family zero invocation,
  missing/incomplete adapters, and fixed-key test override validation.
- Added Dispatcher coverage using the real Dhcp facade and fixed test family
  adapters for an IPv6 query and an IPv4 revision-checked command.
- Added Dispatcher coverage for disabled and unavailable family service gates,
  and schema-level invalid-family zero invocation.

## Verification

All commands ran from the repository root through `devenv shell`.

| Command | Result |
| --- | --- |
| `cd apps/yellow_dog && mix test test/yellow_dog/server/control/dhcp_test.exs test/yellow_dog/server/control/dispatcher_test.exs` | 29 tests, 0 failures |
| `cd apps/yellow_dog && mix test` | 353 tests, 0 failures |
| `cd apps/yellow_dog_dhcpv4 && mix test` | 420 tests, 0 failures, 15 excluded |
| `cd apps/yellow_dog_dhcpv6 && mix test` | 316 tests, 0 failures, 1 skipped |
| `mix compile --warnings-as-errors` | passed |
| `mix format --check-formatted` on changed Elixir files | passed |
| `git diff --check` | passed |
| `cd apps/yellow_dog && mix credo --strict` | 0 issues |

## Scope

This task changes only the new fixed facade, focused control tests, Dispatcher
test coverage, and shared test control fake. No protocol, socket, persistence,
Mnesia, release, console, or root Mix files were modified by this task. The
four protected user files and unrelated worktree changes remain untouched.

## Notes

The full DHCPv4 and DHCPv6 suites emitted existing supervisor/telemetry test
runtime log messages while completing with zero failures. No out-of-scope
changes were made for those logs.
