# Server Task 3A Evidence Report

## Status

Final repair complete on branch `codex/service-node-remote-management`. The
third repair wave started from
`98451f1686658d2d3f29d2ec54f8ad2eb3df3988`; earlier implementation and repair
evidence is preserved below as historical command output.

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

## Second Repair Wave

This repair wave started from
`46ff3ea245817205012e05d6a7b60544300cbcb2` on
`codex/service-node-remote-management`. It adds order-independent RRset TTL
validation, owner-defined CIDR canonicalization, and fixed control-work bounds.
The DNS read/wire boundary and mutation behavior are otherwise unchanged.

Additional owned scope:

- `apps/yellow_dog_dns/lib/yellow_dog/dns/view/acl.ex`
- `apps/yellow_dog_dns/test/yellow_dog/dns/view/acl_test.exs`

Second-wave RED was recorded before production changes:

```text
cd apps/yellow_dog_dns && mix test test/yellow_dog/dns/view/acl_test.exs test/yellow_dog/dns/view_test.exs test/yellow_dog/dns/view_manager_test.exs test/yellow_dog/dns/query_logger_test.exs
145 tests, 5 failures
Missing ACL canonicalization and the three fixed control-work bounds were RED.

cd apps/yellow_dog && mix test test/yellow_dog/server/control/dns_test.exs
23 tests, 21 failures
TTL and ACL canonicalization regressions were RED; the new fixed acl_codec test
dependency key also made the remaining adapter cases fail before production wiring.
```

Second-wave focused GREEN:

```text
cd apps/yellow_dog_dns && mix test test/yellow_dog/dns/view/acl_test.exs test/yellow_dog/dns/view_test.exs test/yellow_dog/dns/view_manager_test.exs test/yellow_dog/dns/query_logger_test.exs
145 tests, 0 failures

cd apps/yellow_dog && mix test test/yellow_dog/server/control/dns_test.exs
23 tests, 0 failures
```

Second-wave regression coverage proved entry-order independence for the selected
TTL field and a static over-limit view count. It did not cover simultaneous
top-level/nested TTL fields or a child set changing between count and fetch; the
third repair wave below records those gaps and their corrected coverage. Rule and
legacy ACL CIDRs mask IPv4 host bits and canonicalize expanded IPv6 through the
DNS ACL owner API, with stable list and `current/2` resources and revisions.
Query-log work is bounded to the newest 1,000 global entries, and ACL projection
rejects more than 100 rules without truncation.

Second-wave full verification, through `devenv shell`:

```text
cd apps/yellow_dog_dns && mix test
1160 tests, 0 failures, 1 skipped

cd apps/yellow_dog && mix test
278 tests, 0 failures

cd apps/yellow_dog_dns && MIX_ENV=dev mix compile --force --warnings-as-errors
exit 0

cd apps/yellow_dog_dns && MIX_ENV=test mix compile --force --warnings-as-errors
exit 0

cd apps/yellow_dog && MIX_ENV=dev mix compile --force --warnings-as-errors
exit 0

cd apps/yellow_dog && MIX_ENV=test mix compile --force --warnings-as-errors
exit 0

mix format --check-formatted <eleven second-wave Elixir files>
exit 0

cd apps/yellow_dog && mix credo --strict <three second-wave Elixir files>
188 mods/funs, found no issues

cd apps/yellow_dog_dns && mix credo --strict <eight second-wave Elixir files>
213 mods/funs, found no issues

git diff --check
exit 0
```

The fixed bounds are explicit wire limitations: query logs older than the newest
1,000 global entries are outside the control snapshot, ACL policies over 100
rules return typed `unsupported`, and more than 1,000 active views return typed
`unsupported` through the adapter. Canonical policy resources are never silently
truncated. The four protected console/root files retain their pre-existing dirty
diffs and remain outside Task 3A staging.

## Third Repair Wave

This final narrow repair started from
`98451f1686658d2d3f29d2ec54f8ad2eb3df3988`. Owned scope was limited to:

- `.superpowers/sdd/server-task-3a-report.md`
- `apps/yellow_dog/lib/yellow_dog/server/control/dns.ex`
- `apps/yellow_dog/test/yellow_dog/server/control/dns_test.exs`
- `apps/yellow_dog_dns/lib/yellow_dog/dns/view_manager.ex`
- `apps/yellow_dog_dns/test/yellow_dog/dns/view_manager_test.exs`

Third-wave RED, after the regression tests and before production changes:

```text
cd apps/yellow_dog && mix test test/yellow_dog/server/control/dns_test.exs
27 tests, 3 failures
Top-level TTLs masked conflicting or invalid nested TTLs, and 1,001 owner views
were silently truncated to the wire bound.

cd apps/yellow_dog_dns && mix test test/yellow_dog/dns/view_manager_test.exs
31 tests, 1 failure
A deterministic count/fetch child-set change bypassed the static count guard.
```

Third-wave focused GREEN:

```text
cd apps/yellow_dog && mix test test/yellow_dog/server/control/dns_test.exs
27 tests, 0 failures

cd apps/yellow_dog_dns && mix test test/yellow_dog/dns/view_manager_test.exs
31 tests, 0 failures
```

Every present top-level and nested `rdata` TTL is now validated independently;
duplicate locations on one entry and all entries in the RRset must agree. Tests
cover reversed top-level/nested conflicts, reversed invalid nested values, and
stable reversed resources/revisions for consistent duplicates. ViewManager calls
`DynamicSupervisor.which_children/1` once, rejects that exact snapshot over
1,000 before any View call, and traverses only the captured snapshot. The adapter
also rejects an oversized owner list with typed `unsupported` for both list and
`current/2`, before `sort_and_bound/2` can truncate canonical view resources.

Third-wave full verification, through `devenv shell`:

```text
cd apps/yellow_dog && mix test
282 tests, 0 failures

cd apps/yellow_dog_dns && mix test
1161 tests, 0 failures, 1 skipped

cd apps/yellow_dog && MIX_ENV=dev mix compile --force --warnings-as-errors
exit 0

cd apps/yellow_dog && MIX_ENV=test mix compile --force --warnings-as-errors
exit 0

cd apps/yellow_dog_dns && MIX_ENV=dev mix compile --force --warnings-as-errors
exit 0

cd apps/yellow_dog_dns && MIX_ENV=test mix compile --force --warnings-as-errors
exit 0

mix format --check-formatted <four third-wave Elixir files>
exit 0

cd apps/yellow_dog && mix credo --strict <two third-wave Elixir files>
162 mods/funs, found no issues

cd apps/yellow_dog_dns && mix credo --strict <two third-wave Elixir files>
50 mods/funs, found no issues

git diff --check
exit 0
```

The remaining explicit bounds are unchanged: query-log control reads inspect the
newest 1,000 global entries, ACL policies over 100 rules return typed
`unsupported`, and a captured snapshot over 1,000 view children or an owner list
over 1,000 views returns typed `unsupported`. No canonical view or policy list is
silently truncated. Protected console files and root `mix.exs` remain untouched
and outside staging.
