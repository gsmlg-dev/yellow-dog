# Console Scoping And Release E2E Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Require an explicit Server or Netman selection before service navigation, route every read and mutation to that concrete runtime, and prove the complete flow by starting all three Linux amd64 releases in PR and manual CI.

**Architecture:** The console owns authenticated Phoenix sockets, concrete connection registries, request correlation, and the `YellowDog.Management.Transport` implementation. A shared LiveView scope hook loads the selected record from management core. Console domain gateways map page actions to typed management-core calls. A coordinated E2E script builds and starts management_core, server, and netman releases together.

**Tech Stack:** Phoenix 1.8, LiveView, Phoenix Channels, DuskMoon components, ExUnit, Bash release orchestration, GitHub Actions.

## Global Constraints

- Complete the shared control-plane, Server runtime, and Netman runtime plans first.
- Keep the visible top navigation order exactly: Management, Servers, Netman, Tools, System.
- The top-level label is `Management`, never `Node Management`.
- `/server` and `/netman` are selection landings. No route selects a default record.
- All service routes include `:server_id` or `:netman_id`.
- Before selection, service items are disabled controls without `href` or `navigate`.
- Registered offline records remain selectable. Cached reads show observation time. Imperative actions remain disabled and are never queued.
- LiveViews do not call runtime modules, PIDs, ETS, Store, Mnesia, Concord, or local config files.
- Use existing DuskMoon/Phoenix components and design tokens. Do not introduce a broad visual rewrite.
- Integrate the existing dirty edits in `layouts.ex`, console `mix.exs`, `service_pages_live_test.exs`, and root `mix.exs`; do not revert them.
- Write each test first and observe the expected failure.

---

### Task 1: Add authenticated Server and Netman control connections

**Files:**
- Modify: `apps/yellow_dog_console/mix.exs`
- Create: `apps/yellow_dog_console/lib/yellow_dog/console/channels/server_socket.ex`
- Create: `apps/yellow_dog_console/lib/yellow_dog/console/channels/server_channel.ex`
- Create: `apps/yellow_dog_console/lib/yellow_dog/console/channels/server_connections.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/channels/netman_socket.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/channels/netman_channel.ex`
- Rename and rewrite: `apps/yellow_dog_console/lib/yellow_dog/console/channels/netman_registry.ex` to `apps/yellow_dog_console/lib/yellow_dog/console/channels/netman_connections.ex`
- Create: `apps/yellow_dog_console/lib/yellow_dog/console/management_transport.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/endpoint.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/application.ex`
- Create: `apps/yellow_dog_console/test/yellow_dog/console/channels/server_socket_test.exs`
- Create: `apps/yellow_dog_console/test/yellow_dog/console/channels/server_channel_test.exs`
- Create: `apps/yellow_dog_console/test/yellow_dog/console/channels/server_connections_test.exs`
- Modify: `apps/yellow_dog_console/test/yellow_dog/console/channels/netman_socket_test.exs`
- Rename and rewrite: `apps/yellow_dog_console/test/yellow_dog/console/channels/netman_registry_test.exs` to `apps/yellow_dog_console/test/yellow_dog/console/channels/netman_connections_test.exs`
- Create: `apps/yellow_dog_console/test/yellow_dog/console/channels/netman_channel_test.exs`
- Create: `apps/yellow_dog_console/test/yellow_dog/console/management_transport_test.exs`

