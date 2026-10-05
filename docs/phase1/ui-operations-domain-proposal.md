# Management operations domain: tasks, artifacts, and recovery

**Prior architecture-only scope (2026-10-04).** Subsequent source-only UI transfer
is recorded in `ui-source-migration.md`; it does not implement the proposal below.
Unimplemented
operations below remain future work. Management owns configuration; network
services, including Netboot and Identity, execute only on Worker. Management-local
backup/artifact tasks are not Worker service execution or observations. Worker
runtime failures do not block the current architecture deliverable.

## Status and approval boundary

**Historical proposal, partially superseded by current task and backup implementations.**
The bounded task slice now implements PostgreSQL definitions, Oban durable jobs,
City/Country artifact download/validation/selection and actual task-history UI.
It uses Oban rather than the proposed custom PG executor below. MAC sync remains
blocked by upstream #8. Current backup create/list/byte verification/download and
confirmed deletion are implemented; the parent reports updated native/release/
Chromium E2E passing, followed by the final 33-test scoped suite and owned-file
formatting passing, including the IPv6 parser addition.
Destructive recovery, cloud-provider tasks and remote service observations remain
proposals/unimplemented. The implementation
and reproducible checks are documented in the Management README and
`ui-migration-matrix.md`; proposed records below are not its schema.

Source review baseline: `main` at
`d83442c0b12deb3173b9e96ca643061b070e6a58`, including the shared uncommitted
Management migration work present on 2026-10-01. The original proposal introduced
no runtime changes; the subsequent task slice introduces only Management tables,
Oban/Mint dependencies and local artifact operations, not a shared protocol.
Pending feature/ownership decisions need
coordination, but blanket approval of every PostgreSQL table was assistant-imposed,
not a user mandate. Explicit confirmation requirements for Mnesia, shared protocols
and global configuration loading remain applicable.

The objective remains functional preservation of the original Console operations,
with business logic redeveloped for standalone Management. A disabled button,
placeholder, or proposed table is not migrated functionality. This bounded proposal
does not claim full Console parity or authorize Phase 2 network integration.
Original routes/events below are evidence of business operations, not an acceptance
checklist of old URLs/APIs. This design stage requires no old backup imports,
legacy identifiers or previous/forward software-version compatibility. Immutable
business history and safe recovery of the current dataset remain required.

Controlling constraints come from
`yellow-dog-phase-1-parallel-refactor-plan-en.md` sections 1–3 and current
`CLAUDE.md`: Management owns PostgreSQL desired business data; Worker executes
local TOML independently. No legacy Store, Console, Agent, task runtime, or local
network service may be imported into the supported Management runtime. Existing
ConfigSpec and SOA/NS/A support stay unchanged. No legacy data/backup migration or
dual writes are proposed.

Management currently has no built-in UI/API login or authorization. The requested
development listener binds `0.0.0.0:4270`; neither loopback nor LAN access proves
operator identity. Wider exposure requires an
explicit trusted deployment or external authorization/TLS proxy. Destructive
restore and outbound jobs require a separate authorization decision; this proposal
does not silently add login or treat an actor label as authenticated identity.

## 1. Source evidence and original operation coverage

Paths below are repository-relative. Symbols identify the inspected behavior,
not dependencies to reuse at runtime.

