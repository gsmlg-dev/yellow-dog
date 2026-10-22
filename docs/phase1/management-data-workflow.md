# Management Data configuration workflow

Starting revision: `a7ebf9490d40520dc932e198fc5d71d681fc1dba`.
Implementation was prepared on `codex/data-workflow-step3` for integration into
`main`. The completed Step 2 review repairs are incorporated and verified with
Data; Git history records the subsequent delivery commits.

## Source capability inventory

This inventory was made from the native application contexts and schemas before
changing the Data workflow; retained redesign templates are not its contract.

| Dataset | Fields and application operations | Concurrency/version | Application scope | Worker target |
| --- | --- | --- | --- | --- |
| Zone | Global name, SOA/NS/A records; create/update/delete, import, record editing, canonical reread | Expected draft revision; confirm freezes saved content, reuses matching source revision | Atomic complete assignment set, max 256; assignment token and expected Worker revisions; fixed version per DNS service, same version across one Worker's services | Confirmed assigned content only |
| DNS View | Service-scoped name, priority, enabled, recursion/ECS, client CIDR/country rules, fallback endpoints/timeouts/retries | Expected revision; default restrictions; no immutable versions | Existing owning Worker/service; no allocation store | Excluded |
| DNS ACL | Service-scoped name/description, ordered allow/deny rules, any/networks/countries; max 128 rules/networks | Expected revision; no immutable versions | Existing owning Worker/service and supported references | Excluded |
| IP Database | Country/City metadata, selected digest, bounded history, existing task settings/run operations, asynchronous integrity checks | Immutable kind/digest files; task config revision and persistent job identity | Global selection; no recipient editor | Excluded |
| MAC Database | Existing global OUI catalog and synchronization | Existing task/catalog semantics | Global | Excluded |

All saves are Management-only. Offline logical Workers are eligible for Zone
assignments; no Worker process is needed for dataset authoring. API/MCP integration
remains Planned. No new protocol, resource schema, authentication or delivery
adapter is provided.

## Routes and editor lifetime

The four primary sections retain their order. Data uses `/management/zones`
(and the existing `/server/:server_id/dns/zones` context), with `/new`, `/import`,
`/:zone_id/edit` (Content), `/:zone_id/versions`, and `/:zone_id/application`.
Existing `/:zone_id/records` single/bulk editor routes remain supported. Worker
context filters navigation; it never changes global Zone ownership. Matched path
parameters own Worker/service/Zone identity; query identities are ignored.

The catalog uses a dedicated SQL read: 20 rows by default, at most 100, bounded
page offsets, literal case-insensitive search, stable name/ID sorting (or draft
revision/name/ID). Record counts, newest version number and Worker/service usage
are metadata aggregates for the page's IDs. It never preloads all records or
version contents. `Domain.list_zones/0` remains the complete read for its existing
callers; CSV explicitly exports **all matching Zones**, independently of pagination.
`GET /api/zone-catalog` exposes the same bounded non-secret metadata read.

Content and Application scope retain separate dirty/reset state and mutation
requests. Same-Zone tabs preserve both proposed editors. Content save rereads
canonical draft content; assignment save rereads the complete canonical set and
links affected Workers to `/server/:id/targets`. Neither action publishes.
Confirmation specifies the saved draft revision and is blocked while content
is dirty, including local input awaiting a server change acknowledgment. Explicit
content discard and assignment reload affect their respective editors.

Assignment editing loads the complete set, up to 256 rows. An oversize set is
rejected, never silently truncated into a replacement request. No list filter or
catalog page removes hidden relationships. A new row pins an explicit displayed
version; subsequent confirmation does not advance it. Multiple eligible services
require selection; a sole service is shown and selected. Stale assignment tokens
and Worker revisions preserve proposed values and require explicit review/reload.
All services on one Worker must use the same version of a given Zone. Pinned
reference names come from immutable content, including after draft renaming.