- [ ] Add `yellow_dog_sync` to console dependencies and configure `YellowDog.Console.ManagementTransport` as management core's transport in console runtime startup.
- [ ] Test missing token, wrong token, constant-time comparison path, malformed ID, unregistered ID, target-type mismatch, and valid connection for both sockets.
- [ ] Replace the existing test that rejects Netman in the management release: control sockets must be accepted there and rejected only when authentication or registration fails.
- [ ] Test one active connection per concrete ID. A replacement must complete its hello/status handshake before the old channel is closed.
- [ ] Test `request_id` correlation, concurrent out-of-order replies, timeout cleanup, late replies, disconnect-to-unknown transitions, and per-ID isolation.
- [ ] Run channel tests and verify failures before implementation.
- [ ] Mount `/server/ws` and retain `/netman/ws`, with the shared token read from `YELLOW_DOG_MANAGEMENT_TOKEN` through runtime config.
- [ ] Store channel PID, monitor reference, identity, capabilities, status, last seen, and pending request map in separate Server and Netman connection processes.
- [ ] Forward status, journal, config-state, result, and event messages into management-core APIs before acknowledging them.
- [ ] Broadcast only ID-scoped PubSub topics: `management:server:<id>` and `management:netman:<id>`.
- [ ] Re-run all channel and transport tests.
- [ ] Commit with `feat(console): add service control channels`.

### Task 2: Add authenticated blob transfer for Netboot assets

**Files:**
- Create: `apps/yellow_dog_management_core/lib/yellow_dog/management/blobs.ex`
- Modify: `apps/yellow_dog_management_core/lib/yellow_dog/management_core.ex`
- Create: `apps/yellow_dog_management_core/test/yellow_dog/management/blobs_test.exs`
- Create: `apps/yellow_dog_console/lib/yellow_dog/console/controllers/management_blob_controller.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/router.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/plugs/management_release_only.ex`
- Create: `apps/yellow_dog_console/test/yellow_dog/console/controllers/management_blob_controller_test.exs`

- [ ] Test token rejection, malformed digest, missing blob, content-length limit, digest verification, and successful streaming.
- [ ] Run the test and verify route/controller absence.
- [ ] Add `GET /management/blobs/:sha256` through a token-authenticated API pipeline.
- [ ] Resolve files only through management-core blob APIs. Never concatenate an unvalidated digest into a path in the controller.
- [ ] Use constant-time token comparison and do not expose filesystem paths in responses.
- [ ] Permit the route in the management-release-only plug.
- [ ] Re-run controller and plug tests.
- [ ] Commit with `feat(console): serve authenticated config blobs`.

### Task 3: Add selector pages, route scope, and deterministic legacy redirects

**Files:**
- Create: `apps/yellow_dog_console/lib/yellow_dog/console/hooks/service_scope.ex`
- Create: `apps/yellow_dog_console/lib/yellow_dog/console/service_paths.ex`
- Create: `apps/yellow_dog_console/lib/yellow_dog/console/live/server_live/selector_live.ex`
- Rewrite: `apps/yellow_dog_console/lib/yellow_dog/console/live/netman_live/dashboard_live.ex`
- Create: `apps/yellow_dog_console/lib/yellow_dog/console/controllers/service_redirect_controller.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/router.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/plugs/management_release_only.ex`
- Create: `apps/yellow_dog_console/test/yellow_dog/console/hooks/service_scope_test.exs`
- Create: `apps/yellow_dog_console/test/yellow_dog/console/service_paths_test.exs`
- Create: `apps/yellow_dog_console/test/yellow_dog/console/live/service_selector_live_test.exs`
- Create: `apps/yellow_dog_console/test/yellow_dog/console/controllers/service_redirect_controller_test.exs`
- Modify: `apps/yellow_dog_console/test/yellow_dog/console/plugs/management_release_only_test.exs`

- [ ] Test `/server` and `/netman` with zero, online, and offline registered records.
- [ ] Test explicit selection links to `/server/<id>/dashboard` and `/netman/<id>`.
- [ ] Test unknown IDs render deterministic not-found content and never substitute another record.
- [ ] Test legacy `/server/dashboard`, `/server/dns`, `/server/settings`, `/netman/config`, and all other unscoped service routes redirect to the matching selector without choosing an ID.
- [ ] Test encoded IDs, overlong IDs, slash traversal, and route helper preservation of nested resource parameters.
- [ ] Run focused tests and verify the old routes/selector behavior fail.
- [ ] Add a global LiveView hook that assigns exactly one of `selected_server` or `selected_netman`, plus `service_online?`, `snapshot_observed_at`, and stable not-found state.
- [ ] Implement route helpers with explicit functions instead of string replacement:

