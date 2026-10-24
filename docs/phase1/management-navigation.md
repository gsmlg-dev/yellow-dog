# Management navigation

Worker is the only node type. The Netman entries and all `/netman` and
`/management/netman` routes have been removed; see [cleanup scope](netman-removal.md).

Step 1 groups the supported Management pages into four sections. The shared
`YellowDog.ManagementUI.Navigation` definition owns ordering, destinations and
route classification; `CurrentPath` and `ServicePaths` retain scope validation.
The header and mobile drawer use these entries in the same order:

| Section | Entry |
| --- | --- |
| Node Management (`nodes`) | `/management/servers` |
| Data Configuration (`data`) | `/management/zones` |
| Monitoring (`monitoring`) | `/management` |
| System Configuration (`system`) | `/system/process-map` |

## Supported route ownership

This mapping was reconciled against `ManagementUI.Router` at the Step 1 baseline
`31a303a8e1ae6b035a65c8ca3310311d5ad8edbe`. Route families below include only
the listed supported descendants, not arbitrary prefix matches.

| Section / secondary item | Routes |
| --- | --- |
| Nodes / Workers | `/management/servers`, `/server` |
| Nodes / selected Worker's service configuration | `/server/:server_id/dashboard`, `/server/:server_id/dns` |
| Nodes / configuration targets and history | `/management/config` |
| Data / DNS zones and records | `/management/zones` and `/server/:server_id/dns/zones`; both support `/new`, `/import`, `/:zone_id/edit`, `/:zone_id/versions`, `/:zone_id/application`, `/:zone_id/records`, `/:zone_id/records/new`, `/:zone_id/records/bulk`, `/:zone_id/records/:rr_index/edit` |
| Data / DNS Views | `/management/dns/views`, `/server/:server_id/dns/views`, `/server/:server_id/dns/views/:service_id` |
| Data / DNS ACLs | `/management/dns/acl`, `/server/:server_id/dns/acl`, `/server/:server_id/dns/acl/:service_id` |
| Data / database catalogs | `/system/ip-database`, `/system/mac-database` |
| Monitoring / overview | `/`, `/management` |
| Monitoring / events and audit | `/management/events` |
| Monitoring / tasks and execution history | `/system/tasks`, `/system/tasks/:task` |
| Monitoring / logs | `/system/logs`, `/system/logs/realtime`, `/system/logs/tasks` |
| Monitoring / network tools | `/tool/mac`, `/tool/whois`, `/tool/geoip` |
| System / backups and restore | `/system/backups`, `/system/backups/restore` |
| System / runtime diagnostics | `/system/process-map` |
| System / API & MCP integration | `/system/integrations` |

## Availability and scope

Available entries link to the router destinations above. Worker service controls
require an explicit Worker; authentication, connections, enabled state, listeners
and service parameters remain capabilities of the existing Worker detail page.
DNS Views and ACLs offer global
Worker/service selectors, then retain the selected scope in their editor routes.
Selected service View/ACL links preserve the service in the route. Scope-free
navigation never selects the first Worker or constructs an invented ID.

Planned entries have a visible **Planned** label and an accessible explanation,
with no URL or event handler: DHCPv4 data, DHCPv6 data, mDNS data; dedicated node,
service and configuration delivery/application status; platform settings,
Management access/external authentication settings, and storage/retention
settings. Retained `ManagementUI.Redesign` source is not a supported destination.

Step 4 activates API & MCP integration at `/system/integrations`, backed by the
versioned HTTP API and MCP endpoint. It reports sanitized deployment settings,
canonical URLs, protocol versions and the finite operation catalog. See
[Management MCP](management-mcp.md) and the [API contract](management-api-contract.md).

Configuration target history describes prepared configuration, not observed
application. Tasks temporarily retain their existing settings, schedules and
execution history on the same page; unavailable task types keep their current
explanations. Backup safeguards remain as implemented. Navigation adds no service
execution, assignments, integration endpoints or business-page implementations.

## Focused browser verification

Run the navigation scope of the existing real Chromium flow from the repository
root inside devenv:

```sh
MANAGEMENT_BROWSER_SCOPE=navigation devenv shell -- scripts/e2e/phase1_postgres.sh scripts/e2e/management_browser.sh
```

