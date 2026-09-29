# Track A implementation and acceptance report

## Result and integration boundary

Implemented `apps/yellow_dog_management` as an independently runnable PostgreSQL
Management application with a browser UI and authenticated HTTP API. It does not
start or contact a Worker, service runtime, Agent, legacy Store, or integration
adapter. All created application files are new; the existing runtime implementation
and shared checkout files are unchanged.

**Shared integration remains pending.** HEAD had no C0 library. As required by the
supplied specifications, this task prepared one proposed ConfigSpec patch and a
root build patch instead of silently taking shared-file ownership. A disposable
assembly containing Management and that proposed C0 was compiled, tested, released,
and run. These results are **not a claim that the unpatched root umbrella release
or Track B interoperability has passed**.

Baseline: `61a447a3e1ae4e80da3800054807e0a0abf1b0a5`.
Initial status: only the two supplied specification files were untracked. They were
preserved. No push, PR, issue, production deployment, or real DNS change was made.

## Delivered responsibilities

- `apps/yellow_dog_management/mix.exs`, `config/`, `application.ex`, `settings.ex`,
  `release.ex`: independent application/release, explicit PostgreSQL migrations,
  loopback HTTP bootstrap and required operator authentication.
- `repo.ex`, `schemas.ex`, `domain.ex`, `priv/repo/migrations/`: PostgreSQL domain,
  revision controls, transactional audit/idempotency and immutable historical data.
- `config_compiler.ex`: selected confirmed target export with normalized TOML
  round-trip and semantic digest checks after database commit.
- `web.ex`, `priv/static/index.html`, `priv/static/management.js`: usable record
  forms, Worker and service forms, multi-Worker version assignment, unassignment,
  complete previews/diffs, confirmation, and selected-revision TOML download.
- `test/domain_test.exs`, `test/web_test.exs`, `test/support/`, `test_helper.exs`:
  real PostgreSQL integration tests and HTTP boundary tests.
- `test/release_smoke.py`: actual release process startup/restart, independent
  concurrent HTTP requests, persisted data/idempotency, exact exports, dependency
  and process-owned listener checks.
- `test/browser_smoke.mjs`: actual headless Chromium workflows through native CDP,
  including download verification and JavaScript exception collection.
- `README.md`: supported DNS surface, operator model, startup/migration commands,
  API request fields, revision/idempotency usage, deletion and Phase 2 boundaries.

## Domain and concurrency decisions

Nine relational tables store logical Workers, services, Zones, RRsets, immutable
resource versions, assignments, immutable targets, audits, and idempotency results.
Worker IDs are stable strings; no address or registration is required. Capabilities
are operator-declared. RRsets have relational Zone/name/type identity and one TTL;
validated JSONB is used for immutable content and target snapshots.

Zone draft revisions, resource versions, Worker aggregate revisions, target plan
revisions and SOA serials are distinct. Zone editing requires its expected draft
revision. Worker changes lock the Worker row and compare its aggregate revision.
Target preview locks that aggregate while reading the complete service/assignment
set. Assignment locks the selected Zone against deletion and references the explicit
immutable version. Foreign keys include the Zone/version pair, and unique indexes
protect allocation/version identities.

A successful mutation, audit and durable response commit in one transaction. A
savepoint rolls back rejected business changes, then records the failure and its
idempotency outcome in the outer transaction. Same-key/different-request retries
conflict. Both successful and failed responses are durable; there is no in-memory
idempotency cache. Concurrent requests on separate PostgreSQL connections were
exercised through the actual release API.

Deleting an assigned Zone conflicts. Explicitly unassign first; deleting its draft
then soft-deletes it and retains its immutable versions and historical targets.
Changing/unassigning one Zone preserves other assignments and stopped desired state.
Confirmed versions, targets and audits reject direct SQL mutation using triggers.

A selected confirmed target is a self-contained, immutable snapshot. Export performs
no remote call or write transaction and validates normalized equality and digests
after parsing generated TOML. Actual runtime state is always `unknown`; confirmation
is `prepared`. The UI/API makes no applied/online/verified claim.

## Commands executed and actual results

All Mix commands used the repository's pinned `devenv shell` (Elixir 1.18.5 and OTP
28 toolchain). PostgreSQL 16.13 was already available in the Nix store; no shared
`devenv.nix` change was needed for isolated checks.

Existing scoped baseline:

```sh
devenv shell -- bash -c 'cd apps/yellow_dog_management_core && mix test test/yellow_dog/management/storage/path_test.exs'
```

Result: **4 tests, 0 failures**. No pre-existing test failure was found in this scope.
The earlier `devenv shell mix cmd --app yellow_dog_management_core mix test ...`
invocation emitted deprecation warnings and did not execute tests; it is not counted
as a pass. No umbrella-wide test run was performed.

PostgreSQL setup (disposable local data only):