```elixir
server_path(server_id, :dashboard)
server_path(server_id, {:dns_zone_records, zone_id})
netman_path(netman_id, :config)
netman_path(netman_id, :dhcp_client)
```

- [ ] Define scoped routes under `/server/:server_id` and `/netman/:netman_id`. Keep redirect routes in a separate legacy scope.
- [ ] Allow selector, scoped service, control socket, LiveView, assets, and management blob paths in the management-only release.
- [ ] Re-run selector, route, hook, and plug tests.
- [ ] Commit with `feat(console): scope service routes by instance`.

### Task 4: Make top navigation and sidebars selection-aware

**Files:**
- Modify and preserve current user edits: `apps/yellow_dog_console/lib/yellow_dog/console/components/layouts.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/components/sidebar.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/hooks/current_path.ex`
- Modify and preserve current user edits: `apps/yellow_dog_console/test/yellow_dog/console/live/service_pages_live_test.exs`
- Create: `apps/yellow_dog_console/test/yellow_dog/console/components/sidebar_scope_test.exs`

- [ ] Test exact top navigation order and selector destinations: Management `/management`, Servers `/server`, Netman `/netman`, Tools, System.
- [ ] Test that Server and Netman top navigation remains enabled because it opens a selector.
- [ ] Test every service sidebar item before selection renders without `href`, without `data-phx-link`, and with `disabled` or `aria-disabled="true"`.
- [ ] Test every service sidebar link after selection includes the exact selected ID and preserves nested paths.
- [ ] Test switching from Server A to Server B changes all service destinations and active-state matching.
- [ ] Run tests and verify current hardcoded sidebar paths fail.
- [ ] Pass selected concrete records into the sidebar from layout assigns set by the scope hook.
- [ ] Render a compact selector control at the top of Server and Netman sidebars. Use a menu/select pattern, not a text button pretending to be a selector.
- [ ] Build links only through `ServicePaths`. Do not perform regex path rewriting in HEEx.
- [ ] Retain the current DuskMoon classes and exact navbar order.
- [ ] Re-run sidebar and service-page navigation tests.
- [ ] Commit with `feat(console): require service selection in navigation`.

### Task 5: Add console-side typed Server and Netman gateways

**Files:**
- Create: `apps/yellow_dog_console/lib/yellow_dog/console/server_management.ex`
- Create: `apps/yellow_dog_console/lib/yellow_dog/console/netman_management.ex`
- Create: `apps/yellow_dog_console/lib/yellow_dog/console/management_result.ex`
- Create: `apps/yellow_dog_console/test/support/management_transport.ex`
- Create: `apps/yellow_dog_console/test/yellow_dog/console/server_management_test.exs`
- Create: `apps/yellow_dog_console/test/yellow_dog/console/netman_management_test.exs`
- Create: `apps/yellow_dog_console/test/yellow_dog/console/management_result_test.exs`

- [ ] Test one named gateway function for every operation in the approved Server and Netman operation tables.
- [ ] Test online query/command dispatch, offline cached query, offline command rejection, conflict rendering metadata, timeout, unsupported capability, validation details, and bounded internal error text.
- [ ] Run focused tests and verify modules are absent.
- [ ] Each gateway function must call a concrete management-core facade and supply selected type/ID, typed operation name, payload, expected revision, and idempotency key.
- [ ] Centralize conversion of stable control errors into LiveView assigns/flash values without leaking stack traces or paths.
- [ ] Keep operation-name strings inside these gateways so LiveViews never construct raw envelopes.
- [ ] Re-run gateway tests.
- [ ] Commit with `feat(console): add typed management gateways`.

### Task 6: Migrate Server runtime, Settings, DNS, and provider pages

