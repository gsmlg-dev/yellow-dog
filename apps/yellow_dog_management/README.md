# Independent Yellow Dog Management (Phase 1 Track A)

Management owns editable DNS data in PostgreSQL and publishes complete confirmed
configuration. Workers actively connect with their own Bearer tokens, retrieve
their targets and report runtime observations. Network services execute on Worker.

Management owns configuration authoring; network services run exclusively on
Worker. Netboot provisioning and Identity enrollment/trust authority belong to
Worker, not Management. A future configuration UI does not transfer ownership of
those services or their observed state to Management. After architecture
verification, the user authorized source-only UI migration for later redesign.

### UI source for redesign

Original UI source is migrated directly into the compiled
`lib/yellow_dog/management_ui/redesign/` tree under `ManagementUI.Redesign`,
without overwriting existing native pages. It includes the full current/original
page source union, shared components, helpers, forms and frontend source. No old
backend, authentication, service runtime or route compatibility layer is connected.
Compilation/runtime failure is accepted for this transfer; full functional
redesign and Worker runtime health remain separate work. Exact provenance and
source-only checks are in `docs/phase1/ui-source-migration.md` and its JSON manifest.

## Integrated shared baseline

Management and Worker now depend on `apps/yellow_dog_config_spec/` in the normal
umbrella. PostgreSQL dependencies are in the root lockfile. No documentation patch
or temporary source assembly is required. From the repository root in devenv:

```sh
mix deps.get
MIX_ENV=prod mix release yellow_dog_management
```

For the dedicated architecture gate (no database or service/UI acceptance):

```sh
devenv shell -- scripts/e2e/architecture_smoke.sh
```

`devenv shell -- docs/phase1/prepare-validation.sh /tmp/yellow-dog-management-build`
optionally selects build output at `/tmp/yellow-dog-management-build/_build/prod/`
and prints the release binary path. It builds the same checkout, not a copied
source assembly, and is not an acceptance gate. Historical Track A reports remain
historical evidence, not proof of current cross-product interoperability.

## Asset build

Management serves self-contained `management.css` and `management-live.js` from
`apps/yellow_dog_management/priv/static/`. Normal Mix builds, releases, and runtime
startup do not require Node, Bun, or npm. Regenerate both artifacts from the
repository root after HEEx, CSS, or client changes:

```sh
devenv shell -- npm ci
devenv shell -- npm run assets.management
```

The source is `apps/yellow_dog_management/assets/management.css`. Tailwind CSS and
its CLI are pinned together to `4.1.18`; the compiler bundles DuskMoon core's
plugin, Sunshine/Moonlight themes, and components without overriding their tokens
or internals. Management HEEx, HTML, JavaScript, and the Phoenix DuskMoon component
source are scanned for utility classes. Bun bundles the Phoenix/LiveView clients
from the matching locked Hex packages and the original Console client hooks.
Include both generated assets with source changes. Assets need no network imports
or font CDN and use local font fallbacks.

## Console page migration

The default UI is now Phoenix LiveView, using the original Console's DuskMoon
navigation, sidebar, theme switcher, and shared components under the independent
`YellowDog.ManagementUI` namespace. It does not start or depend on the Console app
or its legacy Agents. `/management`, `/server`, and the DNS Zone routes adapt
existing PostgreSQL domain operations rather than calling a legacy Server.
Logical Worker service configuration, version assignments, prepared targets,
TOML export, and `/management/events` remain available without a live Worker.
`/management/profiles` restores the original read-only Server/Netman preset
catalog: six Server and seven Netman presets with exact descriptions/default flags
and Netman apply modes. These are historical catalog metadata, not an assertion
that the current Worker supports every preset; reading them never starts Agents,
enables services or writes PostgreSQL. Netman network-profile editing is separate
from these catalog presets and stores desired configuration in PostgreSQL.
Worker registration requires only a name and defaults descriptive `profile_name`
metadata to `custom`. Dashboard editing retains the six Server catalog profiles.
Profile edits use the existing Worker revision CAS and never change capabilities,
services, assignments, immutable targets or historical TOML exports. They do not
enable the services described by a preset. Arbitrary Worker metadata editing is
not implemented.

Focused metadata and registration tests use disposable PostgreSQL:

```sh
devenv shell -- scripts/e2e/phase1_postgres.sh mix do --app yellow_dog_management cmd mix test test/worker_profiles_test.exs test/worker_profiles_live_test.exs
```

