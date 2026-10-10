# YellowDog — Management Configuration and IP Database Implementation Plan

## 1. Task and reviewed baseline

Implement this bounded Management-side increment in `gsmlg-dev/yellow-dog`.

The reviewed remote `main` is `0301404b18b9faffa629982d5035474524f4c21e` (2026-10-05). Verify the actual checkout and preserve existing working-tree changes. Do not reset to this commit or assume that the operator's checkout is identical. This plan is based on source inspection, not newly executed compilation, database, browser, or release tests.

The deliverable is working Management UI and persistent configuration, with explicit Worker selection on DNS Views and Zones, plus centrally synchronized, versioned IP database artifacts. Actual Worker connectivity, delivery, loading, and network-service execution remain a later increment.

This task advances the selected workflows beyond the previous source-retention-only milestone. It does not authorize redevelopment of all retained Console pages.

### Accepted decisions

| Area | Required behavior |
| --- | --- |
| Management | Own configuration editing, PostgreSQL persistence, logical Worker metadata, assignments, and IP database synchronization. |
| DNS View | Belong to one DNS Service instance; that Service identifies the logical Worker. The Worker selector chooses the authoring scope. |
| DNS Zone | Remain globally reusable. Select multiple logical Workers and their DNS Service instances through assignments to confirmed Zone versions. |
| Child configuration | Records, SOA fields, and rules inside a View inherit their enclosing resource's scope. Do not add independent Worker selectors to them. |
| IP Database | Be a global artifact catalog synchronized by Management. No separate manual per-Worker assignment UI on this page. Future consumers derive their database requirements from service configuration. |
| Execution Worker | Later obtain pinned artifacts from Management, verify and persist them locally, and perform local lookups. Management availability must not be required for ongoing lookups. |

A logical Worker record is sufficient for configuration. A real Worker process does not need to exist or be connected. Creating valid global Zone drafts must also work with zero logical Worker records.

## 2. Boundaries and non-goals

Preserve the two independent business releases, `yellow_dog_management` and `yellow_dog_worker`, and the pure shared `yellow_dog_config_spec` boundary. Do not reconnect legacy Console, Store, Agent, Concord/Mnesia, DNS, or DHCP runtimes to Management. Management-local Oban download jobs are allowed; an Oban job module named `*Worker` is not an execution Worker.

Do not implement Worker enrollment, authentication protocols, sockets/channels, polling, push delivery, GeoIP runtime loading, or service repair in this increment. Netboot and Identity execution/authority remain Worker-owned and out of scope.

Do not expand DNS record types, implement new DHCP/mDNS features, invent a new View–Zone relationship, introduce globally shared multi-Worker Views, or build a generic resource framework. Preserve the existing ACL ownership model; adding selectors to standalone ACL or unrelated configuration pages is not part of this task.

There is no released-data compatibility requirement. Use ordinary Ecto migrations for necessary schema changes; do not build legacy-data conversion layers or reset a non-disposable database. Preserve user source changes and retained UI presentations/provenance.

Use existing DuskMoon components and tokens. Do not replace the design system or copy its internals. Keep validation and transformation functions pure where practical, with database/file side effects at explicit boundaries.

Do not commit, push, open a PR, deploy, or change real DNS/network configuration unless separately authorized.

## 3. P0 — Establish the baseline and resolve build prerequisites

Read `AGENTS.md`, `CLAUDE.md`, relevant application instructions, `docs/phase1/architecture-completion.md`, and `docs/phase1/ui-source-migration.md`. Treat historical test reports as historical evidence, not acceptance of the current checkout.

Inspect the active router and distinguish native Management pages from retained `ManagementUI.Redesign` sources. Work on the pages that are actually routed; a disconnected copy with new controls is not delivery.

Run a reproducible Management compile and the relevant existing tests through the repository's Nix/devenv environment, using disposable PostgreSQL. Record the checkout SHA and pre-existing failures before editing.

The retained compiled UI sources may have pre-existing build blockers. Resolve necessary blockers as a clearly separated, minimal prerequisite without importing old runtimes, adding fake service modules, or deleting retained presentations. Do not silently bypass provenance checks or exclude broad source trees merely to obtain a green build. If a blocker cannot be resolved within these boundaries, identify the exact files and errors and report the deliverable as blocked, not completed.