DNS Views retain `/management/dns/views` and scoped service routes. ACLs now also
have the scope-free `/management/dns/acl` selector. Neither selector guesses a
Worker. Existing business fields/default restrictions and revision checks remain;
changing scope navigates, without cloning or moving objects. Their editors and
IP synchronization settings use the same small page-local navigation guard,
without storing business data in browser storage.

IP Database remains `/system/ip-database`. Country/City enabled/cron settings use
`update_task`; execution details stay in Monitoring at `/system/tasks/ip_country`
and `/system/tasks/ip_city`. The catalog distinguishes persistent job state from
selected-file validity. Retry retains one run intent/key until acknowledgment;
a later manual sync creates a new intent. Metadata pagination and selected-file
asynchronous validation retain their existing bounds, cancellation identities
and revalidation rules. A failed synchronization retains the last valid selection.

## Application operation mapping

Commands use `Domain.mutate(operation, params, actor, idempotency_key)` and existing
`POST /api/commands` overlap. A logical intent retains its key and original expected
revision across retries; editing/new workflow retires that intent. Responses are
`{:ok, canonical_result}` or `{:error, %{code, message, details}}`, exposed through
the existing HTTP result/error envelope. Recorded successes/errors remain within
the Domain transaction/audit boundary. No direct LiveView Repo writes are added.

| Operations | Identity, allowed input and bounds | Result / retry / export |
| --- | --- | --- |
| `create_zone`, `update_zone`, `delete_zone` | Global UUID; name/content or name+records, up to 1,024 records and 253-byte domains; ConfigSpec SOA/NS/A validation; updates/deletes require expected revision | Canonical draft/deletion result; stable logical key; drafts never enter export |
| `confirm_zone` | Zone UUID + expected saved revision | Immutable version UUID/number/digest/content; unchanged saved revision reuses a version; no target publication |
| `set_zone_assignments` | Zone UUID, assignment token, expected Worker revision map, complete list of at most 256 Worker/service/version selections | Canonical set/token/revisions; atomic rejection on wrong scope/version, duplicate service, stale token/revision or incompatible per-Worker versions; pinned versions enter target only after Node publication |
| View create/update/delete | Owning Worker and DNS service DB UUID, View UUID/immutable name; up to 128 fallback endpoints, existing rule bounds and expected revisions | Existing canonical revision result and stable retry intent; default restrictions preserved; target/export excluded |
| ACL create/update/delete | Owning Worker/service and ACL UUID; mutable name (1–128 ASCII characters), description (up to 255 characters), max 128 rules/total networks and 249 countries per country rule; expected revisions | Canonical scoped revision result and stable retry intent; target/export excluded |
| `update_task` | Existing `ip_country`/`ip_city`, expected config revision, enabled and cron | Canonical task config; stable retry; no new scheduler or provider credential/URL editor |
| `run_task` | Existing IP task key + logical intent key | Persistent job ID; available/scheduled/retryable are queued, executing is running, completed is succeeded and discarded is failed; retries replay one intent, subsequent synchronization is a new intent |
| Catalog/artifact reads | Bounded kind/history page; selected artifact fetched independently; file identity kind/digest/size | Metadata is unchecked until bounded selected-file verification; no local paths, secrets, file bodies or Worker delivery implied |

Current export remains `dns_zones`; explicit full export is rejected. Views,
ACL/rules and GeoIP artifacts are **saved in Management; not included in the
current Worker target/export**. Historical target TOML remains immutable. MAC
catalog semantics remain unchanged. Detailed Monitoring/System work and actual
versioned HTTP/OpenAPI/MCP adapters remain separate milestones.


## Verification and review handoff

Verification uses the isolated `.trees/data-workflow-step3` checkout. The committed HEAD during
implementation verification was `a7ebf9490d40520dc932e198fc5d71d681fc1dba`; the implementation
and reviewed Step 2 repairs were uncommitted during those checks. Supplied plans and
the concurrent main checkout were preserved.

