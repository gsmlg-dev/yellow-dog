# Management node configuration workflow

Step 4 adds the [versioned HTTP API and MCP operation matrix](management-api-contract.md)
over the same authorized commands and canonical objects. The
[integration security guide](management-integration-security.md) describes the
deployment trust boundary. Worker credentials, enrollment policy and other
administrative operations remain UI-only; their existing behavior is preserved.

The **Step 2 review repair** section below records pre-delivery verification of the repair
against `a7ebf949`. The original Step 2 delivery and its older verification are
retained as historical evidence. In particular, the earlier connected-Worker
shutdown failure was superseded by a successful complete rerun during this repair.

Step 2 starts at `c93175b122c413b7bfe4c7d27b921d002e4f4399` on 2026-10-21.
The original checkout contained only two untracked supplied planning documents.
Implementation was prepared on `codex/node-workflow-step2` in
`.trees/node-workflow-step2` for integration into `main`; the supplied documents
are preserved outside the committed change set.

Management and PostgreSQL are sufficient for registration, desired configuration,
Data assignments and publication. DNS is the supported service. DHCPv4/v6, mDNS,
Netboot, Identity and other service editors remain unavailable. Profiles are
metadata; selecting one does not provision services or change assignments.

## Routes and ownership

The primary order remains Node Management, Data Configuration, Monitoring,
System Configuration. Netman behavior and global configuration history remain.

| Route | Purpose |
| --- | --- |
| `/management/servers`, `/server` | Explicit Worker selection and registration |
| `/management/servers/enrollment` | Global anonymous Worker admission policy |
| `/server/:server_id/dashboard` | Basic information: name and profile |
| `/server/:server_id/connection` | Authentication & connection: reset and transient bootstrap |
| `/server/:server_id/services` | Desired service instances and last-known observations |
| `/server/:server_id/services/new` | Create a DNS instance |
| `/server/:server_id/services/:service_id/edit` | Edit the selected Worker's database service record |
| `/server/:server_id/targets` | Review preview and explicitly publish |
| `/server/:server_id/targets/:revision` | Immutable selected target and exact-revision export |
| `/server/:server_id/dns` | Narrow delegation to the Services tab |
| `/management/config` | Existing cross-node prepared-target history |

Service URLs use database UUIDs, distinct from user-visible instance labels.
`new` precedes dynamic editor routing. Path params determine scope; query identities
cannot replace the selected Worker or service. All four tabs load directly.

Data remains responsible for Zone drafts/confirmation/assignments and DNS View/ACL
editors. The service editor shows bounded, read-only references with Data links.
Pinned Zone versions enter WorkerPlan; saved View/ACL relationships do not. IP
Database remains in Data Configuration. Monitoring retains detailed observations,
logs and audits; System retains Management platform settings.

## Commands, revisions and publication

`create_service` and `update_service` share the existing transaction-backed service
validation/persistence branch. The former refuses an existing instance; the latter
resolves a database service ID within a Worker and forbids renaming. Existing
`put_service` upsert callers retain their semantics. All target inputs (services,
assignments and immutable Zone versions) are covered by existing Worker locking
and revision checks. No schema, Worker runtime or ConfigSpec change is required.

Saving desired `running` or `stopped` does not publish, bind a Management listener,
or establish execution. Stopping preserves assignments and prior targets.
Preview is read-only and captures `worker_revision`. Publish submits exactly that
reviewed revision; a concurrent service/assignment change or another publication
rejects it. A fresh preview is required after a conflict. Publication is explicitly
confirmed because a connected Worker may consume it through existing polling.
A prepared target is separate from last authenticated applied revision/digest.
Offline reports are last-known observations, never manufactured current stages.

Forms use `ManagementUI.Submission`: an unresolved logical retry keeps its identity;
a new interaction receives a new identity. Polling merges observation fields only,
leaving dirty input, editor revision and reviewed preview unchanged. Scope changes
reset intent/preview. Internal links, node selection and browser navigation ask
before discarding dirty input. Reload/review is explicit after conflicts.