Update stale source-only scope documentation for the workflows authorized here. Do not rewrite historical evidence to claim that it tested new behavior.

**Exit condition:** the supported Management build and test path is executable, or a concrete blocking prerequisite is reported before functional completion is claimed.

## 4. P1 — Implement Worker selection and persistent Zone assignments

### 4.1 DNS View: make the existing scope explicit

Relevant starting points are `management/dns_view.ex`, `management/dns_views.ex`, `management_ui/live/dns_views_live.ex`, and `management_ui/router.ex`, under `apps/yellow_dog_management/lib/yellow_dog/`.

Use the existing `View -> Service -> Worker` ownership chain. Do not add another authoritative `worker_id` to View merely for the UI.

Provide Worker selection on the View configuration page. A Worker-specific entry point preselects its Worker; a Management-level entry allows selection before creating a View. Display the selected Worker and Service clearly in the editor and list context.

When a Worker has exactly one eligible DNS Service, preselect it. When it has several, require an explicit Service choice. When it has none, show the prerequisite and a route to Service configuration; do not create a Service as a hidden side effect.

Validate Worker existence, Service existence, Service type, and Service ownership on the server. Include registered but disconnected Workers. Never authorize a mutation using browser-supplied scope alone.

Changing the selector changes the editing scope, not the ownership of an existing View. Reset the loaded resource and form appropriately, with explicit handling of unsaved changes. Do not silently move or duplicate an existing View. Preserve default-View invariants per Service.

### 4.2 DNS Zone: edit assignments from the resource page

Relevant starting points are `management/schemas.ex`, `management/domain.ex`, `management_ui/live/zones_live.ex`, and `management_ui/live/worker_live.ex`.

Keep Zone/RRset data global. Do not add a Zone owner Worker, store a second authoritative `worker_ids` array, or copy a Zone for every Worker. Reuse the existing Service/Zone/ResourceVersion Assignment relationship.

Add a **Worker assignments** section to the Zone page. Show Worker names, Service instances, and the confirmed Zone version selected for each target. Allow multiple Workers. Disambiguate multiple DNS Services using the same rules as the View editor.

Keep **Save draft** and **Save assignments** as distinct commands with distinct success/error messages. A Zone with no confirmed version remains editable, but assignment requires confirming a version first. Saving a draft or confirming a new version must not automatically retarget existing assignments.

Both the Zone page and existing Worker page must read and mutate the same assignment records. Removing Worker A's assignment must not remove Worker B's assignment or delete Zone data. Preserve deletion protection and historical versions/Targets.

Apply one assignment submission atomically across all affected Workers/Services. Validate the full submitted set before committing. Reuse the Management command boundary, audit, and idempotency mechanisms rather than writing directly from LiveView.

Detect stale edits to the assignment set, not only stale Zone content revisions. Use an appropriate assignment-set concurrency token/snapshot and affected Worker revisions, or an equivalent tested aggregate design. Apply a consistent lock order across all mutation entry points. A stale bulk submission must not silently erase a concurrently added assignment.

Respect the active plan's version-reference constraints. Different Workers may select different confirmed versions; conflicting versions of one Zone within a single Worker target must produce a clear validation error rather than silently choosing one.

**Exit condition:** View scope and Zone assignments can be edited with no running Workers, survive fresh database reads and Management restart, and remain consistent across both UI entry points.

## 5. P2 — Complete the in-scope persistence and editor behavior

Keep UI and API mutations behind the same Management business boundary. Preserve database transactions, revision checks, audit records, and idempotency. Reuse existing mechanisms rather than replacing the entire Domain module.

After successful saves, reload canonical data from the backend. Reloading the browser or opening a fresh session must show the same values and assignments. A database failure must never produce a success message or leave partial assignments.

On validation or revision conflicts, preserve the user's unsaved input and show a useful error. Do not silently overwrite another editor's changes. Associate retries of the same logical submission with a stable idempotency key; a new edited submission receives a new key. Disable duplicate submission while pending, without treating this as a substitute for backend protection.