**Files:**
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/dashboard_live.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/dashboard_live.html.heex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/settings_live.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/settings_live.html.heex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/settings_live/dns_tab.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/settings_live/mdns_tab.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/settings_live/dhcpv4_tab.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/settings_live/dhcpv6_tab.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/settings_live/netboot_tab.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/index.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/index.html.heex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/acl_live.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/acl_live.html.heex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/metrics_live.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/query_logs_live.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/view_live/index.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/view_live/index.html.heex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/zone_live/index.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/zone_live/index.html.heex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/rr_live/index.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/rr_live/index.html.heex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/provider_live/index.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/provider_live/index.html.heex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/provider_live/show.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/provider_live/show.html.heex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/provider_live/conflict_live.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/provider_live/conflict_live.html.heex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/cloud_dns_live.ex`
- Modify: `apps/yellow_dog_console/test/yellow_dog/console/live/dashboard_live_test.exs`
- Modify: `apps/yellow_dog_console/test/yellow_dog/console/live/settings_live_test.exs`
- Modify: `apps/yellow_dog_console/test/yellow_dog/console/live/dns_live_test.exs`
- Modify: `apps/yellow_dog_console/test/yellow_dog/console/live/dns_metrics_and_logs_live_test.exs`
- Modify: `apps/yellow_dog_console/test/yellow_dog/console/live/cloud_dns_live_test.exs`
- Create: `apps/yellow_dog_console/test/yellow_dog/console/live/server_scope_isolation_test.exs`

- [ ] Register Server A and Server B and configure the fake transport with distinct capabilities, service status, DNS views/zones/records/providers, metrics, logs, and config revisions.
- [ ] Test every page reads only the selected Server and every link/form/redirect retains its ID.
- [ ] Test start/stop/restart, Settings validate/apply/reload/rollback, DNS CRUD/import/sync/conflict operations, stale revisions, and offline disabling.
- [ ] Run focused tests and verify existing pages call local modules or omit IDs.
- [ ] Replace direct runtime calls with `ServerManagement` functions. Keep local view-state filtering and form validation presentation in LiveView.
- [ ] Move cloud-provider management into the selected Server DNS route set; retain deterministic redirects from old system paths.
- [ ] Render snapshot observation time on offline reads and disable all imperative controls.
- [ ] Re-run all modified Server/DNS/Settings tests.
- [ ] Commit with `feat(console): remote manage server dns and settings`.

### Task 7: Migrate Server DHCP, mDNS, Netboot, Identity, and Fingerprint pages

**Files:**
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/dhcpv4_live/index.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/dhcpv4_live/index.html.heex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/dhcpv4_live/leases_live.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/dhcpv4_live/leases_live.html.heex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/dhcpv4_live/pools_live.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/dhcpv4_live/pool_live.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/dhcpv4_live/pool_live.html.heex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/dhcpv4_live/activity_live.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/dhcpv6_live/index.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/dhcpv6_live/index.html.heex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/dhcpv6_live/leases_live.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/dhcpv6_live/leases_live.html.heex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/dhcpv6_live/pools_live.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/dhcpv6_live/pool_live.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/dhcpv6_live/pool_live.html.heex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/dhcpv6_live/activity_live.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/mdns_live/index.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/mdns_live/index.html.heex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/mdns_live/services_live.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/mdns_live/services_live.html.heex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/mdns_live/discovery_live.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/mdns_live/discovery_live.html.heex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/mdns_live/monitor_live.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/mdns_live/monitor_live.html.heex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/netboot_live/index.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/netboot_live/devices_live.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/netboot_live/device_detail_live.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/netboot_live/profiles_live.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/netboot_live/profile_editor_live.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/netboot_live/tftp_live.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/netboot_live/log_live.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/identity/index.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/identity/hosts_live.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/identity/host_detail_live.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/identity/approvals_live.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/identity/tokens_live.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/identity/policies_live.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/identity/audit_live.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/fingerprint_live/devices_live.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/fingerprint_live/device_detail_live.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/fingerprint_live/fingerprints_live.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/components/pool_form_component.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/components/netboot_components.ex`
- Modify: `apps/yellow_dog_console/test/yellow_dog/console/live/service_pages_live_test.exs`
- Modify: `apps/yellow_dog_console/test/yellow_dog/console/live/pool_detail_live_test.exs`
- Modify: `apps/yellow_dog_console/test/yellow_dog/console/live/mdns_services_live_test.exs`
- Modify: `apps/yellow_dog_console/test/yellow_dog/console/live/netboot_live_test.exs`
- Modify: `apps/yellow_dog_console/test/yellow_dog/console/live/identity_live_test.exs`
- Modify: `apps/yellow_dog_console/test/yellow_dog/console/live/fingerprint_live_test.exs`