The repair gate is based on `yellow-dog-step2-review-fixes.md`, not historical
release-smoke results. Imported repairs cover committed-history navigation,
PostgreSQL observation/credential failure boundaries, uncertain secret issuance,
local bootstrap erasure on disconnect, scoped recovery, and the affected UI/scroll
assertions. Data adds independent editor intents, immediate local-input protection,
immutable proposed versions and stale import-preview rejection. Regression review
also covered cross-Zone oversize snapshots, queued sibling saves, pending row
retries, dirty unrelated View/ACL editors and canonical post-save recovery.

Run commands from the project root in devenv, changing into the worktree:

```sh
cd .trees/data-workflow-step3
MIX_ENV=test mix compile --warnings-as-errors
scripts/e2e/phase1_postgres.sh mix do --app yellow_dog_management test
node --test apps/yellow_dog_management/test/management_ui_test.mjs apps/yellow_dog_management/test/editor_guard_test.mjs
bun run assets.management
MANAGEMENT_BROWSER_SCOPE=data MANAGEMENT_SCREENSHOT_PREFIX=/tmp/yellow-dog-data-step3/workflow-final-toolbar scripts/e2e/phase1_postgres.sh scripts/e2e/management_browser.sh
BUILD_RELEASE=0 MANAGEMENT_BROWSER_SCOPE=navigation scripts/e2e/phase1_postgres.sh scripts/e2e/management_browser.sh
BUILD_RELEASE=0 MANAGEMENT_BROWSER_SCOPE=nodes scripts/e2e/phase1_postgres.sh scripts/e2e/management_browser.sh
scripts/e2e/architecture_smoke.sh
BUILD_RELEASE=0 scripts/e2e/file_gate.sh
```

The Data scope uses loopback-only, deterministic gzip/MMDB fixtures and disposable
PostgreSQL/storage. It verifies zero-Worker authoring, multiple explicit DNS service
assignments, independent dirty editors, immutable v1/v2 and historical exports,
real second-session draft/assignment conflicts, UI/API parity, scoped View/ACL
isolation, fixture sync success/failure, verified durable selection, then a fresh
Chromium session after Management restart. No public provider credential, live
Worker or privileged port is needed for editing.

Safe screenshots are `/tmp/yellow-dog-data-step3/workflow-final-toolbar-data-desktop.png`
and `/tmp/yellow-dog-data-step3/workflow-final-toolbar-data-mobile.png`. They show the Data
application editor and contain no enrollment/bootstrap secret. Browser state and
job/artifact metadata are retained only in disposable test artifacts; no business
editor values are put in browser storage.


History regression checks use CDP's actual browser toolbar traversal, not only
`history.back()`/`forward()`. They assert cancellation preserves the native entry,
URL, mounted scope and immediate local input while the server still reports a
clean editor; repeated canceled Back and subsequent acceptance are also covered.
The early module-owned dispatcher retains only the currently mounted guard and
suppresses canceled/restoration events before LiveView processes them. Per-hook
listeners detach at destruction. Numeric history positions provide the fallback;
without native entry identity or usable positions, unknown traversal restoration
cannot be guaranteed. The exercised browser is Chromium.


### Final local results (2026-10-22, Asia/Shanghai)

Logs are under `/tmp/yellow-dog-data-step3/`. These local results were collected before Git delivery, with no CI
run for the patch at that time; historical CI results are reconciled in the imported Step 2 repair section,
and are not described as results for this patch.