```sh
/nix/store/bzrk3v0ay4cs0hn656464iyzn6n334js-postgresql-16.13/bin/initdb -D /tmp/yellow-dog-track-a-pg -A trust -U postgres --no-locale
/nix/store/bzrk3v0ay4cs0hn656464iyzn6n334js-postgresql-16.13/bin/pg_ctl -D /tmp/yellow-dog-track-a-pg -l /tmp/yellow-dog-track-a-pg.log -o '-h 127.0.0.1 -p 55432 -k /tmp' start
/nix/store/bzrk3v0ay4cs0hn656464iyzn6n334js-postgresql-16.13/bin/createdb -h 127.0.0.1 -p 55432 -U postgres yellow_dog_management_final
/nix/store/bzrk3v0ay4cs0hn656464iyzn6n334js-postgresql-16.13/bin/createdb -h 127.0.0.1 -p 55432 -U postgres yellow_dog_management_browser
```

All exited 0. Separate `yellow_dog_management_test`, `yellow_dog_management_smoke`
and `yellow_dog_management_domain_test` databases were used during development.
The final database was initialized from the final migration; edited migration files
were never assumed to rerun against an already migrated schema.

Assembly and dependency resolution:

```sh
docs/phase1/prepare-validation.sh /tmp/yellow-dog-track-a-validation
devenv shell -- bash -c 'cd /tmp/yellow-dog-track-a-validation/apps/yellow_dog_management && mix deps.get'
```

Result: resolved Ecto SQL 3.14.0 and Postgrex 0.22.4; retained existing pinned
Ecto 3.14.2, Bandit 1.12.5, TOML 0.7.0 and other existing dependency versions.
Only the assembly lockfile changed; its two additions are in the build handoff.

Final Management checks:

```sh
YELLOW_DOG_MANAGEMENT_DATABASE_URL=postgres://postgres@127.0.0.1:55432/yellow_dog_management_final devenv shell -- bash -c 'cd /tmp/yellow-dog-track-a-validation/apps/yellow_dog_management && mix test && MIX_ENV=test mix compile --warnings-as-errors'
YELLOW_DOG_MANAGEMENT_DATABASE_URL=postgres://postgres@127.0.0.1:55432/yellow_dog_management_domain_test devenv shell -- bash -c 'cd /tmp/yellow-dog-track-a-validation/apps/yellow_dog_management && mix test && MIX_ENV=test mix compile --warnings-as-errors && mix format --check-formatted'
```

Result: **11 tests, 0 failures** on both databases; final compile and formatting
checks exited 0. Tests cover zero-Worker editing, four targets sharing one version,
exact selected resources, stopped-state preservation, stale revisions, same-key
conflicts/retries, concurrent assignments, deletion/historical export retention,
invalid-aggregate rollback, authentication and malformed/oversized request errors.

Shared contract checks, after the final source refresh:

```sh
devenv shell -- bash -c 'cd /tmp/yellow-dog-track-a-validation/apps/yellow_dog_config_spec && mix test && mix format --check-formatted && mix compile --warnings-as-errors'
```

Result: **15 tests, 0 failures**, format and warnings-as-errors compilation exited 0.
Fixed fixtures and tests cover complete SOA/NS/A, multiple zones, running/stopped,
explicit empty sets, missing/duplicate references, unknown data, malformed TOML,
wrong digests, formatting equivalence, input limits, RRset TTL conflicts, mailbox
case preservation, duplicate zone names, listener conflicts and oversized exports.

Production build:

```sh
devenv shell -- bash -c 'cd /tmp/yellow-dog-track-a-validation/apps/yellow_dog_management && MIX_ENV=prod mix deps.get && MIX_ENV=prod mix compile --warnings-as-errors && MIX_ENV=prod mix release yellow_dog_management --overwrite'
```

Result: built `/tmp/yellow-dog-track-a-validation/_build/prod/rel/yellow_dog_management`.
Final rebuild after changes also exited 0. TOML 0.7.0 emits existing dependency
charlist deprecation warnings on its first compilation; the new application and
ConfigSpec compile checks passed. No dependency source was patched.

Actual release migration and process restart smoke:

```sh
YELLOW_DOG_MANAGEMENT_DATABASE_URL=postgres://postgres@127.0.0.1:55432/yellow_dog_management_final /tmp/yellow-dog-track-a-validation/_build/prod/rel/yellow_dog_management/bin/yellow_dog_management eval 'YellowDog.Management.Release.migrate()'
YELLOW_DOG_MANAGEMENT_DATABASE_URL=postgres://postgres@127.0.0.1:55432/yellow_dog_management_final python3 apps/yellow_dog_management/test/release_smoke.py /tmp/yellow-dog-track-a-validation/_build/prod/rel/yellow_dog_management/bin/yellow_dog_management
```

Result: **RELEASE SMOKE PASSED**. Fresh UI/API startup; zero-Worker DNS create/edit;
four logical Workers; one shared immutable version; exact target contents;
stopped-state unassignment; two concurrent HTTP assignments producing one explicit
conflict, then a successful retry retaining all three zones; actual OS process
restart preserving drafts, services, assignments, versions, confirmed targets and
idempotency results; historical exports byte-identical after restart.