- [ ] Add distinct fake responses for Server A and B across every migrated domain.
- [ ] Test all approved mutations, bulk per-item results, stale revisions, offline disabling, cached observation timestamps, unknown selected ID, and ID-preserving nested edit/back links.
- [ ] Run focused tests and verify direct local calls or unscoped paths fail.
- [ ] Replace runtime calls with `ServerManagement`. Do not call protocol internals or repeat mutation loops in LiveView.
- [ ] Route fingerprint pages under the selected Server. Retain deterministic redirects from old system paths.
- [ ] Upload Netboot assets through the management blob workflow and send only digest/metadata in the typed command.
- [ ] Re-run every modified LiveView test.
- [ ] Commit with `feat(console): remote manage server service domains`.

### Task 8: Migrate all Netman pages

**Files:**
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/netman_live/node_live.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/netman_live/config_live.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/netman_live/interfaces_live.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/netman_live/resolved_live.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/netman_live/dhcp_client_live.ex`
- Create: `apps/yellow_dog_console/test/yellow_dog/console/live/netman_scope_live_test.exs`
- Modify: `apps/yellow_dog_console/test/yellow_dog/console/live/service_pages_live_test.exs`

- [ ] Test two Netman records with different profiles, apply modes, interfaces, routes, Resolved state, DHCP leases, and online status.
- [ ] Test selected-only reads and profile validate/put/delete/activate/rollback, connection activation/deactivation, Resolved update/rollback/flush, and DHCP release.
- [ ] Test `:observe` and `:observe_first` control states, conflicts, offline cached reads, offline action disabling, and reconnect status updates.
- [ ] Run focused tests and verify current pages read directly from the old registry payload.
- [ ] Replace old registry access with `NetmanManagement` and management-core snapshots.
- [ ] Remove connection documentation from the product page; runtime setup belongs in operator documentation, not the management workflow.
- [ ] Keep VPN visible as profile state only, with no action control.
- [ ] Re-run all Netman LiveView and channel tests.
- [ ] Commit with `feat(console): remote manage selected netman`.

### Task 9: Complete Management config, events, and direct links

**Files:**
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/management_live/index.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/management_live/data.ex`
- Modify: `apps/yellow_dog_console/test/yellow_dog/console/live/management_live_test.exs`

- [ ] Test Server and Netman table rows link to their scoped selectors/pages.
- [ ] Test Config lists desired/delivered/applying/applied/failed versions, digest, timestamps, target, failure phase, and rollback result.
- [ ] Test Events shows durable scoped events and command outcomes in deterministic order.
- [ ] Test management-core restart does not empty these pages.
- [ ] Run focused tests and verify placeholder Config content fails.
- [ ] Replace placeholder cards with facade-backed tables and status badges using existing components.
- [ ] Keep row wording `service nodes` where useful, but do not label the product or domain `Node Management`.
- [ ] Re-run management LiveView tests.
- [ ] Commit with `feat(console): show durable management state`.

### Task 10: Add coordinated three-release management E2E

**Files:**
- Modify and preserve current user edits: `mix.exs`
- Create: `e2e_test/management_release_e2e_test.exs`
- Create: `e2e_test/support/management_release.ex`
- Create: `scripts/e2e/management_releases.sh`
- Modify: `scripts/e2e/release_smoke.sh`
- Modify: `.github/workflows/e2e.yml`