| Check | Result and evidence |
| --- | --- |
| Test compilation with warnings as errors | Passed; `final-compile.log` |
| Full Management/PostgreSQL suite | **560 tests, 0 failures**; `final-management-tests.log`, PostgreSQL artifacts `/tmp/yellow-dog-phase1-pg.j3F6A2` |
| Node/Data guard JavaScript suites | **30 tests, 0 failures**; `final-js.log` |
| Changed Elixir formatting, JS/shell syntax, diff check | Passed; no tests skipped or assertions suppressed |
| Rebuilt Chromium navigation | **Exit 0**; desktop/mobile menus, scope and real scrolling; `navigation-final.log`, browser artifacts `/tmp/yellow-dog-management-browser.MpxUGX` |
| Rebuilt Chromium Nodes + restart | **Exit 0**; real toolbar cancellation, credential disconnect/reconnect, canonical Node/Data references, publication and exact historical export; `nodes-final-ack.log`, browser artifacts `/tmp/yellow-dog-management-browser.jsMIDx` |
| Rebuilt Chromium Data + restart | **Exit 0** on final source, including real toolbar cancellation and post-IP-settings rebuild; `data-toolbar-final.log`, browser artifacts `/tmp/yellow-dog-management-browser.tphtbP`, PostgreSQL `/tmp/yellow-dog-phase1-pg.T5RA1D` |
| Final release architecture | Passed: two independent releases, positive fixture and **35 rejected dependency mutations**; `final-architecture.log` |
| Final export/offline Worker | Passed: zero-Worker edits, four immutable assignments, authentic exports, Management/PostgreSQL stopped, real UDP/TCP DNS and snapshot/lifecycle recovery; `final-offline-export.log`, evidence `/tmp/yellow-dog-file-gate-gdlz5oo5` |
| Full Chromium scope | **Exit 1** at the retained notification expanded-state assertion (`null` versus `true`); `full-browser-final.log`, artifacts `/tmp/yellow-dog-management-browser.FC2yAZ`. Later full-scope assertions did not run. |

