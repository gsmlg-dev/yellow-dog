# UI source migration for redesign

## Subsequent Management configuration increment

The source-only acceptance below records the October 4–5 transfer. The later
`docs/yellow-dog-codex-management-plan.md` authorizes functional work on routed
native DNS View scope, global Zone assignments and editor persistence, and the
Management IP database artifact catalog. It also authorizes minimal compilation
prerequisites, with each retained-source adaptation recorded in the provenance
manifest. Retained redesign pages remain unrouted; importing legacy runtimes or
redeveloping unrelated pages remains outside scope. Current checks and checkpoint
status are recorded in `management-configuration-progress.md`.

The historical 201-file inventory and test statements below describe the
original transfer, not acceptance of these later changes.

P0 now retains 203 files: the original presentations plus the genuine
`ServiceHelper` and pure `ConfigHelpers`. The manifest records namespace fixes,
tagged-map struct matching, deferred constructors/calls to unavailable backends,
and scoped formatting. The checker still verifies exact transformations,
source hashes, both presentation revisions, and complete inventory. The native
Management build is executable; this does not make the unrouted redesign pages
functional or authorize loading their legacy backends.

## Accepted scope

On 2026-10-04 the user authorized moving UI code directly into the current
Management UI source directory, with compilation or runtime failure acceptable.
The UI will be redesigned later. This supersedes the earlier architecture-only
restriction for source transfer, not the Worker service ownership boundary.

Source is in `apps/yellow_dog_management/lib/yellow_dog/management_ui/redesign/`,
with the shared entry point at `management_ui/redesign.ex`. These are ordinary
compiled `lib/` sources, not an archive, fixture or excluded staging directory.
`YellowDog.ManagementUI.Redesign` prevents collisions with current native
Management modules. Existing Management pages and legacy Console source are
preserved; no working-tree edits are discarded.

## Transferred source

- 105 LiveView/page/helper/template files: the union of current Console pages
  and original pages at `8550aa05388270c7c35c3115365d49ed058e48ad`.
- Primary page/template sources select 75 historical and 30 working-tree files.
  Eleven historical-only files are retained, including settings tabs. Neither
  revision is assumed to be a presentation superset of the other.
- Both revisions of all 67 differing live source paths are retained: 64 alternate
  files under `redesign/current/live/` and three under `redesign/original/live/`.
  Their declarations use `ManagementUI.Redesign.Current` or `.Original`, while
  retaining the shared web macro/helpers. Matching template companions remain
  together; no runtime version selection or compatibility adapter is added.
- Eight shared components/templates and two mount hooks. `OriginalSidebar`
  retains the original Netman client, resolver-counter and lease-status UI while
  keeping the current Sidebar unchanged; no old connections are established.
- The web macro, pure display/CSV/validation/path helpers, two embedded form
  schemas and five page/error presentation files, plus the pure diagnostic
  hex-display formatter: 15 files. Protocol diagnostic engines remain excluded.
- The historical home template and its `Original.PageHTML` companion retain
  the DNS/DHCP/mDNS cards and links alongside the current home presentation.
- Original JS hooks and CSS source at `apps/yellow_dog_management/assets/redesign/`.

Total: 201 files. Coverage includes DNS/provider/record pages, DHCPv4/v6 and DHCP
client pages, mDNS, Netboot, Identity, Fingerprint, Netman, management/configuration,
settings, diagnostics, tools, task/log/backup and process-map UI source.
Namespace/app identifiers are changed mechanically; relocated CSS source paths
are adjusted. The migrated web macro references the existing Management endpoint
and router for verified routes. No route compatibility layer is installed.

The exact source revision, replacements and source/destination SHA-256 hashes
are recorded in `docs/phase1/ui-source-migration.json`.

## Intentionally not transferred or implemented

Application supervision, Endpoint/socket/channel implementations, authentication
plugs, Agents, management transports, service runtime wrappers, local configuration
executors and protocol diagnostics engines are not migrated. Boot/enrollment API
controllers are not UI presentation and are excluded: Netboot/Identity execution
and authority remain Worker-only. Existing business release dependencies,
supervision, database schemas, active routes and asset build entry points are
unchanged. Management configuration does not imply Worker execution or observation.

The migrated pages still contain original backend references, structs, route
links and event handlers that need redesign. They are not connected to new
backends and may fail to compile or mount. Some original handlers directly refer
to legacy service APIs; they are source to redesign, not authorization to import
those runtimes into Management. Do not expose these pages by wiring old routes
or copy service libraries merely to make them run. No native service backend,
Worker runtime repair, placeholder result or dependency workaround is added.

## Source-only verification

```sh
devenv shell -- python3 scripts/e2e/check_ui_source_migration.py
```

The checker requires complete current/historical source coverage and exact
mechanical transformations for all 201 files, not just matching file counts.
Historical coverage includes shared components, mount hooks and frontend assets
as well as pages/templates; those groups cannot be silently omitted from the
manifest merely because current source no longer contains them.
For every live or controller-presentation source path, it also requires both differing current/historical
content hashes to be represented. A path-only union cannot prove that both
presentations survive; the stricter guard rejected the earlier transfer before
the alternate revisions were added.
Elixir source syntax is checked with `Code.string_to_quoted!/2`, without compiling
or starting apps. JS syntax is checked separately. These checks do not establish
HEEx compilation, asset bundling, functional migration or runtime acceptance.
No business tests, PostgreSQL, service startup or browser smoke is required by
this transfer; the earlier architecture report is historical evidence for its
earlier source state, not a compilation guarantee for this later UI transfer.

The earlier 130-file check passed path coverage but did not prove presentation
coverage across revisions. The source audit found the omitted alternate forms,
original Netman status presentation and hex formatter; those are now retained.
Full compilation, HEEx compilation, asset bundling, business tests and runtime
acceptance are not part of this source-only transfer.

The prior 199-file source audit is recorded at
`/tmp/yellow-dog-ui-source-audit.CPuwSt.log`. The later completion audit below
supersedes that inventory; neither audit proves full functional redesign.

## Clarified goal completion audit (2026-10-05)

The current goal explicitly requires retaining the original functional pages,
not implementing their business functions now. Source retention in the current
Management UI tree is therefore the completion gate; later redevelopment and
runtime acceptance remain separate tasks.

Independent route coverage verified all 95 historical LiveView routes (62 page
modules) and 91 current routes (63 page modules). It also found the historical
controller-rendered home presentation missing from the earlier transfer. The
checker now includes controller presentation revisions and first reproduced
that omission; the historical home template and companion module are retained
under `redesign/original/controllers/`, without changing active routes.

Fresh checks passed: the full source/revision/hash checker covers all 201 files;
all 162 Elixir files parse with 166 unique module declarations; migrated JS
passes `node --check`; and `git diff --check` passes. No full compilation,
backend implementation, route activation or service startup is claimed.
