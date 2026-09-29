# Track B implementation and acceptance report

Baseline: `fa6dd08348752e9f64a804869258ee99e6857791` (`main`, initially clean).
Implementation branch: `codex/phase1-worker`. This report records pre-commit validation. No push, PR, issue,
production deployment, legacy migration or real DNS delegation change was made.

## Result and remaining acceptance boundary

Implemented and built `yellow_dog_worker` as an independently runnable release.
The actual release passed local TOML boot, real authoritative UDP/TCP SOA/NS/A,
explicit reload, complete RRset replacement, stopped-state persistence, updates
while stopped, later explicit start, directory exclusion, and independent OS restart
including SIGKILL. No Management Agent or PostgreSQL dependency is present.

**Shared integration is still pending.** The production release was built from a
reproducible isolated assembly containing Worker, Abyss, ex_dns and the existing
proposed C0 ConfigSpec. This is a real built/running release, not a claim that the
unpatched root umbrella is integrated or that all of Phase 1 is complete.

The available `yellow-dog-phase-1-parallel-refactor-plan-en.md` was read and followed.
The requested `yellow-dog-phase-1-worker-codex-task-en.md` was not present in the
checkout, local specification copies, Downloads or available Codex attachments.
Its path/text was requested from the user; no response was received. Compliance
with additional requirements in that missing document remains unverified.

## Files and interfaces

- `apps/yellow_dog_worker/mix.exs`, `config/`, `Application`, `Bootstrap`:
  independent application/release and strictly local identity/source/data bootstrap.
- `ConfigLoader`: bounded file reads, target identity checks, traversal/symlink
  rejection, monitored shared parser with timeout and heap limits.
- `LocalStore`/`FileOps`: kernel directory lock, read-back-validated immutable TOML,
  synchronized snapshot and commit-pointer writes, retained previous snapshot,
  interruption recovery, explicit commit uncertainty and reconciliation.
- `ServiceManager`: the complete WorkerPlan submission path, first-boot/restart
  precedence, validation, candidate application, commit, rollback, status and checks.
- `ServiceController`: each instance's serialized lifecycle, listener quiescence,
  data update and runtime recovery. Swapping live bindings releases changed ports
  before starting replacements, including rollback.
- `DnsAdapter`/`Dns.Resolver`/`Dns.UdpHandler`: Abyss-owned UDP and TCP authoritative
  listeners; complete in-memory snapshots; SOA/NS/A and negative answers.
- `YellowDog.Worker.reload/0`, `status/0`, `check/0`, `submit_plan/1`: local control
  and the future internal Agent attachment point. No Agent is implemented/started.
- `examples/`, `README.md`, ExUnit tests and `test/release_smoke.py`: runnable
  bootstrap/plan, operator instructions, fault tests and real release acceptance.
- `docs/phase1/prepare-worker-validation.sh`, `worker-build.patch`: reproducible
  assembly and shared-owner integration handoff.

First boot reads the source only when no committed pointer exists. Later boots use
committed snapshots even with missing/invalid source or uncommitted running edits.
Only explicit reload reads source edits. Semantic no-ops retain snapshot identity,
file inode/mtime and service PID; runtime/disk inconsistencies remain repairable.
Lifecycle commands do not create memory-only desired-state overrides.

ConfigSpec's existing self-contained TOML format is used unchanged. Resource content
is embedded; references select resource IDs. C0 does **not** define external resource
file references. No alternate path-bearing TOML dialect was invented. If separate
resource files are required by the missing specification, the shared owner must
extend and pin that contract before either track implements it.

The adapter explicitly rejects unsupported configured record data/delegations.
It does not implement recursion, transfers, DNSSEC or unrelated network services.

## Exact commands and observed results

All Mix commands ran through the repository's devenv. Assembly preparation copied
only the required application sources and dependency checkout into `/tmp`; the
repository's shared files and lockfile were not edited.

```sh
docs/phase1/prepare-worker-validation.sh /tmp/yellow-dog-track-b-validation
devenv shell -- bash -c 'cd /tmp/yellow-dog-track-b-validation/apps/yellow_dog_worker && mix deps.get'
```

Both exited 0. TOML remained pinned at 0.7.0; no new package was introduced by Worker.

Final full Worker scope:

```sh
devenv shell -- bash -c 'cd /tmp/yellow-dog-track-b-validation/apps/yellow_dog_worker && mix test && MIX_ENV=test mix compile --warnings-as-errors && mix format --check-formatted'
```

**21 tests, 0 failures**, seed `170505`; compile and format exited 0. Covers:

- Real UDP/TCP authoritative and negative replies, loaded identities and live updates.
- Graceful/forced adapter death, actual listener closure and same-port recovery.
- Source-vs-snapshot precedence, stopped update/restart, explicit empty plans.
- Invalid first boot/reload, identity mismatch, bind failure and multi-service rollback.
- Live port exchanges and rollback after a later service fails to bind.
- Semantic no-op snapshot/PID preservation and missing-snapshot repair.
- Directory lock exclusion and kernel-lock release after staged-process termination.
- Injected disk-full/write, permission/rename, post-rename sync, and rollback failures.
- Durability uncertainty survives reads and failed preparation until a successful commit.
- Previous-snapshot fallback, corruption repair, source path/symlink and input bounds.