| Original route / capability | Source evidence | Fields, events, and actual dependencies |
| --- | --- | --- |
| `/system/tasks` | `apps/yellow_dog_console/lib/yellow_dog/console/live/tasks_live/index.ex`, `handle_event/3` | “Data Sync Tasks”; task label/key, status, enabled, cron, source; `refresh`, `run_now(task)`, `save_task_config(task_key, task[enabled], task[cron])`; `YellowDog.Tasks.list_tasks/enqueue/update_task`. Queued flash follows `{:ok, job}`, not just a click. |
| `/system/tasks/:task` | `apps/yellow_dog_console/lib/yellow_dog/console/live/tasks_live/show.ex` | Status, Enabled, Schedule, Recent Jobs; job ID, state, attempt/max_attempts, inserted time, last error; `run_now`. Ledger unavailable is distinct from an empty history. |
| `/system/backups`, `/system/backups/restore` | `apps/yellow_dog_console/lib/yellow_dog/console/live/backups_live.ex` | Optional label; File, Timestamp, Size, Entries; `update_label`, `create_backup`, `refresh`, `verify(path)`, `dismiss_verify`, `restore(path)`, `cancel_restore`, `do_restore`, `delete(path)`; asynchronous create/verify/restore and real failures. Restore confirmation warns about replacing data. |
| `/system/backups/download/:filename` | `apps/yellow_dog_console/lib/yellow_dog/console/controllers/backup_controller.ex` | Local backup download, basename selection and disposition sanitization; not an arbitrary file-download API. |
| `/system/ip-database` | `apps/yellow_dog_console/lib/yellow_dog/console/live/ip_database_live.ex` | City/Country Lite downloads queue `ip_city`/`ip_country`; `refresh`, `download(type)`, `unload(name)`; type, build epoch, IP version, node count, record size, languages, path, file size; links to task history. |
| `/system/mac-database` | `apps/yellow_dog_console/lib/yellow_dog/console/live/mac_database_live.ex` | “Update Database”, “Queue MAC/OUI sync”, history, “Reload from Disk”; `refresh`, `download`, `reload`, `test_lookup(mac)`; source, entries, load time, path, file size/mtime, short/full vendor, invalid/unknown lookup distinctions. |
| `/system/logs`, `/system/logs/realtime`, `/system/logs/tasks` | `apps/yellow_dog_console/lib/yellow_dog/console/live/logs_live.ex` | Category navigation; `toggle_pause`, `clear`, `toggle_app`, `select_all_apps`, `select_no_apps`, `set_level`, `search`, `export_csv`, `toggle_expand`; realtime ring/filter/metadata UI. `task_log_entries/1` derives start/stop entries from genuine `recent_jobs` timestamps, not invented process logs. |
| DNS query logs | `apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/query_logs_live.ex`, `load_logs/2` | `/server/:server_id/dns/logs`; `refresh`, `select_view`; time, query name, action; `ServerManagement.dns_logs_list(server_id, view_name)`. |
| DHCP activity | `apps/yellow_dog_console/lib/yellow_dog/console/live/dhcpv4_live/activity_live.ex`, `apps/yellow_dog_console/lib/yellow_dog/console/live/dhcpv6_live/activity_live.ex` | `/server/:server_id/dhcpv4/activity` and `/dhcpv6/activity`; `search`, `filter_type`, `refresh`; family-specific `dhcp_status_get` and `dhcp_activity_list`; address/client/details/action filtering and cached observation time. |
| Netboot log | `apps/yellow_dog_console/lib/yellow_dog/console/live/netboot_live/log_live.ex` | `/server/:server_id/netboot/log`; search/type/level, pause, `clear_log`, `export_csv`; time, log ID, device, level, message; `netboot_logs_list`. In inspected source, clear is unavailable and export handler is a no-op: labels do not prove implementation. |
| Identity audit | `apps/yellow_dog_console/lib/yellow_dog/console/live/identity/audit_live.ex` | `/server/:server_id/identity/audit`; action, subject link, occurred time; `identity_audit_list`; explicit cached snapshot/error state. This is not Management mutation audit. |

The `/system/logs/dns-query`, `/dhcpv4-activity`, `/dhcpv6-activity`, `/netboot`,
and `/identity-audit` links redirect into selected Server pages in
`apps/yellow_dog_console/lib/yellow_dog/console/router.ex`. They do not themselves
collect logs.

Additional business evidence:

- `apps/yellow_dog_tasks/lib/yellow_dog/tasks.ex`: enqueue/config/history API;
  cloud-zone tasks validate legacy authoritative zones, mirror enablement and
  matching Cloudflare/Route53 providers.
- `apps/yellow_dog_tasks/lib/yellow_dog/tasks/data_sync.ex`: registry keys
  `ip_country`, `ip_city`, `mac`, dynamic `cloud_zone:<view>:<zone>`; labels
  “IP Country”, “IP City”, “MAC/OUI”; source identifiers `db-ip` and
  `wireshark-manuf`; download followed by actual database checks.
- `apps/yellow_dog_tasks/lib/yellow_dog/tasks/job.ex`, `runner.ex`, `store.ex`,
  `task_status.ex`, `config.ex`: persisted jobs before execution, claims/attempts,
  errors/retries, minute reservations, cron/timezone, recent history and unavailable
  status. Legacy terminal states are `completed`/`discarded`; retention is 500
  terminal jobs per task. Defaults use three attempts, country `0 3 2 * *`, city
  `30 3 2 * *`, MAC `0 4 * * SUN`, timezone `Etc/UTC`. These are historical scheduling
  evidence, not permission to enable outbound work automatically.
- `apps/geo_ip_db/lib/geo_ip_db/download.ex`: monthly DB-IP Lite URL
  `https://download.db-ip.com/free/dbip-<city|country>-lite-YYYY-MM.mmdb.gz`,
  gzip, validation and temporary-file replacement. Its runtime downloader is not
  a ready-made bounded Management task executor.
- `apps/yellow_dog_fingerprint/lib/yellow_dog/fingerprint/oui_database.ex`:
  `https://www.wireshark.org/download/automated/data/manuf`, file replacement and
  reload. Do not start the legacy Fingerprint application to preserve this action.