The release check covers registration/reset, persisted display/editing, concurrent
CAS and invalid-profile rejection, immutable export preservation and SIGKILL
recovery, with desktop/mobile styling and no-login checks.

Acceptance preserves and redevelops original business functions, not old routes,
exact API payloads, legacy identifiers or software-version compatibility. Legacy
redirects, the reserved `settings` escape workaround and the old static workspace
are removed. Worker navigation uses explicit registered identity; it must never
infer a selection from existing records or query parameters.
Global Zone, record and import pages ignore query-only identity parameters;
scoped pages derive Worker/Zone/record IDs from the matched path, including when
queries contain conflicting scalar, list or map values. Unknown scoped Workers
cannot mutate shared Zones. Netman runtime operations and wider service functions remain pending;
their historical URLs are not current functionality promises.

`/management/config` lists every immutable prepared target revision, its genuine
digest, preparation time and Worker link directly from PostgreSQL. It does not
load plan bodies to render the history or infer application, failure or rollback
observations. Netman prepared versions and desired rollback publications also appear
in this history; genuine runtime observations remain unknown.

### Named DNS ordered-rule ACL data

`/server/:server_id/dns/acl` selects an existing DNS Service explicitly; it never
infers the first Service, even for a single-Service Worker. Its scoped page at
`/server/:server_id/dns/acl/:service_id` persists named ACLs, edits/renames them,
confirms deletion and performs read-only refresh. Names, descriptions and ordered
`allow|deny` rules use native UUID identity, independent revision CAS,
PostgreSQL constraints and the existing audit/idempotency transaction.
The API is `/api/workers/:worker_id/dns-services/:service_id/acls`, with optional
`/:id` for an individual record. Commands are `create_dns_acl`, `update_dns_acl`
and `delete_dns_acl`. Names are 1–128 ASCII identifier characters; each ACL
contains at most 128 rules and 128 total IP/CIDR entries. Exact IPs normalize to
host CIDRs. Each rule matches networks, uppercase ISO countries, or explicit
`any`; mixed rules keep their order. Empty lists/network sets stay empty, never
catch-all. Country values normalize within their own rule only. Descriptions
are limited to 255 Unicode codepoints. No old flat-payload adapter is retained.

The multiline editor uses one rule per line: `deny networks 192.0.2.7`,
`allow countries CA, US`, or `deny any`. Inline validation retains rejected
fields. Country search/checkboxes/badges append an explicit country rule without
discarding typed rules. Built-in recipes (`any`, `none`, `localhost`, `localnets`)
fill an empty editor only; they persist as ordinary rules, not global references.
Name/description search filters the list; CSV exports all ACLs in the selected
Service regardless of the filter, with spreadsheet-safe escaping.

These are desired metadata only: no ACL attachment, enforcement or WorkerPlan
export is claimed. Existing Worker revisions, services, assignments and immutable
DNS history/export remain unchanged. View ACL editing/attachment,
actual first-match evaluation, Geo matching and enforcement
remain pending; rich desired-data CRUD is not full ACL execution parity.
No software-version compatibility layer is introduced.

```sh
devenv shell -- scripts/e2e/phase1_postgres.sh mix do --app yellow_dog_management cmd mix test test/dns_acls_test.exs test/dns_acls_live_test.exs test/dns_acls_web_test.exs
devenv shell -- scripts/e2e/phase1_postgres.sh scripts/e2e/management_dns_acls.sh
```

The scoped release check uses actual Chromium, independent concurrent HTTP/PG
requests and SIGKILL recovery to verify desired CRUD, confirmation/cancellation,
validation, scoped isolation, immutable export preservation and desktop/mobile
no-login UI. It does not test or imply ACL execution.

### Logical Netman and desired network configuration

`/management/netman` and `/netman` register/select logical Netman nodes.
`/netman/:netman_id` edits metadata, catalog preset, desired feature flags and
apply mode. These records never claim an online state or a last-seen time.
IDs come from matched route parameters, not query-only identity overrides.

`/netman/:netman_id/config` manages Ethernet profiles with interface/zone,
autoconnect/priority, MTU and typed IPv4/IPv6 address, gateway, DNS and search
settings. `/netman/:netman_id/resolved` edits desired resolver upstreams and
search domains. The pure `NetmanConfig` validator validates the entire replacement
document before saving, including unique profile IDs and manual-address/family
semantics. It imposes a 256 KiB document limit and bounds profiles and resolver lists.

