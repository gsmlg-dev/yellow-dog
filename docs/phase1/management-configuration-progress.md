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
| P1 Worker scope and Zone assignments | Pending P0 |
| P2 editor reliability and persistence | Pending P1 |
| P3 artifact catalog | Pending P0 |
| P4 export boundary and integrated acceptance | Pending functional checkpoints |

Subagent assignment and artifact findings are source investigation only. They
do not establish database, LiveView, browser, restart, or release acceptance.