The script enumerated the assembled release's transitive app directory and rejected
Worker, DNS/DHCP, Agent, legacy console/core, Abyss, ex_dns and Concord dependencies.
`ss -lntup` filtered by each actual release PID found exactly one listener:
`127.0.0.1:14280/tcp`, no UDP. Browser release PID similarly owned only
`127.0.0.1:14281/tcp`. Other legacy service processes already on this host were
neither started nor stopped by this task.

Browser checks:

```sh
YELLOW_DOG_MANAGEMENT_DATABASE_URL=postgres://postgres@127.0.0.1:55432/yellow_dog_management_browser /tmp/yellow-dog-track-a-validation/_build/prod/rel/yellow_dog_management/bin/yellow_dog_management eval 'YellowDog.Management.Release.migrate()'
YELLOW_DOG_MANAGEMENT_DATABASE_URL=postgres://postgres@127.0.0.1:55432/yellow_dog_management_browser YELLOW_DOG_MANAGEMENT_OPERATOR_TOKEN=disposable-phase-one-browser-token-0001 YELLOW_DOG_MANAGEMENT_PORT=14281 RELEASE_DISTRIBUTION=none /tmp/yellow-dog-track-a-validation/_build/prod/rel/yellow_dog_management/bin/yellow_dog_management start
YELLOW_DOG_MANAGEMENT_OPERATOR_TOKEN=disposable-phase-one-browser-token-0001 node apps/yellow_dog_management/test/browser_smoke.mjs
node --check apps/yellow_dog_management/priv/static/management.js
node --check apps/yellow_dog_management/test/browser_smoke.mjs
```

Result: **BROWSER SMOKE PASSED**; all syntax checks exited 0. Exercised sign-in,
zero-Worker DNS create/edit/confirm, Worker create/edit, stopped service configuration,
assignment, preview, confirmation, downloaded TOML containing the edited A record,
and unassignment with empty next resource set and stopped state intact. No JS
exceptions. Screenshot: `/tmp/yellow-dog-management-ui.png`.

Direct immutable-record checks used `psql -v ON_ERROR_STOP=1 -c 'BEGIN; UPDATE <table>
SET id=id; ROLLBACK;'` against the disposable final DB for each of
`management_resource_versions`, `management_targets`, and `management_audits`.
All three correctly failed with the immutable-record trigger error; the transaction
was rolled back on connection close.

Handoff and scope checks:

```sh
git apply --check docs/phase1/config-spec.patch
git apply --check docs/phase1/management-build.patch
git diff --check
git diff --exit-code -- mix.exs mix.lock AGENTS.md config devenv.nix apps/yellow_dog_dns apps/yellow_dog_management_core
```

All exited 0. No actual shared/runtime files were modified.

During implementation, the first API suite exposed a malformed-UUID exception;
it was repaired and the suite rerun successfully. The broad formatter invocation
exposed an invalid glob, then remaining unformatted web code; both were repaired
and the final format check passed. A stale validation copy briefly failed ConfigSpec
formatting; refreshing from the frozen handoff fixed that check. An initial smoke
invocation omitted the required database URL and failed startup as expected; the
recorded successful smoke commands above supplied it. None of these earlier failures
are reported as passes.

## Remaining integration and deliberately unexecuted checks

1. The shared-file owner must review/adopt `docs/phase1/config-spec.patch` with
   Track B. It adds the single pure library and fixed fixtures, not a second runtime
   configuration format. Track B's contract compatibility has not been asserted.
2. Integrate `docs/phase1/management-build.patch`: add the root Management release,
   its isolated runtime config path, the two locked database dependencies, and the
   AGENTS application table entries. Both handoffs pass `git apply --check` at the
   inspected baseline. Root shared configuration/CI/devenv remain owner-controlled.
3. The actual full-root release build, coordinated removal of legacy/mixed runtime
   entries, and the final exactly-two-business-release layout remain untested and
   pending shared-owner integration. The tested standalone Management release does
   not require those legacy apps.
4. File-only export-to-Worker startup with Management/PostgreSQL stopped, UDP/TCP DNS
   queries and Worker restart are later cross-track integration checks. They were
   not run; this task did not modify or impersonate Worker execution.
5. No umbrella-wide tests, unrelated protocol E2E suites, global Credo/Dialyzer run,
   production deployment, DNS delegation changes, or Phase 2 network integration
   were performed.

Phase 2 attachment points are the logical Worker identity, immutable confirmed
WorkerPlan/revision and pure ConfigSpec normalization/diff. Authenticated binding,
remote delivery, observations and reconciliation must be added there later; they
must not reinterpret `prepared` as observed `applied` or write runtime observations
back as editable DNS business data.

The disposable Management release processes and PostgreSQL test instance were
stopped after verification. Their temporary assembly, database files and logs remain
under `/tmp` for inspection; existing host services were preserved. These results
describe the implementation before shared-file integration.
