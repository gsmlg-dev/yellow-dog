# Gaoxy HTTP transport

Management uses published Hex `gaoxy_http` 0.5.5 with
`Gaoxy.PhoenixAdapter`. Phoenix's `websock_adapter` dependency is explicitly
resolved to Hex `gaoxy_websock_adapter` 0.5.5, retaining the OTP application and
`WebSockAdapter` module names. Both packages are required for LiveView upgrades.
The Endpoint remains the sole owner of its HTTP listener and existing session,
Origin and router policies.

The matching Gaoxy core uses Hell 0.1.2 TCP/TLS and Abyss 0.9.0 infrastructure.
Management permits these HTTP transport dependencies. Their application startup
creates registries, tasks and ETS infrastructure; UDP/QUIC services require
explicit separate configurations, which Management does not supply. DNS, DHCP,
Netboot, Identity and other Worker business execution remain excluded. Both
supported releases reject `abyss_raw`, the old DHCP native package, Bandit and
ThousandIsland. Worker does not acquire the Gaoxy HTTP stack.

The retained Console source uses the same dependencies and supported listener
settings. It remains excluded from the default umbrella and is not evidence of
a complete Console application build or runtime acceptance. Historical release
and source-retention records remain unchanged.

Run Mix commands through `devenv shell -- …`. The scoped HTTPS proxy tests cover
real TCP WebSocket upgrades, LiveView joins and Origin rejection. The architecture
gate checks active dependency selection and clean release manifests, including
negative mutations. Management release smoke verifies real HTTP, durable state
and that its process opens only the configured HTTP listener. Database release
tasks must leave the web transport and Worker runtimes stopped.

Validated for this migration:

- Strict development/production compilation, changed-file formatting and scoped
  Management Credo checks.
- 14 Management HTTP/settings tests and two retained Console configuration tests.
- Clean release architecture checks and 35 rejected negative mutations.
- Both real release smoke checks, including the 20,138-byte / 203-record JSON
  round-trip and Worker recovery after SIGKILL.
- Fresh Nix dependency hash resolution and both x86_64 Linux package builds;
  assembled packages exclude Bandit/ThousandIsland and preserve the transport
  boundaries above.
- Chromium Worker enrollment, authenticated target delivery, real DNS UDP/TCP,
  Management outage/reconnect, credential reset and final graceful cleanup.

An initial connection smoke run exposed a harness startup race: persisted
Management state could satisfy restart assertions before the new Worker VM had
finished booting, allowing an early SIGTERM. The harness now uses RPC to verify
the new OS process has started the Worker application and initialized its runtime
before those assertions. The corrected full gate passes with the original
20-second graceful-stop deadline; Worker product code is unchanged.

Optional Bandit names in upstream lock metadata do not activate that dependency;
there are no Bandit or ThousandIsland lock entries or packaged applications.
This migration does not establish HTTP/2, HTTP/3, ARM runtime or host deployment
acceptance.

Upstream packages:

- https://hex.pm/packages/gaoxy_http/0.5.5
- https://hex.pm/packages/gaoxy/0.5.5
- https://hex.pm/packages/gaoxy_websock_adapter/0.5.5
