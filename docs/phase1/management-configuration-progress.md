# Management configuration and IP artifact increment

## Scope and baseline

The active task is `docs/yellow-dog-codex-management-plan.md`. The operator
separately authorized committing and pushing each completed checkpoint. The
supplied plan remains local and unmodified.

Starting checkout: `main`, `0301404b18b9faffa629982d5035474524f4c21e`.
The only pre-existing working-tree change was the untracked supplied plan.
Historical architecture and UI-source reports are not acceptance evidence for
this increment.

This increment authorizes the routed native Management DNS View scope, global
Zone assignments and persistence, and a durable IP database artifact catalog.
Retained redesign presentations remain unrouted. Worker runtime repair, service
delivery, View/GeoIP serialization, and unrelated retained-page redevelopment
remain outside scope.

## P0 baseline evidence

Executed through Nix/devenv:

```sh
devenv shell -- bash -c 'cd apps/yellow_dog_management && mix compile --warnings-as-errors'
devenv shell -- scripts/e2e/phase1_postgres.sh bash -c 'cd apps/yellow_dog_management && mix test test/domain_test.exs test/dns_views_test.exs test/zones_live_test.exs test/geo_ip_download_test.exs'
devenv shell -- python3 scripts/e2e/check_ui_source_migration.py
```

Compilation and the scoped test command both exited 1 before tests could run.
The retained `redesign/current/live/dns_live/provider_live/show.ex:6` and other
DNS pages import `Redesign.DnsLive.ManagementComponents`. Its source file also
contains `ManagementSupport`, which expands the omitted legacy
`Redesign.ManagementResult` struct. The first reported failure was the unavailable
component import. The source provenance checker passed all 201 baseline files;
this proves retention, not compilation.

The disposable PostgreSQL wrapper started and cleaned up its own cluster.
Its artifacts are `/tmp/yellow-dog-phase1-pg.qgsxwF` for this initial run.
No execution Worker or legacy service was started.

## P0 completed prerequisite

The prerequisite preserves all retained presentations and both source revisions.
Two genuine pure helpers (`ServiceHelper` and `ConfigHelpers`) were transferred
with source provenance. Unavailable struct patterns now match the same tagged
maps, and constructors defer `struct!/2` until invocation. Retained calls to
unavailable backends use runtime function captures; they keep their original
module, function, arity and arguments. Genuine retained Identity helper aliases
now point to their actual `Redesign.Current` namespace. These pages remain
unrouted and have no functional acceptance claim. No runtime module, dependency,
fake result, route, broad source exclusion or warning suppression was added.

Every adaptation and scoped formatting change is replayed by the unchanged
source checker. The current retained inventory is 203 files. The original
201-file inventory remains historical evidence.

Fresh final checks:

```sh
devenv shell -- bash -c 'cd apps/yellow_dog_management && mix compile --force --warnings-as-errors'
devenv shell -- scripts/e2e/phase1_postgres.sh bash -c 'cd apps/yellow_dog_management && mix test test/domain_test.exs test/dns_views_test.exs test/dns_views_live_test.exs test/zones_live_test.exs test/geo_ip_download_test.exs test/task_artifacts_test.exs test/ip_database_live_test.exs'
devenv shell -- python3 scripts/e2e/check_ui_source_migration.py
git diff --check
```

Forced compilation passed. Focused PostgreSQL baseline tests passed: 94 tests,
0 failures. The source checker passed all 203 files, scoped formatting passed
all 115 changed Elixir/HEEx files, and diff whitespace passed. PostgreSQL was
cleaned up; test artifacts are `/tmp/yellow-dog-phase1-pg.3U12K4`.
Compiler/test evidence is `/tmp/yellow-dog-p0-force-compile.log` and
`/tmp/yellow-dog-p0-baseline-tests.log`. These tests establish an executable
baseline, not the new selectors, assignments or artifact catalog.

## Checkpoint status

| Checkpoint | Status |
| --- | --- |
| P0 build prerequisites | Complete; forced compile and 94 scoped baseline tests pass |
| P1 Worker scope and Zone assignments | Complete; 78 scoped tests and real browser/restart acceptance |
| P2 editor reliability and persistence | Complete; 85 focused checks plus real browser failure/retry acceptance |
| P3 artifact catalog | Complete; fixture publication/UI checks and full release restart acceptance |
| P4 export boundary and integrated acceptance | Complete; explicit export limits, 129 scoped tests, full browser/restart and architecture checks |

P1/P2/P3 now have actual database, browser and restart acceptance; the source-only
retention evidence remains a separate prerequisite check.

## P1 accepted configuration workflows

