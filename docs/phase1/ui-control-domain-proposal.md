# Standalone Management UI control-domain proposal

**Prior architecture-only scope (2026-10-04).** Subsequent source-only UI transfer
is recorded in `ui-source-migration.md`; it does not implement the proposal below.
This proposal's
remaining UI/domain work is deferred. Management authors service configuration;
network services execute on Worker. Netboot and Identity are Worker-only, including
provisioning and identity/trust authority; any contrary authority proposal below
is superseded. Worker runtime health is not this task's completion gate.

**Status: Netman, Worker catalog, named ACL and View desired-data slices implemented; remaining feature decisions are proposals.** Source
audit at `main@d83442c0` with the uncommitted Phase 1 integration, 2026-10-01.
The user's current objective is to retain and redevelop the original business
functions, not preserve old routes, request APIs, identifiers, persistence formats
or previous/forward software-version compatibility. Historical fields/events
below explain the functions; they are not wire-compatibility requirements.
The Netman implementation is now linked below; the remaining proposals implement
nothing by themselves. Keep exactly the Management and
Worker business apps/releases; do not import Console, ManagementCore, Sync, Store,
or legacy Agents. Ordinary PostgreSQL tables do not require blanket user approval;
that restriction was assistant-imposed. Actual unresolved business/ownership and
shared-contract decisions still need coordination. Explicit confirmation rules
for Mnesia, shared protocols and global configuration loading remain applicable.

## 1. Existing foundations and three ownership boundaries

Current PostgreSQL entities are `Worker`, `Zone`, `Rrset`, `ResourceVersion`,
`Service`, `Assignment`, `Target`, `Audit`, and `Idempotency` ([schemas][S1],
[migration][S2], [Domain][S3]). `Zone.name` is globally unique for live drafts;
RRsets are unique by `(zone_id, name, type)`; versions are unique both by
`(zone_id, version)` and `(zone_id, source_revision)`. Assignments already enforce
that a pinned version belongs to its Zone. Target snapshots are immutable.