- `apps/yellow_dog_store/lib/yellow_dog/store/backup.ex`: inspected backup is
  Concord with an ETS fallback, including compressed Erlang terms, namespace
  counts and checksum. Legacy lease/device/cache/RPZ data and reset/repopulate
  restore are not a PostgreSQL Management recovery design; neither a Mnesia nor
  a Concord backup implementation should be copied.
- `apps/yellow_dog_console/lib/yellow_dog/console/server_management.ex`:
  typed Server queries distinguish runtime from cached observations and desired
  drafts. `apps/yellow_dog_sync/lib/yellow_dog/sync/server_operation.ex` defines
  `server.dns.logs.list`, `server.dhcp.activity.list`,
  `server.netboot.logs.list`, `server.identity.audit.list` outside Phase 1.
- `apps/yellow_dog_management_core/lib/yellow_dog/management/commands.ex` and
  `snapshots.ex`: historic remote request IDs, idempotency fingerprints,
  unresolved/unknown outcomes and requested/observed/received timestamps. These
  semantics are useful evidence; JSON journals/transports are not dependencies or
  an approved replacement for Management PostgreSQL.

## 2. Current standalone coverage and honest remaining work

Current Management sources provide real local capabilities:

- `apps/yellow_dog_management/lib/yellow_dog/management/mac_database.ex`:
  `info/1`, `lookup/2`, bounded configured-file `reload/1`, compiled fallback,
  retained successful snapshot on failed replacement. File size/mtime describe
  the **last successfully loaded artifact**, not necessarily current disk bytes.
- `apps/yellow_dog_management/lib/yellow_dog/management/geo_ip.ex`:
  `info/1`, `lookup/3`, configured-file `reload/2`, `unload/2`; genuine local MMDB
  state, not Worker geolocation state or a download queue.
- `apps/yellow_dog_management/lib/yellow_dog/management/log_stream.ex`:
  actual Management OTP Logger capture, ring of at most 1000, topic
  `management:logs`. Restart loses the ring. It is not durable job history and
  does not ingest Worker logs.
- `apps/yellow_dog_management/lib/yellow_dog/management/domain.ex`:
  PostgreSQL desired-domain mutations, expected revisions, transactional audit
  and idempotency; no durable operations queue or backup API.
- `apps/yellow_dog_management/priv/repo/migrations/20260930000000_create_management_domain.exs`:
  logical Workers, zones/RRsets, immutable resource versions, services,
  assignments, immutable targets, audits and idempotency. Immutable versions,
  targets and audits reject UPDATE/DELETE through database triggers.

Queueing/download/history, durable task logs and PG+artifact backup/restore remain
unmigrated. Cloud-provider sync also lacks the new desired provider/credential and
import business model. Worker logs, DHCP leases/activity, Netboot state and
Identity runtime audit remain unavailable without approved observation contracts.

**MAC blocker remains intact:** the parent reports upstream
`gsmlg-dev/gsmlg_umbrella#8`: packaged input has 48,087 unique prefixes but compiled
lookup has 47,784 entries. The current loader checks count parity, and
`apps/yellow_dog_management/test/mac_database_test.exs` contains the required
“packaged GSMLG manuf artifact reload preserves source parity” regression.
These counts/failure are the parent's evidence, not a check rerun for this doc.
Do not weaken that gate, filter mixed-width prefixes, substitute a fake successful
download, or count compatible fixtures as full packaged-MAC parity.

## 3. Minimal recommendation and alternatives

Recommend a PostgreSQL operations ledger inside Management plus a private local
immutable artifact directory. An allowlisted Management executor performs only
self-owned operations. Database rows are the durable queue and history; PubSub
and Logger are notification/diagnostic mechanisms, never the source of success.
No arbitrary module name, shell command, URL, target path or Worker operation is
accepted as a task argument.

| Alternative | Assessment |
| --- | --- |
| Reuse the legacy Tasks/Store runtime | Reject: introduces legacy Concord/service dependencies and the wrong ownership boundary. |
| Add a general PG job framework | Possible after explicit dependency approval; it must still provide durable attempts/outcomes, fencing and artifact coordination. Do not add it as part of this proposal. |
| Small PG ledger and supervised Management executor | Recommended bounded option, provided the claim/recovery tests below are mandatory. More responsibility than a framework, but no legacy runtime or new protocol contract. |

Executable kinds after approval: local IP/MAC download-and-validate, local reload/
unload, backup create/verify/delete, and controlled restore preparation. Local
restore **cutover** belongs to an out-of-process maintenance operator because it
replaces the database used by the queue itself. External provider DNS import can
become Management-owned desired-data work only after separate business-model
approval; it is not a Worker sync command.

## 4. Proposed PostgreSQL records