The routed global View entry `/management/dns/views` selects disconnected logical
Workers. One DNS Service preselects; multiple require a choice; none links to
Service configuration. Scope switches explicitly handle unsaved input and never
reparent a View. Global Zone editing has a separate Worker assignment editor;
atomic submissions use an assignment token, Worker revisions, Zone-first locking,
and existing command audit/idempotency. Both Worker and Zone pages read the same
records. No migration or new authoritative ownership field was added.

```sh
devenv shell -- scripts/e2e/phase1_postgres.sh bash -c 'cd apps/yellow_dog_management && mix compile --warnings-as-errors && mix test test/assignment_domain_test.exs test/domain_test.exs test/web_test.exs test/dns_views_test.exs test/dns_views_live_test.exs test/zones_live_test.exs'
devenv shell -- bash -c 'MIX_ENV=prod mix compile --warnings-as-errors && MIX_ENV=prod mix release yellow_dog_management --overwrite'
devenv shell -- scripts/e2e/phase1_postgres.sh python3 apps/yellow_dog_management/test/management_configuration_smoke.py _build/prod/rel/yellow_dog_management/bin/yellow_dog_management --p1-only
```

Strict compile and 78 scoped tests passed, including independent PostgreSQL
connection concurrency checks. Real Chromium phases create/verify/advance passed
after SIGKILL and a new Management process: zero-Worker Zone creation, View scope,
two assignments, fresh reads, v2 confirmation without retargeting, selective
removal, and unchanged historical Target TOML. The release was built from current
integrated source, including parallel P3 changes; P1 mode does not use the catalog.
Catalog acceptance remains separate. Both PostgreSQL and release/browser processes
were cleaned up. Evidence: `/tmp/yellow-dog-p1-final.log`,
`/tmp/yellow-dog-p1-release.log`, and
`/tmp/yellow-dog-management-configuration-j5ym1tv8`. Scoped formatting and
`git diff --check` passed.

## P2 accepted editor reliability

`ManagementUI.Submission` retains one request identity for unchanged operation
parameters; edited submissions receive new keys. Zone drafts/assignments, Views,
and Worker-page mutations use the existing Domain command boundary. Failures
retain entered fields and selected versions. Successful saves reload canonical
data, submission buttons disable while pending, and assignment/version/target
messages distinguish persistence from runtime operation. Connection failures are
reported as unconfirmed submissions, never as successful saves.

```sh
devenv shell -- scripts/e2e/phase1_postgres.sh bash -c 'cd apps/yellow_dog_management && mix compile --warnings-as-errors && mix test test/assignment_domain_test.exs test/domain_test.exs test/web_test.exs test/dns_views_test.exs test/dns_views_live_test.exs test/zones_live_test.exs test/worker_submission_live_test.exs'
devenv shell -- bash -c 'MIX_ENV=prod mix compile --warnings-as-errors && MIX_ENV=prod mix release yellow_dog_management --overwrite'
devenv shell -- scripts/e2e/phase1_postgres.sh python3 apps/yellow_dog_management/test/management_configuration_smoke.py _build/prod/rel/yellow_dog_management/bin/yellow_dog_management --p1-only
```

Strict compilation and 85 scoped tests passed. Trigger-based PostgreSQL failures
proved retained input, no partial assignments, unchanged retry receipts/audits,
new identity after edits, and successful fresh-session readback. Chromium's
`editor-failures` phase installed a real disposable-database update rejection,
checked invalid-input disabling and backend stability, and verified exact request
counts for rejected saves, retries and changed payloads. Restart and historical
export checks also passed. Evidence: `/tmp/yellow-dog-p2-final.log`,
`/tmp/yellow-dog-p2-release.log`, `/tmp/yellow-dog-p2-browser.log`, and
`/tmp/yellow-dog-management-configuration-e1y_3lhy/editor-failures.json`.

An additional, overly broad subagent command ran
`mix test test/worker_submission_live_test.exs test/ui_test.exs`: 26 tests,
1 failure at `test/ui_test.exs:187` (Events audit-detail selector expected one
`button[phx-click='show']`, found three). The five new Worker tests passed.
The broader check stopped; Events source/tests were not changed or investigated.
This unrelated-page failure is recorded, not counted as a pass or established as
pre-existing. The current repository scope explicitly excludes unrelated suite
failures as completion gates. Log: `/tmp/yellow-dog-worker-submission-green.log`.

## P3 accepted artifact catalog

Management publishes bounded, validated read-only MMDB files before committing
artifact metadata, independent Country/City selections and task receipts. No
publication activates GeoIP, and no GeoIP query process is supervised. Kind/digest
catalog lookup verifies actual durable bytes; missing/corrupt files are unavailable.
The catalog UI separates queued/job state from artifact availability, preserves
prior selections after failed sync, exposes metadata/history, and removes local
reload/unload controls. The diagnostic route explicitly reports unavailable
Worker-backed lookup. A failed queue attempt clears earlier queue feedback.

