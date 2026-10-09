# Yellow Dog Worker (Phase 1)

An independent Linux service host. It obtains the shared ConfigSpec WorkerPlan from
local TOML or Management, runs authoritative DNS, and recovers from its own committed snapshots.
It has no PostgreSQL or Management application dependency. It supports either
local TOML or an opt-in authenticated Management connection. Both submit complete
WorkerPlans through `YellowDog.Worker.submit_plan/2`, the same path as local reload.

Worker owns network-service execution, including Netboot and Identity. Management
authors service configuration but does not run provisioning or identity/trust
services. Only authoritative DNS is currently implemented here; restoring the
architecture does not require adding the remaining services or fixing runtime
failures. This ownership decision is not a claim of functional acceptance.

## Build and run

### Managed connection

Create a Worker under Management → Workers using its name, then save the generated
bootstrap on the Worker host and set `YELLOW_DOG_WORKER_BOOTSTRAP` to that file.
The managed file uses `worker_id`, `data_dir`, `management_url`, and `token`; it has
no `source`. See `examples/managed-bootstrap.toml`. Protect this file as a credential.

The Worker polls `POST /api/worker/connect` every 10 seconds, authenticates using
its Bearer token, fetches only confirmed targets, and reports observed DNS states.
Optional `poll_interval_ms` accepts 100–15000 milliseconds so regular polling stays
within Management's 45-second contact expiry.
Only authoritative DNS is executable. HTTPS verifies the server certificate and
hostname. Optional `tls_ca_file`, `tls_cert_file`, and `tls_key_file` configure a
private CA and client certificate; client certificate and key must be provided
together. TLS file paths resolve relative to the bootstrap. Plain HTTP is allowed
only for loopback development. Redirects are refused; replies are bounded to 1 MiB.

An empty first boot waits for Management without starting services. Restart restores
the last committed snapshot before reconnecting. Connection loss or a rejected
target leaves existing services running; a committed stopped service stays stopped.
Target identity, semantic digest, and monotonic revision are checked before applying.
Token rotation requires replacing the token in the bootstrap and restarting Worker.
Management saves and target preparation are distinct from real execution reports.

### Local TOML

The integrated root build uses the same `apps/yellow_dog_config_spec/` as Management.
Build the real product directly from the repository root in the devenv shell:

```sh
mix deps.get
MIX_ENV=prod mix release yellow_dog_worker --overwrite
```

Check the architecture split separately from service/UI acceptance:

```sh
devenv shell -- scripts/e2e/architecture_smoke.sh
```

`devenv shell -- docs/phase1/prepare-worker-validation.sh /tmp/yellow-dog-worker-build`
optionally selects build output at `/tmp/yellow-dog-worker-build/_build/prod/`
and prints the release binary path. It builds the same checkout, not a copied
source assembly, and is not an acceptance gate.

Copy `apps/yellow_dog_worker/examples/bootstrap.toml` and
`apps/yellow_dog_worker/examples/plan.toml` to a local configuration
directory. Adjust `worker_id` in both files and the DNS listen address/port in the
plan. The sample binds loopback port 1053. Bootstrap paths are relative to the
bootstrap file. Bootstrap has exactly three required fields: `worker_id`, `source`,
and `data_dir`. Its identity and machine-local paths never come from a managed plan.

```sh
YELLOW_DOG_WORKER_BOOTSTRAP=/etc/yellow-dog/bootstrap.toml \
  _build/prod/rel/yellow_dog_worker/bin/yellow_dog_worker start
```

Linux runtime tools `flock`, POSIX `sh`, `cat`, and GNU `sync` must be on PATH.
The release contains the Erlang runtime. DNS ports below 1024 need the appropriate
OS permission; use an unprivileged port for validation. The source and data directory
must be owned by the trusted local operator; symlink paths are rejected. Do not use
a network filesystem: this implementation relies on local Linux flock/rename/syncfs
semantics. It does not claim safety against a malicious writer with the same UID.