Names are proposed, not a migration specification. All IDs are UUIDs except
bounded allowlisted task keys; timestamps are UTC with microsecond precision;
enums are closed strings, not input-created atoms. JSON inputs/errors/results are
schema-validated, size-bounded and secret-redacted. Foreign keys prevent deletion
of referenced artifacts/history. An audit records accepted and rejected mutations;
actor provenance must say whether externally verified or merely supplied.

| Record | Required fields | Constraints / ownership |
| --- | --- | --- |
| `management_task_definitions` | `key`, `kind`, `label`, `source_id`, `source_policy_version`, `enabled`, nullable `cron`, `timezone`, `max_attempts`, `revision`, created/updated times | Known registry only; CAS revision for config edits; validate cron/timezone. Preserve original keys/labels where applicable. New installation scheduling disabled until approved; manual enqueue is explicit, not implicit permission to bypass policy. |
| `management_operation_jobs` | `id`, `task_key`, `kind`, `queue`, immutable validated `args`, definition/source-policy revision snapshots, `trigger` (manual/schedule/recovery), requester provenance, `idempotency_key`, request digest, optional schedule occurrence, `state`, `attempt_count`, `max_attempts`, `available_at`, inserted/started/completed/discarded times, claim owner/token/expiry, optional parent job and recovery lineage | Unique request scope+key; different request digest conflicts. Unique task+definition revision+UTC schedule occurrence. Job state is a projection of committed attempts; args do not change on retry. Queue never contains remote Worker commands. |
| `management_operation_attempts` | `id`, `job_id`, `number`, executor boot ID, claim token, started/finished times, phase, outcome, structured error, bounded diagnostic, validation/result metadata, artifact/backup references | Unique job+number. Open row becomes sealed on finish; sealed outcomes immutable. Outcomes distinguish success, failure, interrupted/unknown and cancelled. Retrying creates a new row and does not erase prior failures. |
| `management_artifacts` | `id`, `kind`, SHA-256 digest, byte size, storage key, created time, producing job/attempt, source ID/policy/version, resolved source URI, fetched time, upstream release date/ETag if supplied, media/format version, validator name/version, validation summary, license/attribution | Catalog only durably published, validated regular files; unique content identity per kind, root-controlled storage. Metadata immutable. Digest covers exact bytes; not a substitute for semantic ConfigSpec digest or trusted publisher proof. Compiled fallback identified by build/dependency provenance, not a nonexistent downloaded file. |
| `management_artifact_selections` | local consumer key (`ip_city`, `ip_country`, `mac`), selected artifact ID or explicit built-in/unloaded selection, desired revision, audit reference, updated time | One selected local asset per consumer; selection is intent, not proof of loaded state. CAS changes; no Worker IDs, assignments or network delivery. External configured files require separate stable-copy/registration approval; do not mutate arbitrary configured paths. |
| `management_artifact_observations` | `id`, consumer key, executor boot ID, selection revision, artifact digest/ID when known, observed time, actual status, load time, entry/MMDB metadata, last successful file metadata, error, producing attempt | Append-only receipts from the real loader. Historical load receipts never imply current-process readiness after restart. Distinguish failed candidate from retained active digest. Unload is observed only after local handle removal. |
| `management_backup_sets` | `id`, label, creating job/attempt, creation time, current format/schema identity, manifest digest, bundle storage key/digest/size, dataset lineage, table counts, pinned artifact IDs, publication/deletion state | Published package immutable. Verification is a new attempt result, not editing package bytes. Physical deletion is separately audited and confirmed; unavailable/missing/corrupt is not an empty list. No self-referential package digest or cross-software-version conversion. |

Restore preparation/verification/approval receipts can initially be typed job
args and sealed attempt results, rather than another generic workflow engine.
A receipt binds backup ID+digest, target database identity, current dataset
generation, validation result digest, confirmation expiry and authorization
provenance. Durable externally supervised cutover receipts must survive loss of
the old database; their exact storage/ingestion contract is an approval item.

## 5. Queue, scheduling, recovery and truthful outcomes

1. Enqueue transaction validates kind/source/policy/permission, inserts the job,
   idempotency result and audit together. Return a job ID only after commit.
   Unavailable PostgreSQL means enqueue failed; no optimistic “Queued” flash.
   Runner startup failure leaves an accepted job with a visible error, not erased
   history. Broadcast only after commit; readers can recover through PG queries.
2. Definitions preserve enable/cron/source/history controls. Disabled means no
   automatic dispatch; manual eligibility is checked explicitly. Scheduler uses
   UTC occurrence identity with the selected IANA timezone, deduplicates DST
   repetition and concurrent ticks, and records enqueue in the same transaction.
   Recommended initial missed-tick policy: no catch-up storm after downtime.
3. Claim a due job transactionally with row locking (for example
   `FOR UPDATE SKIP LOCKED`), increment attempt count and insert its attempt.
   Per-consumer serialization prevents simultaneous MAC/IP activation; bounded
   global concurrency prevents download/backup resource exhaustion.
