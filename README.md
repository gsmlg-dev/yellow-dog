# Yellow Dog

![Yellow Dog](./priv/yellow_dog.png)

Phase 1 has exactly two independent business releases:

- `yellow_dog_management`: PostgreSQL-backed DNS data UI/API, logical Workers,
  immutable resource versions, complete target preview/confirmation, and TOML export.
- `yellow_dog_worker`: local TOML-only desired-state execution, durable committed
  snapshots, explicit reload, and authoritative DNS over UDP/TCP.

Service configuration belongs to Management; network services execute on Worker.
Netboot and Identity are exclusively Worker capabilities, not Management boot
servers or a central identity/trust authority. Their implementation is deferred.
The architecture-only slice is verified. The current task transfers original UI
source directly into Management's compiled `ManagementUI.Redesign` tree for later
redesign, with compilation/runtime failure accepted. Source coverage and provenance
are in `docs/phase1/ui-source-migration.md`; backend redevelopment and Worker
runtime failures remain deferred and are not claimed fixed.

Management can create data without any Worker records. A logical Worker is not a
connected runtime: its actual state remains unknown. Operators explicitly export
and transfer a complete confirmed target to the appropriate local Worker.
There is no enrollment, heartbeat, remote delivery, or connected reconciliation in
Phase 1. Legacy business-data migration and mixed-runtime compatibility are excluded.

## Build From This Checkout

Run Mix commands inside the repository's Nix devenv:

```sh
devenv shell
mix deps.get
mix compile --warnings-as-errors
MIX_ENV=prod mix release yellow_dog_management
MIX_ENV=prod mix release yellow_dog_worker
```

The existing umbrella selects the two products plus `yellow_dog_config_spec`,
`abyss`, and `ex_dns`. Both products use the same ConfigSpec and fixtures under
`apps/yellow_dog_config_spec/`. No source assembly, pending documentation patch,
Node/console asset build, or legacy service startup is needed.

Legacy applications remain reusable source, not supported business releases.
`yellow_dog_management_core`, `yellow_dog_server`, `yellow_dog_netman`, the combined
`yellow_dog` release, and their console/server/Netman startup aliases are retired.
Historical Track A/B reports describe pre-integration runs; they are not current
acceptance evidence.

## Management

Use a dedicated PostgreSQL database. Database credentials are read at runtime,
not during compilation. Normal Ecto migrations are explicit:

```sh
export YELLOW_DOG_MANAGEMENT_DATABASE_URL=postgres://postgres@127.0.0.1:5432/yellow_dog_management
export YELLOW_DOG_MANAGEMENT_PORT=4270
_build/prod/rel/yellow_dog_management/bin/yellow_dog_management eval 'YellowDog.Management.Release.migrate()'
_build/prod/rel/yellow_dog_management/bin/yellow_dog_management start
```

Open `http://127.0.0.1:4270` directly; there is no login or UI/API authentication.
The default listener is loopback (`127.0.0.1`) on port `4270`. Anyone who can reach
it can read, modify, and export business data. Use an external authentication/TLS
reverse proxy for remote access. All-interface development binding is explicit
and must be restricted to a trusted network or protected by that proxy.
See `apps/yellow_dog_management/README.md` for
the API, concurrency controls, immutable targets, and supported DNS data.

For development, devenv supplies a project-specific PostgreSQL Unix socket and
database environment variables; it does not bind a TCP port:

```sh
devenv up -d postgres
devenv shell -- mix ecto.setup
```

Then run `devenv shell -- mix management.run` to start only Management and its
dependencies. No operator token is required. Database data persists under
`.devenv/state/postgres/`. See the Management README for connection and stop commands.

### Management Overview and Events

The overview displays real logical Worker/Netman/Zone counts, all 13 read-only
Server/Netman presets and the latest five durable PostgreSQL audit events.
Refresh is read-only. `/management/events` groups desired Worker/Netman events
and exposes committed/rejected transaction outcomes and JSON details for the
latest 100 retained audits. These are not remote execution, Worker application
or task-completion claims; nonpersisted requests are not invented into history.

Run only this feature's real PostgreSQL/Chromium/restart acceptance with:

```sh
devenv shell -- scripts/e2e/phase1_postgres.sh scripts/e2e/management_overview.sh
```

### Management Backups

`/system/backups` provides optional labels (at most 128 UTF-8 bytes), catalog
metadata, durable Oban creation/deletion jobs, asynchronous verification, and
downloads at `/api/backups/:id/download`. Pending/deleting states refresh
automatically; queued work is not successful completion. Deletion requires
confirmation, can be canceled, and removes only the selected backup package,
not live business data or selected GeoIP artifacts.

Each private current-format package contains a PostgreSQL custom-format dump,
a JSON manifest with per-table counts and digests, and the immutable GeoIP
artifact files referenced by the captured catalog. Ordinary concurrent writers
may continue: manifest counts, artifact references and `pg_dump --snapshot`
use the same exported PostgreSQL snapshot. Concurrent schema migration/DDL and
schema/software-version conversion are outside this backup scope. Worker local
state, live Logger/ETS/socket/process state, deployment credentials, and the bytes
of earlier backup archives are excluded.

The snapshot may include this backup's own pending catalog row and in-progress
job state; it precedes their later ready/completed receipts. Verification reports
`byte_integrity`, not full recoverability or a successful restore.
`/system/backups/restore` supports selection, byte verification and acknowledgment
of destructive downtime requirements, but **restore execution remains
unavailable**. There is no executable restore CLI or live-database restore action.

