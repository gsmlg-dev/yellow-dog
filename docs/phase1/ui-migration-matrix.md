# Console functionality migration matrix

## Current source-only task boundary (2026-10-04)

After the architecture-only slice, the user explicitly authorized migrating UI
code directly into the current Management UI directory, with compilation or
runtime failure acceptable because the UI will be redesigned later. Source is
migrated under `YellowDog.ManagementUI.Redesign` in the compiled `lib/` tree to
avoid overwriting existing native Management pages. No old runtime, transport,
backend service, login or compatibility route is connected by this transfer.
Source completeness is the acceptance gate; full functional migration below
remains future work, not a claim about this source-only transfer.
All 201 transferred files and their exact revisions are recorded in
`ui-source-migration.json`; the current/historical page union, component/helper
coverage and verification procedure are described in `ui-source-migration.md`.
Differing current/historical live and home presentation source is retained separately;
selecting a single revision per path is not proof of complete UI source coverage.

## Prior architecture-only boundary (2026-10-04)

The user narrowed the current task to architecture restoration only. The full
functional inventory below remains future work, not this task's acceptance gate.
Management owns configuration authoring; network services execute on Worker.
Netboot and Identity belong exclusively to Worker, not Management provisioning
or central identity/trust services. Management configuration UI does not imply
service execution, observed state or authority. Worker runtime failures are
acceptable for this task and remain deferred, not passing.

## Acceptance contract

Retain and redevelop the original Console's configuration workflows inside
standalone PostgreSQL Management, with network-service functions owned by Worker.
Future functional acceptance follows usable business workflows and their real
data/effects, not the number of original routes, exact HTTP APIs/event names,
legacy identifiers, old backup formats or software-version migration adapters.
Previous/forward software-version compatibility is not a design-stage goal.
Matching colors, retained navigation, disabled controls, substitute pages and
unrelated all-green test totals do not complete a feature.

- HTTP defaults to port 4270; the requested development listener binds 0.0.0.0.
- UI and business APIs require no login. Signed LiveView sessions provide CSRF
  protection only, not authentication.
- Do not start or depend on the legacy Console, ManagementCore, Store, or Agents.
- Actual Worker state remains unknown until genuine observations exist. A
  prepared target is not an applied target; logical records are not online nodes.
- Existing configuration drafts, immutable versions, assignments, idempotency,
  audit persistence, and TOML exports must remain functional during migration.
- Pending service domains and observation contracts need concrete business and
  ownership decisions. Blanket approval of new PostgreSQL tables was an
  assistant-imposed restriction, not a user mandate. Explicit Mnesia,
  shared-protocol and global-loading confirmation rules still apply.
- The coordinator removed legacy redirects, reserved-ID workarounds and the
  static workspace. None is a compatibility requirement or
  business-completion criterion. Use explicit current identity and navigation.

## Current implementation versus complete migration

The first implementation slice reuses the original Phoenix/DuskMoon navigation,
sidebar, theme switcher, notifications, shared components, and browser hooks under
`YellowDog.ManagementUI`. New LiveViews call the existing Management Domain for
logical Worker registration/editing, desired DNS service instances, shared Zones,
immutable resource versions, assignments, target preview/confirmation/export,
and durable audit inspection. The coordinator removed the former static workspace;
do not migrate or preserve it as a second UI.

This is **not** complete business redevelopment. The historical inventory below
is a source lookup aid, not a list of endpoints to restore. Its coverage labels
record the earlier audit, not a current route-availability promise. A partial
business area has working adapted operations but still lacks original functions.
The second slice adds individual SOA/NS/A
record create/edit/delete, atomic bounded JSON bulk append, and validated
WorkerPlan TOML Zone import with resource selection. Existing revisions, audit
entries, immutable versions and historical exports remain authoritative. Unknown
Worker scopes cannot mutate shared Zones. Other record types, view selection,
provider-source import, ACLs, providers and runtime telemetry still require
redevelopment; these routes are partial, not full Console parity.
Process Map now reuses the original interactive SVG against the actual
Management supervisor, with scoped tests and real Chromium evidence. It does not
claim remote Worker process observations.

The next slice restores actual Management Logger streaming and real MMDB GeoIP
lookup, metadata inspection, configured-file reload and confirmed memory unload.
Logs support application/severity filtering, search, pause/resume, metadata,
view-only clearing and CSV export. These are local Management observations and
cacheable artifacts, not fabricated Worker state. Worker/service log sources
remain unimplemented. Task history and GeoIP download/synchronization are
implemented by the later task slice below.

The subsequent slice adds real immutable target history at `/management/config`
and a Management-owned MAC/OUI snapshot shared by the Tool and Database pages.
Config history uses PostgreSQL metadata without fetching plan bodies or inventing
apply/rollback observations. MAC source/count/load-time/file information, refresh,
lookup and compatible-file reload work; lossless overlapping-prefix imports are
blocked upstream and durable sync jobs remain pending. Both routes are partial.

The original read-only `/management/profiles` catalog now preserves all six
Server and seven Netman presets, exact descriptions/default flags and Netman apply
modes. It has no edit/registration form, database writes, legacy dependency or
agent startup. Presets describe historical defaults, not current Worker support.
This restores that original catalog function, not Netman network-profile editing.

Legacy aliases and reserved-ID escape paths are historical navigation evidence
only and have been removed by the coordinator. Preserving their redirects was
not business-function completion. Netman desired configuration is described below;
runtime observations and wider service functions remain pending. Do not retain
an alias merely to make an inventory green.
Zone, record and import navigation now obtains identity from decoded matched
route parameters, not query parameters. Global routes stay global even when a
query names a Worker or contains arrays/maps; scoped route IDs stay authoritative.
Unknown/invalid scoped Workers continue to block mutations of shared resources.

## Current Netman desired-configuration implementation

The PostgreSQL `management_netmans`, `management_netman_config_drafts` and
`management_netman_config_versions` tables now back logical node metadata,
typed Ethernet profiles, desired Resolved settings and immutable publication
history. Draft replacement uses an independent configuration revision, validates
the whole candidate, and commits through the existing atomic audit/idempotency
gateway. Metadata changes preserve registration time and do not increment the
configuration revision. Preset selection supplies real catalog flags/mode.

Canonical pages are the Management/Netman selector, scoped node metadata,
profile configuration and Resolved desired settings. All scoped IDs derive from
matched paths. Publication records prepared/unknown state; desired rollback
copies a stored version into a new draft revision and a new immutable publication.
Neither operation delivers configuration or alters the Management host network.
Observe-only mutations are rejected server-side, not only disabled in the UI.

This redevelops the desired-data functions from the original Netman configuration
pages, not their runtime operations. Actual profile activation, runtime history
and rollback, interfaces, DHCP lifecycle, resolver cache inspection/flush, and
genuine last-seen/online/apply observations remain pending. No new executable
Netman contract or competing WorkerPlan export has been introduced.

## Current Management overview and durable event views

The overview now restores the original Profiles and Recent Events widgets while
retaining the current Worker/Netman/Zone statistics and configuration links.
Profiles counts the pure six Server and seven Netman presets; recent events
shows exactly the latest five PostgreSQL audit identities, operations, actors
and timestamps. Explicit refresh reloads all widgets without a mutation.

Events retains the complete latest-100 audit/detail view and adds Worker/Netman
desired-event groups and command outcomes from those same retained records.
Global Zone/task/backup events remain visible. `committed` and `rejected` describe
the actual desired-domain transaction, not delivery, Worker application or job
completion. A successful queued backup's `error: null` is not a rejection.
Nonpersisted requests are not fabricated into outcomes; external execution and
runtime-event observations remain pending.

Executed scoped checks: 12 Overview/Events tests, no failures, plus
warnings-as-errors compilation and owned-file formatting. Current real release
evidence: `/tmp/management-overview-release-_swqiqzn` and
`/tmp/yellow-dog-phase1-pg.fLjjLu`, from
`devenv shell -- scripts/e2e/phase1_postgres.sh scripts/e2e/management_overview.sh`.
Chromium exercises logical Worker/Netman registration, actual counts, all 13
presets, catalog/events navigation, actual duplicate-Worker and malformed-Zone
command rejection, details
and acknowledged LiveView refresh. Latest-five identities/actors/operations/time
and transaction outcomes are cross-checked against PostgreSQL. The still-mounted
overview is checked after refresh; read-only refresh is repeated after SIGKILL
under a protected persistent-table snapshot. All current public and
`management_jobs` tables remain identical except intentionally excluded ephemeral
`oban_peers`. Mobile Overview and no-login checks also pass. This is not evidence
that the remaining service/provider/runtime functions have been migrated.

Development deployment restarts `yellow-dog-management-dev.service` with no
schema change. The updated Overview/Events pages return HTTP 200 without login;
the observed listener is `0.0.0.0:4270` (BEAM PID `2846358`). All 19 current
persistent PostgreSQL tables match the before/after Unix-socket snapshots at
`/tmp/management-overview-deploy-d3mkvjmc`; only ephemeral Oban peer state is
excluded. Task schedules stay disabled and no jobs are queued. This is recorded
deployment evidence, not a promise about a future process ID.

## Current Worker catalog profile implementation

The `/server` and `/management/servers` selectors now include a Profile column
and registration selection for all six pure Server catalog names. Dashboard
editing saves name and profile through the existing Worker aggregate CAS.
`profile_name` defaults to `custom`; both Domain validation and a PostgreSQL
constraint reject unknown names. An omitted edit retains the stored profile.
Successful browser registration resets the form/profile to `custom`.

These labels never enable preset services, change expected capabilities,
assignments or immutable target/export content, or fabricate runtime support.
Connected observations and wider service functions remain pending. The original
Management Server listing at `8550aa05` was read-only and had no arbitrary
metadata editor; a backend metadata field is not evidence of a missing UI
workflow. This is current business functionality, not an old-payload or
software-version compatibility layer.

Scoped backend/UI verification executes:

```sh
devenv shell -- scripts/e2e/phase1_postgres.sh mix do --app yellow_dog_management cmd mix test test/worker_profiles_test.exs test/worker_profiles_live_test.exs
```

Result: 14 tests, zero failures, disposable PostgreSQL evidence at
`/tmp/yellow-dog-phase1-pg.mC7agt`. Checks cover all presets/defaults, omission,
rejection, route authority, CAS, idempotency and preservation of existing DNS,
assignments, immutable history and export bytes. App-local strict compilation,
owned-file format and Management asset regeneration also pass.

Real release acceptance executes:

```sh
devenv shell -- env MIX_ENV=prod ERL_FLAGS='+S 2:2 +A 2' mix release yellow_dog_management --overwrite
devenv shell -- env BUILD_RELEASE=0 scripts/e2e/phase1_postgres.sh scripts/e2e/management_worker_profiles.sh
```

Both commands pass. Evidence: `/tmp/management-worker-profiles-release-0yv0d3a6`
and `/tmp/yellow-dog-phase1-pg.Yw7Sl6`. Real Chromium covers registration/reset,
stored Profile display, name/profile editing, stale CAS, unknown profile rejection,
route/query authority, mobile layout, DuskMoon styling and no-login access.
Independent concurrent HTTP requests produce one commit and one conflict; native
SQL rejects an invalid catalog name. Selecting `dhcp_only` on a DNS fixture leaves
its stopped service, capabilities, assignments, immutable history and TOML bytes
unchanged. SIGKILL/restart plus read-only browser replay preserve all persistent
tables except excluded ephemeral `oban_peers`. Export SHA-256 remains
`51c42f4493fc698a795867c6a4588443caae8614f3e92e99e256094358861adf`.
Development deployment applies the profile migration with `devenv shell -- mix
ecto.setup`, then restarts `yellow-dog-management-dev.service`. The observed
listener is `0.0.0.0:4270` (BEAM PID `2858680`); selector, overview, events,
catalog and Worker API return HTTP 200 without login. Fresh real Chromium checks
both connected selectors at desktop/mobile sizes, all six presets, `custom`
default and bundled styling without writes. Unix-socket PostgreSQL before/after
snapshots and the pre-migration dump are at
`/tmp/management-worker-profiles-deploy-31_68grm`. All 19 persistent tables remain
equal after accounting for the added schema-migration row and profile column;
ephemeral `oban_peers` is excluded. The local Worker list remains empty, schedules
disabled and jobs empty. No release-smoke fixtures are added to the development
database. This evidence establishes this slice only, not full Console parity.

## Current global Zone and Record catalog controls

The current reusable global Zone library now retains case-insensitive name
filtering, displayed/total count, read-only refresh and filtered CSV. CSV reads
current drafts and reports actual record counts; runtime queries are explicitly
unavailable, never fabricated zero. Deletion requires a selected draft/revision
and explicit confirmation; cancellation and mismatched confirmation do not write.
Refresh preserves entered editor fields and their original CAS revision, rather
than silently making stale input current. Archival retains immutable versions.

Zone draft changes now restore the original editor's live validation function
(`8550aa05`, `DnsLive.ZoneLive.Index.validate_zone`). The current SOA/NS/A
candidate uses the same pure `ConfigSpec.normalize_resource/1` validator as
Domain, with accessible field-path/message feedback and Save disabled for
invalid content. Adding/removing records revalidates without losing unsaved
fields. Correction clears errors; cancellation and reopening discard unsaved
input. These interactions do not mutate drafts, Audit or Idempotency receipts.
Submission still validates independently in Domain and uses the original CAS;
validation/history refresh never silently rebases an edit. Confirmed versions,
assignments and prepared export bytes remain unchanged by draft validation.
This restores current authoritative draft authoring only, not wider Zone types,
View ownership, BIND import or runtime service execution.

Records now retain owner/type filters, displayed/total count, read-only refresh,
filtered CSV and full-Zone BIND export. A filtered row keeps its original validated
ordinal, not its display position. BIND includes every canonical SOA/NS/A draft
record even when CSV/display filters match only one A record. It downloads as
text, not mislabeled CSV, and is desired draft content—not observed Worker data.
Refreshing a changed draft while editing marks the editor stale and preserves
its unsaved form/CAS identity; saving requires an explicit reload, not silent retry.

The canonical-JSON Bulk Add editor now restores the missing live preview step:
pure shared validation of the full existing-plus-new candidate precedes canonical
appended-row display, per-type counts, existing/new/total counts and original
revision. Preview/invalid input/cancellation never dispatch a mutation or create
audit/idempotency receipts. Save requires the exact reviewed source and original
CAS; it does not silently generate a preview on submission. Refresh or a save
conflict invalidates a stale preview and preserves entered source. BIND preview/
create/append remains a separate required, upstream-blocked function, not replaced
by this JSON editor. Existing native browser record-delete confirmation is
retained rather than rebuilding a second confirmation interface.

Acceptance (2026-10-01): 70 scoped Zone/Records/export/import UI checks pass,
along with strict dev/prod compilation, scoped formatting, assets and release.
`/tmp/management-dns-catalog-release-8vo42i7s` records real Chromium filtered CSV
and full BIND file downloads, original-ordinal links, read-only filters/refresh,
delete cancellation/confirmation and immutable history preservation. SIGKILL
restart replays only reads at desktop/mobile sizes and leaves persistent data
unchanged. `named-checkzone` is not installed and was not claimed as validation.

Local deployment evidence `/tmp/management-dns-catalog-deploy.ySVoDs` confirms
all 21 persistent tables are byte-for-byte unchanged in normalized snapshots,
including migration receipts and immutable histories. No fixtures are inserted;
the Zone library stays empty. The restarted listener is `0.0.0.0:4270` without
login, and the actual served bundle contains the native text-download handler.

### Canonical-JSON bulk preview acceptance (2026-10-02)

The final scoped check executes:

```sh
devenv shell -- scripts/e2e/phase1_postgres.sh mix do --app yellow_dog_management cmd mix test test/records_live_test.exs test/records_bulk_preview_live_test.exs test/dns_record_exports_test.exs test/zones_live_test.exs test/zone_import_live_test.exs
devenv shell -- env BUILD_RELEASE=0 scripts/e2e/phase1_postgres.sh bash scripts/e2e/management_dns_catalog.sh
```

Result: **83 scoped checks, zero failures**, PostgreSQL evidence
`/tmp/yellow-dog-phase1-pg.IRBwXS`; strict dev/prod compilation, owned-file
formatting, assets and the root Management release also pass. A positive test
with a real logical Worker, stopped Service, assigned confirmed version and
prepared target proves preview/append preserves those nonempty records and the
exact existing TOML/plan/digest, not merely empty Worker tables.

Real Chromium release evidence `/tmp/management-dns-catalog-release-6s8t3z46`
and PostgreSQL `/tmp/yellow-dog-phase1-pg.1P7eqQ` cover canonical preview/counts,
invalid-input invalidation and disabled save, explicit append, individual edit,
native record-delete cancellation/acceptance and stale cached-CAS rejection.
The selected record's ordinal changes after a concurrent insertion; the stale
action cannot retarget or silently retry. Native confirmation was already
implemented through Phoenix.HTML; no duplicate confirmation UI is introduced.
Actual SQL rows, six corresponding command outcomes/receipts, unaffected records
and immutable history are checked. Both viewport sizes render and photograph
the new bulk preview; previews and SIGKILL read-only replay leave persistent
data unchanged. This evidence does not claim BIND import or connected execution.

Development deployment evidence `/tmp/management-bulk-preview-deploy.9I2VHh`
shows all 21 persistent tables unchanged before/after, excluding only ephemeral
Oban peers. No fixtures, schema or protocol changes are applied. The restarted
unit is active, listening `0.0.0.0:4270` (observed PID `2960914`), and the Zone
page returns HTTP 200 without authentication. Local Workers and Zones stay empty.

This is not the complete DNS Zone/Records migration: Service/View ownership and
same-apex isolation, forward/stub/cache/RPZ/cloud controls, additional RR types,
BIND import/preview and provider effects remain pending. Worker-route navigation
still operates on the explicitly labeled global library; it is not a View binding.

### Zone editor live validation acceptance (2026-10-02)

The focused command below passes **31 tests**, including nine new validation
checks and the existing Zone workflows:

```sh
devenv shell -- scripts/e2e/phase1_postgres.sh mix do --app yellow_dog_management cmd mix test test/zone_validation_live_test.exs test/zones_live_test.exs
```

Strict dev/prod compilation, scoped formatting, regenerated Management assets
and the root Management release pass. The actual browser command is:

```sh
devenv shell -- env BUILD_RELEASE=0 scripts/e2e/phase1_postgres.sh bash scripts/e2e/management_dns_catalog.sh
```

`/tmp/management-dns-catalog-release-_plz53om` and disposable PostgreSQL
`/tmp/yellow-dog-phase1-pg.R0boUc` retain desktop/mobile validation screenshots
before and after SIGKILL recovery. Real change events cover invalid apex, A, TTL,
SOA and out-of-zone owner input, disabled Save, corrected fields, blank-record
add/remove and cancellation/reopening. Exact persistent SQL/API/version/BIND
bytes remain unchanged by those interactions. Existing append/edit/delete and
stale-CAS checks remain intact. The test downloader tracks fresh completed CDP
download GUIDs because Chromium overwrites repeated filenames; it no longer
mistakes a completed repeated download for a missing file.

Development evidence `/tmp/management-zone-validation-deploy._a9ubqi0` shows
all 21 persistent tables unchanged across restart, excluding only ephemeral
Oban peers. The updated editor returns unauthenticated HTTP 200; the actual
listener remains `0.0.0.0:4270` (observed listener PID `2977491`). No schema,
ConfigSpec/protocol change, fixture insertion or compatibility layer is added.
This authoring slice does not complete the pending execution/ownership work.

### BIND source audit and upstream blockers (2026-10-02)