## Node capability contract for later adapters

Ordinary commands use `Domain.mutate(operation, params, actor, idempotency_key)`.
Revision preconditions and idempotency receipts commit with their audit and business
writes. Results are `{:ok, map}` or `{:error, %{code: ..., message: ..., details: ...}}`;
HTTP wraps these in `data` / `error`. HTTP writes remain under
`POST /api/commands/:operation` with `Idempotency-Key` (1–128 bytes).

| Capability | Application operation and scope | Accepted fields / concurrency |
| --- | --- | --- |
| Worker list/read | `Domain.list_workers/0`, `get_worker/1`; GET `/api/workers`, `/:id` | Non-secret desired state plus authenticated observations |
| Metadata | `update_worker` | `id`, `name`, `profile_name`, `expected_revision`; existing profile validation |
| Enrollment read/update | `worker_enrollment_settings/0`, `set_worker_enrollment` | Global `allow_anonymous` boolean; logical submission identity; does not revoke Workers |
| Register | `WorkerConnections.create/1` | Name only; generated identity, transaction and specialized secret result |
| Reset | `WorkerConnections.rotate/1` | Selected Worker ID; invalidates former token; specialized secret result |
| Services read | `list_services/1`, `get_service/2`; GET `/:worker_id/services`, `/:service_id` | Service database UUID resolved within Worker |
| Create | `create_service` | `worker_id`, `expected_revision`, required immutable `instance_id`, `type`, `desired_state`, `config` |
| Update | `update_service` | `worker_id`, `expected_revision`, required `service_id`, optional matching `instance_id`, `type`, `desired_state`, `config` |
| References | `list_service_references/3`; GET `/:worker_id/services/:service_id/references` | Worker+service scope; ordered SQL LIMIT, default/max 100 per kind; metadata projections |
| Preview | `preview_target/1`; GET `/:worker_id/preview` | Read-only Worker lock; includes `worker_revision`, plan and ConfigSpec diff |
| Publish | `confirm_target` | `worker_id`, exact preview `expected_revision`, logical idempotency key |
| History | `list_worker_target_history/2`; GET `/:worker_id/targets` | Ordered SQL LIMIT; default 50, maximum 100; UI requests 20 |
| Snapshot/export | `get_target/2`, `ConfigCompiler.export_target/2`; GET `/:worker_id/targets/:revision[/export]` | Immutable exact revision; existing ExportScope refusal and exclusion headers |

Service config accepts only IPv4 `listen_address` and integer `port` 1–65535;
type is `dns`, state is `running` or `stopped`. The existing ConfigSpec validation
also enforces listener conflicts and unknown fields. Common failures include
`revision_conflict` and `conflict` (HTTP 409), `invalid_request` / `invalid_config`
(422), and `not_found` (404). Invalid writes have no partial effects.

### Secret-result exception and remaining API/MCP work

Registration/reset are specialized application operations, not generic idempotent
commands. Only credential hashes persist. A successful interaction returns secret
material once, wrapped by `WorkerConnection.Secret` for Inspect redaction and
rendered in a transient copyable bootstrap. Polling preserves this result; dismiss,
scope change or disconnect clears it. Ordinary reads, flashes, audits, generic
receipts and URLs never contain a token. The trusted page origin supplies the
Management endpoint; query strings cannot redirect credential instructions.

Session submission identities suppress duplicate/delayed successful UI events.
They are not durable secret replay: an ambiguous lost response must be recovered by
reading non-secret state and an explicit new reset, never automatic rotation.
There is no read-current-token endpoint or plaintext receipt. Future administrator
API/MCP adapters must explicitly design authorization and specialized secret-result
retry policy around these operations, separately from WorkerAPI Bearer credentials.
No `/api/v1`, OpenAPI, remote MCP transport, OAuth or account system is delivered.