The implemented Netman slice adds `Netman`, `NetmanConfigDraft` and
`NetmanConfigVersion` with the `20261001000000_create_netman_domain.exs` migration.
`Netmans` dispatches through the existing Domain Audit/Idempotency transaction;
`NetmanConfig` is a pure bounded typed validator, not an executable Worker codec.
See [current coverage and executed evidence](ui-migration-matrix.md#current-netman-desired-configuration-implementation).
Logical metadata, full desired profile/Resolved replacement, immutable prepared
versions and desired rollback are working. Runtime activation/observations are not.
Worker catalog profile metadata is now implemented as described below. The
named DNS ordered-rule ACL desired-data slice is also implemented as described below.
Other proposed DNS/provider/Identity entities remain pending.

The current [shared codec][S4] accepts only DNS services, IPv4 `listen_address`
and `port`, `running|stopped`, and `dns_zone` resources containing SOA/NS/A.
It rejects unknown fields and unsupported records. No view, ACL, provider,
Netman, registration, delivery, or observation representation exists there.

| Boundary | Proposed work | What completion would mean |
| --- | --- | --- |
| A: Management-owned data | Catalog display, logical Netman records, policy/provider metadata, typed DNS drafts, immutable publication intent and audit | Real durable read/write functions; feedback says draft saved or intent prepared, not runtime applied. Proposed PG entities support these functions; they are not individually subject to an invented blanket SQL approval rule. |
| B: Shared desired-state contract + Worker | Executable views/ACLs, recursion/forwarding, additional RR types, network profiles/features | One approved ConfigSpec evolution, compiler validation/round-trip, and actual Worker execution. No sidecar TOML or ignored unsupported fields. |
| C: Observation/external effects | Connected state, active revisions, runtime queries/commands, provider synchronization and conflict resolution | Approved execution/transport/credential ownership plus durable, attributable results. Persisting intent is not evidence of effects. |

## 2. Profiles and logical Netman registration

### Source-backed behavior, not invented profile CRUD

`/management/profiles` lists **Server Profiles** and **Netman Profiles**, with
`name`, `description`, and enabled defaults. The [original Management LiveView][S5]
has no profile creation/edit/delete handlers or registration form. Its [data
adapter][S6] reads a [static catalog][S7]. These presets are not the mutable
Ethernet connection profiles in `/netman/:netman_id/config`.

Minimum proposal: reproduce that catalog as pure Management-owned data, **no
profile tables needed for original read-only parity**. If editable catalogs are
wanted, that is a separate requirement/approval; do not infer it from the menu.

- Server preset names: `cloud_dns`, `local_network`, `dns_only`, `dhcp_only`,
  `netboot_only`, `custom`. Boolean defaults: `dns`, `mdns`, `dhcpv4`, `dhcpv6`,
  `netboot`, `identity`, `fingerprint`, `server_agent`.
- Netman preset names: `local_server`, `cloud_server`, `bare_metal`, `vm`,
  `vpn_gateway`, `observe_only`, `custom`. Boolean defaults: `interfaces`,
  `dhcp_client`, `dns_client`, `routes`, `link_state`, `vpn`; apply modes
  `managed`, `observe_first`, `observe` ([S7]). Retain the original descriptions
  and meaningful preset defaults, including the explicitly future VPN preset.
- `server_agent` is historical catalog metadata, **never** a startup dependency.
  Showing a preset does not enable its unsupported services on the DNS-only Worker.
  Existing `expected_capabilities` must not become fabricated observed capabilities.

### Implemented Netman and Worker PostgreSQL additions (A)

| Entity/change | Concrete fields and constraints | Source requirement |
| --- | --- | --- |
| `management_netmans` (implemented) | `id` text PK validated as a concrete ASCII ID of at most 64 bytes; nonempty `name`, defaulting to ID; catalog `profile_name`; one of three `apply_mode` values; six Boolean `features`; `metadata` JSON object bounded to 16 KiB; logical `status` constrained to `not_yet_connected`; positive metadata `revision`; preserved registration timestamp and changing update timestamp | [Netman struct][S8], [registration/upsert][S9]; `/management/netman` shows desired metadata, while actual state/last seen remain unknown/null. |
| Worker catalog profile (implemented) | Non-null `profile_name`, default `custom`, restricted to six Server catalog names at both Domain and PostgreSQL boundaries; edits use existing aggregate revision CAS; retain Worker identity/services/revision and logical status constraint | Server profile column in [S5], preset definitions [S7]. No new generic Node table or role discriminator. The original read-only Server listing did not expose an arbitrary metadata editor; such an editor would be a new requirement, not missing UI parity. |
| `management_netman_config_drafts` (implemented) | `netman_id` PK/FK; independent positive `revision`; whole `document` with at most 128 uniquely identified typed profiles and bounded Resolved lists; timestamps | Management-owned full profile-set replacement and Resolved configuration in [S10]/[S11]. Separate metadata revision from configuration CAS. |
| `management_netman_config_versions` (implemented) | UUID PK; Netman FK; monotonic `version`; `source_revision`; operation; complete immutable document and canonical digest; same-node rollback-source FK; creation timestamp; unique `(netman_id, version)` and `(netman_id, source_revision)`; database trigger rejects update/delete | Desired publications/history and rollback select stored immutable content, never invented runtime history. |

Registration/upsert preserves the original `registered_at`, increments revision,
validates profile/features/mode and commits with Audit/Idempotency. Unknown IDs
on scoped pages return not found. No registration request may set online state,
reported capabilities, or `last_seen_at`. Those need a future observation source.
The legacy [typed socket][S12] requires a pre-registered concrete Netman; it is
not evidence that the old Management listing contained an operator registration
form, and it must not be restarted to fill this gap.

Worker registration and name/profile editing now persist and display the catalog
selection. Omitted profile edits retain the current selection; successful UI
registration resets the selection to `custom`. This field is descriptive only:
it never changes capabilities, services, assignments, immutable targets or TOML,
and never starts Agents. No legacy payload or data adapter is introduced.

### Network profile fields/events that must not disappear

From [ConfigLive][S10] and the [legacy operation schema][S13]:

| Form/input | Typed desired value / source bounds |
| --- | --- |
| `profile[profile_id]`, `interface`, `zone` | Stable profile ID using alphanumeric/`_.-`, excluding `.` and `..`; nullable interface, otherwise nonempty, at most 15 bytes, excluding spaces, tabs, newlines, `/` and `:`; nonempty network zone at most 64 bytes using alphanumeric/`_.-`, not a DNS Zone FK. |
| `autoconnect`, `autoconnect_priority`, `mtu` | Boolean; priority `-1000..10000`; nullable Ethernet MTU `68..65535`; fixed profile `type=ethernet`. |
| `ipv4_method`, `ipv6_method` | IPv4 `auto|manual|disabled`; IPv6 additionally `link-local`. |
| Each family's `address`, `gateway`, `dns`, `dns_search` | Nullable family-valid CIDR/address; nullable family-valid gateway; IP-address list; search-domain list. Preserve manual-mode semantic validation, not just JSON shape. |
| `patch[profile_id,field,value]` | Allow only `zone`, `interface`, `autoconnect_priority`, `ethernet.mtu`; route/scoped identity must refer to the stored profile. |
| `resolved[upstreams,search_domains]` | Valid IP list and domain list; `rollback[target_revision]` selects immutable desired content, not arbitrary client JSON. |

`put_profile`, `patch_profile`, `delete_profile`, and `replace_profiles` currently
publish a **complete desired profile set**, with configuration CAS; keep that
transaction boundary. Validate the entire candidate before replacement. Respect
`observe` read-only mode. `validate_profile` may gain a local desired validator,
but must label that result separately from the old online runtime validation.
`load_history` must distinguish desired history from the original runtime query.
`activate_profile`, `rollback_profile`, `load_active_revision`, interface
activation/deactivation, cache flush and lease release need B/C; a stored revision
cannot produce their old runtime success messages. [ResolvedLive][S11] also
requires desired update/rollback separately from runtime cache operations.

## 3. DNS views, ACLs, providers and view-scoped Zones

Original routes live under `/server/:server_id/dns`; resolve `server_id` to an
existing logical Worker, never a legacy Server. A Worker can have multiple DNS
`Service` instances today: the missing service-selection convention is an
approval question, not permission to choose the first service silently.

| Original route/event/form | Source-backed fields and identities | Proposed durable representation (A); execution gap |
| --- | --- | --- |
| `/views`, `/views/new`, `/views/:view_name/edit`; View CRUD, desired toggles/filter/CSV | Later forms expose only name/CIDRs/recursion, but `8550aa05` also exposes priority, enabled/ECS, inline client rules and ordered fallback endpoints/timeout/retries | Implemented native `management_dns_views`: explicit DNS Service, immutable name, controlled default/infinite priority, desired flags, canonical ordered client rules, typed endpoints, independent UUID/CAS. Default provisioning and partial-edit preservation are transactional. Actual execution/export and View-Zone ownership remain pending. |
| `/acl`; `create_acl`, `update_acl`, `delete_acl`; `acl[...]` | `acl_id`, CIDR `networks`, `action=allow|deny`; separate create/update forms, digest CAS ([S16]/[S17]); earlier `8550aa05` includes descriptions, ordered rules and countries | Named ordered-rule data implemented in `management_dns_acls`: native UUID, explicit DNS Service FK, name/description, ordered action + networks/countries/any rules, independent positive revision and timestamps; unique `(service_id,name)`. Worker and Service scopes are checked at reads/writes. No ACL-to-view attachment or evaluation is implemented. B must define actual execution/export. |
| `/providers`, `/providers/new`, `/providers/:name`, `/edit`; delete/create/update provider | `provider_id`, type `cloudflare|route53|rfc2136`, nullable endpoint, opaque `credential_ref` ([S18]/[S19]/[S13]) | `management_dns_providers`: UUID, DNS Service FK, identifier/type checks, nullable validated endpoint, credential reference, revision, timestamps; unique `(service_id,provider_id)`. Store no raw secret in drafts, Audit, Target or TOML. Operational credentials/adapters need C. |
| Provider `select_view`, `sync_zone`; Zone create/update/import/sync/delete | View name, canonical zone name, `zone_type=authoritative|forward`, nullable provider ID; import `source_type`, `source_id`, `source_revision` ([S19]/[S20]) | `management_dns_zone_bindings`: UUID, View FK, Zone FK, nullable Provider FK, zone-type check, revision. Composite scoped references prevent cross-Service provider/view use. Binding uniqueness must prohibit duplicate apex within a view. Forwarding and sync are not implemented by a binding. |
| `/providers/:name/conflicts`; `resolve_conflict` | `conflict_id`, `resolution=use_local|use_cloud` ([S21]) | Future `management_dns_provider_conflicts`: stable ID, provider/binding FKs, immutable local/remote candidate snapshots + digests/revisions, positive CAS revision, state, resolution, resolved timestamp. No resolvable conflict until actual sync supplies both candidates and a revision. |
| Record create/update/delete and bulk editing | Historical form had user-entered `record_id`, owner `name`, type, TTL `0..2147483647`, textual `values`; list includes A/AAAA/CNAME/MX/NS/PTR/SRV/TXT ([S22]/[S13]) | Reuse Rrset and current native identity; map owner to `name`, values to type-specific `data`. No legacy-identifier field or old-data adapter is required. Validate edit identity and revision; do not trust an arbitrary client ordinal. Extra record types require B before executable export. |

CIDR/domain/type validation belongs at the write boundary as well as in forms;
normalize domain apex/owners, not case-sensitive opaque resource IDs. Retain
positive revisions, scoped FKs and uniqueness in PostgreSQL. Reject deleting
referenced views/providers rather than cascading away bindings, versions or
assignments. A rename must be an explicit transaction, not identity substitution
from posted form fields. No runtime online check is needed to save a *desired*
draft; migrated feedback must say so.

### Current named DNS ordered-rule ACL data

`/server/:server_id/dns/acl` requires explicit DNS Service selection, even when
only one exists. `/server/:server_id/dns/acl/:service_id` lists, creates, edits,
deliberately renames and confirms deletion of that Service's desired named ACLs.
Scope IDs come from matched paths; posted/query IDs cannot retarget mutations.
The native API uses `/api/workers/:worker_id/dns-services/:service_id/acls` and
the existing idempotent `create_dns_acl`, `update_dns_acl`, `delete_dns_acl`
gateway. These are new native contracts, not old request/route adapters.

The current data policy allows 1–128 ASCII identifier characters, optional
descriptions up to 255 Unicode codepoints, and at most 128 ordered rules.
Each explicitly selects `allow|deny` and exactly one matcher: `any`, `networks`
or `countries`. Exact IPv4/IPv6 IPs normalize to host CIDRs; networks share a
128-entry total limit. Country lists require valid uppercase catalog codes and
normalize within each rule. The rule list is never sorted or merged. Empty
rule/network sets stay empty, not catch-all. PostgreSQL enforces descriptions,
rule shapes/actions, canonical networks, country syntax, uniqueness, positive
revisions and Service FK restrictions. ACL edits use
their own CAS and do not mutate Worker revisions, Service configs, assignments,
Zones, immutable targets or exports. Read-only refresh does not write data.

The editor retains descriptions, ordered rules, country search/selection,
name/description filtering and whole-Service CSV export. Built-in recipes fill
an empty editor and become ordinary current rules, not global or named
references. A forward PostgreSQL schema change preserves existing Management
records as one networks rule and removes the former flat columns; it adds no
old-payload/format adapter or alternative persistence mode.

This is **not full historical ACL parity**. View ACL editing and attachment,
evaluation/enforcement, Geo-rule
semantics and a single executable shared contract still require B/C decisions.
There is no ignored ACL field in WorkerPlan or competing sidecar codec.

**Existing identity limitation:** global `Zone.name` uniqueness cannot represent
different content at the same apex in different views. Recommended proposal:
nullable `Zone.dns_view_id` for view-owned drafts; partial unique apex indexes for
unscoped live drafts and `(dns_view_id,name)` for scoped live drafts. Global
reusable Zones can be attached through bindings. Enforce unique binding apex
under a View, including renames, with a concrete constraint/FK design approved
before migration. Keep historical ResourceVersion content independent of renamed
drafts. Retaining global uniqueness instead is a legitimate smaller scope, but
does **not** preserve full view-scoped zone functionality.

The richer historical View editor at `8550aa05` exposes immutable names,
priority (default 100, lower first), desired enabled toggles, recursion, ECS,
inline client policy and ordered fallback endpoints, timeout and retries.
The later three-field form is not the complete business inventory. Preserve
these functions, not its lossy save behavior or old serialization sentinels.

### Current-native DNS View desired domain

`management_dns_views` stores a native UUID, DNS Service FK, immutable name,
controlled `is_default`, nullable priority, desired booleans, View-owned ordered
`client_rules`, ordered `{address,port}` fallback endpoints, timeout/retries,
independent CAS revision and timestamps. The current rule validator and text
grammar are shared with named ACLs; no speculative named-reference mode is added.
Creating a DNS Service atomically provisions one durable default View. The
schema migration provisions existing DNS Services without altering their
configs/revisions. Reads, refresh and startup never provision rows.

Default has the reserved name `default`, infinite (`null`) priority and
unconditional allow policy. Its name, priority and client rules are protected
at every mutation entry point, and deletion is prohibited. Its desired enabled
flag remains editable, as in the historical UI; no execution behavior is claimed.
Custom priorities are nonnegative signed PostgreSQL bigint values. Endpoints
are strict IPv4/IPv6 addresses with ports 1–65535 (default 53); timeout is
100–30000ms (default 2000), retries 0–5 (default 1). Empty client policy and
forwarder lists remain empty. Updates merge only supplied mutable fields before
validation/CAS, so toggles and policy edits cannot reset unrelated settings.

This slice is desired metadata only. View-scoped Zones/same-apex identity,
RPZ bindings, actual matching/recursion/ECS/forwarding/retry semantics and the
single shared executable WorkerPlan contract remain pending. It does not mutate
Worker revisions, Service configs, immutable targets, assignments or exports;
it cannot be described as full View functionality or Worker enforcement.

### View–Zone ownership source refresh (2026-10-01)

The historical Store at `8550aa05` namespaces metadata/RRsets by View and apex;
runtime Zone children use `{view_name, zone_type, zone_name}`. However, that
historical Console Zone screen selects `default` and rejects another View's
Zone UUID. Do not describe arbitrary View selection as a verified old UI feature,
or treat its missing selector as justification for globally unique Zone content
in the new View domain. Current Worker-route Zone navigation still operates on
the global reusable library, not on Service/View-owned Zones.

The current-native ownership choice has been presented to the user and remains
unconfirmed: independent View-owned Zones plus reusable global bindings, versus
all Zones owned by Views with only immutable versions shared across Workers.
No ownership schema or association has been implemented by this proposal.

For the mixed ownership option, the minimal candidate extends `Zone` with an
immutable nullable owner-View FK, with separate active global-apex and
`(owner_view_id,name)` unique indexes. Existing native library rows remain
global; there is no automatic default-View adoption or legacy-data adapter.
Reads/mutations/record/history/import paths must check the complete matched
Worker → DNS Service UUID → View UUID → Zone UUID chain. Library operations
must explicitly reject owned Zones rather than becoming a scope escape hatch.

Retain ownership and immutable history after Zone archival. One candidate uses
View tombstones: prevent deleting default or a View with active owned Zones;
retain its UUID/FK after its Zones are archived, and restrict name uniqueness to
active Views. The smaller alternative permanently restricts View deletion while
any owned Zone remains, including archived history. Never cascade histories,
null ownership or silently promote owned content into the global catalog.
The user-facing deletion/association policy must be settled with the model.

If reusable resources can be selected inside a View, use an explicit desired
selection pinned to an immutable ResourceVersion with a composite version/Zone
FK and unique apex per View. Unbinding removes that selection only. This is a
business design choice, not evidence that historical registration implemented
immutable pinning. Current Service-level `assign` must reject owned content until
the one shared View-aware WorkerPlan contract is implemented; flattening it into
the current Service namespace would lose View identity. Global assignments and
already committed export bytes remain intact.

The historical Zone editor exposes authoritative/forward/stub creation, while
handlers additionally mention cache/RPZ; forward upstream IPs, stub NS names,
cloud mirror fields/effects, BIND import and import-into-existing remain required
separate work. The Records screen also has broader record types and BIND bulk
preview/import. Current SOA/NS/A filters/downloads cannot stand in for that scope.

### Provider limitations are real, not completed features

Original create/update handlers return: “Provider credential references cannot
yet be materialized by the selected Server.” Conflict resolution is disabled
because its revision is not exposed ([S18]/[S19]/[S21]). The runtime boundary also
rejects unsupported provider updates, including RFC2136 in the examined path
([S23]). A route or stored credential reference cannot be counted as functional
provider setup. The existing WorkerPlan-paste import is likewise not the old
provider/snapshot import.

For full provider operations, propose a separately approved provider-run entity:
`provider_id`, binding/Zone reference, action (`import|sync`), idempotency identity,
pinned local/remote revisions, queued/running/succeeded/failed state, timestamps,
result/error. Capture external data outside SQL locks, then CAS the original
revisions before changing a draft. Conflict resolution locks the conflict and
draft, checks both pinned revisions, and records the chosen candidate/audit;
`use_local` and `use_cloud` remain distinct effects. Durable jobs, retries and
secret materialization are **not** authorized by this proposal. Decide whether
provider I/O belongs to Management or Worker before treating it as executable.

### Provider source refresh and pending ownership decision (2026-10-01)

The current standalone Management has no provider context or routes. Provider
navigation and the task page's unavailable synchronization notice are not
implemented provider functions. The legacy Provider Index rejects creation,
Show rejects updates, ConflictLive rejects conflict resolution, and ZoneLive
rejects provider import; scripted transport tests do not establish real provider
acceptance. Delete/sync still dispatch through the excluded legacy runtime.

Cloudflare, GCP and Vultr adapter sources contain HTTP implementations and
conversion helpers, but complete pagination, provider metadata preservation and
partial-write reconciliation need review/redevelopment. AWS explicitly lacks
SigV4, IANA is read-only and drops SOA in its parser, and RFC2136 is unsupported.
These are local implementation gaps, not reproduced upstream dependency bugs.
Importing `yellow_dog_dns_provider` as-is would pull legacy core/DNS/Store into
Management and is not an acceptable integration.

The coordinator has presented a current-design choice between shared
Management-owned provider accounts with explicit Zone bindings and accounts
scoped to each DNS instance; user confirmation is pending. The shared-account
proposal uses existing PostgreSQL/Oban/Mint, external credential aliases,
explicit pull/push direction and real remote observations. It preserves
CRUD/test/record inspection/import/conflict/cloud overview functions without
claiming Worker application. It is not implementation approval or a completed
provider feature. Shared DNS record/type/name expansion and restore/startup
fencing remain separate pending confirmations.

When implementing the chosen design, reject raw credential fields before
Domain fingerprinting/auditing, including rejected requests. Current backups
dump PostgreSQL: encrypting secrets inside that dump would not exclude them.
Retain complete remote observations separately from exportable ConfigSpec
records; never discard unsupported types or invent SOA to make import pass.
Freeze synchronization/conflict candidates and revisions, use provider-side
preconditions where available, and reconcile ambiguous writes before retrying.
Local PG fencing does not cancel an HTTP mutation already sent to a provider.
Restored jobs must not automatically replay external mutations.

## 4. Redeveloped DNS publication functions

The [router][S25], [controller][S26], [DnsZones][S27] and [DnsZone validator][S28]
are historical evidence for draft editing, target selection, publication and
result inspection. They do not require restoring `/api/v1`, exact request keys,
old limits/status codes, bearer authentication or old manifest formats.

| Business function to retain | Standalone semantics and meaningful acceptance |
| --- | --- |
| Create and inspect a Zone draft | Canonical apex and typed RRsets, with intended targets kept separate from observed presence. Decide whether incomplete drafts can be saved; never export invalid executable content. Work without any Worker when unassigned. |
| Edit individual records or a batch | Native current IDs/validated ordinals and expected revisions; validate the whole candidate, commit once, and roll back invalid/stale edits without changing unrelated records or confirmed history. Preserve needed record types through typed representation, not filtering. |
| Select target services | Explicit existing Worker and DNS Service identities; service belongs to Worker. Keep editable intent separate from a pinned immutable version. No first-service inference. |
| Publish and inspect desired content | Validate full content, deliberate SOA serial semantics, immutable content/plan identity, target revision/digest, auditable idempotent result. Publication prepares intent; it does not report delivery or application. |
| Inspect runtime result | Unknown until genuine attributed observations exist; actual loaded digest, outcome and observation time require boundary C. |

The historical validator and form differed on record types and TTL limits. Use
them to identify business needs, then choose one current typed policy. Current
ConfigSpec supports SOA/NS/A only; additional executable types remain pending.
There is no previous/forward software-version compatibility, old-data conversion,
legacy-identifier adapter or requirement to reproduce the old HTTP surface.

### Minimal publication representation and invariants

Reuse Rrset, ResourceVersion, Assignment and Target before introducing additional
entities. If editable target intent and grouped publication receipts need durable
storage, proposed records can hold Zone/Worker/Service references, source draft
revision, publication identity, SOA serial, pinned version/target IDs, actor and
request digest. Concrete entity count and repeat-publication semantics remain
design choices, not prerequisites invented to emulate the old API.

A grouped publication must validate all candidates before committing its intended
effects, lock aggregates consistently, preserve unrelated assignments and record
the immutable result and audit with idempotency. A failed group cannot leave a
partially published desired set. If the UX instead makes separately committed
target actions, it must report those boundaries honestly. External delivery never
occurs inside a desired-data transaction.

Current `confirm_zone` confirms a resource snapshot, not the entire publication
workflow. Decide how serial changes, version confirmation and target preparation
compose. Do not require a second version-origin scheme merely for old-API parity,
or alter drafts to evade uniqueness. Confirmed business versions/history remain
immutable; this is data integrity, not software-version compatibility.

Use the existing Domain idempotency pattern: identical request replay returns its
result, conflicting reuse fails, and rollback leaves no partial business state.
Audit excludes secrets. Resource and WorkerPlan digests describe different
objects; do not conflate them or accept a legacy acknowledgment as runtime proof.

## 5. Pending feature decisions and focused acceptance

1. **Business sequencing:** choose the next functional slice and validate its
   behavior. Ordinary PG implementation does not need blanket table approval.
   Profiles stays a read-only catalog unless editable presets are requested.
2. **DNS scoping:** define DNS Service selection, same-apex view-owned draft
   identity, deletion/rename constraints, view ordering/hidden settings, and
   named ACL attachment semantics.
3. **DNS draft/publication:** decide incomplete drafts, needed record types,
   meaningful limits/TTL policy, serial/repeat-publication behavior, target-edit
   semantics and idempotency. Unsupported executable content remains an error.
4. **B authorization:** decide the versioned ConfigSpec/Worker changes for views,
   ACLs, forwarding/recursion and additional RR types; no independent format.
5. **Netman execution:** decide how actual network management fits the retained
   two-product architecture. Logical Netman registration/config tables do not
   authorize a third runtime or turn DNS Worker into a Netman. Specify who applies
   profiles, observe-mode rules, runtime validation and rollback/activation semantics.
6. **C authorization:** decide provider credentials/I/O ownership, durable jobs,
   conflict evidence, and any authenticated observation/command channel. Specify
   disconnected/error/stale-ack handling. Until then, no fake online/applied/synced
   success, no legacy transport startup, and no declaration of full functional parity.

Validation performed for this proposal: source/field/route inspection only.
No builds, tests, services, schema changes or acceptance claims.

Future acceptance is per business function: PG persistence/restart, stale revision
and atomic rollback, immutable history/export, same-apex view isolation, validated
target selection, safe rename/delete, and actual provider results/conflict evidence
when that feature is implemented. Worker execution needs real runtime/data tests
for the chosen capability. Neither an old-route checklist nor an unrelated
whole-suite all-green result establishes completion; relevant failures must remain
visible and cannot be hidden by skipped or weakened tests.

## Source anchors

[S1]: ../../apps/yellow_dog_management/lib/yellow_dog/management/schemas.ex
[S2]: ../../apps/yellow_dog_management/priv/repo/migrations/20260930000000_create_management_domain.exs
[S3]: ../../apps/yellow_dog_management/lib/yellow_dog/management/domain.ex
[S4]: ../../apps/yellow_dog_config_spec/lib/yellow_dog/config_spec.ex
[S5]: ../../apps/yellow_dog_console/lib/yellow_dog/console/live/management_live/index.ex
[S6]: ../../apps/yellow_dog_console/lib/yellow_dog/console/live/management_live/data.ex
[S7]: ../../apps/yellow_dog_management_core/lib/yellow_dog/management/profiles.ex
[S8]: ../../apps/yellow_dog_management_core/lib/yellow_dog/management/netman.ex
[S9]: ../../apps/yellow_dog_management_core/lib/yellow_dog/management/netmans.ex
[S10]: ../../apps/yellow_dog_console/lib/yellow_dog/console/live/netman_live/config_live.ex
[S11]: ../../apps/yellow_dog_console/lib/yellow_dog/console/live/netman_live/resolved_live.ex
[S12]: ../../apps/yellow_dog_console/lib/yellow_dog/console/channels/netman_socket.ex
[S13]: ../../apps/yellow_dog_sync/lib/yellow_dog/sync/operation.ex
[S14]: ../../apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/view_live/index.ex
[S15]: ../../apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/view_live/index.html.heex
[S16]: ../../apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/acl_live.ex
[S17]: ../../apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/acl_live.html.heex
[S18]: ../../apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/provider_live/index.ex
[S19]: ../../apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/provider_live/show.ex
[S20]: ../../apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/zone_live/index.ex
[S21]: ../../apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/provider_live/conflict_live.ex
[S22]: ../../apps/yellow_dog_console/lib/yellow_dog/console/live/dns_live/rr_live/index.ex
[S23]: ../../apps/yellow_dog/lib/yellow_dog/server/control/dns.ex
[S24]: ../../apps/yellow_dog_dns/lib/yellow_dog/dns/view.ex
[S25]: ../../apps/yellow_dog_console/lib/yellow_dog/console/router.ex
[S26]: ../../apps/yellow_dog_console/lib/yellow_dog/console/controllers/dns_zone_controller.ex
[S27]: ../../apps/yellow_dog_management_core/lib/yellow_dog/management/dns_zones.ex
[S28]: ../../apps/yellow_dog_management_core/lib/yellow_dog/management/dns_zone.ex