4. `available`/`scheduled` means committed eligible intent, not running.
   `executing` requires a live executor claim; UI also displays claim freshness.
   `completed` requires the kind's verified effect and committed outcome;
   exhausted failures become `discarded`. `cancelled` applies only after safe
   cancellation; `needs_review` exposes an outcome that cannot safely be retried.
5. Claim tokens fence late PG writes. They do not by themselves fence filesystem
   side effects: publication/selection needs the same consumer lock and generation
   check. Loss of PG/claim authority must stop activation and destructive effects.
6. Expired claims create an interrupted/unknown outcome. Inspect durable artifact
   identities before safe retry; never assert failure or success from timeout
   alone. Use bounded backoff and immutable input/source identity. Restore cutover
   is never automatically retried; backup deletion reconciles actual presence.
7. Schedule/state UI distinguishes active/succeeded/failed/idle, unavailable,
   recovery hold and needs review. Keep original recent-job fields and errors;
   terminal history retention must be approved, not silently pruned at 500 when
   backups/artifacts still reference it.

Initial explicit limits recommended for approval: three attempts for retryable
downloads, at most two simultaneous transfers and one activation per consumer.
Existing MAC loading limits (64 MiB, 30 seconds) provide a starting validation
budget; MMDB compressed/decompressed/time/disk limits need dataset-specific values
before enabling downloads. No unbounded read or decompression is acceptable.

## 6. Download, validation and local activation

Preserve original city/country/MAC buttons and task-history links, but implement
the entire accepted-job → fetch → validate → publish → activate → outcome chain.

- Use approved source IDs mapped to versioned HTTPS policies; freeze the resolved
  monthly URL/release in the job. HTTP 2xx or nonzero bytes are not success.
  Verify TLS; bound redirects, timeouts, response/decompressed size and disk usage.
  Revalidate host/address policy on redirects and connection; reject arbitrary
  UI URLs, credentials in URLs, loopback/private/link-local destinations and
  unexpected hosts unless separately authorized. Source licenses/attribution and
  redirect-host allowlists remain approval items.
- Stage in a private controlled directory, no symlink/path traversal, execute-bit
  payloads or user-controlled archive extraction. Validate actual MMDB metadata,
  supported type/IP version/tree structure and representative lookups; validate
  MAC prefix syntax, width handling, unique-prefix count and lookup parity.
  The existing upstream #8 failure blocks affected MAC activation/download parity,
  not unrelated compatible local lookups or PG design work.
- Flush validated bytes, atomically publish within the artifact filesystem and
  flush its directory before catalog commit. Crash before commit may leave an
  orphan file, never a successful job; bounded reconciliation can register/delete
  only validated, unreferenced orphans. A catalog row must not precede durable
  bytes. Content files remain immutable; GC honors selections and backup pins.
- Selection commit records desired local digest. Real loader receipt must prove
  the loaded digest and current boot identity before “completed/loaded.” Existing
  loaders' count/mtime-only APIs are not sufficient for this new identity claim:
  a future coordinated backend extension is needed, not fabricated evidence.
- Failed reload retains prior valid lookup state and selected/loaded distinctions.
  Publication can succeed while activation fails; show both phases and preserve
  the old observed digest. No Worker service was started or updated. Reload from
  configured disk and invalid/unknown lookup remain real independent operations.
- Treat IP unload as local process state, not deletion of source bytes or a Worker
  command. Whether unload persists across restart requires approval; the proposal
  recommends an explicit desired local selection rather than pretending current
  process state is durable. MAC compiled fallback remains explicitly labeled.

## 7. Task and service logs: observation boundary

`/system/logs/tasks` should project actual attempts: started time, sealed completion
or error, task/source/job/attempt ID, executor and artifact/result identity.
Label these **Management task events**, not raw Worker or OTP logs. Preserve
pause/search/severity/app selection, metadata expansion and CSV behavior; filter
retained entries, escape CSV/formula prefixes and display pagination/retention.
No attempt timestamp means no invented start/stop row. Logger events with job IDs
may assist diagnostics but do not commit a task outcome.

Current realtime page remains the genuine process-local Management stream.
“Clear” clears the view only, never audit/job history. Ring loss/drop and reload
boundaries must be visible. Do not add phantom legacy service app filters.

Future Worker query/event contracts require approval of trusted physical identity,
authorization, cursor/order/deduplication, clock/staleness/retention/privacy bounds,
capabilities, disconnect behavior and restart generation. Observation must carry
Worker/service identity, occurred/observed/received times, event ID/cursor and
actual loaded plan/resource digest where relevant. Unavailable is not zero leases,
empty logs, stopped service or success. A logical Worker row is not an authenticated
physical Worker; desired `running` is not observed running.