Migration: `apps/yellow_dog_management/priv/repo/migrations/20261006010000_add_geoip_artifact_catalog.exs`
adds constrained kind/format metadata and a catalog index. Historical rows are
not backfilled or modified through immutable-table trigger bypasses. No Worker,
ConfigSpec, network protocol, enrollment or delivery implementation changed.

```sh
devenv shell -- scripts/e2e/phase1_postgres.sh bash -c 'cd apps/yellow_dog_management && mix compile --warnings-as-errors && mix test test/task_artifacts_test.exs test/geo_ip_download_test.exs test/ip_database_live_test.exs test/geoip_live_test.exs'
devenv shell -- scripts/e2e/phase1_postgres.sh python3 apps/yellow_dog_management/test/management_configuration_smoke.py _build/prod/rel/yellow_dog_management/bin/yellow_dog_management
```

The focused catalog checks passed: 41 tests, 0 failures. Coverage includes real
Country/City jobs, duplicate content, old retries/receipts, wrong-kind/corrupt/large
files, filesystem failures, real database publication rollback, missing files,
and catalog UI behavior. The final integrated suite also passes 129 tests after
three test-isolation assertions were corrected to inspect new audits instead of
assuming independent-connection tests leave no immutable audit history. Audit
history remains intact; production immutability was not weakened.

The full real release/Chromium flow passed create/sync/verify/editor-failures/advance/
failed-sync. City and Country metadata and digest-addressed file bytes survived
SIGKILL and a new Management process. A later local-HTTP failure retained both
available selections. Read-only probes of the actual supervisor/application
inventory confirmed no GeoIP query process or execution Worker/legacy runtime.
The only Management listener was its ephemeral loopback HTTP port. All owned
release/browser/HTTP/PostgreSQL processes were stopped. Evidence:
`/tmp/yellow-dog-p3-final.log`, `/tmp/yellow-dog-final-tests.log`,
`/tmp/yellow-dog-final-browser.log`, and
`/tmp/yellow-dog-management-configuration-_eow0b5a` (runtime snapshots, durable
file hashes, browser failure counters and screenshots).

## P4 accepted export boundary and final verification

Supported implicit or `?scope=dns_zones` exports retain their historical TOML
bytes, digest and shared WorkerPlan round-trip. The API declares its limited scope
in response headers, and the actual Worker page explains excluded DNS View/IP
artifact serialization. Explicit `?scope=full` requests receive structured
`unsupported_export` errors; drafts remain editable. No codec/schema or competing
wire format was added. `management-artifact-integration.md` records the future
consumer-derived requirements, exact pinned artifact references, separate file
transfer, durable Worker acceptance/rollback and offline continuity contract.
It is a future requirement, not current Worker runtime acceptance.

Executed final checks:

```sh
devenv shell -- scripts/e2e/phase1_postgres.sh bash -c 'cd apps/yellow_dog_management && mix compile --warnings-as-errors && mix test test/assignment_domain_test.exs test/domain_test.exs test/web_test.exs test/dns_views_test.exs test/dns_views_live_test.exs test/zones_live_test.exs test/worker_submission_live_test.exs test/task_artifacts_test.exs test/geo_ip_download_test.exs test/ip_database_live_test.exs test/geoip_live_test.exs test/export_scope_test.exs'
devenv shell -- scripts/e2e/architecture_smoke.sh
devenv shell -- python3 scripts/e2e/check_ui_source_migration.py
devenv shell -- scripts/e2e/phase1_postgres.sh python3 apps/yellow_dog_management/test/management_configuration_smoke.py _build/prod/rel/yellow_dog_management/bin/yellow_dog_management
git diff --check
```

Results: strict compilation passed; 129 scoped tests passed; both isolated release
assemblies and the positive/four negative architecture fixtures passed; provenance
passed 203 retained files; scoped `mix format --check-formatted` passed all 141
changed Elixir/HEEx sources. Full actual browser phases and forced restart passed
on the final release source, including explicit full-export rejection and visible
limited-export disclosure. Evidence: `/tmp/yellow-dog-final-tests.log`,
`/tmp/yellow-dog-final-architecture.log`, `/tmp/yellow-dog-final-provenance.log`,
`/tmp/yellow-dog-final-browser.log`, and
`/tmp/yellow-dog-management-configuration-_eow0b5a`.

