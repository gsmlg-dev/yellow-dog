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
| P3 artifact catalog | Pending P0 |
| P4 export boundary and integrated acceptance | Pending functional checkpoints |

P3 backend implementation is in progress separately; its scoped tests do not
replace pending catalog UI and full release restart acceptance.

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