- [ ] Add `mix test.e2e.management` that runs only the management release E2E test.
- [ ] Write orchestration assertions before the script: all three release binaries must exist and the test must fail when any one is absent.
- [ ] Add test fixtures under temporary directories for management durable state, Server config/data, Netman profiles, ports, and logs.
- [ ] Build host-native Linux amd64 releases `yellow_dog_management_core`, `yellow_dog_server`, and `yellow_dog_netman` in one job.
- [ ] Start management first, then Server and Netman with the shared test token, concrete IDs, safe nonprivileged ports, and isolated data directories. Capture PIDs and logs and always stop processes in a trap.
- [ ] Poll release-backed health with bounded deadlines; never use source `mix run` as the runtime under test.
- [ ] Verify through management-core RPC and HTTP/LiveView-visible state:
  - both concrete runtimes authenticate and register;
  - selected Server and Netman queries return distinct data;
  - representative typed mutations for every approved domain return correlated results;
  - valid config reaches applied only after runtime acknowledgement;
  - offline latest-desired delivery works after runtime restart;
  - duplicate delivery returns the journaled result;
  - invalid activation restores previous known-good state;
  - Netman connectivity timeout restores its prior profile;
  - management restart preserves records, versions, commands, snapshots, and events.
- [ ] Print all three release logs when a check fails.
- [ ] Keep the existing per-release smoke matrix. Add a separate `management-release-e2e` job gated by `pull_request` or `workflow_dispatch` because integration requires all three releases together.
- [ ] Run `devenv shell -- mix test.e2e.management` locally and verify it builds and uses release binaries.
- [ ] Validate workflow syntax and inspect the event/job gates.
- [ ] Commit with `test(e2e): exercise three management releases`.

### Task 11: Final console, release, and architecture verification

**Files:**
- Modify only files required to resolve failures introduced by this plan.

- [ ] Run `devenv shell -- mix format --check-formatted`.
- [ ] Run `devenv shell -- mix compile --warnings-as-errors`.
- [ ] Run `devenv shell -- mix test`.
- [ ] Run `devenv shell -- bash -lc 'cd apps/yellow_dog_console && mix test'`.
- [ ] Run `devenv shell -- bash -lc 'cd apps/yellow_dog_console && mix assets.build'`.
- [ ] Run `devenv shell -- mix test.e2e.management`.
- [ ] Start `devenv shell -- mix console.run` and verify `/server`, one scoped Server page, `/netman`, one scoped Netman page, and `/management/config` in a browser at desktop and mobile widths.
- [ ] Verify the DOM has no enabled service link before selection and every enabled service link contains the selected ID.
- [ ] Verify `mix yellowdog.run` and `mix console.run` both start the Web UI, while `mix server.run` and `mix netman.run` start their respective runtimes.
- [ ] Run `rg -n 'defmodule YellowDog\.(Domain\.Node|Management\.Node|Node)' apps docs`; expect no matches.
- [ ] Run `find apps -maxdepth 1 -type d \( -name yellow_dog_cloud_dns -o -name yellow_dog_local_server \)`; expect no output.
- [ ] Run `rg -n 'yellow_dog_store|YellowDog\.Store' apps/yellow_dog_netman apps/yellow_dog_netman_agent`; expect no matches.
- [ ] Run `git diff -U0 | rg '^\+.*:gen_udp'`; expect no output.
- [ ] Run `git diff --name-only -- apps/abyss apps/ex_dns apps/ex_dhcp`; expect no output.
- [ ] Run `git diff --name-only | rg 'migrations|mnesia|schema'`; inspect and require no database/schema change from this work.
- [ ] Run `git diff --check`.
- [ ] Commit verification-only corrections with `fix(management): satisfy integration guardrails` when needed. Do not create an empty commit.

## Completion Evidence

Record every command and result, including skipped checks and exact failures. This plan is complete only when selection controls all Server and Netman navigation, every page targets its selected concrete runtime, offline and conflict states are visible and safe, the management-only release serves the scoped pages and control sockets, and CI builds and exercises all three releases together.