Metadata and configuration have independent optimistic revisions. Configuration
updates, publication and desired rollback use the existing atomic PostgreSQL
Audit/Idempotency gateway. Publication creates immutable prepared snapshots;
rollback selects stored content and creates a new draft revision and a new
publication without modifying earlier history. Observe-only configuration cannot
be saved, published or rolled back, including via direct API requests.

The unauthenticated current APIs are `/api/netmans`, `/api/netmans/:id`,
`/api/netmans/:id/config` and `/api/netmans/:id/versions`, plus the current
`create_netman`, `update_netman`, `update_netman_config`, `confirm_netman_config`
and `rollback_netman_config` commands. Mutation keys and revision checks remain
mandatory. There is no Netman WorkerPlan export, delivery or host-network change:
these desired documents do not extend the shared DNS-only ConfigSpec. Actual
interfaces, DHCP leases, resolver caches, profile activation and runtime rollback
still require genuine execution/observation support and are not implemented by
pretending the Management host is the selected Netman.

Zone draft forms validate current SOA/NS/A content on change through the same
pure ConfigSpec contract as Domain. Invalid candidates show field paths/messages
and disable Save; adding/removing rows revalidates while retaining entered fields.
Validation and cancellation write no drafts or audit/idempotency receipts.
Submission remains independently validated with the editor's original revision;
history refresh does not rebase unsaved edits or alter immutable exports.

`/management/zones/:zone_id/records` and matching Worker-scoped routes provide
SOA/NS/A record creation, editing, deletion, live bulk preview and atomic JSON
bulk append. Bulk input is a nonempty array of canonical record objects, limited
to 1 MiB. The pure shared validator checks the complete existing-plus-appended
candidate, including its 1024-record limit, before showing canonical appended
rows, per-type counts, total count and original draft revision. Preview writes
no business data or audit receipts. Append requires the exact reviewed source
and original revision; invalid input clears the preview, and concurrent edits
are rejected without rebasing or retrying. All updates leave confirmed versions
unchanged. BIND bulk preview/import remains blocked by upstream parser issues,
not implemented by this canonical-JSON editor.
`/management/zones/import` accepts a complete exported WorkerPlan TOML (1 MiB
maximum), validates it through the shared ConfigSpec, previews its DNS resources,
and imports one selected Zone into a new audited draft. It does not confirm a
version, assign it to the selected Worker, or apply anything to a runtime. Name
conflicts never replace an existing Zone. Provider-source import and other
original record types remain pending.

Track business-function coverage and pending backend work in
`docs/phase1/ui-migration-matrix.md`; its historical route/action inventory is
reference-only. Retaining a menu entry or passing unrelated checks does not
complete a function. In particular, DHCP/mDNS/Netboot/Identity/Netman runtime
observations cannot be fabricated or obtained by reconnecting legacy Agents.
Control/operations proposals remain designs, not implemented features. Ordinary
PostgreSQL additions have no blanket table-approval requirement; unresolved
ownership and shared-contract decisions still need coordination. Explicit Mnesia,
shared-protocol and global-loading confirmation rules remain applicable.

### Management logs and GeoIP artifacts

`/system/logs/realtime` observes actual OTP Logger events from the Management VM
and its dependencies. It supports application/severity filters, retained-message
search, metadata expansion, pause/resume, view-only clearing and CSV download.
The process-local replay retains 1,000 entries and resets on restart; paused views
retain at most 500 pending entries and display the dropped count. Logger's primary
level still controls which events exist; the page cannot recover filtered-out
debug events. Worker/service logs remain pending. Task logs read real PostgreSQL
job attempts, errors and immutable artifact-selection receipts.

`/tool/geoip` reads real MMDB artifacts through the pure `mmdb2_decoder` library.
Configure optional paths before startup:

```sh
export YELLOW_DOG_MANAGEMENT_GEOIP_CITY_PATH=/absolute/path/city.mmdb
export YELLOW_DOG_MANAGEMENT_GEOIP_COUNTRY_PATH=/absolute/path/country.mmdb
```

Unset paths leave their fixed slots unconfigured, without blocking startup.
Relative paths resolve against the process working directory. The IP Database
page at `/system/ip-database` inspects actual metadata and file information,
reloads configured files, and unloads in-memory snapshots after confirmation.
Unloading leaves the file on disk; Reload restores it. Loading is asynchronous,
limited to 256 MiB and 30 seconds. An invalid replacement preserves the last valid
snapshot. These disposable artifacts are not PostgreSQL business configuration.
Queue IP City/Country directly enqueues the corresponding durable synchronization
task; Sync History opens its actual job history. Queueing reports a real job ID,
not successful completion, and does not enable schedules or reload the lookup
snapshot. Task identity and download source are server-controlled. The bundled
synthetic MaxMind fixture is for tests only, never a development database default.