The historical Events-page test failure above remains untriaged and unchanged.
No other out-of-scope test suite or deferred Worker runtime repair was pursued.
Current acceptance is Management persistence, configuration editing and artifact
synchronization. Legacy redesign pages remain retained/unrouted; Worker delivery,
View/GeoIP serialization, GeoIP loading, diagnostics and network execution remain
deferred. No source file changed in `apps/yellow_dog_worker` or
`apps/yellow_dog_config_spec`.

### Delivery and reproduction

The checkpoints are separate Conventional Commits pushed to `origin/main`:
P0 `b6d6a015`, P1 `2b5a73af`, P2 `09dd320f`, P3 `9f93b528`, followed by the P4
export-boundary/report commit. The final response records the exact ending SHA
after that commit and push. The starting SHA is
`0301404b18b9faffa629982d5035474524f4c21e`. The supplied untracked plan is preserved
unmodified and is intentionally excluded from every commit.

To reproduce the complete demonstration, enter the repository and run the
architecture smoke command above to rebuild the releases. Then run the full
configuration smoke command above. It creates disposable PostgreSQL, an isolated
artifact directory and controlled loopback Country/City HTTP fixtures, starts
only Management, and drives fresh Chromium profiles. It creates a global Zone
with zero Workers, two disconnected logical Workers/Services, a selected-scope
View, v1 assignments and a prepared historical target. It synchronizes datasets,
SIGKILLs/restarts Management, verifies persistence, injects/clears a disposable
database failure to prove retained edits and idempotency, confirms v2 without
retargeting v1, removes one assignment, fails a subsequent sync, and checks the
previous catalog and immutable historical TOML. Temporary processes stop in
cleanup. The run prints its evidence directory for snapshots and screenshots.

### Modified files

All paths below are repository-relative. P0 additionally changes retained
`apps/yellow_dog_management/lib/yellow_dog/management_ui/redesign/` sources and
their exact `docs/phase1/ui-source-migration.json` transformation manifest; the
source checker verifies every retained adaptation. The list below names every
changed file outside that retained tree. The complete retained path inventory is
reproducible with `git show --name-only b6d6a015`.

- `AGENTS.md`
- `apps/yellow_dog_management/lib/yellow_dog/management/application.ex`
- `apps/yellow_dog_management/lib/yellow_dog/management/config_compiler.ex`
- `apps/yellow_dog_management/lib/yellow_dog/management/domain.ex`
- `apps/yellow_dog_management/lib/yellow_dog/management/export_scope.ex`
- `apps/yellow_dog_management/lib/yellow_dog/management/geo_ip_download.ex`
- `apps/yellow_dog_management/lib/yellow_dog/management/sync_geo_ip_worker.ex`
- `apps/yellow_dog_management/lib/yellow_dog/management/task_artifacts.ex`
- `apps/yellow_dog_management/lib/yellow_dog/management/task_schemas.ex`
- `apps/yellow_dog_management/lib/yellow_dog/management/web.ex`
- `apps/yellow_dog_management/lib/yellow_dog/management_ui/components/sidebar.ex`
- `apps/yellow_dog_management/lib/yellow_dog/management_ui/live/dns_views_live.ex`
- `apps/yellow_dog_management/lib/yellow_dog/management_ui/live/ip_database_live.ex`
- `apps/yellow_dog_management/lib/yellow_dog/management_ui/live/tools_live/geoip_live.ex`
- `apps/yellow_dog_management/lib/yellow_dog/management_ui/live/worker_live.ex`
- `apps/yellow_dog_management/lib/yellow_dog/management_ui/live/zones_live.ex`
- `apps/yellow_dog_management/lib/yellow_dog/management_ui/router.ex`
- `apps/yellow_dog_management/lib/yellow_dog/management_ui/submission.ex`
- `apps/yellow_dog_management/priv/repo/migrations/20261006010000_add_geoip_artifact_catalog.exs`
- `apps/yellow_dog_management/test/assignment_domain_test.exs`
- `apps/yellow_dog_management/test/dns_views_browser_smoke.mjs`
- `apps/yellow_dog_management/test/dns_views_live_test.exs`
- `apps/yellow_dog_management/test/export_scope_test.exs`
- `apps/yellow_dog_management/test/geoip_live_test.exs`
- `apps/yellow_dog_management/test/ip_database_live_test.exs`
- `apps/yellow_dog_management/test/management_configuration_browser_smoke.mjs`
- `apps/yellow_dog_management/test/management_configuration_smoke.py`
- `apps/yellow_dog_management/test/task_artifacts_test.exs`
- `apps/yellow_dog_management/test/worker_submission_live_test.exs`
- `apps/yellow_dog_management/test/zones_live_test.exs`
- `docs/phase1/management-artifact-integration.md`
- `docs/phase1/management-configuration-progress.md`
- `docs/phase1/ui-source-migration.json`
- `docs/phase1/ui-source-migration.md`
