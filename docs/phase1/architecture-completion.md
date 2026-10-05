# Phase 1 architecture split

## Subsequent UI source-only transfer

After this architecture verification, the user authorized migrating original UI
source directly into Management's compiled UI tree for later redesign; compilation
and runtime failure are acceptable. The new `ManagementUI.Redesign` sources are
not backend redevelopment or functional acceptance. Architecture verification
below applies to the earlier source state; it does not prove the later UI transfer
compiles or runs. No Worker service/Agent runtime is connected by the transfer.

## Accepted scope

The latest user instruction prioritizes finishing the architecture split and
temporarily defers existing bugs/service problems and the previous blockers.
The 2026-10-04 clarification limits this task to architecture restoration; Worker
runtime failures are acceptable. Management owns service configuration; network
services execute on Worker. Netboot and Identity are exclusively Worker-owned,
including provisioning and identity/trust authority. Their implementation and
full UI redevelopment are deferred, not architecture completion gates.
This report covers architecture/build/deployment boundaries, not full Phase 1
service/UI acceptance. Known failures are retained, not relabelled as passing.

Baseline and current HEAD: `d83442c0b12deb3173b9e96ca643061b070e6a58`, branch
`main`. The integrated implementation remains an uncommitted working-tree diff;
no final commit, publication, PR, production deployment or real DNS change is
claimed. Existing edits and supplied specifications are preserved.

## Delivered boundaries

| Boundary | Implementation and authoritative evidence |
| --- | --- |
| Two business products only | Root Mix enables Management, Worker, ConfigSpec, Abyss and ExDns, and exposes only the two business releases. The new architecture gate asserts both the selected app graph and release entry points. |
| Independent release configuration | Each product selects its own runtime configuration. Root development runtime configuration no longer uses unsupported runtime `import_config`. Management settings are validated when Management starts, not by Worker or the build. |
| Management ownership | PostgreSQL/Ecto configuration and UI/API without built-in login on port 4270; logical Workers and immutable complete target export. It has no Worker execution, Netboot/Identity authority, DNS/DHCP engine, legacy console/core/store, Agent or Concord/Mnesia release dependency. |
| Worker ownership | Network-service execution, including exclusive Netboot/Identity ownership; currently local bootstrap, TOML, LocalStore, one ServiceManager/Controller execution path and authoritative DNS. Its release has no Management/UI, Repo/Postgrex/Ecto, Agent or hidden database. Real file-gate execution occurs after Management/PostgreSQL stop. Other service implementations are deferred. |
| One pure shared contract | Both products use the actual umbrella ConfigSpec and shared fixtures. The gate verifies its runtime-free application specification and byte-identical packaged BEAM implementation. External-resource source-format work is deferred; the embedded C0 contract is unchanged. |
| Reproducible source build | A clean disposable `MIX_BUILD_PATH` builds both products from the actual repository root. No source subset is copied or pending patch applied. Historical handoff/assembly instructions are removed from current operator documentation. |
| Packaging | Supported Debian and Nix build definitions select one of the two products. Nix Worker supplies Linux locking/synchronization helpers. Nix packages require an operator-supplied `RELEASE_COOKIE` because their store path is immutable. |
| Independent CI | A dedicated architecture job builds and inspects release closures without starting business services or depending on service/UI jobs. The real file gate also invokes the same release-boundary check. |

New entry point: `devenv shell -- scripts/e2e/architecture_smoke.sh`.
The checker is `scripts/e2e/check_release_boundary.exs`. It inspects every
packaged application against the release manifest, rejects unexpected business
apps/dependencies and obsolete CLI packaging, and checks shared codec purity.
It also checks the packaged product application callback and permanent startup
mode, rejects misplaced Worker/Netboot/Identity execution modules in Management
and Management modules in Worker, and explicitly excludes legacy `:yellow_dog`.
`scripts/e2e/architecture_negative_smoke.py` exercises these guards with disposable
artifact mutations without starting either product or altering real releases.

## Architecture-only verification (2026-10-04)

Source audit confirms Management supervises its Repo, UI and local management
operations, not Worker network services. Worker supervises its local ServiceManager
and has no Management/PostgreSQL/UI dependency. Netboot and Identity are not yet
implemented in the supported Worker; their absence is accepted in this task.
No service adapter, database schema, credential implementation or UI workflow is
added by this architecture-only work. Existing working-tree changes are preserved.

Fresh verification uses disposable build output at
`/tmp/yellow-dog-architecture-20261004.8NL6Fi/build`. The initial clean production
compile with `--warnings-as-errors` and both release assemblies passed. After the
checker changes, the complete command passed again:

```sh
MIX_BUILD_PATH=/tmp/yellow-dog-architecture-20261004.8NL6Fi/build devenv shell -- scripts/e2e/architecture_smoke.sh
```

Both release closures and shared ConfigSpec equality pass. The positive artifact
fixture and four negative cases pass: legacy `:yellow_dog`, misplaced Netboot
execution module, incorrect product callback and non-permanent product startup.
Final log: `/tmp/yellow-dog-architecture-20261004.8NL6Fi/final-architecture.log`;
disposable negative evidence: `/tmp/yellow-dog-architecture-negative-7okhbqgc`.
Scoped `mix format --check-formatted scripts/e2e/check_release_boundary.exs`,
`bash -n scripts/e2e/architecture_smoke.sh` and `git diff --check` pass.
Neither business release, PostgreSQL, browser nor network service was started;
no Worker runtime health, full functional acceptance or remote CI pass is claimed.

## Historical executed local verification

The results below predate the 2026-10-04 scope clarification and subsequent UI
changes. Authenticated smoke descriptions refer to those historical artifacts,
not current no-login behavior. They are retained evidence, not newly executed checks.

All Mix/Python commands execute through `devenv shell --`. Disposable build path:
`/tmp/yellow-dog-architecture-build.Xaz2bl`. Logs share the prefix
`/tmp/yellow-dog-phase1-architecture-`.

| Command/check | Actual result and log suffix |
| --- | --- |
| `MIX_BUILD_PATH=/tmp/yellow-dog-architecture-build.Xaz2bl scripts/e2e/architecture_smoke.sh` | Clean production build and both release closures pass; `clean-build.log`. |
| `mix run --no-start scripts/e2e/check_release_boundary.exs /tmp/yellow-dog-architecture-build.Xaz2bl/rel` | Final boundary checker passes; `final-boundary.log`. |
| Artifact-only injected extra application | Checker rejects the disposable altered closure with exit 1 and the expected unmanifested-app error; regression command exits 0; `negative-check.log`. Original artifacts are unchanged. |
| `MIX_ENV=dev/test mix compile --force --warnings-as-errors` | Both strict root compiles pass; `final-unit-checks.log`. |
| ConfigSpec/Management scoped tests | 15/0 and 14/0 with fresh disposable PG; `contract-tests.log`. |
| Worker `mix test --seed 20260930` | 95 tests, 0 failures, **1 previously authorized skip**; `final-unit-checks.log`. No additional test skips. |
| `mix format --check-formatted`, scoped shell syntax, `git diff --check` | Pass. |
| `actionlint .github/workflows/phase1.yml` | Pass after fixing five shell-expression warnings in this scoped workflow. |
| `BUILD_RELEASE=0 scripts/e2e/release_smoke.sh yellow_dog_worker` | Fresh release passes real UDP/TCP, 1,026 reload queries, snapshot-only restart, locking and stopped intent; `worker-smoke.log`, evidence `/tmp/yellow-dog-worker-smoke-m2d_63g2`. |
| `BUILD_RELEASE=0 scripts/e2e/phase1_postgres.sh scripts/e2e/release_smoke.sh yellow_dog_management` | Fresh release passes PG migration, authenticated zero-Worker edits, independent concurrency, process restart and immutable exports; `management-smoke.log`. |
| `BUILD_RELEASE=0 scripts/e2e/file_gate.sh` with the same clean build path | Real authenticated two-zone export consumption with Management/PG offline passes; `file-gate.log`, evidence `/tmp/yellow-dog-file-gate-3lxqn6hg`. |
| Pinned-input Nix packages and both images | Build successfully; `nix-builds.log`. Uses unchanged `flake.lock` revisions and the full filtered working tree. |
| Same boundary checker against actual Nix package closures | Passes full transitive manifests and byte-identical ConfigSpec without starting services; `nix-boundary.log`. |
| Nix Management package with explicit runtime cookie | Full independent release smoke passes; `nix-management-cookie-smoke.log`. The first invocation without a cookie failed before startup; retained in `nix-management-smoke.log`. |
| Nix Worker and Management images | Both actual container tests pass dependency separation and independent startup. Worker consumes the new authentic export and answers real UDP/TCP SOA/NS/A; Management migrates fresh PG and creates/confirms data with zero Workers; `nix-worker-container.log`, `nix-management-container.log`. |
| Debian Management and Worker images | Both builds exit 0; `debian-builds.log`. Both actual container architecture tests pass, with the same authentic export/zero-Worker checks; `debian-worker-container.log`, `debian-management-container.log`. |
| Same boundary checker against copied Debian release artifacts | Full manifest, product separation and shared codec equality pass; `debian-boundary.log`. Only built artifacts were copied, not source assembly. |