The historical full-scope limitation was the same defect reproduced on pristine reviewed HEAD
and the Step 2 repair with the 10.0.9 lock, recorded in
[duskmoon-dev/phoenix-duskmoon-ui#209](https://github.com/duskmoon-dev/phoenix-duskmoon-ui/issues/209).
The callsite retained the upstream TODO; no component internals, design tokens or
acceptance assertions were replaced to hide it. Dedicated Data, Node and navigation
scopes preserve their substantive browser assertions.

The first combined Node run reached all business assertions but failed its JS
error gate: the harness forced navigation after observing an API save before the
Zone editor acknowledged it, causing Chromium's beforeunload intervention.
The final harness waits for the canonical route and editor-clean acknowledgement
before navigating. The JS error gate remains unchanged and passed on the rerun.

Review regressions also include a real postcommit assignment-read outage: the
application command's complete canonical result now supplies the editor directly,
without a second SQL read. A failed IP schedule submission retains its original
revision/key; changing that proposal retires the old intent, so a delayed old
submit cannot overwrite the newer cron fields. Country and City remain independent.
All browser/release/database processes started by the checks are cleaned up by
the disposable wrappers.

D0–D5 are complete for the authorized Management Data scope. No Worker/ConfigSpec
runtime, schema, dependency lock, retained redesign source, remote MCP, authentication
or target-delivery capability was expanded. Verification created no commit, push or PR. The user subsequently authorized
commit, worktree integration into `main`, and push as a separate delivery action.

## Upstream dropdown fix follow-up

On 2026-10-22, Management updated `phoenix_duskmoon` from 10.0.9 to 10.0.11,
which includes the fix for upstream #209. The dependency requirement and lock
now select the fixed release; the external JavaScript bundle was rebuilt and
the obsolete callsite TODO removed. No local component or CSP workaround is used.

Fresh verification on `main` before this follow-up commit:

- Strict test compilation, scoped formatting and asset build passed
  (`/tmp/yellow-dog-upstream-build.log`).
- Management: **560 tests, 0 failures**, using disposable PostgreSQL
  (`/tmp/yellow-dog-upstream-management.log`).
- JavaScript: **30 tests, 0 failures** (`/tmp/yellow-dog-upstream-js.log`).
- The rebuilt full Chromium flow passed notification initial closed state,
  open, click close/reopen, and Escape dismissal, with explicit `aria-expanded`
  values. It then exited 1 at the later publish-preview assertion expecting
  `/prepared_preview/` in visible text. That assertion and downstream behavior
  were not changed by this dependency update. No full-flow pass is claimed.
  Log: `/tmp/yellow-dog-upstream-browser.log`; browser artifacts:
  `/tmp/yellow-dog-management-browser.Jbb7bU`.


## Step 3 review repairs and acceptance (2026-10-23)

The repair checkout is `/home/gao/Workspace/gsmlg-dev/yellow-dog` on
`codex/step3-repairs-step4-integration`, starting from
`67a1135e50d9a060f050a5183afbc2c917144b3c`. These results cover uncommitted Step 3
repairs against `yellow-dog-step3-review-fixes.md`. Supplied untracked plans and
unrelated changes were preserved. Earlier results above describe their original
source revisions; the previously incomplete full-browser flow now passes locally.
Logs below are under `/tmp/yellow-dog-step3-step4/`.

- **R1:** A clean dependency derivation reproduced the fixed-output mismatch in
  `r1-fod-clean.log`. `default.nix` now uses the observed
  `sha256-PzEJz+07iJMAe+HnomQF9AVTnrVOVZKMmK4JR8gkNbQ=`. Strict integrity checks,
  both products, both architecture declarations and the Gaoxy transport remain.
  Both x86 packages and images built from the repair snapshot; the native ARM
  artifact hash was checked separately. The ARM package/image matrix remains
  blocked by the unavailable native builder, as detailed below.
- **R2:** IP task notifications, explicit reloads and post-command display reads
  use the existing narrow database-availability boundary. Failed reads retain
  forms, revisions, tokens, request keys and last known observations. Known jobs
  and canonical saved revisions remain visible independently of refresh failure.
  View/ACL post-save and catalog reads follow the same rule; initial View row
  state and initial routed scopes are retained for recovery. Infrastructure
  failures leave artifact byte validity unknown. SQL/programming errors continue
  to propagate. `data_database_recovery_test.exs` exercises deterministic read
  failures, lost acknowledgements, committed results, replay effects and recovery.
- **R3:** Catalog mount reads Worker IDs/names without fleet detail preloads.
  Application loads searchable, stable 20-row Worker/DNS Service candidate pages;
  selected identities remain visible independently of the page. Canonical
  full-replacement snapshots retain the complete 256-assignment limit and reject
  oversized sets. LiveView route SQL telemetry covers unrelated fleet growth
  and a large valid immutable version; hidden assignments, multiple services,
  wrong scope, atomicity and revision conflicts remain covered.
- **R4:** CI explicitly runs both maintained JavaScript suites. Full Chromium
  checks the selected Worker, reviewed revision, included service/pinned version,
  no target before publication, stale-preview rejection and subsequent explicit
  publication. Import retries preserve their request identity; changing the
  source starts a new intent after resolving a duplicate-name conflict. GeoIP
  acceptance checks a persistent fixture-backed sync job and verified selected
  digest, while Worker diagnostics/runtime controls remain unavailable in
  Management. Full/Data scopes use the disposable loopback MMDB source.

| Check | Result and evidence |
| --- | --- |
| Strict test compilation and scoped formatting/syntax | Passed; `step3-compile.log`, `step3-format.log`; the final browser helper also passed `node --check` |
| Full Management/PostgreSQL suite | **576 tests, 0 failures**; `step3-management-final.log`, PostgreSQL `/tmp/yellow-dog-phase1-pg.tywvr7` |
| Both JavaScript suites | **30 tests, 0 failures**, none skipped; `step3-js-final.log` |
| Chromium navigation | Passed; `step3-browser-navigation.log`, browser `/tmp/yellow-dog-management-browser.0hKycN` |
| Chromium Nodes and restart | Passed; `step3-browser-nodes.log`, browser `/tmp/yellow-dog-management-browser.tDU8tQ` |
| Chromium Data and restart | Passed; `step3-browser-data.log`, browser `/tmp/yellow-dog-management-browser.G5MQfw` |
| Full Chromium, rebuilt final release | **Exit 0**; `step3-browser-final-rebuilt-retry.log`, browser `/tmp/yellow-dog-management-browser.hw6N05`, PostgreSQL `/tmp/yellow-dog-phase1-pg.b3C0NM` |
| Release architecture | Passed, including positive fixture and **35 rejected dependency mutations**; `step3-architecture.log` |
| Offline export/Worker gate | Passed, including PostgreSQL/Management shutdown, real UDP/TCP and snapshot/lifecycle recovery; `step3-offline-export.log`, evidence `/tmp/yellow-dog-file-gate-9ue2cxrd` |
| x86 Nix packages and images | Both products passed for the source snapshot below; `r1-x86-clean-snapshot.log`, image metadata `step3-nix-images.json` |
| ARM Nix packages and images | **Blocked/unverified**; `r1-aarch64-build.log`: required `aarch64-linux`, current `x86_64-linux`; no native builder configured |

The final full-browser invocation reused the rebuilt release with:

```sh
devenv shell -- env BUILD_RELEASE=0 MANAGEMENT_BROWSER_SCOPE=full scripts/e2e/phase1_postgres.sh scripts/e2e/management_browser.sh
```

An earlier full run passed (`step3-browser-full.log`). A later rebuilt-release
attempt (`step3-browser-final-rebuilt.log`) reached the auxiliary log-buffer
browser but exited on CDP `Execution context was destroyed.` before the remaining
assertions. The helper had started an asynchronous evaluation while the newly
created tab was still replacing its document. It now creates the tab at
`about:blank`, attaches CDP before explicit navigation, waits for load, and polls
connectivity with short synchronous evaluations. The final rerun above completed
the genuine second LiveView connection, pause/buffer/resume checks and all later
assertions. No product assertion or JavaScript error gate was removed or relaxed.
The disposable wrappers stopped their Management, PostgreSQL and fixture servers.

The successful Nix command was:

```sh
nix build -L --no-link --print-out-paths \
  path:/tmp/yellow-dog-step3-step4/nix-step3-source-cyq8b24j#packages.x86_64-linux.yellow_dog_management \
  path:/tmp/yellow-dog-step3-step4/nix-step3-source-cyq8b24j#packages.x86_64-linux.yellow_dog_worker \
  path:/tmp/yellow-dog-step3-step4/nix-step3-source-cyq8b24j#packages.x86_64-linux.docker-management \
  path:/tmp/yellow-dog-step3-step4/nix-step3-source-cyq8b24j#packages.x86_64-linux.docker-worker
```

The clean snapshot includes tracked repair changes and new Management Elixir/test
files, excluding supplied untracked plans. It predates the final View/ACL
initial-recovery and harness refinements; its successful build proves packaging
with the corrected dependency hash, not exact final-source image acceptance.
The outputs are Management `/nix/store/773sz4avk373x3nqv1zhq1cxg4vp681y-yellow_dog_management-1.2.12`,
Worker `/nix/store/76vfzwffypi6889lwd7ymvn8wn45nnfy-yellow_dog_worker-1.2.12`,
Management image `/nix/store/7z9ksq1nxpgzs677rv9fwjbhbhkh00ng-yellow_dog_management.tar.gz`
and Worker image `/nix/store/vk399ciygzjmig6cxia8amsg7brbd2hl-yellow_dog_worker.tar.gz`.
Image metadata records Linux/amd64 and the corresponding product entrypoints.

The same four attributes under `packages.aarch64-linux` were attempted and failed
on platform mismatch. Independently,
`sha256sum /tmp/yellow-dog-step3-step4/mdex-aarch64.so.tar.gz` produced
`f321e6c8a121a9ca8f10dad784940c70440e4670d54e0d3ccd54eb30f489f5c4`, matching
the declared native input hash. That verifies the downloaded input only; no ARM
build, image execution or target-host runtime acceptance is claimed. ARM execution
requires a configured native builder, and final delivery requires fresh-source
package/image verification after subsequent changes.