The parent reports the final 33 scoped tests, owned-file formatting and the
current native/release/Chromium E2E passing, including isolated staging PostgreSQL
restore and identical-archive adoption on retry after publication but before the
ready catalog commit. Destructive live/offline restore execution was not
exercised and remains unimplemented. See the backup section of
`docs/phase1/ui-migration-matrix.md` for exact evidence, development deployment
observations and remaining destructive-recovery gates.

## Worker

The Linux Worker requires `flock` from util-linux, GNU coreutils `sync` (including
`sync -f`), and `/bin/sh`. The devenv includes these tools. A packaged runtime must
put them on `PATH`; no database, Management URL, Agent, or credential is required.

```toml
worker_id = "edge-01"
data_dir = "/var/lib/yellowdog-worker"
source = "/etc/yellowdog-worker/target.toml"
```

Save this machine-local bootstrap separately from the Management-exported target.
The target's `worker_id` must match it. Start with:

```sh
YELLOW_DOG_WORKER_BOOTSTRAP=/etc/yellowdog-worker/bootstrap.toml \
  _build/prod/rel/yellow_dog_worker/bin/yellow_dog_worker start
```

For development, `mix worker.run` starts only Worker and its dependencies. See
`apps/yellow_dog_worker/README.md` for explicit lifecycle/reload commands, local
snapshot recovery, file permissions, and SOA/NS/A configuration.

## Architecture Validation

From the repository root, run the dedicated architecture-split gate:

```sh
devenv shell -- scripts/e2e/architecture_smoke.sh
```

It compiles the production root with warnings-as-errors, builds exactly the two
business releases, and checks root app/release selection, isolated runtime config,
full artifact dependencies, and the purity and byte equality of shared ConfigSpec.
It does not start Management, PostgreSQL, or Worker services and is separate from
full service/UI acceptance.

## Scoped Service and Contract Validation

Run the following commands from the repository root inside `devenv shell`:

```sh
mix cmd --app yellow_dog_config_spec --app yellow_dog_worker mix test
scripts/e2e/phase1_postgres.sh mix cmd --app yellow_dog_management mix test
mix format --check-formatted mix.exs config/config.exs apps/yellow_dog_management/mix.exs apps/yellow_dog_worker/mix.exs
(cd apps/yellow_dog_config_spec && mix format --check-formatted)
```

Run actual release smokes against disposable state, not an operator's database:

```sh
scripts/e2e/phase1_postgres.sh scripts/e2e/release_smoke.sh yellow_dog_management
scripts/e2e/release_smoke.sh yellow_dog_worker
```

The PostgreSQL helper starts an isolated cluster on a temporary loopback port,
exports its fresh database URL only to the command, stops it on exit, and retains
its data/logs under the printed temporary directory. Release tests inspect complete
transitive application contents and actual process-owned listeners.

Release smokes and fixture tests do not replace the final file-only interoperability
gate: Management's actual export must boot/recover Worker after both
Management and PostgreSQL stop. This is a separate service integration check, not
the dedicated architecture gate. Known runtime/UI defects and external-resource
source-format work are explicitly deferred while completing the architecture
split; failures must not be hidden with new test skips. Current evidence and
remaining work are tracked in `docs/phase1/integration-progress.md`.

Run the real file-only gate from the same checkout:

```sh
devenv shell -- scripts/e2e/file_gate.sh
```

It builds both products without assembling source trees, creates and confirms
targets through HTTP without authentication, and stops both Management and its disposable
PostgreSQL cluster before booting Worker. Its selected exports and process logs
are retained under `/tmp/yellow-dog-file-gate-*`. The gate compares actual UDP/TCP
SOA/NS/A content to those exports and exercises local recovery, stopped intent,
zone change/removal and equivalent no-write reloads. It does not replace the
separate blocked-shutdown, TCP concurrency or negative-SOA-TTL regressions.

## Linux Packages

The pinned Nix flake exposes two independent packages and two images:

```sh
nix build .#yellow_dog_management
nix build .#yellow_dog_worker
nix build .#docker-management
nix build .#docker-worker
```

`default` aliases Worker; it is not a third product. Both x86_64 and aarch64 Linux
are supported. The Worker Nix wrapper supplies util-linux, GNU coreutils and Bash
on `PATH`, including inside its Nix image. The images provide `/bin/sh`; neither
contains a PostgreSQL server or baked database/operator credentials.

Set `RELEASE_COOKIE` to a deployment-specific secret before running either Nix
package, including `eval` for migrations. The immutable Nix store cannot generate
`releases/COOKIE` at startup; `RELEASE_DISTRIBUTION=none` does not remove this
bootstrap requirement. Do not bake the cookie into an image.

The Debian Dockerfile selects one product using `MIX_RELEASE_NAME`. Build locally
without publishing using the devenv:

```sh
devenv shell -- ./build_img.sh 1.2.0 yellow_dog_management --load
devenv shell -- ./build_img.sh 1.2.0 yellow_dog_worker --load
```

Worker containers need a writable local state directory and a mounted bootstrap
and target; Management containers need a dedicated external PostgreSQL database
and network access restricted to trusted hosts or an external authentication/TLS
proxy. Use the explicit release commands above for migrations.
Release tarballs contain ERTS but need the host's compatible Linux shared libraries;
Worker tarball hosts must also install util-linux/coreutils and provide `/bin/sh`.
Only the two products have tarball/image release matrices. Image publication is
explicitly opt-in on the manual image workflows; the existing release workflow
publishes only when manually dispatched. No workflow is dispatched by these
local validation commands.

## License

See `LICENSE`.