## Local control and precedence

In the release's remote console (`bin/yellow_dog_worker remote`) or with its local
`rpc` command:

```elixir
YellowDog.Worker.status()
YellowDog.Worker.check()
YellowDog.Worker.reload()
```

For example, `bin/yellow_dog_worker rpc 'IO.inspect(YellowDog.Worker.reload())'`.
Release RPC uses normal Erlang distribution and its cookie; it is local operator
control, not a Management Agent. Standard release node/cookie settings must match
between `start` and `rpc`. Use `RELEASE_DISTRIBUTION=none` when RPC is not needed.

First boot with no committed snapshot reads the source. Invalid first-boot source
leaves Worker alive and explicitly not ready, with the validation error available
in status. A missing/invalid bootstrap or unavailable data-directory lock fails boot.

Once a plan is committed, restart always restores that snapshot, even if the source
is missing, invalid, or contains uncommitted changes. Edit source and explicitly
invoke `reload()` to change the desired state. There is no file watcher or implicit
source overwrite on restart. To stop/start DNS, change its `desired_state` to
`stopped`/`running` and reload. There are no memory-only lifecycle overrides.
Updating a stopped service persists its data without creating listeners. Removing
an instance from the complete plan stops it. Required explicit empty service and
resource arrays are valid; missing arrays are invalid.

A reload validates the entire plan and target identity, stages an immutable snapshot,
serializes each service's change, and commits one pointer only after all applications
succeed. Failures restore the recoverable committed target and report the rejection,
attempted per-service outcomes and rollback outcome. Cross-service cutover is not
simultaneous; each DNS query sees one complete in-memory zone snapshot. DNS data
updates with an unchanged binding keep the listener process running. Resource
versions and DNS SOA serials are explicit input fields, separate from plan revision.

Equivalent semantic reloads retain the existing committed revision, snapshot and
healthy service PID. A missing runtime is repaired through the same controller;
missing/corrupt persisted data can be reinstalled on explicit reload. Status has
separate desired, prepared, persisted, active, readiness and error fields; `check()`
returns structured runtime/content/disk differences and does not execute repair.
A rejected reload can coexist with a ready last-valid service; inspect `error`.

## Supported configuration

Plans use the one shared C0 schema described in
`docs/phase1/shared-baseline/README.md`. The checked-in example is the shared complete
SOA/NS/A fixture. Resources are self-contained in the plan's TOML; external resource
file references are not defined by C0 and are rejected, rather than interpreted as
an alternate format. Service resource references select IDs in that complete plan.

Only allowlisted `dns` instances and `dns_zone` resources are executable. IPv4
listeners, IN SOA/NS/A data, authoritative UDP/TCP queries, negative replies and
UDP truncation are supported. Recursion, zone transfers, DNSSEC, non-apex NS
referrals/delegations and other record data are outside this adapter's supported
surface. Unsupported configuration fails explicitly. Queries outside loaded zones
are refused. DNS answers use loaded memory and never read TOML per query.

C0 bounds a plan to 1 MiB, 64 services, 256 resources and 1,024 records per zone;
IDs and domain/record fields have additional shared bounds. Input digests are
recomputed. No configuration string is converted to an executable module or atom.

## Persistence and recovery

`data_dir` is owned by one LocalStore. A kernel flock held by a child process is
released when its owning process/VM dies; a second Worker is refused. The snapshots
are complete generated TOML, addressed by SHA-256 of canonical encoded bytes. These
storage hashes are distinct from shared semantic resource/plan digests.

The store writes a uniquely named temporary file, checks file sync and close,
reads/validates the generated TOML, renames it to the immutable snapshot name, and
checks directory/filesystem synchronization with GNU `sync -f` (Linux syncfs).
Only then does it write/sync/read back a temporary commit pointer and atomically
replace `current`, followed by synchronization. The pointer names both active and
previous snapshots. Prepared but uncommitted files never become startup state.
A post-rename synchronization error attempts a synchronized pointer rollback;
failure of rollback is explicitly `commit_uncertain`, never success.