Historical BIND import creates a Zone or **appends** to an existing Zone; replacing
the existing draft is not a substitute for that business function. Native BIND
preview/create/append remain unimplemented. The current pure parsers block
lossless import: the AST parser rejects valid single-line SOA/inherited owners
([ex_dns#5](https://github.com/gsmlg-dev/ex_dns/issues/5)); FileParser drops unknown
records/errors and corrupts SOA/inherited-owner data
([ex_dns#6](https://github.com/gsmlg-dev/ex_dns/issues/6)). Both are upstream
`Bug`/`internal request` blockers; no local parser workaround is introduced.

The standalone, unskipped `scripts/e2e/management_bind_parser_gate.exs` preserves
these fidelity requirements without starting services or adding `ex_dns` to the
Management release. See [source evidence and pending decisions](dns-bind-import-audit.md).
Permission to use the pure library, additional shared record types and View–Zone
ownership remain distinct pending decisions. This audit is not BIND completion.

## Current DNS View desired data

The historical editor at `8550aa05` supplies the full View business inventory;
the simplified current legacy form is insufficient. Native Management Views
use an explicit Worker/DNS Service selection and UUID/CAS, with create/edit/
cancel, desired status toggles, confirmed delete/cancel, read-only refresh,
name/status filtering, displayed/total count and CSV of filtered Views only.
The editor includes immutable name, numeric priority, recursion/ECS, ordered
inline client rules, country search/selection/removal/append, safe empty-editor
recipes, ordered IPv4/IPv6 fallback endpoints, timeout and retries.

Default provisioning is transactional on DNS Service creation and backfills
existing Services. Default name/policy/infinite priority are protected consistently
and deletion is rejected; enabled remains desired-editable. Partial edits preserve
all omitted settings. Lists, refresh and startup never provision or reset data.
The grammar and pure rule validator are shared with named ACLs, not duplicated.

This is not full View parity: View-Zone same-apex ownership, RPZ bindings, actual
evaluation/recursion/ECS/forwarding and shared WorkerPlan mapping remain pending.
No legacy route, identity, payload or runtime-configuration adapter is introduced.
The new selected-Service UI is `/server/:server_id/dns/views/:service_id`;
API reads use `/api/workers/:worker_id/dns-services/:service_id/views` and writes
use the idempotent native `create_dns_view`, `update_dns_view`, `delete_dns_view`.
Edits leave Worker revisions, Service configs, immutable targets and exports alone.

Current desired-data acceptance (2026-10-01): 77 scoped View/ACL domain, LiveView
and API checks pass, with strict dev/prod compilation and scoped formatting.
Disposable release evidence `/tmp/management-dns-views-release-c0l9u09q` covers
default backfill/provisioning, actual Chromium CRUD/CAS, ordered country rules
and IPv6 endpoints, default protections, filtering/real CSV downloads, independent
HTTP concurrency/idempotency and SIGKILL read-only replay at desktop/mobile sizes.
All unrelated persistent tables and target previews remain unchanged.

The browser exposed a real editor bug: native `form.reset()` erased a correctly
patched textarea because its `defaultValue` was still empty. Views now send
explicit server field values to a native form-sync event; the saved-endpoint
assertion is retained. This is not an old-payload/version adapter. A separate
browser-harness multiline JavaScript escaping error was corrected without
weakening business checks. ACL schema integrity is scoped to its own migration,
so subsequent View provisioning is not misclassified as an ACL data mutation.

Development deployment evidence `/tmp/management-views-deploy.kT21Dj` preserves
all 20 previous persistent tables except the new migration receipt, creates no
fixtures (Workers/Views remain empty), and verifies unauthenticated HTTP plus
the actual listener at `0.0.0.0:4270`. View-Zone/RPZ/execution parity remains pending.

## Current named DNS ordered-rule ACL data

The named ACL form is redeveloped as PostgreSQL-owned desired data
on an explicit existing Worker DNS Service. A Service selector never infers the
first Service, even when only one exists. The scoped page provides create,
edit/rename, read-only refresh, editor reset and server-confirmed deletion with
cancel. Worker/Service scope is route-authoritative; native UUID identity and
independent ACL revision CAS prevent retargeting or stale writes. Existing
audit/idempotency receipts and Worker desired-event grouping record real
committed/rejected commands, not runtime enforcement.

The single current contract has `description` and ordered `rules`, replacing
flat action/networks fields without an old-payload adapter. Each rule has an
explicit `allow|deny` action and one `any`, `networks` or `countries` matcher.
Mixed rules keep their order; exact IPs normalize to host CIDRs. Countries are
validated against one pure Management catalog and normalized inside their rule.
Descriptions are bounded to 255 Unicode codepoints; limits are 128 rules and
128 total networks. PostgreSQL also validates exact rule shapes/actions,
canonical IPv4/IPv6 networks, country syntax, uniqueness, positive revisions and
native Service references. Empty lists/network sets remain empty, not catch-all.
This slice
does not alter Worker revisions, desired DNS Services, Zones, assignments or
immutable targets/export bytes. It adds no shared ConfigSpec fields, Worker
execution, attachment, policy sidecar or version-compatibility adapter.

The editor has descriptions, multiline ordered rules, inline validation,
searchable country checkboxes/removable badges, safe append without discarding
typed rules, and built-in recipes that fill only an empty editor. Name and
description filtering changes display only; CSV exports all ACLs in the selected
Service, using spreadsheet-safe escaping. Recipes persist as ordinary rules,
not active global builtins or named-reference evaluation.

**Full ACL functionality remains incomplete.** View ACL editing/binding and
actual ordered/Geo matching, evaluation/enforcement and shared executable export
remain pending. Rich desired data does not claim those runtime effects.

Ordered-rule acceptance (2026-10-01): 45 current ACL backend/UI/API checks plus
8 IP Database checks pass at `/tmp/yellow-dog-phase1-pg.97kll2`; the final
primary-save button ordering change passes all 18 UI checks again at
`/tmp/yellow-dog-phase1-pg.JeFUZK`. Strict compilation, scoped formatting, shell
and JavaScript syntax pass, and assets/the production release are rebuilt.
The updated `management_dns_acls.sh` also checks the forward reshaping of this
Management domain's own current table in a separate disposable UTF8 database;
empty allow/deny sets, IPv4/IPv6 entries, UUIDs, revisions, timestamps and all
non-ACL data remain intact. No former columns or request adapters remain.
Migration evidence is `/tmp/management-dns-acl-rules-migration-f7c73jao`.

Fresh independent HTTP/PG updates prove one persisted winner, one
`revision_conflict`, and exactly one revision increment. Actual Chromium
exercises mixed ordered rules/descriptions, exact-IP normalization, country
code/name search with retained selections/removable badges, safe append,
empty-only presets and rejected replacement, inline validation, stale CAS,
rename/reset, confirmed/canceled deletion, explicit scoping, filtered display
and an actual whole-Service spreadsheet-safe CSV download. SIGKILL restart and
read-only browser replay preserve every persistent table (excluding ephemeral
Oban peers) and immutable target/export bytes. Latest release evidence:
`/tmp/management-dns-acls-release-g6sql687`, PostgreSQL:
`/tmp/yellow-dog-phase1-pg.P3mxO0`. These checks prove desired-data workflows,
not View attachment or ACL enforcement.

Executed current commands:

```sh
devenv shell -- scripts/e2e/phase1_postgres.sh mix do --app yellow_dog_management cmd mix test test/dns_acls_test.exs test/dns_acls_live_test.exs test/dns_acls_web_test.exs test/ip_database_live_test.exs
devenv shell -- env BUILD_RELEASE=0 scripts/e2e/phase1_postgres.sh scripts/e2e/management_dns_acls.sh
```

Development applies `20261001050000` with `devenv shell -- mix ecto.setup`
and restarts `yellow-dog-management-dev.service`. The final observed listener
is `0.0.0.0:4270` (BEAM PID `2902929`), without login; `/api/workers` remains
empty. Unix-socket PostgreSQL dump/snapshots and read-only desktop/mobile Chromium
evidence at `/tmp/management-rich-acls-deploy-K3drSA` preserve all 20 persistent
tables except the new schema-migration receipt, with no Workers, ACLs or jobs and
all schedules disabled. Browser inspection verifies both direct IP queue controls
and honest unknown-scope ACL errors without submitting mutations. No disposable
job, Worker, ACL or MMDB fixture is inserted into the development database.

Earlier CIDR-only acceptance (before the ordered-rule extension):

```sh
devenv shell -- scripts/e2e/phase1_postgres.sh mix do --app yellow_dog_management cmd mix test test/dns_acls_test.exs test/dns_acls_live_test.exs test/dns_acls_web_test.exs
devenv shell -- env BUILD_RELEASE=0 scripts/e2e/phase1_postgres.sh scripts/e2e/management_dns_acls.sh
```

The scoped suite passes 28 tests at `/tmp/yellow-dog-phase1-pg.UE8paf`.
Strict app-local compilation and owned-file formatting pass; assets and the
source-current production release are rebuilt before the second command.
Real release evidence is `/tmp/management-dns-acls-release-oiz_i_6i` and
`/tmp/yellow-dog-phase1-pg.n6ZTgt`. Independent HTTP/PG updates produce one
commit/one conflict; native SQL rejects invalid action/CIDR data. Actual Chromium
covers CRUD/rename/reset, stale CAS, invalid-CIDR feedback, confirmation/cancel,
route/query isolation, explicit one/two-Service selection, styled desktop/mobile
UI and no-login access. SIGKILL restart plus read-only browser replay preserves
all persistent public/`management_jobs` rows except excluded ephemeral
`oban_peers`, including unchanged immutable DNS targets/export bytes.
Development applies the ACL migration with `devenv shell -- mix ecto.setup` and
restarts `yellow-dog-management-dev.service`. The observed listener remains
`0.0.0.0:4270` (BEAM PID `2875124`), without login. Unix-socket PostgreSQL
snapshots and the pre-migration dump at
`/tmp/management-dns-acls-deploy-zs9ahfsf` show all 19 existing persistent tables
unchanged apart from the new migration receipt; the added ACL table is empty.
Fresh Chromium connects to both unknown-Worker ACL routes at desktop/mobile
sizes, displays the actual scope error and no editor, and verifies bundled
styling without mutations. The unknown-scope API returns a genuine 404.
The final protected snapshot preserves all 20 persistent tables after those
read-only checks. Local Workers/ACLs stay empty, schedules disabled and jobs empty;
disposable smoke fixtures never enter the development database. This establishes
deployment of the desired-data slice only, not pending execution or full ACL parity.

## Historical route inventory (reference only)

Source: `apps/yellow_dog_console/lib/yellow_dog/console/router.ex`, current
checkout. Inventory contains 130 routes (91
LiveView route/action entries); those counts are not acceptance targets.
Development-only LiveDashboard is listed separately as optional diagnostics.
Paths, APIs, redirects and last-recorded statuses here locate original source;
they do not require current URL/API compatibility. In particular, historically
restored redirects and removed static pages are not current supported functions.

| Method | Original path | Original implementation / action | Historical function-coverage note |
| --- | --- | --- | --- |
| GET | `/` | `PageController` / home | Partial adaptation; original action parity pending |
| LIVE | `/management` | `ManagementLive.Index` / overview | Real Worker/Netman/Zone statistics, all 13 pure preset count, latest-five durable audits and read-only refresh; genuine runtime observations remain pending |
| LIVE | `/management/servers` | `ManagementLive.Index` / servers | Partial adaptation; original action parity pending |
| LIVE | `/management/netman` | `ManagementLive.Index` / netman | Logical registration/metadata, typed desired profiles/Resolved settings and immutable desired history implemented; runtime observations/activation remain pending |
| LIVE | `/management/profiles` | `ManagementLive.Index` / profiles | Original read-only Server/Netman catalog restored; all 13 preset descriptions/defaults and Netman apply modes; no runtime activation |
| LIVE | `/management/config` | `ManagementLive.Index` / config | Prepared Worker targets and Netman desired versions/rollback history with refresh; genuine apply/failure/runtime rollback observations remain pending |
| LIVE | `/management/events` | `ManagementLive.Index` / events | Retained latest-100 audit/details, Worker/Netman desired groups and actual committed/rejected transaction outcomes; remote/runtime/job outcomes remain separate and pending |
| GET | `/management/blobs/:sha256` | `ManagementBlobController` / show | Not migrated |
| LIVE | `/server` | `ServerLive.SelectorLive` / default | Partial adaptation; original action parity pending |
| GET | `/server/settings/dns` | `ServiceRedirectController` / server | Original explicit-selector redirect restored; scoped Settings functionality pending |
| GET | `/server/settings/mdns` | `ServiceRedirectController` / server | Original explicit-selector redirect restored; scoped Settings functionality pending |
| GET | `/server/settings/dhcpv4` | `ServiceRedirectController` / server | Original explicit-selector redirect restored; scoped Settings functionality pending |
| GET | `/server/settings/dhcpv6` | `ServiceRedirectController` / server | Original explicit-selector redirect restored; scoped Settings functionality pending |
| GET | `/server/settings/netboot` | `ServiceRedirectController` / server | Original explicit-selector redirect restored; scoped Settings functionality pending |
| LIVE | `/server/:server_id/dashboard` | `DashboardLive` / default | Partial adaptation; original action parity pending |
| LIVE | `/server/:server_id/dns` | `DnsLive.Index` / default | Partial adaptation; original action parity pending |
| LIVE | `/server/:server_id/dns/zones` | `DnsLive.ZoneLive.Index` / index | Partial adaptation; original action parity pending |
| LIVE | `/server/:server_id/dns/zones/new` | `DnsLive.ZoneLive.Index` / new | Partial adaptation; original action parity pending |
| LIVE | `/server/:server_id/dns/zones/import` | `DnsLive.ZoneLive.Index` / import | WorkerPlan TOML import; provider-source workflow pending |
| LIVE | `/server/:server_id/dns/zones/:zone_id/edit` | `DnsLive.ZoneLive.Index` / edit | Partial adaptation; original action parity pending |
| LIVE | `/server/:server_id/dns/zones/:zone_id/records` | `DnsLive.RrLive.Index` / index | SOA/NS/A list/delete; other types and views pending |
| LIVE | `/server/:server_id/dns/zones/:zone_id/records/new` | `DnsLive.RrLive.Index` / new | SOA/NS/A create; other types and views pending |
| LIVE | `/server/:server_id/dns/zones/:zone_id/records/bulk` | `DnsLive.RrLive.Index` / bulk | Atomic canonical JSON append; other types and views pending |
| LIVE | `/server/:server_id/dns/zones/:zone_id/records/:rr_index/edit` | `DnsLive.RrLive.Index` / edit | SOA/NS/A edit with revision checks; other types and views pending |
| LIVE | `/server/:server_id/dns/views` | `DnsLive.ViewLive.Index` / index | Native explicit DNS Service selector; desired View workflows under selected Service |
| LIVE | `/server/:server_id/dns/views/new` | `DnsLive.ViewLive.Index` / new | Redeveloped inline creation in Service-scoped Views; no old URL adapter |
| LIVE | `/server/:server_id/dns/views/:view_name/edit` | `DnsLive.ViewLive.Index` / edit | Redeveloped UUID/CAS inline editor; View-Zone/RPZ execution remains pending |
| LIVE | `/server/:server_id/dns/acl` | `DnsLive.AclLive` / default | Not migrated |
| LIVE | `/server/:server_id/dns/logs` | `DnsLive.QueryLogsLive` / default | Not migrated |
| LIVE | `/server/:server_id/dns/metrics` | `DnsLive.MetricsLive` / default | Not migrated |
| LIVE | `/server/:server_id/dns/providers` | `DnsLive.ProviderLive.Index` / default | Not migrated |
| LIVE | `/server/:server_id/dns/providers/new` | `DnsLive.ProviderLive.Index` / new | Not migrated |
| LIVE | `/server/:server_id/dns/providers/:name` | `DnsLive.ProviderLive.Show` / default | Not migrated |
| LIVE | `/server/:server_id/dns/providers/:name/edit` | `DnsLive.ProviderLive.Show` / edit | Not migrated |
| LIVE | `/server/:server_id/dns/providers/:name/conflicts` | `DnsLive.ProviderLive.ConflictLive` / default | Not migrated |
| LIVE | `/server/:server_id/dhcpv4` | `Dhcpv4Live.Index` / default | Not migrated |
| LIVE | `/server/:server_id/dhcpv4/leases` | `Dhcpv4Live.LeasesLive` / default | Not migrated |
| LIVE | `/server/:server_id/dhcpv4/pools` | `Dhcpv4Live.PoolsLive` / default | Not migrated |
| LIVE | `/server/:server_id/dhcpv4/pools/:pool_name` | `Dhcpv4Live.PoolLive` / default | Not migrated |
| LIVE | `/server/:server_id/dhcpv4/activity` | `Dhcpv4Live.ActivityLive` / default | Not migrated |
| LIVE | `/server/:server_id/dhcpv6` | `Dhcpv6Live.Index` / default | Not migrated |
| LIVE | `/server/:server_id/dhcpv6/leases` | `Dhcpv6Live.LeasesLive` / default | Not migrated |
| LIVE | `/server/:server_id/dhcpv6/pools` | `Dhcpv6Live.PoolsLive` / default | Not migrated |
| LIVE | `/server/:server_id/dhcpv6/pools/:pool_name` | `Dhcpv6Live.PoolLive` / default | Not migrated |
| LIVE | `/server/:server_id/dhcpv6/activity` | `Dhcpv6Live.ActivityLive` / default | Not migrated |
| LIVE | `/server/:server_id/mdns` | `MdnsLive.Index` / default | Not migrated |
| LIVE | `/server/:server_id/mdns/services` | `MdnsLive.ServicesLive` / default | Not migrated |
| LIVE | `/server/:server_id/mdns/discovery` | `MdnsLive.DiscoveryLive` / default | Not migrated |
| LIVE | `/server/:server_id/mdns/monitor` | `MdnsLive.MonitorLive` / default | Not migrated |
| LIVE | `/server/:server_id/netboot` | `NetbootLive.Index` / default | Not migrated |
| LIVE | `/server/:server_id/netboot/devices` | `NetbootLive.DevicesLive` / default | Not migrated |
| LIVE | `/server/:server_id/netboot/devices/:mac` | `NetbootLive.DeviceDetailLive` / default | Not migrated |
| LIVE | `/server/:server_id/netboot/profiles` | `NetbootLive.ProfilesLive` / default | Not migrated |
| LIVE | `/server/:server_id/netboot/profiles/new` | `NetbootLive.ProfileEditorLive` / default | Not migrated |
| LIVE | `/server/:server_id/netboot/profiles/:id/edit` | `NetbootLive.ProfileEditorLive` / default | Not migrated |
| LIVE | `/server/:server_id/netboot/tftp` | `NetbootLive.TftpLive` / default | Not migrated |
| LIVE | `/server/:server_id/netboot/log` | `NetbootLive.LogLive` / default | Not migrated |
| LIVE | `/server/:server_id/identity` | `IdentityLive.Index` / default | Not migrated |
| LIVE | `/server/:server_id/identity/hosts` | `IdentityLive.HostsLive` / default | Not migrated |
| LIVE | `/server/:server_id/identity/hosts/:id` | `IdentityLive.HostDetailLive` / default | Not migrated |
| LIVE | `/server/:server_id/identity/approvals` | `IdentityLive.ApprovalsLive` / default | Not migrated |
| LIVE | `/server/:server_id/identity/tokens` | `IdentityLive.TokensLive` / default | Not migrated |
| LIVE | `/server/:server_id/identity/policies` | `IdentityLive.PoliciesLive` / default | Not migrated |
| LIVE | `/server/:server_id/identity/audit` | `IdentityLive.AuditLive` / default | Not migrated |
| LIVE | `/server/:server_id/fingerprint/devices` | `FingerprintLive.DevicesLive` / default | Not migrated |
| LIVE | `/server/:server_id/fingerprint/devices/:mac` | `FingerprintLive.DeviceDetailLive` / default | Not migrated |
| LIVE | `/server/:server_id/fingerprint/fingerprints` | `FingerprintLive.FingerprintsLive` / default | Not migrated |
| LIVE | `/server/:server_id/dns/cloud-provider` | `CloudDnsLive` / default | Not migrated |
| LIVE | `/server/:server_id/settings` | `SettingsLive` / dns | Not migrated |
| LIVE | `/server/:server_id/settings/dns` | `SettingsLive` / dns | Not migrated |
| LIVE | `/server/:server_id/settings/mdns` | `SettingsLive` / mdns | Not migrated |
| LIVE | `/server/:server_id/settings/dhcpv4` | `SettingsLive` / dhcpv4 | Not migrated |
| LIVE | `/server/:server_id/settings/dhcpv6` | `SettingsLive` / dhcpv6 | Not migrated |
| LIVE | `/server/:server_id/settings/netboot` | `SettingsLive` / netboot | Not migrated |
| GET | `/server/*legacy_path` | `ServiceRedirectController` / server | Original static/resource whitelist redirects to selector; unknown paths return bounded 404; scoped service functions remain separately tracked |
| GET | `/service-not-found/:service` | `ServiceRedirectController` / not_found | Original Server/Netman/generic bounded 404 bodies restored |
| LIVE | `/tool/geoip` | `ToolsLive.GeoipLive` / default | Real configured MMDB lookup and metadata; scoped tests and built-release Chromium passed |
| LIVE | `/tool/whois` | `ToolsLive.WhoisLive` / default | Raw async lookup/error UI, 30-second task deadline and local TCP cleanup verified; live external example.com lookup verified; upstream client deadline support pending |
| LIVE | `/tool/mac` | `ToolsLive.MacLive` / default | UI ported; scoped tests and actual browser vendor lookup passed |
| LIVE | `/tool/diagnostics` | `DiagnosticsLive` / dns | Not migrated |
| LIVE | `/tool/diagnostics/dns` | `DiagnosticsLive` / dns | Not migrated |
| LIVE | `/tool/diagnostics/mdns` | `DiagnosticsLive` / mdns | Not migrated |
| LIVE | `/tool/diagnostics/dhcpv4` | `DiagnosticsLive` / dhcpv4 | Not migrated |
| LIVE | `/tool/diagnostics/dhcpv6` | `DiagnosticsLive` / dhcpv6 | Not migrated |
| LIVE | `/system/logs` | `LogsLive` / index | Partial; Management log entry point works, Worker/task categories remain unavailable |
| LIVE | `/system/logs/realtime` | `LogsLive` / realtime | Actual Management Logger filtering/search/pause/metadata/CSV/clear verified; Worker sources pending |
| LIVE | `/system/logs/tasks` | `LogsLive` / tasks | Redeveloped actual job attempts/errors and immutable artifact-selection receipts |
| GET | `/system/logs/dns-query` | `ServiceRedirectController` / server | Original selector redirect restored; DNS query-log destination pending |
| GET | `/system/logs/dhcpv4-activity` | `ServiceRedirectController` / server | Original selector redirect restored; DHCPv4 activity destination pending |
| GET | `/system/logs/dhcpv6-activity` | `ServiceRedirectController` / server | Original selector redirect restored; DHCPv6 activity destination pending |
| GET | `/system/logs/netboot` | `ServiceRedirectController` / server | Original selector redirect restored; Netboot log destination pending |
| GET | `/system/logs/identity-audit` | `ServiceRedirectController` / server | Original selector redirect restored; Identity audit destination pending |
| LIVE | `/system/process-map` | `ProcessMapLive` / default | Management runtime adaptation; scoped tests and real browser passed |
| LIVE | `/system/backups` | `BackupsLive` / default | Current catalog, labeled creation, byte verification, download and confirmed deletion implemented; parent reports updated native/release/Chromium E2E passing |
| LIVE | `/system/backups/restore` | `BackupsLive` / restore | Package selection/byte verification and downtime acknowledgment implemented; destructive execution and restore CLI unavailable |
| GET | `/system/backups/download/:filename` | `BackupController` / download | Historical filename route not retained; current catalog UUID downloads use `/api/backups/:id/download` |
| LIVE | `/system/tasks` | `TasksLive.Index` / default | Redeveloped schedule/manual run/history for City/Country; MAC unavailable upstream; cloud tasks pending |
| LIVE | `/system/tasks/:task` | `TasksLive.Show` / default | Redeveloped task details, actual attempts/errors and immutable artifact receipts |
| GET | `/system/provider/cloud-dns` | `ServiceRedirectController` / server | Original selector redirect restored; provider destination pending |
| GET | `/system/fingerprint/devices` | `ServiceRedirectController` / server | Original selector redirect restored; device destination pending |
| GET | `/system/fingerprint/devices/:mac` | `ServiceRedirectController` / server | Original selector redirect restored; device detail destination pending |
| GET | `/system/fingerprint/fingerprints` | `ServiceRedirectController` / server | Original selector redirect restored; fingerprint destination pending |
| LIVE | `/system/ip-database` | `IpDatabaseLive` / default | Metadata/reload/confirmed unload plus durable City/Country synchronization task links |
| LIVE | `/system/mac-database` | `MacDatabaseLive` / default | Partial; compiled and compatible-file metadata/reload/lookup implemented; normal overlapping-prefix artifacts blocked upstream; durable sync pending |
| LIVE | `/netman` | `NetmanLive.DashboardLive` / default | Not migrated |
| GET | `/netman/config` | `ServiceRedirectController` / netman | Original redirect restored; destination `/netman` still not migrated, so navigation is incomplete |
| LIVE | `/netman/:netman_id` | `NetmanLive.NodeLive` / default | Not migrated |
| LIVE | `/netman/:netman_id/config` | `NetmanLive.ConfigLive` / default | Not migrated |
| LIVE | `/netman/:netman_id/interfaces` | `NetmanLive.InterfacesLive` / default | Not migrated |
| LIVE | `/netman/:netman_id/resolved` | `NetmanLive.ResolvedLive` / default | Not migrated |
| LIVE | `/netman/:netman_id/dhcp-client` | `NetmanLive.DhcpClientLive` / default | Not migrated |
| GET | `/boot/ipxe` | `BootController` / ipxe | Not migrated |
| GET | `/boot/assets/*path` | `BootController` / asset | Not migrated |
| GET | `/boot/manifest/:device_id` | `BootController` / manifest | Not migrated |
| POST | `/boot/register` | `BootController` / register_device | Not migrated |
| POST | `/boot/status` | `BootController` / status_update | Not migrated |
| POST | `/api/hosts/register` | `IdentityController` / register | Not migrated |
| GET | `/api/hosts/recipients` | `IdentityController` / recipients | Not migrated |
| GET | `/api/hosts/:id/status` | `IdentityController` / status | Not migrated |
| PUT | `/api/hosts/:id/approve` | `IdentityController` / approve | Not migrated |
| POST | `/api/hosts/:id/revoke` | `IdentityController` / revoke | Not migrated |
| DELETE | `/api/hosts/:id` | `IdentityController` / delete | Not migrated |
| POST | `/api/v1/zones` | `DnsZoneController` / create | Not migrated |
| GET | `/api/v1/zones` | `DnsZoneController` / index | Not migrated |
| GET | `/api/v1/zones/:id` | `DnsZoneController` / show | Not migrated |
| GET | `/api/v1/zones/:id/rrsets` | `DnsZoneController` / rrsets | Not migrated |
| PATCH | `/api/v1/zones/:id/rrsets` | `DnsZoneController` / edit | Not migrated |
| POST | `/api/v1/zones/:id/publish` | `DnsZoneController` / publish | Not migrated |
| GET | `/api/v1/deployments/:id` | `DnsZoneController` / deployment | Not migrated |
| GET | `/api/v1/servers` | `DnsZoneController` / servers | Not migrated |

Optional original route: `/dev/dashboard` (LiveDashboard/Telemetry).
Not migrated; development-only diagnostics should not silently reintroduce
legacy runtimes or a new login requirement.

## Functional and backend work remaining

| Page family | Original functions to preserve | Redevelopment / acceptance still required |
| --- | --- | --- |
| Management | Server and Netman registration/editing/selection, read-only profile catalog, configuration versions, events and event details | Original read-only catalog and prepared target history/digests now work; complete original forms, Netman network-profile models and genuine apply/rollback/event semantics remain; logical Worker adaptation alone is not full parity |
| Server dashboard/settings | Service summaries, health/status, configuration forms, status and command results | Expand desired service configuration; define actual observations without inferring connectivity or executing services inside Management |
| DNS Zones and records | View selection, create/edit/delete, resource records, individual record edit/delete, bulk entry, import/provider source selection, immutable publish results | SOA/NS/A individual CRUD, atomic bulk append and WorkerPlan import now work; full type/form parity, source metadata and view/provider integration remain; revisions/immutable versions must remain durable |
| DNS views and ACLs | View CRUD and matching rules, ACL listing/configuration and validation | PostgreSQL ownership and versioned export contract; never use legacy DNS runtime state as authoritative configuration |
| DNS providers | Provider CRUD, test/sync, provider record inspection, cloud-provider entry point, import/conflict resolution | Provider secrets/configuration/job ownership, pure provider libraries where suitable, external calls mocked in scoped tests |
| DNS telemetry | Query log filtering/pagination/download and metrics | Genuine supplied observations, retention and explicit freshness/disconnected states; no fabricated logs/counters |
| DHCPv4/v6 | Overview, lease search/state/pool filters and release actions, pool create/edit/delete/force-delete, pool details, activity | Desired configuration, durable allocation policy and genuine lease observations; Worker-side commands must respect the two-product boundary |
| mDNS | Registration/edit/delete/toggle, name/type/port/TXT/IPv4/IPv6-address/enabled editing, filters/CSV, passive discovery/details and actual monitor/cache-clear controls | Full historical source scope and executable-boundary findings are in [redevelopment readiness](rrtypes-and-mdns-redevelopment.md); no Management-local advertisements or fabricated Worker observations |
| Netboot | Full kernel/initrd/arguments/installer/architecture/manifest profile authoring and clone/default/CSV/preview, devices/actions, TFTP files/history, boot logs and installer HTTP | [Full historical scope and unresolved ownership](netboot-identity-fingerprint-scope.md); a four-field profile form or saved draft cannot stand in for provisioning |
| Identity | Actual enrollment, host/key/trust details, individual/batch approval/rejection/revocation, token creation/show-once/revocation, read-only ordered policies and identity audit | [Authority/credential boundaries](netboot-identity-fingerprint-scope.md); the later read-only token listing is not full parity, and raw token secrets must not enter generic audit/idempotency results |
| Fingerprint | Observed device/signature lists and details, known/unknown/search/CSV, existing-profile classification with note and override saving | [Classification and observation scope](netboot-identity-fingerprint-scope.md); not inspection-only, no invented class/profile CRUD, synthetic observations or hit counts |
| Tools | GeoIP lookup/metadata, WHOIS asynchronous results/errors, MAC vendor lookup, DNS/mDNS/DHCP diagnostics | MAC/WHOIS UI tests exist; real MMDB GeoIP lookup/metadata verified; protocol diagnostics remain; no unrequested local protocol servers |
| System logs/tasks | Log modes/filter/search/clear/pause/download, task listing/details/run/result history | Actual Management Logger and durable City/Country scheduling/run/history verified; Worker/service sources, cloud-provider tasks and lossless MAC synchronization remain |
| System Process Map | Expand/collapse, refresh, PID selection and process status detail | Reuse SVG UI against the actual Management supervisor only; Worker inspection requires genuine observation support |
| Backups/databases | Backup create/list/download/delete/restore/upload, GeoIP database management, MAC database statistics/search/reload | Real GeoIP operations and compiled/compatible MAC metadata/lookup/reload verified; lossless overlapping MAC imports blocked upstream; backup creation/list/byte verification/download/confirmed deletion implemented with parent-reported updated E2E passing; destructive restore/upload unavailable |
| Netman | Selector, node/status, config editing, interface actions, resolver cache/upstreams/intercepts, DHCP client lifecycle | PG logical nodes, typed Ethernet/Resolved desired drafts, prepared history and desired rollback are implemented; actual interfaces/DHCP/cache/intercepts/activation and genuine observations remain pending. Do not restore legacy Agents or alter Management host network to simulate Netman |

## Current verification evidence

### Netman desired-data integration

The current Netman integration is verified by executed coordinator checks:

- Strict app compilation, scoped formatting and asset generation: **PASS**.
- Netman domain, pure validation, selector/config UI, combined Config history and
  Management overview tests: **60 tests, 0 failures**. The meaningful CAS checks
  reject floating-point, string, missing and Boolean revisions with durable error
  receipts and unchanged business rows. PostgreSQL immutable-version triggers are
  exercised, not inferred from schema source.
- Production-release smoke: **PASS** using disposable PostgreSQL and independent
  HTTP database connections. Two competing full-draft edits yield one success and
  one revision conflict; retry, desired rollback and observe-only rejection pass.
  Stopping/restarting the real release preserves exact node metadata, drafts,
  all versions and the original idempotent publication result.
- Real Chromium smoke: **PASS**. It registers a logical Netman, verifies form
  reset and path-only identity, creates/edits/deletes a typed Ethernet profile,
  rejects a wrong address family without changing the draft, edits IPv4/IPv6
  Resolved upstreams without dropping profiles, prepares two versions, confirms
  desired rollback into a third version, checks combined Management history and
  observe-only disabled publication. Historical versions stay unchanged.
- Local `mix ecto.setup` and development-service restart: **PASS**. New selector,
  Management history, static assets and `/api/netmans` return unauthenticated 200;
  the listener remains `0.0.0.0:4270` (observed PID `2789002`). Original Worker/Zone
  response bytes retain identical SHA-256 digests across migration/restart.

Executed entrypoints:

```sh
devenv shell -- scripts/e2e/phase1_postgres.sh bash -c 'cd apps/yellow_dog_management && mix test test/netman_domain_test.exs test/netman_config_test.exs test/netmans_live_test.exs test/netman_config_live_test.exs test/config_live_test.exs test/ui_test.exs'
devenv shell -- scripts/e2e/phase1_postgres.sh env YELLOW_DOG_MANAGEMENT_BIND_ADDRESS=127.0.0.1 scripts/e2e/release_smoke.sh yellow_dog_management
devenv shell -- scripts/e2e/phase1_postgres.sh env BUILD_RELEASE=0 scripts/e2e/management_browser.sh
devenv shell -- mix ecto.setup
systemctl --user restart yellow-dog-management-dev.service
```

The two release/browser commands ran sequentially in one `devenv shell -- bash -c`
invocation; browser validation reused that just-built release. No legacy runtime
or host-network action is part of this evidence. Runtime Netman observations,
interfaces/DHCP/cache/intercepts/activation and the other pending service domains
remain incomplete; the full business migration goal is not complete.

### Prior compatibility-removal slice

Earlier coordinator-reported results after compatibility removal:

- Compilation, formatting and asset generation: **PASS** (supporting checks).
- Final scoped UI/Web/Config/Zones/Import/Records rerun after Netman reserved-ID
  removal: **71 tests, 0 failures** (the earlier 70-test run was a prior snapshot).
- Disposable-release real Chromium workflow: **PASS** after removal of legacy
  redirects, the reserved `settings` workaround and the static workspace.
- Live restart: **PASS**. The coordinator observed PID `2775405` listening on
  `0.0.0.0:4270`; `/management`, `/management/config`, current CSS/JS and API
  requests returned unauthenticated HTTP 200. This PID is an observation from
  that run, not a persistent deployment identity.
- Retired `/workspace`, `/index.html`, `/management.js`, `/server/dns` and
  `/netman/config` returned HTTP 404. Worker/Zone API response bytes retained
  identical SHA-256 digests across the successful restart.
- The initial shell request loop failed because it used zsh special variables
  `path`/`status`. The corrected `request_path`/`response_status` loop passed;
  that failed command is not a Management runtime regression or a passing check.

These results are the coordinator's executed evidence, not checks rerun by this
documentation worker. They establish the covered current workflows, not complete
DNS/protocol/Netman/task/backup functionality or resolution of the independent MAC
source-loss blocker. Historical compatibility browser successes and older suite
totals below do not extend the current acceptance scope.

## Historical verification log (reference only)

These recorded runs describe earlier snapshots, including compatibility paths
and the retiring static UI. They are not current acceptance requirements or proof
that pending features work. Neither route coverage nor suite size/all-green totals
substitute for relevant business, runtime and data evidence. Do not rerun obsolete
compatibility cases merely to preserve these totals. Current evidence must identify
the concrete workflow, persistence/effect, error handling and observed boundary.

Recorded earlier runs:
- Management `ui_test.exs` + `tools_live_test.exs`: 12 tests, 0 failures.
- Expanded UI/tools/settings run: 18 tests, 0 failures.
- Initial CSS/Bun build succeeds with matching locked Phoenix/LiveView clients.
- First-slice Management scoped suite: 52 tests, 0 failures.
- Expanded Management scoped suite: 77 tests, 0 failures, with disposable
  PostgreSQL and warnings-as-errors. Includes 11 record workflow tests and 13
  import tests, stale revisions, atomic rollback, unknown scopes, malformed
  inputs, 1 MiB byte limits, actual ConfigCompiler round trips and idempotent
  import; no schema/shared-contract changes.
- Compatibility workspace JavaScript suite: 38 tests, 0 failures, no skips.
- Previous Management-only suite: 108 tests, 0 failures, disposable PostgreSQL,
  warnings-as-errors; includes actual Logger capture/recovery, bounded replay,
  log workflows, real MMDB decoding, loader failures and GeoIP/database pages.
  Asset rebuild, app-local strict compilation/format and scoped diff check pass.
- Subsequent Config/history, shared-runtime MAC tool and Settings scoped run:
  18 tests, 0 failures. MAC Database UI scoped run: 7 tests, 0 failures.
- Previous full Management-only suite: **133 tests, 1 failure**, warnings-as-errors
  and disposable PostgreSQL. The failure is
  `mac_database_test.exs:70`, packaged GSMLG artifact source parity, blocked by
  upstream #8. All other 132 tests pass. The gate compares the unique parsed
  prefixes, not the already-lossy compiled count, and remains unskipped.
- Previous full Management-only suite: **141 tests, 1 failure**, warnings-as-errors
  and disposable PostgreSQL. The same packaged MAC source-parity gate remains
  failing and unskipped; the other 140 pass. The new Profiles slice has four
  passing tests covering exact catalog values, original rows, no login/writes
  and no legacy startup. WHOIS has 12 passing tests including deadline retry,
  actual local TCP peer closure, stale deadlines, blank cancellation and normal
  page shutdown. These do not establish external WHOIS reachability or full UI
  migration. Asset build, strict compile/format and 38 JavaScript tests pass.
- Historical full Management-only suite: **175 tests, 1 failure**, warnings-as-errors
  and disposable PostgreSQL. Only the same upstream packaged-MAC parity gate
  fails; all other 174 tests pass. The redirect/UI/config slice passes 26 tests,
  and the expanded Zones/import/records scope slice passes 51 tests. Coverage
  includes every original whitelist entry and System alias, query/array/map
  identity overrides, reserved registered IDs, explicit alias lookup, bounded
  unknown responses, invalid-scope mutation rejection and read-only audit/state
  invariants. No test skips or new SQL/WorkerPlan fields were added. Strict
  compile/format, 38 JavaScript tests, assets and release restart/export smoke pass.
- Historical production-release Chromium smoke also verifies all 13 original
  Profiles rows and a blank WHOIS submission with no lookup/error or disabled
  form, alongside the existing expanded workflows. Its first run exposed that
  assigning an unchanged empty string does not clear a focused browser input;
  the existing Console `ResetForm` hook now receives an explicit reset event.
  The reproduced failure and scoped event regression both pass after that fix.
  This is separate from the previously deferred `/workspace` New Zone report.
- The following expanded production-release Chromium run passes selector-only
  legacy redirects with both `dns` and `settings` records registered, the explicit
  reserved-ID dashboard/DNS-overview routes, bounded unknown aliases and global
  versus scoped Zone/import/record contexts under malicious scalar/list/map
  query identities. Existing business, theme, Logger, database, import/export,
  Process Map and mobile flows still pass. No login/JS/CSP/asset errors occur.
  The selector retains its original dropdown with an empty selected value; absence
  of that dropdown is not the no-inferred-Worker acceptance criterion.
- Strict compilation, app-local format check, and scoped diff check pass.
- Real Chromium against the built release and disposable PostgreSQL passes:
  WebSocket, original navigation, notification dropdown and persisted theme,
  Worker registration and browser form reset, desired service, immutable
  assignment, preview/target confirmation/TOML export, Zone listing, MAC lookup,
  durable audit, real Management process inspection, 390px drawer and no overflow.
  No login, JavaScript errors, CSP violations, or missing assets were observed.
- Expanded built-release Chromium smoke also passes individual record
  create/edit/delete, real confirmation cancellation and acceptance, atomic
  invalid/valid bulk append, Phoenix New Zone identity reset, actual historical
  WorkerPlan import preview/conflict/success, exact immutable record content,
  unchanged historical export bytes, desktop sidebar without horizontal
  overflow and the 390px mobile drawer. No development data is mutated.
- Historical built-release Chromium run additionally passes real MMDB lookup fields,
  invalid-IP errors, unload cancellation/acceptance, unloaded lookup failure and
  reload recovery. A temporary decoded synthetic MaxMind artifact is removed
  after the smoke. Genuine Logger replay/search/app/severity filtering, metadata,
  pause/resume with a second browser connection, actual CSV download, view-only
  clear and backend replay also pass; no JavaScript/CSP/asset errors.
- Subsequent built-release Chromium run passes the real prepared-config history
  row/digest/unknown state/refresh and OUI artifact metadata/count, invalid input,
  actual 2-to-3-entry file reload, shared Tool lookup, invalid-replacement failure,
  last-valid lookup preservation and 3-to-2-entry recovery. The browser wrapper
  exits successfully and cleans temporary artifacts; original flows still pass.
  This compatible-artifact smoke does not establish overlapping-prefix parity or
  override the failing packaged-file regression. Release restart/persistence and
  immutable-export smoke, 38 JavaScript tests and formatting also pass.
- Read-only Chromium against `http://10.100.10.15:4270/management` verifies the
  connected WebSocket, all five original navbar sections, loaded stylesheet,
  no login and no browser errors; it does not mutate development data.
- The development service restarts on `0.0.0.0:4270` with byte-identical Worker
  and Zone API data and exact rebuilt CSS/JavaScript asset bytes. The new logs,
  GeoIP and IP Database routes return HTTP 200 without login. No synthetic MMDB
  fixture is configured on this service.
- After the Config/MAC slice, another restart preserves identical Worker/Zone
  API bytes and rebuilt asset bytes. Read-only LAN Chromium verifies the new
  Config table, connected WebSocket, local stylesheet and no login; both MAC
  pages return the actual compiled-source Omron lookup. The Database page shows
  the genuine 47,784 compiled entries, no configured file and disabled disk
  reload, with no browser errors or synthetic artifact on the live service.
- After the Profiles/WHOIS slice, the development service restarts again on
  `0.0.0.0:4270`, preserving byte-identical Worker/Zone API responses and serving
  exact rebuilt CSS/JavaScript bytes. Read-only LAN Chromium at 1440px verifies
  the original navbar, styled connected Profiles page, six Server/seven Netman
  rows and no login. A real `example.com` WHOIS query returns a raw result in
  1,976 ms and re-enables the form, without JavaScript errors or database changes.
  This one external-domain probe is not a guarantee of all WHOIS peer availability.
- After the legacy-route/scope slice, another restart preserves exact Worker/Zone
  API bytes and compiled asset bytes on `0.0.0.0:4270`. Read-only LAN Chromium
  confirms styled connected global Zone/import pages ignore array/map query
  scope, and the original settings alias opens the unselected Server selector.
  Actual HTTP responses confirm the original 302 destination and bounded
  service-not-found text. No database writes or authentication are introduced.
- Management release smoke passes: independent dependency closure, packaged CSS
  and LiveView client, zero-Worker DNS editing, four logical targets, concurrent
  assignment conflict/retry, real restart persistence and byte-identical exports.

Browser foundation initially exposed a native dropdown CSP integration issue.

Expanded browser validation exposed duplicate confirmation handlers inherited
from the original Console. Management now relies on its imported Phoenix HTML
handler alone; retaining the legacy capture handler prompts twice and can cancel
a valid delete. The real browser smoke verifies both cancel-with-no-mutation and
accept-with-one-delete. Do not restore a second `data-confirm` listener when
porting another page.
Upstream Feature request `duskmoon-dev/phoenix-duskmoon-ui#172` is labeled
`internal request`, severity `needed`. Until the packaged dropdown removes its
inline toggle callback, the browser policy allows only that exact handler hash;
external scripts remain same-origin. Inline style attributes are allowed for
the upstream native anchor positioning and LiveView form recovery, while style
elements remain same-origin. No component internals were reimplemented.

These results verify only their covered functions, not the full matrix.
Historical static-UI bug reports do not require preserving or repairing the
retired workspace. Relevant current Worker/service failures must remain visible;
unrelated checks cannot erase them or prove this UI's pending functions complete.

## Meaningful verification selection

Select checks for the implemented business function; the examples below are not
a mandatory whole-suite green gate. Compilation/format and asset generation are
supporting checks, not functional evidence.

```sh
devenv shell -- npm run assets.management
devenv shell -- mix do --app yellow_dog_management cmd mix compile --warnings-as-errors
devenv shell -- mix do --app yellow_dog_management cmd mix format --check-formatted
devenv shell -- scripts/e2e/phase1_postgres.sh mix do --app yellow_dog_management cmd mix test test/domain_test.exs test/ui_test.exs test/records_live_test.exs test/zone_import_live_test.exs --warnings-as-errors
devenv shell -- scripts/e2e/phase1_postgres.sh scripts/e2e/release_smoke.sh yellow_dog_management
```

```sh
devenv shell -- scripts/e2e/phase1_postgres.sh scripts/e2e/management_browser.sh
```

The browser wrapper supplies real navigation/data evidence, not an old-route
compatibility acceptance list. The coordinator owns updates for retired aliases
and static UI; meaningful business assertions must remain. It builds the release
before startup, chooses a random loopback
HTTP port, configures temporary synthetic GeoIP/OUI artifacts, and stops the
server and removes those artifacts on exit. `test/live_browser_smoke.mjs`
requires the empty disposable database and `MANAGEMENT_MAC_SMOKE_PATH` from this
wrapper. It validates actual Chromium/WebSocket navigation, file reloads and
business mutations. Never point the mutating smoke at the development database,
or overwrite its release while it is running. The GeoIP fixture is synthetic
test data, not an operational City/Country dataset or a development default.

## Outstanding architecture decisions

The source-backed control-domain proposal is
`docs/phase1/ui-control-domain-proposal.md`. It separates Management-owned SQL,
shared desired-state/Worker execution and real observations/external effects.
These proposals are not implementation approval or migrated functionality.
The operations-domain proposal is
`docs/phase1/ui-operations-domain-proposal.md`. It covers original task configuration,
actual durable attempts/outcomes, downloaded-artifact ownership and PostgreSQL plus
artifact backup/recovery. Its queue, executor, download, restore-safety and
authorization decisions are still pending; the document adds no schema or runtime.
In particular, the original Profiles page is a read-only preset catalog, not
editable profile CRUD and does not require profile tables. Redeveloped DNS
publication must preserve the business functions of target selection, atomic
revisioned record edits, deliberate serial/publication semantics, immutable
history and idempotency. Its current representation can reuse existing entities;
exact old deployment APIs/digests and compatibility adapters are not required.
Resource confirmation or target preparation alone does not prove runtime application.

Full protocol diagnostics cannot currently be ported by adding the old clients:
`scripts/e2e/check_release_boundary.exs` and the Management release smoke forbid
`abyss`, `ex_dns` and `ex_dhcp` in its dependency closure. The original clients
use these libraries or the excluded `YellowDog.Dns.Client` runtime. A decision
is pending between explicitly allowing pure client/protocol libraries without
starting protocol servers, or designing an independent Worker diagnostics
interface. Do not silently weaken either verifier, recreate wire protocols in
Management, or restore a legacy Agent to make these routes look functional.

Service, Netman network-profile and durable task functions still need design and
implementation. Pending execution/observation ownership and shared contracts need
coordinated decisions; ordinary PG table additions have no blanket approval rule.
Existing cacheable GeoIP/OUI artifacts and local Logger observations do not stand
in for those durable domains.

Lossless MAC/OUI artifact reload is blocked by
[`gsmlg-dev/gsmlg_umbrella#8`](https://github.com/gsmlg-dev/gsmlg_umbrella/issues/8),
an open Bug labeled `internal request`. The locked `gsmlg_mac` compiler drops
different prefix lengths under the same OUI: its actual packaged `manuf.txt`
contains 48,087 unique parsed prefixes but compiles to 47,784 entries. The new
Management loader rejects that loss rather than silently activating incomplete
data, retaining the compiled or last valid snapshot. The required packaged-file
parity regression remains failing and is not skipped. Compiled-source inspection
and compatible single-width-per-OUI files are independent supported subsets,
not complete original MAC page parity. Do not replace the upstream compiler
locally; resume lossless artifact import after upstream fixes the dependency.

## Business-function acceptance

Keep remaining business areas accurately pending until their original functions
are redeveloped with real backend behavior. For each function, record intended
input/output and ownership, meaningful success/error workflows, durable data and
immutable-history invariants, focused tests and browser evidence when interactive.
Runtime claims need actual observations; desired preparation remains distinct.
Current backups need integrity and safe destructive recovery, not old-format or
cross-software-version restore support. A relevant failing test blocks its claimed
function; an unrelated failure is reported separately, not repaired or skipped to
obtain an all-green total. Inventory URLs/events and menus are reference material,
not completion targets. No pending feature is complete merely because design,
disabled controls or placeholder feedback exists.

## Management tasks integration (2026-10-01)

Standalone Management now owns task definitions with CAS revisions, standard
five-field UTC schedules, disabled defaults and manual runs independent of the
schedule. Oban owns durable attempts/retries under the `management_jobs` PG
prefix; active tasks and scheduler occurrences deduplicate. This replaces the
historical proposal for a custom queue, not the original Tasks/Concord runtime.

City/Country jobs download actual gzip bytes using Mint, verify the actual status
200 and HTTPS peers/hostnames, enforce bounded input/inflation/deadlines, validate
dataset-specific MMDB metadata and durably publish immutable digest-named files.
The real GeoIP loader verifies those bytes before a current job claim commits the
artifact selection and immutable receipt. Stale claims, failed downloads/loads
and corrupt restart artifacts cannot silently replace the prior valid snapshot.
PostgreSQL-selected artifacts restore on Management restart. Task detail/log pages
show real attempts, errors, timestamps and receipts, with bounded polling while
active; read-only inspection does not mutate or enqueue.

Executed focused validation:

```sh
devenv shell -- scripts/e2e/phase1_postgres.sh bash -lc 'cd apps/yellow_dog_management && mix test test/tasks_test.exs test/task_artifacts_test.exs test/geo_ip_test.exs test/ip_database_live_test.exs test/tasks_live_test.exs test/geo_ip_download_test.exs'
devenv shell -- scripts/e2e/phase1_postgres.sh scripts/e2e/management_tasks.sh
```

- 53 meaningful scoped tests, 0 failures; scoped formatting and
  `mix compile --warnings-as-errors` pass. No unrelated whole-suite gate.
- A real fresh production release binds 0.0.0.0 on a disposable port and starts
  only Management. Real local HTTP fixtures exercise actual gzip download,
  immutable artifact publication, successful queue completion and retained
  source-failure attempts. This does not establish public DB-IP availability.
- Separate real PG connections prove concurrent command idempotency and schedule
  CAS. The running scheduler enqueues and completes a genuinely due occurrence.
- Real Chromium saves a disabled UTC schedule, manually queues a download,
  automatically observes completion, renders actual result/error history,
  refuses unavailable MAC work and queries actual London data from the selected
  fixture. SIGKILL followed by a new independent process retains receipts,
  schedules and the selected artifact; another browser verifies restored lookup
  without enqueueing. In-flight Lifeline rescue is configured, not separately
  exercised by this terminal-job restart smoke.
- Release/browser evidence: `/tmp/management-tasks-release-txh0png5`;
  disposable PostgreSQL evidence: `/tmp/yellow-dog-phase1-pg.RSo0Kb`.

MAC synchronization remains affected-subtask blocked by
`gsmlg-dev/gsmlg_umbrella#8`, with no replacement compiler or fake success. Cloud
provider synchronization, backup/recovery, remote logs and the remaining DNS and
service/Netman runtime workflows are not completed by this slice. No legacy URL,
payload, backup-format or software-version compatibility layer was added.

### Direct IP Database synchronization (2026-10-01)

The City/Country cards now directly queue their durable synchronization tasks,
rather than requiring navigation to Tasks. Server-owned task identity and source
cannot be changed through submitted keys, URLs or paths. The result exposes the
actual job ID and explicitly distinguishes queue acceptance from completion;
the existing Sync History links remain. Enqueueing leaves physical task schedules
and loaded GeoIP snapshots unchanged. Invalid selection and recognized queue
insertion rejection show errors without a fake job or completion.

Focused verification executes 24 IP Database/Tasks backend and LiveView tests,
all passing, at `/tmp/yellow-dog-phase1-pg.fn97lR`. Strict compilation, scoped
formatting and JavaScript syntax checks pass. Rebuilt assets and a fresh
production release run the real Tasks/browser harness at
`/tmp/management-tasks-release-267kj2tc` and `/tmp/yellow-dog-phase1-pg.dAxCHd`:
direct City queue records a new real job and completed MMDB digest/attempt
receipt with its schedule still disabled. Existing Country failure history,
manual queue, real due scheduler, and SIGKILL persistence checks pass. Browser
restart verification remains read-only and queues no downloads.

An exploratory unregistered PostgreSQL check-constraint injection also exposed
an existing Oban nested-transaction exception that aborts the command connection;
that low-level failure is retained, not repaired by this UI slice. The scoped
queue rejection check uses Oban's registered constraint and verifies its normal
error return and atomic no-job result. This is not an outage-recovery guarantee
or a reason to require unrelated whole-suite tests to pass.

## Management backups: current slice (2026-10-01)

The current Management backend and DuskMoon UI redevelop labeled create/list,
metadata, asynchronous verify/dismiss, package download and confirmed/cancelable
deletion. Creation and deletion enqueue durable Oban jobs; polling and
`management:backups` updates show actual pending/ready/deleting/deleted/failed
catalog results. Controls reset after creation. Labels are bounded to 128 UTF-8
bytes, and actions select server-owned backup UUIDs rather than arbitrary paths.
Deletion removes only the chosen package, retaining live business data and
selected artifact files. Existing parent-seeded snapshots are not cleanup targets.

Packages are private current-format PostgreSQL custom dumps plus a bounded JSON
manifest and immutable GeoIP artifact bytes from the captured catalog. One
exported read-only repeatable-read snapshot binds dump contents, manifest
per-table counts and artifact references while ordinary concurrent writers
continue. Concurrent schema migration/DDL is excluded; schema/software migration,
earlier-format import and cross-version archive compatibility are not goals.
Worker local state, Logger/ETS/socket/process state, deployment credentials and
the bytes of earlier backup archives are not included. Other backup catalog rows
may still be present in the database dump.

The creating backup's own pending catalog row and in-progress job can appear in
the snapshot. Its later ready state, package digest receipt and job completion
are outside that capture boundary; the dump does not contain its own completed
package receipt. Catalog metadata and the manifest identify that boundary.

Verification exposes `level: "byte_integrity"`: actual checksum/package checks,
dump digest, artifact count and package row count. It does **not** establish full
recoverability, prove a safe destructive cutover, or restore the live database.
The restore page supports current-package selection/verification, downtime
acknowledgment and cancellation, but explicitly reports execution unavailable.
No executable restore CLI exists. Lifetime maintenance fencing, a durable
recovery hold and request/dataset-generation policy still require implementation
and validation before destructive recovery can be offered.

Evidence is version-scoped, not an all-green completion claim:

- The parent reports the **updated native/release/Chromium E2E passing** at
  `/tmp/management-backups-release-jhp6ctaz` and
  `/tmp/yellow-dog-phase1-pg.z5YJp6`: actual concurrent-writer snapshot consistency,
  isolated staging PostgreSQL restore and manifest/table-count checks; a real
  failure after package publication but before the PostgreSQL ready commit,
  followed by UTC-scheduled Oban retry adopting the identical immutable archive;
  Chromium create/reset/byte verification, checksum-matched download, canceled
  and confirmed deletion with business data unchanged; and SIGKILL persistence
  of ready metadata, archive and artifacts. This replaces the pending retry
  result, not the missing destructive live/offline restore implementation.
- The parent reports the final **33 scoped tests, 0 failures**, plus owned-file
  formatting exit 0, at `/tmp/yellow-dog-phase1-pg.rnbzBV`, including the IPv6
  parser addition. Strict development compilation and full backup-file formatting
  passed earlier. The current release E2E above also passed; destructive
  live/offline restore execution remains unimplemented and was not exercised.
- The reported development deployment applied the backup migration with
  `devenv shell -- mix ecto.setup` and restarted
  `yellow-dog-management-dev.service`. Its observed BEAM PID was `2829436`, bound
  to `0.0.0.0:4270`; both backup pages returned HTTP 200 without authentication.
  The read-only business snapshot stayed identical: no Workers/Zones/Netmans,
  three disabled tasks, zero backups and no newly queued jobs. Evidence:
  `/tmp/management-backup-deploy-glvjms0z/baseline.json`. This is a recorded
  deployment observation, not proof of restore execution or a permanent PID.
- This bounded documentation update runs no service, browser or test suite and
  adds no independent runtime verification claim. Destructive restore and full
  Console business-function parity remain incomplete.

## Historical source action inventory (reference only)

Direct string-named `handle_event` entry points in the original LiveView source,
not a claim that every original handler had a complete backend. Dynamic guards,
LiveComponent form events, parameter-based actions, timers and observation
subscriptions help discover business behavior; event names are not compatibility
requirements for redeveloped pages. Source files below
are relative to `apps/yellow_dog_console/lib/yellow_dog/console/live/`.
A matching event name in new code alone does not establish functional parity.

| Original source | Explicit UI events |
| --- | --- |
| `backups_live.ex` | `update_label`, `create_backup`, `refresh`, `verify`, `dismiss_verify`, `restore`, `cancel_restore`, `do_restore`, `delete` |
| `cloud_dns_live.ex` | `refresh` |
| `components/pool_form_component.ex` | `validate`, `save`, `close` |
| `dashboard_live.ex` | `refresh` |
| `dhcp_client_live/activity_live.ex` | `search`, `filter_type`, `toggle_pause`, `clear`, `export_csv` |
| `dhcp_client_live/index.ex` | `release` |
| `dhcpv4_live/activity_live.ex` | `search`, `filter_type`, `refresh` |
| `dhcpv4_live/index.ex` | `refresh` |
| `dhcpv4_live/leases_live.ex` | `search`, `filter_state`, `filter_pool`, `release_lease`, `refresh` |
| `dhcpv4_live/pool_live.ex` | `search`, `filter_state`, `release_lease` |
| `dhcpv4_live/pools_live.ex` | `show_new_form`, `show_edit_form`, `delete_pool`, `force_delete_pool`, `filter`, `refresh` |
| `dhcpv6_live/activity_live.ex` | `search`, `filter_type`, `refresh` |
| `dhcpv6_live/index.ex` | `refresh` |
| `dhcpv6_live/leases_live.ex` | `search`, `filter_state`, `filter_ia_type`, `filter_pool`, `release_lease`, `refresh` |
| `dhcpv6_live/pools_live.ex` | `show_new_form`, `show_edit_form`, `delete_pool`, `force_delete_pool`, `filter`, `refresh` |
| `diagnostics_live/diagnostics_live.ex` | `toggle_display_mode`, `toggle_history`, `clear_history`, `select_history`, `copied`, `copy_failed`, `validate_dns`, `send_dns_query`, `validate_mdns`, `send_mdns_query`, `validate_dhcpv4`, `send_dhcpv4_query`, `validate_dhcpv6`, `send_dhcpv6_query` |
| `dns_live/acl_live.ex` | `create_acl`, `update_acl`, `delete_acl` |
| `dns_live/index.ex` | `refresh` |
| `dns_live/metrics_live.ex` | `refresh` |
| `dns_live/provider_live/conflict_live.ex` | `refresh`, `resolve_conflict` |
| `dns_live/provider_live/index.ex` | `create_provider`, `delete_provider` |
| `dns_live/provider_live/show.ex` | `refresh`, `select_view`, `update_provider`, `sync_zone` |
| `dns_live/query_logs_live.ex` | `refresh`, `select_view` |
| `dns_live/rr_live/index.ex` | `create_record`, `update_record`, `delete_record` |
| `dns_live/view_live/index.ex` | `create_view`, `update_view`, `delete_view` |
| `dns_live/zone_live/index.ex` | `select_view`, `create_zone`, `update_zone`, `delete_zone`, `sync_zone`, `import_zone` |
| `identity/host_detail_live.ex` | `approve`, `revoke`, `delete` |
| `identity/hosts_live.ex` | `refresh`, `approve`, `revoke`, `delete` |
| `ip_database_live.ex` | `refresh`, `download`, `unload` |
| `logs_live.ex` | `toggle_pause`, `clear`, `toggle_app`, `select_all_apps`, `select_no_apps`, `set_level`, `search`, `export_csv`, `toggle_expand` |
| `mac_database_live.ex` | `refresh`, `download`, `reload`, `test_lookup` |
| `mdns_live/discovery_live.ex` | `refresh`, `search`, `filter_by_type`, `view_details`, `close_details` |
| `mdns_live/index.ex` | `refresh` |
| `mdns_live/monitor_live.ex` | `refresh`, `search`, `set_limit`, `clear_cache` |
| `mdns_live/services_live.ex` | `refresh`, `filter`, `show_new_form`, `show_edit_form`, `hide_form`, `validate_service`, `save_service`, `toggle_service`, `delete_service` |
| `netboot_live/device_detail_live.ex` | `assign_profile`, `delete_device` |
| `netboot_live/devices_live.ex` | `search`, `filter_profile`, `filter_state`, `sort`, `export_csv`, `assign_profile`, `delete_device` |
| `netboot_live/index.ex` | `refresh` |
| `netboot_live/log_live.ex` | `search`, `filter_type`, `filter_level`, `toggle_pause`, `clear_log`, `export_csv` |
| `netboot_live/profile_editor_live.ex` | `validate`, `save`, `delete_profile` |
| `netboot_live/profiles_live.ex` | `search`, `sort`, `export_csv`, `set_default`, `delete_profile` |
| `netboot_live/tftp_live.ex` | `filter_history`, `sort_history` |
| `netman_live/config_live.ex` | `validate_profile`, `put_profile`, `patch_profile`, `delete_profile`, `activate_profile`, `rollback_profile`, `replace_profiles`, `load_history`, `load_active_revision` |
| `netman_live/dhcp_client_live.ex` | `inspect_fsm`, `release_lease` |
| `netman_live/interfaces_live.ex` | `connection_state`, `activate_connection`, `deactivate_connection` |
| `netman_live/resolved_live.ex` | `update_resolved`, `rollback_resolved`, `flush_cache` |
| `process_map_live.ex` | `select_node`, `close_panel`, `toggle_expand` |
| `settings_live.ex` | `refresh`, `save`, `apply`, `rollback` |
| `tasks_live/index.ex` | `refresh`, `run_now`, `save_task_config` |
| `tasks_live/show.ex` | `run_now` |
| `tools_live/geoip_live.ex` | `lookup` |
| `tools_live/mac_live.ex` | `lookup` |
| `tools_live/whois_live.ex` | `lookup` |