DHCP leases/activity, DNS queries, Netboot log/devices and Identity decisions
cannot be reconstructed from Management desired data, task jobs or its Logger.
Start/stop/reload, lease mutations and other network Worker commands need separate
contracts with unknown-outcome reconciliation. They are not entries in this local
task queue and are not approved here. Cloud-provider import, if later approved,
updates a draft with expected revision/provenance; it cannot bypass confirmation,
overwrite immutable versions or claim Worker application.

## 8. PostgreSQL plus artifact backup ownership

The bounded implementation uses a current-format package containing a PostgreSQL
custom-format logical dump, a bounded JSON manifest and captured immutable GeoIP
artifact files. Create/list, optional bounded labels, metadata, asynchronous
verify/dismiss, catalog UUID downloads and confirmed/cancelable deletion are
implemented through Management, Oban and the DuskMoon UI. Pending/deleting jobs
are polled and observed through PubSub; neither enqueueing nor an unchanged
pending catalog row is reported as success. This is a
Management recovery package, not a WorkerPlan, external resource source format,
or a legacy backup importer. Current tooling uses native PostgreSQL utilities
and a private tar package; no arbitrary upload/import path is offered.
Recover only the current design's dataset; retaining old or forward software
formats, building upgrade adapters and supporting legacy backups are not goals.
Do not deserialize untrusted Erlang terms or use legacy reset-and-put-many restore.

The database capture includes Management's current dataset: logical Workers, zones/RRsets, resource
versions, services, assignments, targets, audits, idempotency and approved
operations tables, with their relationships and historical provenance. GeoIP
artifact catalog rows are read from the same snapshot, and their immutable
digest-addressed files are copied and checked. Concurrent ordinary domain writers
and immutable artifact publication do not require a stop-the-world writer barrier:
changes outside the exported snapshot are outside this package. Concurrent schema
migration/DDL is unsupported, and this backup is not a schema migration or
software-version conversion workflow. Future artifact GC must respect capture
references; changing external/configured files are not included by filename alone.

Exclude Worker local snapshots/journals/runtime files, leases, device observations,
DNS cache, live OTP/ETS tables, Logger ring, sockets and process identities, and the
bytes of earlier backup archives. Other backup catalog records may remain in the
database dump. Exclude
deployment bootstrap/env credentials, PG roles/passwords, TLS keys and provider
secrets outside Management's dataset. The package is not an automatic secret
scrubber; requirements to reject newly embedded secrets remain a schema/security
review concern, not a claimed implemented detector.
Business/audit data may still be sensitive: controlled download, storage protection,
encryption/key management and retention require approval.

Current capture and publication boundaries:

1. The durable backup job opens a read-only repeatable-read transaction and exports
   one PostgreSQL snapshot. Manifest table counts and artifact catalog references
   come from that transaction; ordinary concurrent writers may continue. This is
   a snapshot-consistency boundary, not a destructive-restore maintenance fence.
2. Run the deployment's native `pg_dump --snapshot` against that same snapshot.
   Copy the referenced immutable GeoIP files and verify their digests/sizes.
   Use server-controlled arguments and protected connection environment settings,
   no shell interpolation or elevated database superuser for ordinary backup.
3. Seal the dump, manifest and artifacts in staging, compute package size/digest,
   and durably publish the package before recording its ready catalog receipt.
   Filesystem publication and database completion are separate boundaries;
   the parent reports a real publication-before-ready-commit failure followed by
   UTC-scheduled Oban retry adopting the identical immutable archive. This is
   package/catalog publication recovery, not destructive database recovery.
4. The dump may contain its own pending backup catalog row and in-progress creating
   job. Their later ready state, package digest receipt and job completion are not
   in that snapshot. Record the creating job and precompletion boundary in the
   manifest; do not create a circular package digest or claim the dump contains
   its own completed package receipt.

The current manifest records format, backup UUID/label/capture time, creating job,
snapshot and precompletion boundary, artifact root, per-table counts/total rows,
dump path/digest/size, artifact paths/digests/sizes and exclusions. Dataset lineage,
generation-bound recovery requests, build/tool provenance, current-schema
fingerprints and secret-reference policy remain proposed recovery prerequisites,
not additional implemented manifest guarantees.
Semantic desired-data digests, target revisions, zone versions and
source revisions must remain distinct. Checksums prove integrity, not trusted
origin; accepted import provenance/signature policy is an unresolved decision.