Use truthful, distinct UI concepts: **draft saved**, **version confirmed**, **assignment saved**, and **target prepared**. None means delivered, loaded, running, or healthy. Worker actual state remains unknown until real reporting exists.

Do not redesign the record editor beyond changes required for these workflows. Existing valid record saves must continue working without Worker-specific fields.

**Exit condition:** actual database, LiveView, and browser behavior proves persistence and failure handling, not merely a success flash or an updated socket assign.

## 6. P3 — Make IP Database a Management-owned artifact catalog

### 6.1 Preserve download safety; remove runtime activation from publication

Inspect `management/geo_ip_download.ex`, `management/sync_geo_ip_worker.ex`, `management/task_artifacts.ex`, `management/task_schemas.ex`, `management/geo_ip.ex`, and `management/application.ex`.

Reuse the existing bounded download, decompression, MMDB validation, digest-addressed file storage, and task infrastructure. Keep manual and scheduled synchronization for the supported Country and City databases. Preserve controlled server-side source selection; do not accept arbitrary browser-supplied URLs or filesystem paths.

Separate the pipeline into download, bounded validation, durable immutable file publication, and database publication of the artifact/selected version/task receipt. Publication must not call `Management.GeoIP.activate`, require a resident lookup database, or depend on a running Worker.

PostgreSQL stores metadata and selection/history references; the MMDB bytes stay in the configured durable artifact directory. The content digest identifies an immutable dataset. Preserve database kind, digest, byte size, format/metadata, build information when supplied, source, and synchronization timestamps. Country and City have independent current selections.

A successful job requires a valid durable file and committed metadata. Retrying identical content reuses its artifact. A failed download, invalid file, database transaction failure, or stale job retry must not corrupt or replace the last valid selection. Preserve job-attempt/idempotency guards and prevent an old receipt/retry from reverting a newer selected artifact.

Filesystem and PostgreSQL publication are not one atomic transaction: publish the immutable file before making it selectable. A later database failure may leave an unreferenced file, never a selected partial file. Do not add aggressive garbage collection; retain artifacts referenced by selections or historical metadata.

After restart, reconstruct the catalog from persistence without loading a lookup database. Missing or invalid files must not be advertised as distributable solely because a metadata row exists.

### 6.2 Replace local runtime controls with artifact management

Inspect `management_ui/live/ip_database_live.ex`, the related GeoIP tool page, navigation, and tests.

Make IP Database show source/schedule, synchronization state, last success/failure, available dataset versions, selected digest, size, and artifact metadata. Keep queue/sync and history actions. Remove Management-local **Reload**, **Unload**, **Loaded snapshot**, and local lookup-process state from this page.

Show synchronization job state separately from artifact availability: a failed new sync can coexist with a previously available valid artifact. Queued is not synchronized; synchronized is not delivered; delivered is not loaded.

Do not require a resident Management GeoIP query process for this workflow. Short-lived parsing for validation/metadata remains allowed. Adjust application supervision and callers accordingly. Do not move the entire Management module into Worker or leave broken local-query buttons/routes. Until a Worker-backed diagnostic exists, remove the misleading entry or show an explicit unavailable state without a fake result. Update tests for this intentional behavior change.

Do not add manual per-Worker database selection. Expose catalog lookup by kind/digest for later integration, but do not implement the Worker transfer client or a new delivery protocol.

**Exit condition:** fixture-backed synchronization, catalog persistence, retries, failure handling, and the Management UI work with no Worker and no long-lived Management GeoIP lookup process.

## 7. P4 — Preserve current exports and document the next integration boundary

Keep existing supported Zone target preview, confirmation, and TOML round-trip behavior working. Do not modify the active WorkerPlan schema merely to implement selectors or artifact metadata, and do not create a competing wire format inside Management.

Be explicit that this increment does not complete View/GeoIP serialization or delivery. Existing limited exports must disclose their scope; do not claim they contain new data that the codec cannot represent. An explicitly requested full export involving unsupported features must return a clear unsupported/incomplete result rather than silently dropping configuration. Do not mislabel that restriction as an inability to save drafts.

Document the later integration contract without implementing its runtime:

- Derive required database kinds from the effective configuration assigned to a Worker, not from a separate manually maintained recipient list. Country-dependent rules need a suitable country dataset; City data is needed only when a configured feature actually consumes it.
- Freeze exact artifact references when creating a distributable target. References contain logical kind/format, digest, and size, not Management absolute paths, upstream credentials, or expiring URLs. Historical targets must not resolve mutable `latest` references at delivery time.
- Transfer database files separately from TOML. Worker verifies and durably stores the file, switches only after successful local loading, retains the last valid version on failure, and reports the digest actually in use.
- Initial installation without a required dataset must report the missing dependency and avoid pretending a dependent feature is ready. Disconnecting Management must not invalidate data already accepted locally.

These are requirements for the next increment, not current Worker acceptance claims.

## 8. Required verification

Execute relevant tests in the Nix/devenv environment with disposable databases, isolated artifact directories, and controlled local HTTP/MMDB fixtures. Do not depend on a live upstream provider, the developer's existing cache, a running execution Worker, or privileged network ports.

| Area | Minimum evidence |
| --- | --- |
| View scoping | Disconnected Worker is selectable; single/multiple/no-Service cases; invalid or cross-Worker Service rejected; changing scope does not leak edits or reparent Views; default invariants preserved. |
| Zone persistence | Valid draft creation with zero Workers; fresh-session readback; confirmed versions remain immutable. |
| Assignments | One Zone assigned to two Workers without data copies; removal affects only its target; both pages agree; stale/invalid bulk submissions have no partial effects; assignment concurrency is exercised. |
| Editor reliability | Validation and database failures retain input; conflicts are visible; submission retry is idempotent; new edits receive a new request identity. |
| Artifact publication | Valid Country/City files; corrupt/wrong-kind/oversized input; duplicate-content retry; stale retry after newer selection; filesystem/database failure preserves last valid selection. |
| Restart and availability | Metadata, selection, and files survive a new Management process; missing selected file is reported unavailable; no GeoIP query-process activation is required. |
| IP UI | Task state differs from artifact availability; no local reload/unload; no false Worker delivery/loading status or broken lookup entry. |
| Regression/boundaries | Existing supported Zone exports remain immutable and round-trip correctly; Management does not start execution services or import legacy runtimes. |

Run focused ExUnit/LiveView tests, browser tests for the changed flows, scoped formatting, and compilation with warnings-as-errors. Reuse `scripts/e2e/phase1_postgres.sh` for disposable PostgreSQL and `scripts/e2e/architecture_smoke.sh` for applicable release-boundary verification. Inspect each script before using it against the current checkout. Do not repair deferred Worker runtime failures as part of this task or weaken their assertions to obtain a pass.

### End-to-end demonstration

Start only Management and disposable PostgreSQL. Create a Zone before any Worker records exist. Register two disconnected logical Workers with DNS Services, create a View in a selected scope, confirm Zone v1, and assign that version to both Workers from the Zone page. Verify both Worker pages show the same assignment records. Refresh and restart Management and verify persistence.

Edit and confirm Zone v2 without changing v1 assignments or historical Zone targets. Remove one assignment and verify the other survives. Run a fixture-backed IP database sync, verify its durable catalog entry without a query process, then fail a later sync and verify the previous artifact remains available. No step may report Worker execution or delivery.

## 9. Execution order and final report

Complete P0 first. P1/P2 and P3 may then proceed in separate branches/worktrees, with one integrator coordinating changes to Domain, router, application supervision, migrations, shared tests, and documentation. Complete P4 and integrated verification before declaring the increment done. Do not dispatch the deferred Worker work in parallel.

Keep prerequisite fixes and the functional milestones reviewable as separate changes. Include targeted regression tests with each change.

The final report must state the actual starting/ending revision and working-tree state, modified files and migrations, commands run and their real results, and each milestone's status. Distinguish tested behavior, source inspection, pre-existing blockers, and deferred features. Include concise reproduction steps for the end-to-end demonstration.

Completion requires working Management configuration persistence and artifact synchronization under these boundaries. Source presence, a queued job, a success notification, historical test logs, or metadata without a valid file is not sufficient evidence. If blocked, report the exact blocker and completed subset rather than claiming full acceptance.