The wrapper starts an isolated PostgreSQL database and a Management release on an
ephemeral loopback port, then runs `live_browser_smoke.mjs`, including
`navigation_browser_smoke.mjs`. It exercises desktop/mobile section switching,
zero-Worker access, disabled entries, scoped DNS routes with malformed query
identities, refresh and browser back/forward. Omit `MANAGEMENT_BROWSER_SCOPE` to
run the full existing page workflows as well. With `phoenix_duskmoon` 10.0.11,
the full flow passes the notification-trigger expanded-state checks, including
click close/reopen and Escape dismissal. The 2026-10-23 Step 3 repair run also
passed the later publication, import, artifact, logging and mobile assertions.
The obsolete visible `/prepared_preview/` expectation was migrated to the current
review/publication workflow. See the current repair evidence and remaining ARM
packaging limitation in [management-data-workflow.md](management-data-workflow.md).
The wrapper reports its artifact directory and stops its Management/PostgreSQL
processes. Set `MANAGEMENT_SCREENSHOT_PREFIX=/absolute/path/navigation` to capture
each desktop section, the mobile navigation and existing layout screenshots.

## Step 1 delivery evidence

Implementation baseline: `31a303a8e1ae6b035a65c8ca3310311d5ad8edbe`.

Changed surfaces (paths within `apps/yellow_dog_management`):

- Shared definition: `lib/yellow_dog/management_ui/navigation.ex`.
- Shell: `lib/yellow_dog/management_ui/components/layouts.ex` and `components/sidebar.ex`.
- Existing scope wiring only: `lib/yellow_dog/management_ui/live/dns_views_live.ex`.
- Styles: `assets/management.css` and generated `priv/static/management.css`.
- Tests: `test/navigation_test.exs`, `test/navigation_live_test.exs`,
  `test/navigation_browser_smoke.mjs`, `test/live_browser_smoke.mjs`,
  `test/ui_test.exs`, `test/profiles_live_test.exs`, `test/appbar_version_test.exs`.
- This mapping document: `docs/phase1/management-navigation.md` (repository root).

Validation on 2026-10-20: affected Management tests passed (156 tests); after the
final selector restriction, the navigation tests passed again (13 tests).
Compilation with warnings as errors, scoped formatting, asset build, JavaScript
syntax checks and `git diff --check` passed. The navigation browser command above
passed after rebuilding the final source, using disposable PostgreSQL. This is
navigation acceptance, not a claim that the full browser flow passed.

Screenshots: `/tmp/yellow-dog-navigation-step1/navigation-desktop-nodes.png`,
`navigation-desktop-data.png`, `navigation-desktop-monitoring.png`,
`navigation-desktop-system.png`, `navigation-mobile-navigation.png` in the same
directory. Browser log: `/tmp/yellow-dog-navigation-step1/navigation-browser-final.log`.

## Step 2 node workflow route additions

Starting at `c93175b122c413b7bfe4c7d27b921d002e4f4399`, node details have four
stable tabs. `/server/:server_id/dashboard` is Basic information;
`/connection` is Authentication & connection; `/services` lists DNS instances;
`/targets` is the review/publication workspace. Service creation uses
`/services/new` and editing uses `/services/:service_id/edit` with the database
service UUID scoped to the selected Worker. Historical targets load at
`/targets/:revision`. `/server/:server_id/dns` delegates narrowly to Services.
All these routes are owned by Node Management and the Selected Worker entry.

The global anonymous admission policy now has a separate Node Management entry
at `/management/servers/enrollment`. The Workers list retains name-only logical
registration and canonical transient bootstrap presentation; individual token
reset lives on the selected Worker's connection tab. Policy is not administrator
login and disabling it does not revoke registered Workers. Cross-node history,
Data route ownership, and the four primary sections are unchanged.

Node pages link to existing Data editors and show service-scoped references.
They no longer provide a duplicate Zone assignment form. DNS View/ACL scope
continues to use the selected service UUID. No planned service or platform menu
entry gains a fabricated destination. See [management-node-workflow.md](management-node-workflow.md)
for the application contract, final evidence and limitations.

## Step 3 Data workflow

Zone Content, Versions and Application scope have directly addressable tabs.
Application scope owns complete, fixed-version assignment editing; Node service
references link there and use the pinned version name. The Zone catalog is bounded
and searchable. IP synchronization settings stay in Data; persistent job history
links to Monitoring. See [management-data-workflow.md](management-data-workflow.md)
for operation bounds, target exclusions and verification evidence.