## Step 2 review repair — 2026-10-22

Committed HEAD during repair verification: `a7ebf9490d40520dc932e198fc5d71d681fc1dba`
on `main`, with repair changes uncommitted during those checks. Subsequent
Git delivery is recorded in commit history. The initial
checkout had two untracked supplied plans; all supplied plans, including the later
Step 3 and review-fixes documents, are preserved. The separate
`.trees/data-workflow-step3` worktree was outside this repair verification.
No Step 3 feature was included in the repair checks below.

### Reproductions and changes

Baseline reproductions used an isolated detached worktree at the exact reviewed
HEAD, with its own rebuilt assets and release against the current dependency lock.
An older release already present in the checkout was not accepted as baseline
evidence. These are locally executed reproductions, distinct from the CI evidence
below.

| Finding | Baseline evidence and repair |
| --- | --- |
| R1 dirty history | Real Chromium reproduced retained editor/value with incorrect address and loss of the original history entry. `NodeWorkflow` observes installed LiveView 1.2.13's `phx:navigate` lifecycle and protects immediate local input. One application-owned `popstate` dispatcher is installed before LiveSocket connects; only the active node hook handles rejected traversals. It restores the original native entry by key and suppresses canceled/restoration events before LiveView can change scope. Hook-owned listeners detach on destruction, and the inactive dispatcher retains no hook/DOM reference. No synthetic history entry, router replacement or browser/LiveView monkey patch is used. |
| R2 database recovery | Actual PostgreSQL failure injection reproduced an escaping credential error and termination of a dirty editor during observation refresh. A narrow application boundary now distinguishes availability failures, confirmed SQL rejection and unknown credential outcome; programming errors propagate. Observation failures retain input, revision, preview and last known connectivity, with explicit stale feedback and one refresh timer. Recovery merges observations without rebasing. |
| R2 uncertain issuance | Registration generates a nonsecret identity before its transaction. Uncertain results retire the submission intent, retain nonsecret input and identify that exact Worker for explicit recovery. Names are not used to select a possible registration. Rotation never automatically retries or promises the previous token is valid. Secret results are not generic replay receipts. |
| R3 transient credentials | Real Chromium reproduced secret-bearing DOM and a usable copy control while disconnected. A transient-credential hook now erases textarea value, default value and text immediately, disables copy, and retires the matching issuance on reconnection. Queued updates cannot restore that retired issuance. Connected polling retains it; explicit fresh issuance remains possible. No disconnect-induced rotation occurs. Tokens already deliberately copied by the operator cannot be erased. |
| R4 affected acceptance | The exact baseline reproduced six affected Elixir failures and both PreserveScroll failures. Tests now follow dedicated service routes and scoped Data assignment navigation, retaining persistence, unusual IDs, immutable identity, publication and exact-export assertions. The DOM double implements `querySelector`; nested/fallback scrolling, restricted storage, identity, update and listener cleanup remain covered. The logs test selects the intended patch control. |

Fault injection uses disposable PostgreSQL roles, row policies and functions. It
covers dirty observation failure/recovery, failure before rotation, ambiguous
registration, stale-intent suppression, exact-ID recovery, transaction/audit
integrity and propagation of SQL programming errors. The lost-acknowledgment test
commits a real issuance, then **models acknowledgment loss at the application
boundary**; it does not inject a wire-level COMMIT fault. Explicit SQL rejection
fixtures use `23514` rather than treating arbitrary PL/pgSQL programming exceptions
as constraints. No schema or Worker protocol/runtime change is included.
An explicit Preview read is covered by the same availability boundary: failure
retains the reviewed preview, revision and intent; a successful retry clears the
stale-observation message.

Final review also reproduced a failed same-Worker route load retaining the old
service editor. Loaded scope now includes both route parameters and action:
identical-scope failures preserve edits and preview, while a failed destination
load retires the previous submission and clears actionable stale content. An
explicit retry loads the destination. Tests cover service A to B, edit to new,
ignored old actions, and recovery without changing either service or its audit.

