# Netman removal

Worker is the only node type. Management owns configuration and PostgreSQL;
Worker owns execution. The cancelled Netman product has been removed from the
supported UI, HTTP queries, generic command dispatch and domain. This change does
not implement network management or Resolved in Worker.

The implementation is present in the working tree. Acceptance is **incomplete**:
the Overview browser check exposed an existing audit-outcome defect outside this
cleanup. Work stopped at that boundary, as requested; the defect is not repaired
and its assertions are not weakened.

## Removed surfaces

- Native Netman selection, registration, metadata/configuration/Resolved pages,
  routes, authorization, navigation, overview statistics/presets, event groups and
  configuration-history branches.
- `Netmans`, `NetmanConfig`, the node/draft/version schemas and Domain delegates;
  `/api/netmans` query routes and five Netman mutations. Other generic commands
  remain available under their existing access policy. The finite API/MCP catalog
  continues to expose only its supported operations.
- `apps/yellow_dog_netman`, `apps/yellow_dog_netman_agent`, their startup commands,
  Console sockets/channels/registries/transport, Netman-specific Sync/Core entities
  and obsolete mixed-release campaign, native compiler/CI references and tests.
- Netman-only Console and Redesign presentations, including both retained versions
  of six page paths. Other presentation source remains. The source-transfer
  manifest retains original revision/hash evidence and explicitly records the
  twelve removed targets and precise edits to retained files.

The reusable DHCP client, Resolved, DNS/DHCP protocol libraries, Store and other
service presentations remain source outside the supported root build. Neither
business release loads the old Console, ManagementCore, Sync or Agent runtimes.

## Reviewable database cleanup

The original `20261001000000_create_netman_domain.exs` stays in migration history.
The new `20261024000000_remove_standalone_netman_domain.exs` runs in the normal
Ecto migration transaction and:

1. Removes receipts attributable to the five retired operations through exact
   historical audit fingerprints or exclusive successful Netman result shapes.
2. Removes only those operations' audit rows. It temporarily disables the shared
   immutable-audit trigger inside the transaction and restores it before commit.
3. Drops `management_netman_config_versions`, then
   `management_netman_config_drafts`, then `management_netmans`. This order handles
   the foreign keys; version rollback self-references disappear with their table.

There are no external foreign keys to these three tables. Worker, Service, Zone,
DNS View/ACL, Target, IP artifact, task/job and backup tables are retained.
Configuration is not copied or renamed into Worker records. Rollback is explicitly
irreversible because dropped records cannot be recreated; recovery requires a
pre-migration database backup.

Older idempotency rows have no operation column. Some failed receipts retain only
an opaque digest and a generic error, while the corresponding audit request has
been projected. These cannot be attributed safely and remain. Removed operations
are rejected before receipt lookup, so these rows cannot restore a callable
Netman operation or domain entity.

On 2026-10-25, the user explicitly authorized applying the removal migration to
the existing local devenv database and restarting it. All three Netman tables
were empty and were removed successfully. The existing Worker and bootstrap
identity were retained. Automated migration verification uses
`scripts/e2e/phase1_postgres.sh`; the migration smoke also verifies that the actual
PostgreSQL data directory is the disposable helper cluster before seeding data.
It tests both a fresh schema and an upgrade from the preceding migration, with
nonempty Worker/DNS/Zone/Target/View/ACL/IP/task/backup fixtures and complete table
snapshots. The upgrade acceptance has not passed in this run (see below).

```sh
devenv shell -- scripts/e2e/phase1_postgres.sh python3 \
  apps/yellow_dog_management/test/netman_removal_migration_smoke.py \
  _build/prod/rel/yellow_dog_management/bin/yellow_dog_management
```

## Executed evidence and remaining acceptance

Passed on 2026-10-24:

- `mix compile --warnings-as-errors` in devenv, and production strict compilation.
- 156 scoped Management tests in disposable PostgreSQL: removed UI/API/commands,
  native navigation/overview/events/history, Worker profiles, Domain/Web,
  DNS Views/ACLs, Zone assignments/exports, IP pages and finite API/MCP behavior.
- `scripts/e2e/architecture_smoke.sh`: both isolated releases, shared ConfigSpec
  boundary, positive artifact and 35 rejected artifact mutations.
- Worker release smoke: real authoritative SOA/NS/A over UDP/TCP, concurrent reload,
  SIGKILL recovery, stopped-state persistence and exclusive data-directory locking.
- Real Chromium navigation scope: four desktop/mobile sections, selected Worker
  and DNS context, empty inventory, planned entries and back/forward/refresh.
- Fresh-database migration: no Netman tables remain.
- Management JS bundle rebuilt without Netman references.
- Scoped formatting and syntax checks, `git diff --check`, and source provenance
  verification: 191 retained files and 12 explicitly retired Netman pages.

Additional local verification on 2026-10-25: `devenv up -d` exited successfully;
PostgreSQL, Management and Worker reported `ready`; both loopback and LAN
Management pages returned HTTP 200 and the existing Worker reported `connected`.
This is development startup evidence, not a Management release-smoke result.

Not passed / pending:

- The existing development database still has the old Oban queue tables while
  the current runtime expects `management_jobs.styx_jobs`. Background queues
  report missing-table errors despite HTTP/Worker readiness. This predates the
  Netman removal and requires separate queue-schema repair; it was not changed.
- Overview browser: a duplicate Worker creation genuinely returns `409 conflict`,
  but `AuditContext.project/1` retains only `error.code` and
  `EventsLive.failure/1` requires both `code` and `message`. The existing UI and
  release SQL therefore classify the rejected transaction as committed. Both
  implementations predate this cleanup at `d437bcad`. Evidence:
  `/tmp/management-overview-release-zmevqayd`.
- Management release smoke: listener startup failed with `:eaddrinuse`, including
  the retry with a selected free `YELLOW_DOG_MANAGEMENT_PORT`; its API/runtime
  acceptance is not claimed. Log:
  `/tmp/yellow-dog-netman-cleanup/management-release.log`.
- Upgrade migration: the newly added ACL fixture initially used a name containing
  spaces, which the existing validator rejects before migration. That fixture is
  corrected, but the upgrade has not been rerun after the scope stop. Evidence:
  `/tmp/management-netman-removal-xcy_scmz`.
- Legacy Console/Core/Sync runtime suites, ARM runtime and real Gao-OS/VPN host
  deployment are unexercised. No publication or production deployment is made.

## Necessary remaining references

Netman text remains intentionally in:

- The original and removal migrations above: historical schema and explicit
  cleanup instructions, without a runtime schema or dispatch implementation.
- `test/netman_removal*`, native navigation/overview/events/history tests and
  retained legacy rejection tests: absence, 404, invalid-target and no-runtime
  assertions. Release dependency deny lists still reject retired Agent packages.
- `docs/phase1/ui-source-migration.json` and its checker: original provenance and
  explicit retirement inventory. The 191 other retained files remain unrouted.
- Historical PRDs/plans/reports (`docs/prd`, `docs/superpowers`, build patches,
  migration matrices and user-provided root plan/review files): preserved as
  historical evidence. Current architecture/navigation/API documentation states
  the Worker-only node model; historical inventories do not authorize old routes.

Current native Management, retained Console/Redesign, legacy Core/Sync, config,
supervision and telemetry production source contain no Netman references. Scope
tests prove removed native routes return 404 and retired commands reject before
audit or receipt creation; release artifact checks exclude old runtimes. This
does not claim that the pending Management runtime checks passed.