“Entries” becomes the manifest's Management row count with per-table breakdown,
not legacy leases/zones/config namespace counts. File/Timestamp/Size/Label and
verify/delete/download actions remain recognizable. Use opaque package IDs and
catalog-owned storage keys, never user-supplied restore paths. No legacy filename
route adapter is required; downloads resolve current catalog items under the
private backup root.
Deletion requires server-owned package selection and explicit confirmation;
cancellation queues no deletion. The durable job removes only that package and
reports actual deleted/failed state, retaining domain data, selected GeoIP files
and Worker state. There is no active destructive-restore path. Race-safe download
and any future restore-reference lifetime policy remain separate requirements,
not proof of full destructive recovery.

Parent-reported final scoped validation is 33 tests with 0 failures and owned-file
formatting exit 0 at `/tmp/yellow-dog-phase1-pg.rnbzBV`, including the IPv6 parser
addition. Strict development compilation and full backup-file formatting passed
earlier. The current full native/release/Chromium E2E passed at
`/tmp/management-backups-release-jhp6ctaz` and
`/tmp/yellow-dog-phase1-pg.z5YJp6`, covering concurrent-writer snapshot/counts and
isolated staging restore, identical-archive adoption after interrupted ready
commit, browser lifecycle/checksum/cancellation with retained business data, and
SIGKILL metadata/archive/artifact persistence. The development deployment's
unchanged read-only business snapshot is recorded at
`/tmp/management-backup-deploy-glvjms0z/baseline.json`. See the backup section of
`ui-migration-matrix.md` for exact boundaries; this documentation update reruns no
runtime checks. Destructive live/offline restore execution was not exercised and
remains unimplemented.

## 9. Current-dataset integrity and destructive restore safety

**Destructive restore execution remains unavailable.** The UI can select and
byte-verify a current package and acknowledge/cancel downtime requirements, but
cannot restore the live database or offer an executable restore CLI. Verification
reports `byte_integrity`, not full recoverability. Earlier isolated staging-PG
restore evidence does not establish a safe live cutover. A lifetime maintenance
fence, durable recovery hold and request/dataset-generation policy must be
implemented and verified before execution is exposed. The recommendations below
remain future recovery work, not current features.

Recommend **staged replacement database + staged artifact root + explicit offline
cutover**, not web-triggered truncation or in-place overwrite. Existing immutable
resource/target/audit triggers must remain enforced in the live database. Restore
data into a new empty isolated database using controlled schema/data ordering;
verify required triggers/constraints before making it writable. Never disable live
immutability or grant the normal web process database-drop privileges.

1. `verify` checks bounded manifest/package paths, regular files, hashes, scope,
   size/disk budgets and current-format identity. Inspect dump object inventory in isolation:
   an arbitrary dump may execute functions/DDL. Accept only approved source and
   schema objects; integrity alone does not make an uploaded dump safe.
2. Restore into staging with a dedicated least-privilege maintenance role, no web
   listener, task dispatch, outbound sync or Worker integration. Validate exact
   tables/types/FKs/uniqueness/checks/triggers, row counts, artifact links, resource
   and target digests by the supported ConfigSpec, and required secret references.
   Verification has levels: byte integrity, current-schema validity and actual
   staging restore; a checksum-only result cannot promise recoverability.
3. Validate the captured dataset against the current schema and supported
   ConfigSpec shape. Reject mismatched or unknown package/schema/resource identity;
   do not attempt upgrade/downgrade, previous/forward-version support, software
   migration or silent field removal. Use the current deployment's known dump/
   restore tools. No old Console/Mnesia/Concord import. This checks current backup
   recoverability, not a software-version compatibility matrix.
4. Present scope, source lineage, timestamp, target identity, lost post-snapshot
   changes and validation results. Require a typed destructive confirmation bound
   to package digest+target+current generation, short expiry and exclusive lock.
   A dialog/CSRF token is not authorization; under today's noauth deployment,
   production cutover stays an operator-only maintenance procedure unless an
   approved external authorization control is demonstrably enforced.
5. Before cutover, stop/drain all Management writers, connections and executors;
   create and verify a pre-restore recovery package. A stale receipt or changed
   target/generation invalidates confirmation. No concurrent parent automation is
   assumed to be fenced without an implemented maintenance gate.
6. Switch PG dataset and artifact-root selection together under externally
   supervised maintenance. Record old/new database/root/package identities and
   every step durably outside the database being replaced. Filesystem+PG switching
   is not one transaction: interrupted switch stays in maintenance, with explicit
   reconciliation and rollback. Do not expose a mixed dataset/artifact pair.
7. Start restored Management in **recovery hold**, with schedules/dispatch/outbound
   downloads disabled operationally, irrespective of restored definition values.
   Restored executing attempts are historical; fence old tokens and classify them
   interrupted/unknown, preserving prior outcomes. Require operator release of
   queued jobs/schedules; never blindly replay downloads or destructive actions.
8. Verify desired-domain reads/export, artifact validation and genuine local loader
   observations before declaring restore successful. Historical `loaded_at` and
   boot IDs do not prove new-process readiness. Remain in hold if assets are absent
   or activation fails; retain the old database/root for rollback.