`/system/mac-database` uses a Management-owned runtime OUI snapshot, shared with
`/tool/mac`. The default source is the actual compiled `gsmlg_mac` dataset. Set
`YELLOW_DOG_MANAGEMENT_MAC_DATABASE_PATH` before startup to load a local Wireshark
`manuf.txt` artifact instead. The page displays source, entry count, load time and
file information, supports configured-file reload and test lookups, and retains
the last valid snapshot on replacement failures. This optional path follows the
same working-directory resolution as GeoIP paths. MAC/OUI download jobs remain
unavailable; task history is implemented for City/Country synchronization. This
is not full original page parity.
Lossless overlapping-prefix file import is also blocked by upstream
[`gsmlg-dev/gsmlg_umbrella#8`](https://github.com/gsmlg-dev/gsmlg_umbrella/issues/8):
the locked compiler drops different prefix lengths sharing an OUI. Management
rejects those files and preserves the last valid snapshot; it does not substitute
a local compiler. The packaged-file parity test remains failing until the
dependency is fixed. Compatible single-width artifacts can still reload.

The restored `/tool/whois` page keeps asynchronous raw Domain/IP/ASN results and
error feedback. Each lookup has a 30-second UI deadline; expiry cancels the task,
closes its owned TCP sockets, retains the query and enables retry. Replacement,
blank submissions and normal page shutdown also cancel pending work. This is a
temporary callsite workaround for
[`gsmlg-dev/gsmlg_umbrella#9`](https://github.com/gsmlg-dev/gsmlg_umbrella/issues/9):
the locked WHOIS client has no bounded receive/referral deadline. Local TCP peer
tests verify cancellation/cleanup; they do not prove external WHOIS availability.
A read-only LAN Chromium probe also confirms a real `example.com` raw lookup
result and re-enabled form; peer availability remains external to Management.

### Management synchronization tasks

`/system/tasks` and individual task pages support revision-checked enable/UTC cron
edits, manual runs even with schedules disabled, actual queue states and history.
`/system/logs/tasks` exposes actual attempts, timestamps, errors and result receipts;
it does not invent worker stdout. Reads do not enqueue jobs or create audit entries.
Commands, including rejected commands, retain the durable audit/idempotency contract.
All schedules start disabled. Cloud-provider tasks remain unimplemented; MAC
synchronization is unavailable pending upstream issue #8.

City/Country synchronization uses Oban with a PostgreSQL `management_jobs` prefix,
one `management_sync` consumer, three attempts and crash-claim recovery. Repeated
active runs deduplicate by task; scheduler occurrence IDs deduplicate each UTC
minute. Job history is retained, with no automatic pruning.

Mint streams the actual HTTP response with peer/hostname-verified HTTPS. Downloads
require status 200, reject redirects/partial responses, and enforce 64 MiB compressed,
256 MiB decompressed and 120-second limits. Validated dataset-specific MMDB files
are immutable SHA-256-addressed artifacts. A fenced current job claim commits the
artifact selection and immutable receipt only after the real loader verifies its
bytes. Failed downloads/loads preserve the previous selection and lookup snapshot.
Selected paths and digests restore on restart; tampered artifacts fail closed.

The default source is the current monthly DB-IP Lite URL. Operator startup settings
`YELLOW_DOG_MANAGEMENT_GEOIP_CITY_URL` and `YELLOW_DOG_MANAGEMENT_GEOIP_COUNTRY_URL`
can override it; public command payloads cannot supply source URLs or file paths.
`YELLOW_DOG_MANAGEMENT_ARTIFACT_DIRECTORY` defaults to
`~/.local/share/yellow-dog-management/artifacts`. Preserve that directory alongside
PostgreSQL; a database-only copy does not preserve artifact bytes.

Meaningful scoped queue/loader/UI checks and real release/Chromium/SIGKILL recovery
against controlled local HTTP fixtures use disposable PostgreSQL:

```sh
devenv shell -- scripts/e2e/phase1_postgres.sh bash -lc 'cd apps/yellow_dog_management && mix test test/tasks_test.exs test/task_artifacts_test.exs test/geo_ip_test.exs test/ip_database_live_test.exs test/tasks_live_test.exs test/geo_ip_download_test.exs'
devenv shell -- scripts/e2e/phase1_postgres.sh scripts/e2e/management_tasks.sh
```

The app's `mix test` alias creates/migrates its test database before application
startup so Oban can verify its schema. It does not run unrelated application tests.

LiveView uses a signed session for CSRF protection, not login authentication.
WebSocket origins must match the request connection, including when browsing via
a LAN address. Set `YELLOW_DOG_MANAGEMENT_SECRET_KEY_BASE` to at least 64 bytes
for stable sessions across restarts; without it startup generates an ephemeral
key and existing browser sessions reconnect after a reload.

For HTTPS terminated by a local Caddy proxy, configure the public origin and the
exact proxy socket peer before startup:

```sh
export YELLOW_DOG_MANAGEMENT_EXTERNAL_ORIGIN=https://yellow-dog.gsmlg.net
export YELLOW_DOG_MANAGEMENT_TRUSTED_PROXY_IP=127.0.0.1
```

The origin must be HTTPS without a path, credentials, query or fragment; include
the explicit port if it is not 443. This sets the Endpoint URL and a precise
WebSocket Origin allowlist. Foreign hosts, schemes and ports remain rejected.
Without an external origin, connection-based Origin checking remains unchanged.

Proxy trust is disabled by default and accepts only `127.0.0.1` or `::1`, compared
against the actual socket peer, independently of client/forwarded IP headers.
Trusted HTTP requests rewrite only scheme and port; the proxy must overwrite
`X-Forwarded-Proto` with `https` and `X-Forwarded-Port` with the public port instead
of forwarding client-supplied values. Preserve the public Host header. Management
does not trust `X-Forwarded-For` or `X-Forwarded-Host`; WebSockets use the explicit
origin allowlist independently of these HTTP rewrites.

Keep the backend bound to loopback. Caddy authentication, such as mandatory client
certificates, must protect every UI, WebSocket, API, export and download route;
these settings do not add application login or make plain TLS an access control.

The browser CSP permits same-origin scripts/styles, inline style attributes
needed by LiveView/native anchor positioning, and only the exact hash of the
upstream dropdown toggle handler. The latter is a temporary integration allowance
tracked by `duskmoon-dev/phoenix-duskmoon-ui#172`, not general inline-script access.

## Run and initialize the database

### Local development database

devenv manages PostgreSQL 16 for this checkout. It disables TCP and exports
`PGHOST`, `PGPORT`, `PGDATA`, `PGDATABASE` and
`YELLOW_DOG_MANAGEMENT_DATABASE_URL`. The URL's `socket_dir` selects the
project-specific Unix socket; `localhost` is only the URL parser's required host,
not a TCP connection. Existing PostgreSQL services on TCP port 5432 are untouched.

```sh
# From the repository root:
devenv up -d postgres
devenv shell -- mix ecto.setup
devenv shell -- psql -U yellow_dog
devenv processes status postgres
devenv processes stop postgres
```

`mix ecto.setup` creates `yellow_dog_management_dev` and applies existing
migrations, without starting Management, Worker or HTTP. It can also run directly
inside `apps/yellow_dog_management`. Repeating it is safe. PostgreSQL creates the
local `yellow_dog` role with database-creation permission on first initialization;
Ecto owns database creation and migrations. Data persists in
`.devenv/state/postgres/` after stopping the service.

Local socket authentication uses trust with owner-only socket permissions (`0700`);
this is a development-only configuration, not a production authentication policy.
To run Management, start PostgreSQL as above and run
`devenv shell -- mix management.run`. Open `http://127.0.0.1:4270` directly.
The UI/API has no authentication or login and requires no operator token.

`YELLOW_DOG_MANAGEMENT_BIND_ADDRESS` defaults to `127.0.0.1` and
`YELLOW_DOG_MANAGEMENT_PORT` defaults to `4270`. With PostgreSQL
running, test/development startup on all IPv4 interfaces is:

```sh
devenv shell -- env YELLOW_DOG_MANAGEMENT_BIND_ADDRESS=0.0.0.0 mix management.run
```

Non-loopback binding exposes the unauthenticated UI/API to reachable hosts. Anyone
who can reach it can read, modify, and export business data. Use this explicit
all-interface development mode only on a trusted network or behind an external
authentication/TLS reverse proxy. For production remote access, protect the
loopback listener with that proxy rather than exposing plain HTTP directly.

Choose focused business tests and use disposable PostgreSQL rather than the
development database. For desired-data, UI and record/import workflows:

```sh
devenv shell -- scripts/e2e/phase1_postgres.sh mix do --app yellow_dog_management cmd mix test test/domain_test.exs test/ui_test.exs test/records_live_test.exs test/zone_import_live_test.exs
```

For real Chromium acceptance against a freshly built release and temporary
GeoIP/OUI artifacts, with no development database mutations:

```sh
devenv shell -- scripts/e2e/phase1_postgres.sh scripts/e2e/management_browser.sh
```

The historical profile browser workflow assumes the superseded ID/Profile
registration form. Current registration and real connection acceptance use the
Worker connection workflow below.

## Worker management and connection

Open `/management/servers` under Management. **Add Worker** requires only its
name; the ID and random token are generated automatically. Save the displayed
`bootstrap.toml` on the Worker with mode `0600`. The token is shown once. **Reset
token** revokes the old token and displays a replacement configuration.

```toml
worker_id = "generated-worker-id"
data_dir = "data"
management_url = "https://yellow-dog.gsmlg.net"
token = "generated-worker-token"
poll_interval_ms = 10000
# Optional local PEM files for a private CA or mutual-TLS gateway:
# tls_ca_file = "/etc/yellow-dog/ca.pem"
# tls_cert_file = "/etc/yellow-dog/client.pem"
# tls_key_file = "/etc/yellow-dog/client-key.pem"
```

Start the independent Worker release:

```sh
YELLOW_DOG_WORKER_BOOTSTRAP=/absolute/path/bootstrap.toml bin/yellow_dog_worker start
```

New Workers have no services. Configure a DNS instance and its Zone assignments,
save the desired state, then **Publish configuration**. Saving a service draft
does not publish it. The Worker validates and applies the complete confirmed
target through its existing durable execution path. DNS is the only currently
implemented service; historical profiles do not establish other runtime support.

The table and dashboard refresh connection and actual service reports. No contact
for 45 seconds changes the connection to Offline; older service reports are
labelled as the last report. Desired state, applied revision and actual state
remain distinct. An outage leaves the last committed Worker configuration running;
Worker restart restores that snapshot even when Management is unavailable.

`POST /api/worker/connect` is a dedicated Bearer-authenticated machine endpoint.
The credential permits only its own Worker identity, target and report. Tokens
are SHA-256 hashes in PostgreSQL and are excluded from ordinary Worker queries,
audit and idempotency records. Configure an external gateway to allow this route
with the Worker authentication and any required TLS client certificate; browser
session authentication cannot be supplied by the polling client.

Verify separate releases and real DNS UDP/TCP behavior with disposable PostgreSQL:

```sh
devenv shell -- scripts/e2e/phase1_postgres.sh scripts/e2e/worker_connection_smoke.sh
```

### Deployment database

Use a dedicated PostgreSQL database. The UI and operator API routes are unauthenticated:
there is no login or operator token, and reachable clients have full
read/write/export access. The dedicated Worker machine API requires its own token.
The listener binds to loopback on port `4270` by default; use an external
authentication/TLS reverse proxy for non-local browser or API access.

```sh
export YELLOW_DOG_MANAGEMENT_DATABASE_URL=postgres://postgres@127.0.0.1:5432/yellow_dog_management
export YELLOW_DOG_MANAGEMENT_PORT=4270
# From the repository root, inside devenv shell:
MIX_ENV=prod mix deps.get
MIX_ENV=prod mix compile --warnings-as-errors
MIX_ENV=prod mix release yellow_dog_management
_build/prod/rel/yellow_dog_management/bin/yellow_dog_management eval 'YellowDog.Management.Release.migrate()'
_build/prod/rel/yellow_dog_management/bin/yellow_dog_management start
```

Open `http://127.0.0.1:4270`, create a complete SOA/NS/A zone, save and
confirm its version. This works with an empty Worker list. Then create any number
of logical Workers, define their DNS service instance, select an explicit version,
and check one or more Worker targets. Each selected Worker assignment is a separate
transaction; the UI reports how many completed if a later assignment fails.
Preview the complete target, confirm it, and download its selected revision.

For development, `mix management.run` from the root starts only Management and its
dependencies; it does not start Worker or the legacy Phoenix console.

The UI's record editor supports SOA, NS, and A only. Fully qualified names are
recommended. SOA value order is `mname rname serial refresh retry expire minimum`.
Service configuration is IPv4 `listen_address` and port 1–65535. Recursion, DNSSEC,
other record types, and other protocols are explicitly unsupported in C0.

## API

No `Authorization` header or login is required for `/api` requests. All JSON mutations
use `POST /api/commands/<operation>` and require `Idempotency-Key: <1..128 bytes>`.
Success is `{"data": ...}`; failure is `{"error":{"code":...,"message":...,"details":...}}`.
Revision/idempotency conflicts return HTTP 409, missing data 404, invalid data 422,
malformed JSON 400, and oversized bodies 413 (1 MiB maximum).

Read routes:

- `GET /api/workers`, `/api/workers/:id` (includes services and assignments)
- `GET /api/zones`, `/api/zones/:id`, `/api/zones/:id/versions`
- `GET /api/workers/:id/preview` (complete next plan and previous-target diff)
- `GET /api/workers/:id/targets/:revision` (`latest` also accepted)
- `GET /api/workers/:id/targets/:revision/export` (TOML attachment)

Operations and required parameters:

| Operation | Parameters |
| --- | --- |
| `create_worker` | `id`, `name`, `expected_capabilities: ["dns"]` |
| `update_worker` | `id`, `expected_revision`, editable name/capabilities |
| `create_zone` | `name`, `records` |
| `update_zone` | `id`, `expected_revision`, `name`, complete `records` |
| `delete_zone`, `confirm_zone` | `id`, `expected_revision` |
| `put_service` | `worker_id`, `expected_revision`, `id` (instance ID), `type: "dns"`, `desired_state`, `config` |
| `assign` | `worker_id`, `expected_revision`, `service_id`, `resource_version_id` |
| `unassign` | `worker_id`, `expected_revision`, `service_id`, `resource_id` |
| `confirm_target` | `worker_id`, `expected_revision` |

For Worker operations, fetch the current Worker `revision`; it is the aggregate
compare-and-swap revision, separate from confirmed plan revision, Zone draft revision,
resource version, and SOA serial. Savepoint rollback persists a failed mutation's
idempotency outcome too. Retry the exact same request/key after a lost response;
use a new key for a corrected request. No key expiry is implemented in Phase 1.

For example, to confirm and export a selected prepared target:

```sh
curl --fail-with-body \
  -H 'Content-Type: application/json' -H 'Idempotency-Key: prepare-worker-one-r3' \
  -d '{"worker_id":"worker-one","expected_revision":3}' \
  http://127.0.0.1:4270/api/commands/confirm_target
curl --fail-with-body \
  http://127.0.0.1:4270/api/workers/worker-one/targets/1/export > worker-one-1.toml
```

## Data and transaction boundaries

Relational tables cover Workers, services, Zones, RRsets, immutable resource
versions, assignments, immutable target plans, audit events, and idempotency outcomes.
RRset records are stored together by `(zone_id, name, type)` with one TTL. Immutable
content and complete confirmed targets use validated JSONB snapshots; editable
business data is not a giant JSONB store. Foreign keys and unique indexes constrain
relationships. PostgreSQL triggers prevent update/delete of confirmed versions and
targets, including direct SQL writes.

A mutation locks its idempotency row, then its aggregate rows, validates the complete
candidate, and commits business effects, audit, and durable response together. Zone
edits and Worker mutations require expected revisions. Conflicting concurrent edits
return an explicit conflict; the caller reloads and retries with a new key.

Assignments reference one immutable version, shared across Workers. A Zone cannot
be deleted while assigned: explicitly unassign it first. Deleting an unassigned
Zone soft-deletes its draft and retains immutable versions and target snapshots.
Unassignment changes the next complete target only. Editing a draft never updates
an assigned version implicitly, and no operation starts a stopped service.

Exports use the committed target JSONB snapshot outside a write transaction, pass it
through ConfigSpec encoding and decoding, and check normalized equality and semantic
digests. A failed export can be retried for the same revision. This verifies
PostgreSQL/export consistency, not a physical Worker's disk or runtime.

## Business acceptance evidence

### Global DNS catalog controls

The reusable Zone library provides name filters/counts, read-only refresh,
filtered CSV and explicit draft-delete confirmation/cancellation. Refresh keeps
entered editor data and its original revision; deletion archives drafts and
retains confirmed history. Unknown runtime query counts are marked unavailable.

Records provide owner/type filters, filtered CSV and full-Zone BIND download.
Filtering never changes record action ordinals. BIND exports every current
SOA/NS/A draft record regardless of filters; it is not a runtime snapshot.
Refreshing a changed draft during editing preserves the unsaved form and blocks
stale saves until explicitly reloaded. View ownership, more types and BIND import
remain separate pending functions.

Bulk Add previews the full candidate through the same pure ConfigSpec validator
used by draft mutation, and shows only the canonical appended rows and their
type counts. Save stays disabled without a valid current-source preview; a
changed revision invalidates the preview while retaining the entered text.
The existing record-delete browser confirmation retains cancellation and
cached-revision CAS. Filtered row actions continue to use original ordinals.
See `docs/phase1/dns-bind-import-audit.md` for the separate BIND parser blockers;
this JSON workflow is not a substitute for required BIND create/append support.

Current scoped acceptance (2026-10-02): 83 Zone/Records/bulk-preview/export/import
checks pass. The prepared-export regression uses a nonempty logical Worker,
stopped Service, assigned immutable version and prepared target, preserving exact
TOML/plan/digest after draft append. Real Chromium release evidence at
`/tmp/management-dns-catalog-release-6s8t3z46` verifies preview/append/edit,
native record-delete cancel/accept and stale CAS, exact PostgreSQL effects,
desktop/mobile bulk-preview rendering and SIGKILL read-only replay. Development
deployment `/tmp/management-bulk-preview-deploy.9I2VHh` preserves all 21 persistent
tables and inserts no fixtures; the listener remains `0.0.0.0:4270` without login.

```sh
scripts/e2e/phase1_postgres.sh scripts/e2e/management_dns_catalog.sh
```

### DNS Views desired configuration

Select a Worker, then an explicit DNS Service at
`/server/:server_id/dns/views/:service_id`. Views retain name/status filtering,
filtered CSV, create/edit/cancel, desired enable toggles and confirmed deletion.
The native editor includes priority, recursion, ECS, ordered inline client rules,
country selection/recipes and ordered IPv4/IPv6 fallback endpoints with timeout
and retries. Names are immutable; View edits use independent revisions and
preserve omitted settings.

A DNS Service creation atomically provisions its default View; migration
provisions existing DNS Services. Read/refresh/startup do not create records.
Default has infinite priority and unconditional allow policy, neither editable;
it cannot be deleted. Its desired enabled, recursion, ECS and fallback fields
remain editable. These are PostgreSQL desired data, not execution or observation.
View-Zone/RPZ bindings and matching/recursion/forwarding/WorkerPlan integration
remain pending. View edits do not change Service configs or Worker exports.

```sh
scripts/e2e/phase1_postgres.sh bash scripts/e2e/management_dns_views.sh
```

Verify the function being delivered: durable desired-data changes/restart,
stale-input rejection and atomic rollback, immutable business history/export,
actual local lookup/log/effect observations, and meaningful interactive success/
error behavior. Whole-suite all-green totals, old-route counts and exact legacy
API reproduction are not completion criteria. Relevant failed checks remain real
failures and cannot be skipped or weakened; unrelated failures are reported
separately. Pending functions stay pending.

Run selected checks from the repository root inside `devenv shell`. The PostgreSQL
helper supplies a disposable database; current schema setup and SQL Sandbox are
test infrastructure, not a requirement to migrate old software/data versions:

```sh
scripts/e2e/phase1_postgres.sh mix cmd --app yellow_dog_management mix test test/domain_test.exs test/ui_test.exs test/records_live_test.exs test/zone_import_live_test.exs
mix cmd --app yellow_dog_management mix compile --warnings-as-errors
(cd apps/yellow_dog_management && mix format --check-formatted)
mix cmd --app yellow_dog_config_spec mix test
```

The release helper builds the root production release and migrates a **fresh empty
disposable DB** before invoking `apps/yellow_dog_management/test/release_smoke.py`.
It starts/stops the actual release twice, asserts its dependency set, exercises
four-Worker allocation, and verifies restart/idempotency/historical export durability.
It intentionally fails on a populated database instead of deleting data.
Requests omit `Authorization` headers and the release receives no operator token.
The disposable smoke listener defaults to port `14280` to avoid the development
listener on `4270`; `YELLOW_DOG_MANAGEMENT_PORT` explicitly overrides the smoke port.

```sh
scripts/e2e/phase1_postgres.sh scripts/e2e/release_smoke.sh yellow_dog_management
```

Compilation/format and architecture isolation are supporting evidence, not proof
of full business-function coverage. There is no previous/forward software-version
compatibility, legacy-record adapter or old-backup import requirement. Future
backup work must instead prove current-dataset integrity, immutable history and
safe destructive restore; the operations proposal is still pending implementation.

Authenticated Worker attachment, observation reports and confirmed-target delivery
are implemented by the Worker connection workflow above. Other network services
remain deferred; the data ownership and single ConfigSpec boundary remain intact.