LocalStore also atomically replaces one bounded, checksummed
`journal/transition.toml` under the same directory lock. It retains the latest
attempt, exact base pointer/last-valid hash, candidate hash, phase and ordered
forward/recovery service outcomes, without duplicating plans or storing PIDs.
Complete-plan adapter validation precedes staging. Durable intent precedes effects;
each dispatch is recorded before execution and its observed acceptance or confirmed
owned termination afterward. Lost outcome persistence stops forward work and
reports uncertainty. Commit intent, synchronized pointer replacement,
`pointer_committed` and completed finalization all precede a successful reply.

Restart chooses the base for incomplete application/commit intent, even when a
candidate pointer is readable. Only a matching pointer and `pointer_committed` or
completed-commit checkpoint permit candidate recovery, after checked synchronization
and real runtime reconciliation. Interrupted first boot without a base stays not
ready until explicit reload; it never implicitly retries editable source. Invalid,
unsupported or unrelated journals fail explicitly. Journal-free directories remain
compatible. Completed historical rejection is diagnostic rather than permanent
storage uncertainty; finalization failures still return errors, never retroactive
success. Status/check only observe; managed controller repair is coordinated through
the same manager/journal path. Healthy semantic no-ops perform zero persistence
operations, including journal writes; projection repair preserves sound snapshots
and `current`.

An explicit retry first reconciles an unfinished attempt and checkpoints its
recovery before staging another plan or returning unchanged. A failed recovery
checkpoint halts further actions and remains visible as persistence uncertainty;
a later explicit retry must reconcile again. Journal APIs reject missing or
out-of-order transitions without advancing durable state. Recovery through a
valid previous snapshot retains the corrupted-active warning in status/check.

Recovery verifies snapshot bytes and parses the full shared plan. If the active
snapshot is damaged and the previous one is valid, status reports recovery on the
previous version. Corrupt commit records fail explicitly. No garbage collection is
implemented: active, previous and staged snapshots are all retained. Operators must
monitor disk usage. The fault tests exercise write/permission/sync failures and
process interruption; they do not simulate every filesystem or physical power loss.

## Verification

Run from the repository root. These service checks are separate from the dedicated
architecture gate. Known runtime/UI defects and external-resource source-format
work are deferred while completing the split; do not add skips to hide failures.

```sh
devenv shell -- mix cmd --app yellow_dog_worker mix test
devenv shell -- scripts/e2e/release_smoke.sh yellow_dog_worker
devenv shell -- env MIX_ENV=prod mix release yellow_dog_worker --overwrite
devenv shell -- python3 apps/yellow_dog_worker/test/worker_transition_crash.py \
  _build/prod/rel/yellow_dog_worker/bin/yellow_dog_worker
```

The release smoke uses real sockets and independent OS restarts, including SIGKILL.
It unsets Management/database environment settings, checks release dependencies,
serves SOA/NS/A on UDP and TCP, reloads during queries, verifies no-op file/PID
stability, rejects a second directory owner, and proves stopped-state persistence
and later explicit start with updated data. See `docs/phase1/track-b-report.md` for
historical isolated results. Current integrated evidence and remaining acceptance
gates are in `docs/phase1/integration-progress.md`.

The dedicated journal crash harness installs test-only barriers in the actual
release through local RPC, blocks at precise dispatch/action/commit boundaries,
and SIGKILLs independent OS processes. It checks source-absent recovery using an
independent UDP/TCP SOA/NS/A client, stopped intent and explicit first-boot reload.
These are process-crash tests, not proof against physical power loss. Unit faults
exercise the actual FileOps open/write/file-sync/close wrapper and store readback,
rename and directory synchronization paths. Test logs/data stay under `/tmp`.