Chromium disconnect acceptance found a second pre-existing behavior: LiveView
automatically recovered the sidebar's navigation selector as a form change,
redirecting the connection page to Basic. A minimal probe against the rebuilt
reviewed HEAD reproduced it (`/tmp/yellow-dog-review-browser-baseline-reconnect.log`).
The navigation selector now opts out of automatic form recovery; editor recovery
is retained. Credential tests assert that reconnection preserves the route as well
as erasing the retired result and leaving reset audits unchanged.

History acceptance checks native entry identity and count, URL, selected Worker,
editor value, delayed validation, repeated canceled Back and missing-position
Forward. Both cancellation and acceptance exercise CDP's actual browser history
action (`Page.navigateToHistoryEntry`), as well as scripted immediate input/Back.
Script-only cancellation was insufficient: the browser-toolbar probe exposed
incorrect URL restoration, and remains a required regression assertion. While an
asynchronous restoration is pending, additional pops target the same saved entry
without advancing the committed snapshot or prompting again. Legacy restoration
uses known numeric history positions; a browser lacking both native entry identity
and usable positions cannot deterministically restore an unknown traversal with
the History API alone. Real-browser acceptance here covers Chromium.

### Current local verification

All commands run from this checkout through Nix/devenv. PostgreSQL checks use
`scripts/e2e/phase1_postgres.sh`, never the user's database. Checked-in assets and
the Management release were rebuilt before browser acceptance.

| Command | Locally executed result / log |
| --- | --- |
| `devenv shell -- env MIX_ENV=test mix compile --warnings-as-errors` | Passed; `/tmp/step2-compile-final.log` |
| `devenv shell -- scripts/e2e/phase1_postgres.sh mix do --app yellow_dog_management test` | **537 tests, 0 failures**; `/tmp/step2-management-full-final.log` |
| `devenv shell -- node --test apps/yellow_dog_management/test/management_ui_test.mjs` | **17 tests, 0 failures**; `/tmp/node-r1-toolbar-unit-final.log`. The asynchronous model installs the simulated LiveView listener at connect, covers repeated pending restoration and owner replacement, and retains all 12 non-navigation tests. |
| `devenv shell -- bun run assets.management` | Passed; `/tmp/step2-assets.log` |
| `devenv shell -- env MIX_ENV=prod mix release yellow_dog_management --overwrite` | Passed; `/tmp/step2-release-rebuild.log` |
| `BUILD_RELEASE=0 MANAGEMENT_BROWSER_SCOPE=navigation devenv shell -- scripts/e2e/phase1_postgres.sh scripts/e2e/management_browser.sh` | **Exit 0 PASS**; desktop/mobile navigation, actual scrolling and scope assertions; `/tmp/yellow-dog-review-browser-navigation-final.log`, browser artifacts `/tmp/yellow-dog-management-browser.2zc2Ml` |
| `BUILD_RELEASE=0 MANAGEMENT_BROWSER_SCOPE=nodes devenv shell -- scripts/e2e/phase1_postgres.sh scripts/e2e/management_browser.sh` | **Exit 0 PASS, including restart**; actual toolbar cancellation/acceptance, missing-position Forward, delayed input/repeated Back, registration/reset disconnect lifetime and route retention, original service/assignment/preview/publication/exact-export workflow, desktop/mobile and canonical state after Management restart. `/tmp/yellow-dog-review-browser-nodes-final.log`, browser artifacts `/tmp/yellow-dog-management-browser.5SpCG6` |
| `BUILD_RELEASE=0 devenv shell -- scripts/e2e/phase1_postgres.sh scripts/e2e/management_browser.sh` | **Exit 1**, same baseline notifications expanded-state assertion; final rebuilt release confirmed this remaining limitation. `/tmp/step2-full-browser.log`, browser artifacts `/tmp/yellow-dog-management-browser.e8msof`; downstream assertions did not execute. |
| `devenv shell -- scripts/e2e/architecture_smoke.sh` | Passed: positive fixture and **35 rejected mutations**; `/tmp/step2-architecture.log` |
| `BUILD_RELEASE=0 devenv shell -- scripts/e2e/file_gate.sh` | Passed: offline selected export, real DNS UDP/TCP, snapshot recovery and lifecycle; `/tmp/step2-file-gate.log` |
| `BUILD_RELEASE=0 devenv shell -- scripts/e2e/phase1_postgres.sh scripts/e2e/worker_connection_smoke.sh` | **Complete exit 0 PASS**, including final cleanup; `/tmp/step2-connected-worker.log`, evidence `/tmp/yellow-dog-worker-connection-vt5b2dga`. Supersedes the historical shutdown limitation below. |