Successful restore preserves captured immutable versions/audits exactly; it does
not rewrite history to appear newest. Record a new recovery generation/lineage
link and the external cutover receipt in the restored dataset. Retain the old
dataset's audit and post-snapshot operations for forensic continuity rather than
merging conflicting histories. Fresh UI sessions/idempotency request namespaces
must prevent pre-cutover stale requests from mutating an older restored revision;
exact generation propagation into the existing Domain gateway needs approval.
Once writes resume, rollback loses new work and requires a new explicit recovery
decision, not an automatic switch back.

Restoring Management desired data does not update Worker local files, restart
services, remove leases or prove applied targets. Export remains prepared desired
state. Any reconciliation after recovery is a separate approved network phase.

## 10. Pending feature and safety decisions

| Decision | Proposed bounded default / unresolved detail |
| --- | --- |
| Ledger/executor approach | Approve small PG ledger or name an approved framework; no new dependency is assumed. |
| Task permissions and noauth safety | Explicit deployment policy for outbound operations; operator-only restore cutover initially. External verified actor binding is unresolved; no built-in login redesign. |
| Source policy and licensing | Approve DB-IP/Wireshark endpoints, redirects, release identity, attribution, transfer/parse limits and credentials policy. Do not widen accepted formats to bypass #8. |
| Local asset ownership | Approve private artifact root and consumer selections; decide configured-path registration, restart/unload policy and digest-aware loader extension. No Worker resource format change. |
| Scheduler/retries/retention | Disabled new schedules, no downtime catch-up, bounded retries; approve timezone/DST semantics, concurrency/backoff and history retention without deleting referenced evidence. |
| Backup scope/toolchain | Full current Management dataset plus referenced artifacts; decide package encoding, PG utilities in the maintenance environment, integrity validation, storage quotas/encryption/retention. No previous/forward-version compatibility or legacy restore adapters. Runtime packaging changes are not authorized by this document. |
| Restore orchestration | Approve staged offline cutover owner, durable external receipt location, recovery hold, authorization, rollback window, all-writer barrier and dataset-generation propagation. |
| Cloud imports and Worker operations | Separate proposals/contracts required for provider credentials/import provenance and remote commands/logs/leases/runtime identity. This document cannot approve them. |

No additional schema design or runtime implementation should resolve these by
assumption. The parent owns approval and coordinated changes to Domain, Settings,
Application, routes and packaging.
This is a documentation-only assignment, not a claim that every ordinary PG table
needs separate user authorization. Resolve genuine feature/safety choices without
adding an artificial SQL approval gate.

## 11. Focused future acceptance evidence

These are required scenarios for a later implementation assignment, **not checks
executed for this document**:

- PG sandbox tests: enqueue commit/error, idempotency replay/conflict, invalid
  config rollback, two claimers/one attempt, concurrent schedule ticks, timezone
  boundaries, sealed outcome immutability, unavailable ledger versus empty history.
- Actual executor recovery: kill/restart around fetch, publication, selection and
  receipt; expired tokens cannot activate; safe retry reconciles bytes; uncertain
  effects stay unknown; restore never auto-retries or auto-requeues.
- Controlled HTTP fixtures: valid city/country/MAC, redirect/SSRF rejection,
  compression bomb/oversize/timeouts, invalid parse and failed reload retain prior
  lookup/digest, license/provenance shown. Packaged-MAC losslessness regression
  remains mandatory and blocked on upstream #8; no skips or weakened assertions.
- LiveView/browser: preserve original task/config/history fields and events,
  real queued IDs/errors, real local database metadata/lookup, last-loaded-file
  note, durable task-log filtering/CSV, no synthetic Worker app or observation.
- Disposable PG+filesystem recovery: ordinary concurrent domain writes retain a
  consistent exported dump/manifest/artifact-reference snapshot; concurrent schema
  migration/DDL is excluded; restore checks
  digests/FKs/immutable triggers; corrupted/foreign/mismatched-schema packages reject;
  path/symlink attacks reject; source/target lineage and generation remain explicit.
- Restore crash acceptance: pre-backup and confirmation, interrupted DB/root switch
  stays offline, safe rollback before writes, historical jobs not replayed,
  genuine new-boot asset observations, no old-session mutation, no Worker calls.

Documentation-only validation is limited to whitespace, assigned-path ownership
and existence of cited source files. No build, service, Mix/npm/Nix command, test
or upstream failure gate was changed or rerun for this proposal.
Functional acceptance depends on those actual data/effect/error/recovery scenarios,
not the number of old routes restored or an unrelated all-green test run. A
relevant failed integrity or destructive-recovery test remains a real blocker;
passing unrelated checks cannot complete pending operations.