Fault injection is limited to deterministic filesystem error paths. It does not
replace any UDP/TCP or independent release restart scenario. Expected `killed`
process logs come from intentional crash tests and are not suite failures.

Shared C0 scope:

```sh
devenv shell -- bash -c 'cd /tmp/yellow-dog-track-b-validation/apps/yellow_dog_config_spec && mix test && mix format --check-formatted && mix compile --warnings-as-errors'
```

**15 tests, 0 failures**, seed `559928`; format and compile exited 0. This uses the
unchanged shared fixture set, including multiple zones, running/stopped, explicit
empty sets, malformed/unsupported input, duplicate IDs, missing refs, wrong digests,
semantic equivalence and input bounds.

Final production build and real release smoke:

```sh
devenv shell -- bash -c 'cd /tmp/yellow-dog-track-b-validation/apps/yellow_dog_worker && MIX_ENV=prod mix compile --warnings-as-errors && MIX_ENV=prod mix release yellow_dog_worker --overwrite'
python3 apps/yellow_dog_worker/test/release_smoke.py /tmp/yellow-dog-track-b-validation/_build/prod/rel/yellow_dog_worker/bin/yellow_dog_worker
```

Build exited 0. The first dependency compilation emitted existing TOML 0.7.0
charlist deprecation warnings; Worker warnings-as-errors compilation passed and
no dependency was patched. **RELEASE SMOKE PASSED**:

- Release library inspection rejects Management, Ecto/Postgrex, console, Store,
  Concord and legacy Agents. Management/database environment settings are removed.
- Both UDP and TCP answer complete SOA/NS/A data authoritatively; two zones loaded.
- Equivalent source formatting preserves all snapshot bytes/inodes/mtimes and PID.
- **644 actual UDP/TCP queries** during reload saw either the complete old or new
  A RRset; no partial RRset or query failure. The other zone remained correct.
- Invalid input preserved valid answers. SIGKILL followed by independent startup
  with the source removed recovered the committed content.
- A second OS release process using the same data directory failed explicitly.
- A stopped service had no UDP/TCP DNS listeners; Worker remained inspectable.
- SIGKILL/restart preserved stopped state despite a conflicting running source.
- Updating while stopped, restarting, and explicitly starting served the new content.

Final logs/state: `/tmp/yellow-dog-worker-smoke-jomolk4y`.
An earlier successful smoke observed 642 queries and is retained at
`/tmp/yellow-dog-worker-smoke-dx8o7wnm`. Both temporary Worker processes were stopped.
Existing unrelated host processes were preserved. Worker never configured or used
those host services. Physical power-loss, network partition simulation and hostile
same-UID filesystem races were not tested or claimed.

Early DNS test development found a compile-name conflict, then an ExUnit linked
process cleanup race; both were fixed. The final review found live-binding swap
rollback and durability-error clearing defects; both received regression tests and
passed the final suite and rebuilt release smoke. Earlier failures are not counted
as successful validation.

## Shared-file integration handoff

```sh
git apply --check docs/phase1/config-spec.patch
git apply --check docs/phase1/worker-build.patch
git diff --check
git diff --exit-code -- mix.exs mix.lock AGENTS.md config devenv.nix apps/abyss apps/ex_dns apps/yellow_dog_management docs/phase1/shared-baseline
```

All exited 0 at the inspected baseline. Only new Worker and Track B handoff/report
files are part of this work. No shared ConfigSpec, Management, protocol-library,
root build/config, devenv or top-level CI files were modified.
The Worker patch also passed `git apply --check` after applying Track A's build
patch in `/tmp/yellow-dog-shared-patch-check-drbo5iay`. Before committing, new files
were marked intent-to-add so `git diff` presented the complete reviewable change.

The shared owner must:

1. Adopt the existing `config-spec.patch`; Worker and Management use that one library.
2. Apply `worker-build.patch` alongside Track A's `management-build.patch`. The Worker
   patch adds its root release with isolated runtime config and its AGENTS table row.
   Worker needs no new lockfile entry.
3. Coordinate removal of legacy/mixed runtime release entries so the supported final
   deployment surface is exactly Management and Worker. This task preserves legacy
   sources still owned by the parallel effort; it adds no compatibility mode.
4. Wire final release/CI/devenv packaging as needed, including Linux flock/coreutils
   runtime availability, then test the integrated root build.
5. Run the file-only Management-export-to-Worker check with Management/PostgreSQL
   stopped. This task validated the shared fixtures and offline Worker independently;
   it did not run or change Track A's PostgreSQL/UI workflow.
6. Supply/review the missing Worker task specification and resolve any additional
   resource-file contract requirements through ConfigSpec ownership.

No umbrella-wide suite, unrelated protocol E2E, global Dialyzer, production changes,
legacy migration, live Management integration or Agent implementation was performed.
The internal complete-plan API is ready for later authenticated delivery; ownership,
observations and connected reconciliation remain Phase 2 work.