Focused node/credential/Domain/API checks also passed (54 tests), affected
UI/logs checks passed (21), and constraint-fixture suites passed (46 and 26).
Changed Elixir formatting, JavaScript syntax and `git diff --check` passed.
No test was skipped or assertion suppressed to obtain these results.
The final same-scope/changed-scope fault checks passed 22 focused tests; explicit
Preview failure/recovery passed the nine-test database recovery suite. Logs:
`/tmp/node-r2-scope-final.log` and `/tmp/node-r2-preview-focused.log`.

The bounded Step 2 review gate is satisfied locally. Expected failures preserve
recovery UI, canceled operator navigation preserves scope/history, transient
credentials obey their lifetime, and affected regression suites pass. This does
not declare the unrelated full-browser suite green or authorize Step 3 integration.

Reproduction logs: `/tmp/yellow-dog-review-browser-baseline.log` (R1/R3),
`/tmp/step2-database-baseline-final.log` (two database baseline checks),
`/tmp/yellow-dog-r4-tests-baseline.log` (six Elixir failures), and
`/tmp/step2-js-baseline.log` (two JavaScript failures).

### CI and remaining limits

The actual logs of [Phase 1 run 39642011290](https://github.com/gsmlg-dev/yellow-dog/actions/runs/39642011290)
at the exact reviewed HEAD were directly inspected: Management had 527 tests with
six failures, and Node had ten tests with two failures. Worker, ConfigSpec,
architecture, release and offline-export jobs succeeded. These repair results were collected
before Git delivery; **no CI run covered the repair at verification time**. Local
green checks do not change the reviewed run's status.

At repair verification time, the unscoped browser command failed the notifications trigger assertion
(`aria-expanded` is null, expected `true`, currently `live_browser_smoke.mjs:165`). It was
reproduced on both pristine reviewed HEAD and this repair with the final lock;
downstream full-browser assertions are not claimed. The native DuskMoon dropdown
defect is filed as Bug, `internal request`, severity `needed`:
[phoenix-duskmoon-ui#209](https://github.com/duskmoon-dev/phoenix-duskmoon-ui/issues/209).
The callsite recorded the upstream TODO; no component internals, CSP rules or
assertions were replaced. Logs: `/tmp/step2-baseline-full-browser.log` and
`/tmp/step2-full-browser.log`. Historical retained-source provenance results below
were not rerun in this repair and are not current acceptance evidence.

Dependency follow-up on 2026-10-22: `phoenix_duskmoon` 10.0.11 includes the
upstream #209 fix, and the obsolete callsite TODO has been removed. Rebuilt
Chromium passed the notification open/close/reopen and Escape expanded-state
checks. The full flow then stopped at the later publish-preview assertion
expecting `/prepared_preview/`; downstream assertions remain unverified. See
[the current evidence](management-data-workflow.md#upstream-dropdown-fix-follow-up).

## Historical Step 2 verification

Validation on 2026-10-21 (Asia/Shanghai), against the Step 2 tree before integration:

| Check | Result |
| --- | --- |
| Strict test compilation | Passed with `--warnings-as-errors` |
| Focused Management domain/API/navigation/connection/submission/profile/Zone assignment tests | 113 tests, 0 failures |
| Final responsive markup: node workflow and credential LiveView regressions | 12 tests, 0 failures |
| Worker authenticated connection/offline snapshot regression | 5 tests, 0 failures; expected TLS rejection cases exercised |
| Production architecture gate | Passed: two isolated releases, pure shared ConfigSpec, six negative mutations rejected |
| Official DuskMoon menu integration | Locked `phoenix_duskmoon` 10.0.9; upstream issue 207 closed; 13 baseline navigation tests passed and final dedicated Chromium navigation passed |
| Chromium node workflow | Passed; two offline Workers, canonical registration, invalid registration retained input, same-tab rapid-edit discard, selector cancel, polling, DNS create/edit, Data Zone create/confirm/assign, scoped references, stale-preview rejection, fresh publication and immutable earlier export |
| Real connected Worker release smoke | All business assertions passed: authenticated polling, real DNS UDP/TCP, Management outage/offline restart/reconnect, stopped snapshot, credential reset, failed-target preservation and URL-only enrollment. Command exited 1 during final cleanup: Worker failed to exit within 20 seconds. Worker runtime unchanged; cleanup limitation remains unresolved/out of scope |
| Restart | Passed; Management restarted on the same disposable PostgreSQL/artifact state, a new Chromium session re-read exact service/assignment/target data and earlier TOML |
| Desktop/mobile | Passed: direct routes, refresh, node-route back/forward, mobile tab activation, readable horizontally scrolling service table and no viewport overflow |
| Formatting/assets/JS/shell/diff | Passed; existing asset build used; no assertion skips or warning suppression |
| Full Chromium suite | Baseline failure retained: notifications popover opens, but the trigger's `aria-expanded` is null rather than the assertion's `true`. Reproduced both on starting HEAD and Step 2; no downstream full-suite assertions are claimed to have run |
| Retained-source provenance | Baseline failure retained: `check_ui_source_migration.py` rejects `apps/yellow_dog_console/assets/js/app.js` source SHA at line 29 on both starting HEAD and Step 2; retained source and manifest unchanged |

Actual commands (run from this worktree unless stated):

```sh
devenv shell -- env MIX_ENV=test mix compile --warnings-as-errors
devenv shell -- scripts/e2e/phase1_postgres.sh mix do --app yellow_dog_management test \
  test/navigation_test.exs test/navigation_live_test.exs test/workers_connection_live_test.exs \
  test/node_workflow_live_test.exs test/worker_submission_live_test.exs \
  test/worker_profiles_live_test.exs test/node_workflow_domain_test.exs \
  test/domain_test.exs test/web_test.exs test/zones_live_test.exs \
  test/assignment_domain_test.exs test/worker_connections_test.exs
devenv shell -- mix do --app yellow_dog_worker test test/connection_test.exs
devenv shell -- scripts/e2e/architecture_smoke.sh
devenv shell -- bun run assets.management
MANAGEMENT_BROWSER_SCOPE=nodes MANAGEMENT_SCREENSHOT_PREFIX=/tmp/yellow-dog-node-step2/workflow \
  devenv shell -- scripts/e2e/phase1_postgres.sh scripts/e2e/management_browser.sh
BUILD_RELEASE=0 MANAGEMENT_BROWSER_SCOPE=navigation \
  devenv shell -- scripts/e2e/phase1_postgres.sh scripts/e2e/management_browser.sh
BUILD_RELEASE=0 devenv shell -- scripts/e2e/phase1_postgres.sh scripts/e2e/management_browser.sh
python3 scripts/e2e/check_ui_source_migration.py
BUILD_RELEASE=0 devenv shell -- scripts/e2e/phase1_postgres.sh scripts/e2e/worker_connection_smoke.sh
```

The unscoped browser command and provenance checker were additionally run from
the original checkout at starting HEAD to classify their failures. No unrelated
fixes were made. The new `nodes` browser scope retains all existing `full` and
`navigation` assertions and adds its own restart pass. It never captures the
transient credential view. Changed Elixir files were checked with
`mix format --check-formatted`, changed JS modules with `node --check`, the harness
with `bash -n`, and the diff with `git diff --check`.

Logs and safe screenshots are under `/tmp/yellow-dog-node-step2/`:
`focused-tests-accepted.log`, `layout-final-tests.log`, `worker-protocol.log`,
`compile-final.log`, `architecture.log`, `navigation-browser.log`,
`nodes-browser-final.log`, `connected-worker-final.log`, `full-browser.log`, `baseline-full-browser.log`,
`workflow-node-desktop.png`, and `workflow-node-mobile.png`.
Final node browser/restart artifacts: `/tmp/yellow-dog-management-browser.g3dGA3`.
Connected Worker release evidence: `/tmp/yellow-dog-worker-connection-9elh3v01`.
The first concurrent protocol smoke was interrupted by SIGTERM/database cleanup
(exit 143); the unchanged serial rerun passed every business stage but failed final Worker
shutdown cleanup. This is not a green full release-smoke result. No Worker runtime
fix or shutdown-timeout relaxation was attempted. Scoped leftover test processes
were stopped and transient enrollment/bootstrap credential fixtures removed.

The verified change set is delivered through a feature commit integrated into
`main`; Git history records the delivery commit. API/MCP administrator transports, additional
Worker services, Data editor redesign, monitoring dashboards, platform settings,
rename/delete and rollback remain deferred. This task does not claim the unrelated
full browser suite or historical source-provenance gate is green.

## Changed files

- `apps/yellow_dog_management/assets/app.js`
- `apps/yellow_dog_management/lib/yellow_dog/management/domain.ex`
- `apps/yellow_dog_management/lib/yellow_dog/management/web.ex`
- `apps/yellow_dog_management/lib/yellow_dog/management_ui/components/service_paths.ex`
- `apps/yellow_dog_management/lib/yellow_dog/management_ui/live/worker_live.ex`
- `apps/yellow_dog_management/lib/yellow_dog/management_ui/live/workers_live.ex`
- `apps/yellow_dog_management/lib/yellow_dog/management_ui/navigation.ex`
- `apps/yellow_dog_management/lib/yellow_dog/management_ui/router.ex`
- `apps/yellow_dog_management/priv/static/management-live.js`
- `apps/yellow_dog_management/test/live_browser_smoke.mjs`
- `apps/yellow_dog_management/test/navigation_test.exs`
- `apps/yellow_dog_management/test/node_workflow_browser_smoke.mjs`
- `apps/yellow_dog_management/test/node_workflow_domain_test.exs`
- `apps/yellow_dog_management/test/node_workflow_live_test.exs`
- `apps/yellow_dog_management/test/worker_connection_browser_smoke.mjs`
- `apps/yellow_dog_management/test/worker_profiles_live_test.exs`
- `apps/yellow_dog_management/test/worker_submission_live_test.exs`
- `apps/yellow_dog_management/test/workers_connection_live_test.exs`
- `apps/yellow_dog_management/test/zones_live_test.exs`
- `docs/phase1/management-navigation.md`
- `docs/phase1/management-node-workflow.md`
- `scripts/e2e/management_browser.sh`

## Step 3 Data cross-links

Zone references use the immutable pinned version name and link directly to the
Zone Application scope tab. Assignment editing remains owned by Data; Node
publication remains explicit. Data now offers Content, Versions and Application
scope routes, global View/ACL scope selectors, and IP synchronization settings
with Monitoring job links. See [management-data-workflow.md](management-data-workflow.md)
for the complete operation contract and combined verification evidence.
