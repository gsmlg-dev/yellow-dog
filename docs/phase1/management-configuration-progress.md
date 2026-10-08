# Management configuration and IP artifact increment

## 2026-10-08 upstream MAC fix integration

The operator reported the upstream fix and resumed CI repair. Upstream
[gsmlg_umbrella#8](https://github.com/gsmlg-dev/gsmlg_umbrella/issues/8) is now
closed, and Hex publishes `gsmlg_mac` 0.1.2. Management requires `~> 0.1.2` and
the lockfile updates only this package; its telemetry dependency uses the existing
locked telemetry. The historical dependency blocker below applies to 0.1.1.

Management delegates lookup to the new upstream `Vendor.lookup/2` API and accepts
overlapping /24, /28 and /36 prefixes. Strict input/file parsing, 64 MiB and
loader resource limits, unique parsed-versus-compiled prefix count equality, and
failure retention of the previous valid snapshot remain enforced. No local
replacement compiler is introduced. Regression fixtures verify longest-prefix
lookup and broader-prefix fallback in both source orders. Packaged-source checks
assert all **48,087 unique prefixes** survive compilation/loading and compare a
query for every source prefix against the upstream lookup result.

Verification commands run inside
`devenv shell -- bash -c 'cd .trees/fix-ci-management && ...'`:

| Command | Actual result |
| --- | --- |
| `mix deps.update gsmlg_mac` | Published 0.1.2 installed; only its lock entry changes. |
| `MIX_ENV=test mix compile --warnings-as-errors` | Exit 0. |
| `scripts/e2e/phase1_postgres.sh mix do --app yellow_dog_management test test/mac_database_test.exs test/mac_database_live_test.exs --seed 0` | 19 tests, 0 failures, exit 0. |
| `scripts/e2e/phase1_postgres.sh mix do --app yellow_dog_management test --warnings-as-errors --seed 0` | 474 tests, 0 failures, exit 0. |
| Same full Management command with `--seed 635407` | 474 tests, 0 failures, exit 0. |
| `mix format --check-formatted && mix compile --warnings-as-errors && mix credo --strict` | All supported formatter/compile/Credo checks pass, exit 0. |
| `python3 scripts/e2e/check_ui_source_migration.py` | 203 retained files pass, exit 0. |
| `node --test apps/yellow_dog_management/test/management_ui_test.mjs` | 10 tests, 0 failures, exit 0. |
| `nix build .#docker-management .#docker-worker .#yellow_dog_management .#yellow_dog_worker --no-link --print-out-paths --print-build-logs` | Both x86_64 images and releases build, exit 0. |
| Actual Nix Management release: `migrate`, MDEx HTML evaluation, packaged MAC load/reload/count/query, `python3 apps/yellow_dog_management/test/release_smoke.py <nix-release-binary>` | Native HTML renders; MAC retains 48,087 entries; PostgreSQL/HTTP/concurrency/restart pass, exit 0. |
| `python3 apps/yellow_dog_worker/test/release_smoke.py <nix-release-binary>` | UDP/TCP, reload, SIGKILL recovery and stopped-state persistence pass, exit 0. |
| `scripts/e2e/phase1_postgres.sh python3 apps/yellow_dog_management/test/management_configuration_smoke.py <nix-release-binary>` | All six Chromium phases and forced-restart/configuration/artifact persistence gates pass, exit 0. |

Updating the dependency before adapting Management reproduced three failing MAC
regressions (12 tests): obsolete lookup-table representation, packaged load, and
mixed-width load. The new implementation resolves them. Only the complete
packaged-file test observation window follows the unchanged production 30-second
load budget; small synthetic fixture waits and all integrity assertions remain.
An existing test-only Abyss compile-environment cache mismatch required rebuilding
that dependency in `MIX_ENV=test`; no source/configuration checks were disabled.

Nix's production Mix dependency hash was recomputed by an actual fixed-output
build with an intentionally invalid discovery hash. Its reported content hash is
`sha256-LEFPmWZw7Cu/GH28kJOyPY3xMYAeL4J55o5LJeBqwoo=`; the final source contains
this real hash. Logs: `/tmp/yellow-dog-ci-mac-deps-update.log`,
`/tmp/yellow-dog-mac-upstream-{before,after}.log`,
`/tmp/yellow-dog-mac-full-seed{0,635407}.log`,
`/tmp/yellow-dog-ci-mac-checks.log`, and
`/tmp/yellow-dog-ci-mac-nix-new-hash.log`.

Runtime commands use the disposable release-cookie/distribution settings
documented below and fresh isolated PostgreSQL. The rebuilt release outputs are
`/nix/store/y74a8xgda8g5xn5h4mkr373056vdnqbm-yellow_dog_management-1.2.1` and
`/nix/store/i349znw72fqgxyjq22nqfkj8a6716qvf-yellow_dog_worker-1.2.1`. Logs:
`/tmp/yellow-dog-ci-mac-nix-images.log`,
`/tmp/yellow-dog-ci-mac-nix-runtime.log`,
`/tmp/yellow-dog-ci-mac-worker-runtime.log`, and
`/tmp/yellow-dog-ci-mac-configuration-browser.log`.

The optional older `scripts/e2e/management_browser.sh` harness was also run
against this Nix release. Its MAC lookup/reload/failure-retention/recovery
assertions completed, but the harness then failed at `live_browser_smoke.mjs:346`
trying to submit the absent `#geoip-lookup-form`. The routed GeoIP page explicitly
declares Worker-backed lookup unavailable; this script and page are unchanged
from the starting revision. This is not a passing full legacy browser run or
permission to reconnect a Management query runtime. Its broader failure remains
outside this CI repair; the current configuration acceptance command above
passed in full. Evidence: `/tmp/yellow-dog-ci-mac-browser.log`.

Code integration is commit `cf0cf7432dcf3e195c9fed258617693f053e4ec1` on
`codex/fix-ci-management`; remote CI for the new revision remains pending at this
checkpoint. FlakeHub organization authorization is a separate external gate;
the upstream MAC release does not establish that it has been resolved. No
workflow YAML, published prerelease tag or existing image digest is changed.

## 2026-10-08 CI repair after release 1.2.1

The operator expanded the work to all current CI failures after the `v1.2.1`
release build succeeded. Repairs are isolated in `.trees/fix-ci-management`,
branch `codex/fix-ci-management`, starting from
`a7a60dfa6226f159702d28fc69a9a2023c4875af`. The release remains a prerelease;
its existing tag and published artifacts are not rewritten.

Two independent-connection assignment tests committed fixtures outside the SQL
sandbox, then left 21 audit/idempotency records behind. This polluted later
Events, Tasks, Backups, Zone import and other test expectations depending on
execution order. Regression assertions reproduced both leaks (9 tests, 2
failures). Each test now uses a unique actor/request-key namespace and removes
only its committed fixture records. Audit cleanup disables its immutable trigger
inside one teardown transaction and reenables it before commit; the trigger is
asserted enabled and the exact prior receipt state is asserted restored before
and after each test. Production migrations and command invariants are unchanged.
The same assignment regressions now pass (9 tests, 0 failures).

Five synthetic Zone/Worker submissions now carry the actual rendered hidden
`_submission` value, preserving forged-field, validation and CAS assertions.
The Events UI test selects its actual audit record in the audit group, where the
page also renders separate receipt/job detail buttons. The missing Node CI
entrypoint is supplied by 10 behavioral tests of the current LiveView hooks;
these execute the current entrypoint with package/browser boundaries stubbed,
without restoring the obsolete native UI. These are Node checks, not Chromium
acceptance.

Supported child applications now declare their own development/test Credo
dependency so the root per-app alias can run. The two resulting Credo warnings
are repaired with a SQL sigil and a credential-free reraised ArgumentError.
Two retained presentations receive formatting-only adjustments recorded as exact
manifest transformations; all 203 source-retention files still pass provenance.
Nix packaging updates the production Mix dependency hash to the value reproduced
by both CI architectures and the local fixed-output build. MDEx's checksum-pinned
native artifact is declared as a Nix input and placed in Rustler's cache before
dependency compilation, instead of attempting a download inside the sandbox.

Full Management testing with disposable PostgreSQL and both seed 0 and the
original Phase 1 seed 635407 reports **474 tests, 1 failure**: packaged MAC source parity. Upstream
[gsmlg_umbrella#8](https://github.com/gsmlg-dev/gsmlg_umbrella/issues/8) is still
open, and Hex still publishes only `gsmlg_mac` 0.1.1/0.1.0. The lossless import
check remains enabled and the task stays blocked by this dependency; no local
replacement compiler or lossy acceptance is introduced. The FlakeHub rolling
workflow separately returns **401 Unauthorized**, explicitly requiring the
`gsmlg-dev` organization to register/authorize in FlakeHub. These external
blockers prevent a claim that all CI is green.

Evidence: `/tmp/yellow-dog-release-1.2.1/assignment-isolation-{before,after}.log`,
`management-full-seed0.log`, `/tmp/yellow-dog-ci-node-parent.log`,
`/tmp/yellow-dog-ci-nix-deps.log` and `/tmp/yellow-dog-flakehub.log`.
Completed local verification (commands run from the worktree inside the root
`devenv shell -- bash -c 'cd .trees/fix-ci-management; ...'` context):

| Command | Actual result |
| --- | --- |
| `mix format --check-formatted` | Exit 0, full supported formatter scope. |
| `mix compile --warnings-as-errors` and `MIX_ENV=test mix compile --warnings-as-errors` | Both exit 0. |
| `mix credo --strict` | All five supported child applications pass, exit 0. |
| `mix cmd --app yellow_dog_config_spec --app yellow_dog_worker mix test` | ConfigSpec 15/0; Worker 95/0 with its existing 1 skipped test, exit 0. |
| `scripts/e2e/phase1_postgres.sh mix cmd --app yellow_dog_management mix test --warnings-as-errors test/assignment_domain_test.exs test/ui_test.exs test/worker_profiles_live_test.exs test/zone_validation_live_test.exs test/backups_test.exs test/postgres_tools_test.exs` | 58/0, exit 0. |
| `scripts/e2e/phase1_postgres.sh mix cmd --app yellow_dog_management mix test --seed 0` and the same command with `--seed 635407` | Each 474/1, exit 1 from the command wrapper; only the MAC upstream blocker. No filters/skips applied. |
| `node --test apps/yellow_dog_management/test/management_ui_test.mjs` | 10/0, exit 0. |
| `python3 scripts/e2e/check_ui_source_migration.py` | 203 files, exit 0. |
| `scripts/e2e/architecture_smoke.sh` | Positive architecture and four negative fixtures pass, exit 0. |
| `nix build .#yellow_dog_management.mixFodDeps --no-link --print-build-logs` | Corrected fixed-output hash passes, exit 0. |
| `nix build .#docker-management .#docker-worker --no-link --print-build-logs` | Both x86_64 product images build, exit 0. |
| Actual Nix Management release: `migrate`, MDEx HTML evaluation, `python3 apps/yellow_dog_management/test/release_smoke.py <nix-release-binary>` | Native artifact loads and renders HTML; PostgreSQL/HTTP/concurrency/restart gates pass, exit 0. |
| `python3 apps/yellow_dog_worker/test/release_smoke.py <nix-release-binary>` | Real UDP/TCP, atomic reload, SIGKILL and stopped-state persistence pass, exit 0. |
| `git diff --check` and supplied-plan SHA-256 | Exit 0; original plan hash unchanged. |

Nix runtime smoke uses `RELEASE_DISTRIBUTION=none`, a disposable
`RELEASE_COOKIE=yellow_dog_ci_smoke`, and `ERL_FLAGS='+S 2:2 +A 2'`. nixpkgs
removes the generated release cookie from the immutable store by default;
operators must supply `RELEASE_COOKIE`, including for nondistributed startup.
Management was migrated through the disposable PostgreSQL wrapper. Neither
smoke deployed to NixOS/Podman nor exercised ARM runtime behavior.

Additional logs: `/tmp/yellow-dog-ci-parent-checks.log`,
`/tmp/yellow-dog-ci-architecture.log`,
`/tmp/yellow-dog-ci-nix-images-verified.log`,
`/tmp/yellow-dog-ci-nix-runtime-verified.log` and
`/tmp/yellow-dog-release-1.2.1/management-full-seed635407.log`.
Initial repair revision `0927d502` has inspected remote results:

- [Nix Product Images 37734994510](https://github.com/gsmlg-dev/yellow-dog/actions/runs/37734994510): all four Management/Worker amd64/arm64 builds and image uploads pass. Optional publication was not requested.
- [Phase 1 37734982212](https://github.com/gsmlg-dev/yellow-dog/actions/runs/37734982212): seven jobs pass, including both releases, architecture, Node and offline export; Management reports 474/1, only MAC parity.
- [E2E 37734982155](https://github.com/gsmlg-dev/yellow-dog/actions/runs/37734982155): both product release jobs pass.
- [Test 37734982150](https://github.com/gsmlg-dev/yellow-dog/actions/runs/37734982150): Management 474/1, only MAC parity.
- [CI 37734982176](https://github.com/gsmlg-dev/yellow-dog/actions/runs/37734982176): compile/format/Credo/Rust pass; Management reports 474/2, adding an intermittent BackupsLive timeout at seed 699.

That last failure was a `render_async` wait using ExUnit's incidental 100 ms
default while real native `pg_restore --list` was still running after integrity
hashing. The three successful native verification waits now have a bounded
5-second allowance. Missing/corrupt-package and cancellation waits, integrity
assertions and production timeouts are unchanged. Scoped fresh PostgreSQL
verification with the failing remote seed 699 passes **14 tests, 0 failures**,
exit 0 (`/tmp/yellow-dog-backups-native-wait.log`). Parent reran full formatting,
strict Credo and full Management with seed 699: formatting/Credo pass and
Management returns 474/1, only MAC parity
(`/tmp/yellow-dog-ci-native-wait-full.log`). The next CI iteration checks
this patch; [draft PR #30](https://github.com/gsmlg-dev/yellow-dog/pull/30) tracks
the current revision and remaining external blockers. ARM build success does
not establish ARM runtime acceptance.


## 2026-10-08 release 1.2.1 preparation

The operator authorized committing the local fixes, fresh verification and a new
release/build. The root release version is now `1.2.1`; application versions and
Worker implementation remain unchanged. The supplied untracked Management plan
is preserved locally with its original SHA-256.

Pre-commit review found one additional submission regression: after a rejected
request, changing fields and reverting them allowed a delayed original token to
create a second receipt/audit. The new database-backed regression failed before
the repair (26 tests, 1 failure, 25 excluded). The bounded previous intent now
retains its original canonical request/key, and all callers pass the submitted
token explicitly to `Submission.prepare/4`. A matching retired request replays
its original key without installing that key into the current intent. An
intentional submission with the current token still obtains a new key. No Domain
transaction, schema, protocol or generic submission framework was changed.

Fresh final-source commands on 2026-10-08:

```sh
devenv shell -- scripts/e2e/phase1_postgres.sh bash -c 'cd apps/yellow_dog_management && mix compile --warnings-as-errors && mix test --warnings-as-errors test/assignment_domain_test.exs test/domain_test.exs test/web_test.exs test/dns_views_test.exs test/dns_views_web_test.exs test/dns_views_live_test.exs test/zones_live_test.exs test/worker_submission_live_test.exs test/task_artifacts_test.exs test/geo_ip_download_test.exs test/ip_database_live_test.exs test/geoip_live_test.exs test/export_scope_test.exs'
devenv shell -- scripts/e2e/architecture_smoke.sh
devenv shell -- scripts/e2e/phase1_postgres.sh python3 apps/yellow_dog_management/test/management_configuration_smoke.py _build/prod/rel/yellow_dog_management/bin/yellow_dog_management
devenv shell -- scripts/e2e/phase1_postgres.sh env BUILD_RELEASE=0 scripts/e2e/release_smoke.sh yellow_dog_management
devenv shell -- python3 scripts/e2e/check_ui_source_migration.py
git diff --check
sha256sum -c /tmp/yellow-dog-release-1.2.1/local-plan.sha256
```

All commands passed. Strict compilation and **151 scoped tests** passed; the
intentional refused-loopback connection regression remains expected evidence.
Changed Elixir sources plus root `mix.exs` passed `mix format --check-formatted`;
the browser script passed `node --check`, and the Python harness passed AST
parsing. Source retention passed **203 files**. Production architecture rebuilt
both release assemblies and passed the positive/four negative fixtures. The
Management release's `start_erl.data` identifies version `1.2.1`.

The six real Chromium phases and SIGKILL recovery passed again, including
same-session View recreation, immediate change/submit, durable artifact bytes,
immutable exports and failed-sync preservation. The separate release smoke
passed real HTTP/database behavior and process restart. These do not establish
target NixOS/Podman deployment, HTTPS proxy readiness, full-suite CI success, or
Worker connectivity/delivery/runtime acceptance.

Evidence: `/tmp/yellow-dog-release-1.2.1/{final-scoped-tests,architecture,
format-syntax,browser-restart,release-smoke,provenance}.log`; the new red/green
logs are `submission-edit-revert-{red,green}.log` there. Browser evidence is
`/tmp/yellow-dog-management-configuration-a2xiq3a4/`. Disposable PostgreSQL
wrappers finished and stopped their owned clusters. Commit/tag and published
artifacts are recorded in the ensuing GitHub release, after publication rather
than inferred from these local checks. Earlier sections remain historical
evidence, including the starting-commit CI failures and uncommitted snapshot.

## 2026-10-07 correctness/performance follow-up

This follow-up addresses logical editor submission identity and catalog refresh
cost. Starting HEAD is `8725b765653fd9300523e62888caaf9ed3bedb16` on the current
checkout. The only starting worktree change is the untracked supplied
`docs/yellow-dog-codex-management-plan.md`; its SHA-256 is
`07fab5d348a6085de7870f95d528e0977d80f4f0ef67c8e05c6995c4834a2069`.
It remains preserved and unmodified. No Worker execution, delivery, GeoIP runtime,
shared ConfigSpec change or retained-page redevelopment is authorized here.

### Starting baseline and inspected CI

```sh
devenv shell -- scripts/e2e/phase1_postgres.sh bash -c 'cd apps/yellow_dog_management && mix compile --warnings-as-errors && mix test test/assignment_domain_test.exs test/domain_test.exs test/web_test.exs test/dns_views_test.exs test/dns_views_live_test.exs test/zones_live_test.exs test/worker_submission_live_test.exs test/task_artifacts_test.exs test/geo_ip_download_test.exs test/ip_database_live_test.exs test/geoip_live_test.exs test/export_scope_test.exs'
devenv shell -- node --test apps/yellow_dog_management/test/management_ui_test.mjs
gh run view 37413145962 --json jobs
gh run view 37413145962 --log-failed
```

Starting strict compilation and all 129 scoped tests pass. The Node command
fails because the workflow names a nonexistent `management_ui_test.mjs`.
The actual starting-commit [Phase 1 CI run](https://github.com/gsmlg-dev/yellow-dog/actions/runs/37413145962)
was inspected directly: Management reports 454 tests with 21 failures; Node
reports the same missing file. The two release jobs, architecture job, ConfigSpec,
Worker and offline export jobs passed in that run. These are CI results for the
starting commit, not acceptance of the follow-up worktree.

The 21 baseline CI failures occur in MAC database (1), Events UI (1), Overview
(4), Backups (2), Tasks (3), Worker profiles (1), and Zone import (9) tests.
They remain outside this follow-up's editor/catalog scope and are not repaired
or counted as passes. Their attribution as starting-baseline failures rests on
the inspected commit-specific logs, rather than the earlier progress report.
Full-suite green CI is not claimed.

Baseline evidence: `/tmp/yellow-dog-management-review-fixes/baseline-scoped.log`,
`baseline-node.log`, `baseline-ci-jobs.json`, and `baseline-ci-failed.log` in the
same directory. Disposable PostgreSQL evidence:
`/tmp/yellow-dog-phase1-pg.Iia8zR`.

### Reproductions before production edits

```sh
devenv shell -- scripts/e2e/phase1_postgres.sh bash -c 'cd apps/yellow_dog_management && mix test test/dns_views_live_test.exs:32'
devenv shell -- scripts/e2e/phase1_postgres.sh bash -c 'cd apps/yellow_dog_management && mix test test/task_artifacts_test.exs:26'
```

The first regression fails at the canonical lookup of `office` following
create/delete/recreate with identical parameters in one mounted session
(19 tests, 1 failure, 18 excluded). The existing helper's parameter-based key
survives editor reset; Domain correctly replays the original successful result
instead of inserting a new View. The second regression fails because a
deterministic call trace captures `GeoIPDownload.check_artifact/1` on historical
artifact `missing-history-25` during ordinary `catalog/0` construction
(12 tests, 1 failure, 11 excluded). The catalog query also has no SQL limit.
These results establish both findings on the starting checkout, independent
of flashes and wall-clock timing. Logs: `submission-red.log` and `catalog-red.log`
under `/tmp/yellow-dog-management-review-fixes`.

An additional real-browser regression dispatches a changed Zone form and its
submit in the same JavaScript turn, before the change response can patch a new
intent marker. The initial token implementation incorrectly ignored that submit:
receipt/audit counts stayed `[14, 1]` instead of `[15, 2]`. This failure was
introduced by this work, not present in the parameter-only starting helper.
It is recorded in `browser-pipelined-red.log`. The final rebuilt release passes
this case for both Zone edits and View updates whose immutable name is omitted
by the real browser form. Rejected retries retain their original receipts;
changed input creates exactly one additional receipt and audit.

### Implemented lifecycle and verification behavior

Editor intent markers and Domain request keys have separate lifetimes. View,
Zone and Worker forms carry the current intent marker. An unresolved request
keeps its operation/parameters/key; retries replay the existing Domain result.
Confirmed success, explicit reopening/reset, and scope changes retire the old
intent and keys. Missing or stale submit markers are ignored before retaining
fields or invoking Domain, preventing delayed duplicates from becoming new
writes or overwriting newly entered input. Canonical command parameters retain
Worker, Service, Zone and revision/assignment scope.

Input edits retire the relevant pending key. One bounded previous intent marker
permits a submit already queued behind `phx-change`, only for its edited operation
and current authoritative editable fields/record rows. Readonly View fields
omitted by browsers are excluded from this comparison. Removed records cannot
be restored by stale payloads, and explicit Service reopening/assignment reset
clears this alias. Database connection failures remain unconfirmed, preserve
input and retain the same request key for retry. No Domain, schema, constraint,
immutable-table or command transaction semantics changed.

Catalog reads are metadata-only. Each kind queries deterministic descending
`inserted_at`/`digest` order with SQL `LIMIT 21` and `OFFSET`, displaying 20 rows
and using the extra row to detect another page. The current selected artifact
is independently fetched if outside the page. Metadata starts unverified.

The IP Database page uses existing LiveView `start_async` checks for selected
files only. Each mounted page retains at most one checker/result per kind (two
total). Repeated refreshes/task updates deduplicate pending work. Replacing a
selection cancels its checker and waits for its completion/exit callback before
starting the latest selection; token and selection identity guards reject stale
results. The UI distinguishes Unverified, Checking, Available and Unavailable,
shows the last check time, and keeps job state separate. Explicit Refresh always
revalidates unless that check is already pending. Other metadata refreshes reuse
only the current selection's result for up to 60 seconds, revalidating on the
next refresh after expiry. Idle pages show the check time; no periodic timer
claims ongoing verification. Cache storage disappears on unmount.

Historical rows are not hashed. `TaskArtifacts.get/2` still validates actual file
bytes on every access; cached UI availability never authorizes a consumer.
Publication retains full size/digest/MMDB/kind verification and all existing
downloader limits. Failed synchronization preserves prior selections. Neither
the downloader nor any Worker, ConfigSpec, application supervision, router,
dependency, global configuration or migration source changed.

### Changed files and regression coverage

All application paths below are under `apps/yellow_dog_management/`:

| Files | Change and evidence |
| --- | --- |
| `lib/yellow_dog/management_ui/submission.ex`; `lib/yellow_dog/management_ui/live/dns_views_live.ex`, `zones_live.ex`, `worker_live.ex` | Submission lifecycle, form/button intent markers, consistent reset/edit handling and delayed-event guards. |
| `test/dns_views_live_test.exs`, `zones_live_test.exs`, `worker_submission_live_test.exs` | Same-session recreation with new IDs and fresh reads; retry receipts/audits; duplicate/delayed writes; edited input and scope isolation; actual unavailable PostgreSQL connection and confirmed retry; immediate change/submit; readonly View fields; explicit Service reopening; removed Zone records and malformed events. |
| `lib/yellow_dog/management/task_artifacts.ex`; `lib/yellow_dog/management_ui/live/ip_database_live.ex` | SQL pagination, metadata-only catalog, selected-only asynchronous checks and bounded page-local state. |
| `test/task_artifacts_test.exs`, `ip_database_live_test.exs` | Actual SQL row/limit telemetry, deterministic no-hashing call trace, outside-page selection, pending-event responsiveness, deduplication, dual-kind concurrency, cancellation, stale results, 60-second expiry, missing/corrupt bytes and consumer validation despite a positive UI cache. Existing publication/rollback/receipt/prior-selection cases remain passing. |
| `test/management_configuration_browser_smoke.mjs`, `management_configuration_smoke.py` | Real Chromium same-mounted-session recreation, distinct object IDs, canonical API reads, exact receipt/audit counts, immediate Zone/View change-submit and independent durable file-byte/digest checks. Disposable View rejection trigger added beside the existing Zone trigger. |
| `docs/phase1/management-configuration-progress.md`, `management-artifact-integration.md` | Actual evidence, availability timing/revalidation and preserved integration limits. |

### Final verification and completion audit

Executed on the final source, through Nix/devenv and disposable PostgreSQL:

```sh
devenv shell -- scripts/e2e/phase1_postgres.sh bash -c 'cd apps/yellow_dog_management && mix compile --warnings-as-errors && mix test --warnings-as-errors test/assignment_domain_test.exs test/domain_test.exs test/web_test.exs test/dns_views_test.exs test/dns_views_web_test.exs test/dns_views_live_test.exs test/zones_live_test.exs test/worker_submission_live_test.exs test/task_artifacts_test.exs test/geo_ip_download_test.exs test/ip_database_live_test.exs test/geoip_live_test.exs test/export_scope_test.exs'
devenv shell -- scripts/e2e/architecture_smoke.sh
devenv shell -- scripts/e2e/phase1_postgres.sh python3 apps/yellow_dog_management/test/management_configuration_smoke.py _build/prod/rel/yellow_dog_management/bin/yellow_dog_management
devenv shell -- python3 scripts/e2e/check_ui_source_migration.py
devenv shell -- bash -c 'cd apps/yellow_dog_management && mix format --check-formatted lib/yellow_dog/management/task_artifacts.ex lib/yellow_dog/management_ui/live/dns_views_live.ex lib/yellow_dog/management_ui/live/ip_database_live.ex lib/yellow_dog/management_ui/live/worker_live.ex lib/yellow_dog/management_ui/live/zones_live.ex lib/yellow_dog/management_ui/submission.ex test/dns_views_live_test.exs test/ip_database_live_test.exs test/task_artifacts_test.exs test/worker_submission_live_test.exs test/zones_live_test.exs'
devenv shell -- bash -c 'node --check apps/yellow_dog_management/test/management_configuration_browser_smoke.mjs && python3 -B -c "import ast,pathlib; ast.parse(pathlib.Path(\"apps/yellow_dog_management/test/management_configuration_smoke.py\").read_text())"'
git diff --check
```

Every command passed. Strict compilation and all **150 scoped tests**
passed. The single logged refused-loopback connection error is intentional
unconfirmed-outcome regression evidence, not a compiler warning or test failure.
The architecture script strictly compiled production source, rebuilt both
independent release assemblies, and passed the positive/four negative boundary
fixtures. It did not start an execution Worker. Source provenance passed all
**203 retained files**; retained presentations remain unrouted.

The rebuilt Management release passed Chromium create/sync/verify/editor-failures/
advance/failed-sync phases, including SIGKILL and a new Management process.
View recreation changed ID from `02dc0afa-4ba2-4207-9196-c1fb6548f773` to
`a93da889-1697-4db8-85a3-6de61f634317`; recreation receipt/create-audit counts
increased from `[7, 1]` to `[8, 2]`. Zone failed/retry/edited counts were
`[14, 1]`/`[14, 1]`/`[15, 2]`; View failed/edited counts were `[16, 1]`/`[17, 2]`.
Canonical Zone/View state remained unchanged under the rejection triggers.
City/Country file bytes, catalog selection, configuration, assignments and
historical target export survived restart. A subsequent failed synchronization
retained both selected artifacts. Actual supervisor/application probes showed
no GeoIP query process or execution Worker/legacy runtime; the harness verified
only Management's ephemeral loopback HTTP listener. Owned browser, release,
fixture HTTP and PostgreSQL processes were cleaned up.

Final evidence is under `/tmp/yellow-dog-management-review-fixes/`:
`final-scoped.log`, `final-format.log`, `architecture-final.log`,
`browser-restart-final.log`, `provenance-final.log`, `harness-syntax-final.log`.
Browser/runtime evidence is `/tmp/yellow-dog-management-configuration-nsto_sic/`
(`view-recreation.json`, `editor-failures.json`, `before-restart.json`,
`final-runtime.json`, phase screenshots and release log). Final PostgreSQL
directories are `/tmp/yellow-dog-phase1-pg.BfgluY` and
`/tmp/yellow-dog-phase1-pg.o4e5Vc`; both clusters stopped successfully.

Completion audit on 2026-10-08 verified the unchanged final sources and these
results. Both requested fixes and all scoped gates are complete. No scoped
failure remains. Failures introduced during implementation, including the
immediate-submit race, were repaired and covered by the final tests/browser
run. The 21 starting-commit CI failures and missing Node test remain documented
above; the full unrelated suite was not rerun or repaired, and no CI run of this
uncommitted worktree is claimed. Worker connectivity, artifact transfer/loading,
full View/GeoIP export and unrelated retained-page redevelopment remain deferred.
Starting and ending HEAD are both `8725b765653fd9300523e62888caaf9ed3bedb16`;
the 15 follow-up files remain uncommitted. The supplied untracked plan is unchanged.

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
