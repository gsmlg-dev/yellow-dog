# Server Task 3A Evidence Report

## Status

Repair complete on branch `codex/service-node-remote-management`, based on Task
3A implementation commit `6afd6397e2689cd76281ae53e9e4a5b66a69217b`.

The implementation remains the DNS read/wire boundary only. DNS mutation
dispatches return typed `unsupported` without dependency calls or side effects.

## Scope

- `.superpowers/sdd/server-task-3a-report.md`
- `apps/yellow_dog/lib/yellow_dog/server/control/dns.ex`
- `apps/yellow_dog/test/support/server_dns_control_fake.ex`
- `apps/yellow_dog/test/yellow_dog/server/control/dns_test.exs`
- `apps/yellow_dog_dns/lib/yellow_dog/dns/query_logger.ex`
- `apps/yellow_dog_dns/lib/yellow_dog/dns/view.ex`
- `apps/yellow_dog_dns/lib/yellow_dog/dns/view_manager.ex`
- `apps/yellow_dog_dns/test/yellow_dog/dns/query_logger_test.exs`
- `apps/yellow_dog_dns/test/yellow_dog/dns/view_manager_test.exs`
- `apps/yellow_dog_dns/test/yellow_dog/dns/view_test.exs`

Production dependencies remain fixed modules. The adapter reads canonical view
and query-log snapshots through DNS owner APIs and does not read TOML, inspect
process state, or select caller-provided modules.

## TDD Evidence

The original Task 3A full-matrix RED was 14 tests with 14 expected
`UndefinedFunctionError` failures before the adapter existed. Its final focused
suite was 15 tests with 0 failures.

Repair RED was recorded before changing production code:

```text
cd apps/yellow_dog_dns && mix test test/yellow_dog/dns/view_test.exs test/yellow_dog/dns/query_logger_test.exs
65 tests, 5 failures
Missing View.control_snapshot/1 and QueryLogger.control_snapshot/2.

cd apps/yellow_dog && mix test test/yellow_dog/server/control/dns_test.exs
19 tests, 6 failures
View owner wiring, canonical log pagination, ACL rejection, result validation,
and RRset value ordering were RED.

cd apps/yellow_dog_dns && mix test test/yellow_dog/dns/view_manager_test.exs
29 tests, 2 failures
Missing ViewManager.list_control_views/1.
```

Repair focused GREEN:

```text
cd apps/yellow_dog_dns && mix test test/yellow_dog/dns/view_test.exs test/yellow_dog/dns/view_manager_test.exs test/yellow_dog/dns/query_logger_test.exs
94 tests, 0 failures

cd apps/yellow_dog && mix test test/yellow_dog/server/control/dns_test.exs
19 tests, 0 failures
```

Regression coverage proves production view CIDR/recursion snapshots, canonical
query-log revision before pagination, cursor reachability, bounded owner output,
lossless homogeneous ACL projection, mixed/geo ACL rejection, exact Sync result
validation for reads and current snapshots, and sorted RRset values.

## Verification

All commands ran through `devenv shell` in the shared checkout.

```text
cd apps/yellow_dog_dns && mix test
1155 tests, 0 failures, 1 skipped

cd apps/yellow_dog && mix test
274 tests, 0 failures

cd apps/yellow_dog_dns && MIX_ENV=dev mix compile --force --warnings-as-errors
exit 0

cd apps/yellow_dog_dns && MIX_ENV=test mix compile --force --warnings-as-errors
exit 0

cd apps/yellow_dog && MIX_ENV=dev mix compile --force --warnings-as-errors
exit 0

cd apps/yellow_dog && MIX_ENV=test mix compile --force --warnings-as-errors
exit 0

mix format --check-formatted <nine Task 3A Elixir files>
exit 0

cd apps/yellow_dog && mix credo --strict <three Task 3A Elixir files>
178 mods/funs, found no issues

cd apps/yellow_dog_dns && mix credo --strict <six Task 3A Elixir files>
180 mods/funs, found no issues
```

The protected console files and root `mix.exs` retained their pre-existing dirty
diffs and were not edited, formatted, staged, or reverted by Task 3A.

## Concerns

The query-log control snapshot intentionally exposes only the newest 1,000
entries. View ACLs and registry ACLs that cannot be represented without changing
semantics return typed `unsupported`; mixed-action and geographic ACLs are not
partially projected. Provider types outside the approved fixed projection remain
omitted as required by the Task 3 decisions.