Nix build command (no lock/input update or Git staging):

```sh
nix build --impure --no-link --print-out-paths --expr 'let outputs = (import /home/gao/Workspace/gsmlg-dev/yellow-dog/flake.nix).outputs { nixpkgs = { outPath = /nix/store/pfwrb65dsv8phlsf1m98bvz11cvgb290-source; }; flake-utils = builtins.getFlake "github:numtide/flake-utils/c1dfcf08411b08f6b8615f7d8971a2bfa81d5e8a"; }; in [ outputs.packages.x86_64-linux.yellow_dog_management outputs.packages.x86_64-linux.yellow_dog_worker outputs.packages.x86_64-linux.docker-worker outputs.packages.x86_64-linux.docker-management ]'
```

| Nix artifact | Immutable identity |
| --- | --- |
| Management package | `/nix/store/3ja17nfcnjlf1j6r8yycd2ad332zvc3p-yellow_dog_management-1.2.0` |
| Worker package | `/nix/store/p4wrmvfqbkhbwf4mw2clq0nxpgdfb44y-yellow_dog_worker-1.2.0` |
| Management image | `sha256:db4fd82d306708e757f6a5efd12a21e6292f048f0db29507dd79d3112c887e8c` |
| Worker image | `sha256:97ead03734e85b4f34208e9d02106e10266050b6614e4f7dd371f9bf7cf1db05` |

Debian builds use the supported Dockerfile, without publishing:

```sh
for product in management worker; do
  docker build --build-arg MIX_RELEASE_NAME=yellow_dog_${product} \
    --build-arg RELEASE_VERSION=1.2.0 \
    -t yellow-dog-phase1-${product}:architecture .
done
```

| Debian artifact | Immutable identity |
| --- | --- |
| Management image | `sha256:ad509fdfd42d790fe93242416892458ae4ec4630602e6077d5d186c228ed53d5` |
| Worker image | `sha256:a54cb993c7c68c6131e3a13c150b956f692632a183696cfeaf0b38f96e25c610` |

## Changes and completion audit

The current architecture slice adds the two gate/checker scripts, updates root
runtime configuration and formatter inputs, wires the independent Phase 1 CI
architecture/log-artifact job and file gate, and reconciles root/app/operator
documentation plus the two temporary-build helpers. Existing integrated
ConfigSpec, product models, supervision, release definitions, lockfile and
packaging changes remain preserved; no stale handoff is reapplied.

The explicitly prioritized **architecture deliverable is complete**: two
independent source-built releases, one shared pure contract, isolated runtime
entry points, independent CI, and both Debian/Nix product images have actual
artifact and standalone-process evidence. This is not full Phase 1 business/UI
or crash-recovery acceptance. The user-deferred failures below remain unresolved
and must be a separate future work item, not silently resumed or counted green.

All owned build/smoke/PG processes are terminal and temporary containers are
removed. Unrelated user BEAM processes and the three existing application
containers are preserved. Final root formatting, workflow lint, shell syntax and
`git diff --check` pass. User model configuration, UI JS, LocalStore and
ServiceManager hashes remain identical to the pre-split-priority handoff.

## Deferred, not passing

- Real interrupted-first-boot journal recovery: explicit reload returns
  `{:error, :transition_pending}`. Journal task counters remain Sol 6/Astra 0;
  no seventh repair round was dispatched.
- Chromium `New Zone editor did not reset`; UI repair remains stopped.
- Corruption fallback revision-only fixture: its existing skip/body/assertions
  are retained; this is not an acceptance pass.
- External resource-file/allowed-root source-format extension: not implemented
  or silently folded into a competing shared dialect.
- Additional minimal-PATH Nix Worker smoke passed initial UDP/TCP, no-write reload
  and 1,504 reload queries, but timed out querying DNS after SIGKILL/restart at
  `release_smoke.py:209`. Full smoke exited 1; `nix-worker-smoke.log` and
  `/tmp/yellow-dog-worker-smoke-49h5zts3` preserve it. No service fix or assertion
  weakening follows that failure. Its independent container architecture gate
  passed, but does not waive this recovery failure.
- Remote CI, arm64 execution, Credo/Dialyzer, live Management Agent integration,
  legacy data migration and production deployment were not run/implemented.

Architecture evidence does not imply full Phase 1 business/service acceptance.
