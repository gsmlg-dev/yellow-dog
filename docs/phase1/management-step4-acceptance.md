# Step 3 repairs and Step 4 integration acceptance

Verified on 2026-10-23 in `/home/gao/Workspace/gsmlg-dev/yellow-dog`.
Verification ran on `codex/step3-repairs-step4-integration`, with baseline HEAD
`67a1135e50d9a060f050a5183afbc2c917144b3c` and implementation changes in the
working tree. Commit and push were separately authorized after verification.
The six supplied untracked planning documents were preserved intact and unstaged.

## Delivered scope

Step 3 repairs were completed before Step 4 integration. Their independent patch,
new files and manifest are preserved under
`/tmp/yellow-dog-step3-step4/step3-checkpoint/`. The
[Data workflow evidence](management-data-workflow.md#step-3-review-repairs-and-acceptance-2026-10-23)
records the availability recovery, bounded Zone route, CI guard coverage and
complete browser migration. Final combined-source acceptance below supersedes
that checkpoint's packaging snapshot.

Step 4 provides 42 finite operations under `/api/v1` and corresponding MCP tools,
the checked OpenAPI 3.1.2 document, and `/system/integrations`. The
[operation matrix](management-api-contract.md), [MCP guide](management-mcp.md), and
[security guide](management-integration-security.md) document inputs, projections,
permissions, concurrency, durable logical requests, exact publication and setup.
MCP is deliberately pinned to **2025-11-25**, tested with official SDK **1.32.1**;
the selected SDK does not implement the newer lifecycle. OpenAPI validation uses
Redocly **2.69.0**; runtime JSON Schema validation uses JSV **0.26.1**, and JWT
verification uses JOSE **1.11.12**.

The main changes are Management authentication/policy and shared application
modules, HTTP/MCP adapters, UI command/session/socket integration, sanitized audit
context, contract/client tests and fixtures, documentation, CI, and dependency
locks/Nix input hash. Migration
`20261023000000_add_management_audit_context.exs` adds only the non-null audit
`context` JSONB map. No Worker/ConfigSpec business source was changed, and the two
existing products retain their dependency boundaries and Gaoxy transport.

Adapters default to disabled. Trusted-local requires explicit direct loopback
operation. Protected-remote uses an external OAuth issuer and public JWKS files,
plus a separate signed UI gateway assertion. Public keys are distributed out of
band; bounded token lifetimes and revocation limits are documented. There is no
local identity provider or account database. The remote operation matrix excludes
credentials, enrollment policy, backups, Netman, arbitrary tasks/files and runtime
actions; existing UI administration is separately authorized.

Final regression repairs preserve rich existing View fallback endpoints, including
IPv6, without extending DNS service listeners, A records or WorkerPlan. UI canonical
commands retain Domain validation receipts and editor lifetimes while sharing
authorization, key namespaces, transactions and validated outcomes with the remote
adapters. Wrong ownership, original expected revisions, immutable versions, full
assignment replacement, stale previews, postcommit read failure and lost-response
retry remain covered. Views, ACLs and IP artifacts remain excluded from targets;
Management writes do not establish Worker execution.

## Executed gates

Commands below ran from the repository root inside `devenv shell --`.
`BUILD_RELEASE=0` acceptance used the releases freshly rebuilt by the architecture
gate. Every PostgreSQL wrapper used its own disposable database. Logs are under
`/tmp/yellow-dog-step3-step4/` unless an absolute path is shown.

| Gate | Command / result | Evidence |
| --- | --- | --- |
| Management regressions | `scripts/e2e/phase1_postgres.sh mix do --app yellow_dog_management test` — **609 tests, 0 failures** | `step4-management-final609.log` |
| Authorization additions | Scoped `test/integration_security_test.exs` — **14 tests, 0 failures**; issued Worker credentials fail API/MCP, Management JWTs fail WorkerAPI, ten same-key sync attempts create one job/receipt/audit and a subsequent cross-adapter attempt is limited | `step4-security-final2.log` |
| Existing JavaScript suites | `node --test apps/yellow_dog_management/test/management_ui_test.mjs apps/yellow_dog_management/test/editor_guard_test.mjs` — **30 passed** | `step4-js-final.log` |
| Assets | `npm run assets.management` — passed | `step4-assets-final.log` |
| Source checks | Explicit changed-file `mix format --check-formatted`, `MIX_ENV=test mix compile --warnings-as-errors`, JavaScript/shell syntax, `git diff --check` — passed; 71 changed Elixir files | `step4-source-checks-final.log` |
| OpenAPI | `env MIX_ENV=test scripts/e2e/management_openapi.sh --check` — real specification validation and generated-artifact equality passed | `/tmp/yellow-dog-step4-ci-openapi-check.log` |
| Official SDK / OAuth / UI / restart | `env BUILD_RELEASE=0 scripts/e2e/phase1_postgres.sh scripts/e2e/management_integration.sh` — all stages passed | `step4-sdk-final-rebuilt.log`; artifacts `/tmp/yellow-dog-management-integration.x6eB9F` |
| Complete Chromium flow | `env BUILD_RELEASE=0 scripts/e2e/phase1_postgres.sh scripts/e2e/management_browser.sh` — complete maintained flow passed | `step4-browser-full-final.log`; browser `2FpDNb` |
| Navigation Chromium | Same wrapper with `MANAGEMENT_BROWSER_SCOPE=navigation` — passed, including the real integration-page deep link | `step4-browser-navigation-final.log`; browser `qzBtOY` |
| Nodes Chromium / restart | Same wrapper with `MANAGEMENT_BROWSER_SCOPE=nodes` — both stages passed | `step4-browser-nodes-final.log`; browser `4AQSEs` |
| Data Chromium / restart | Same wrapper with `MANAGEMENT_BROWSER_SCOPE=data` — both stages passed | `step4-browser-data-final.log`; browser `iPcoRC` |
| Architecture | `scripts/e2e/architecture_smoke.sh` — strict production compile, two isolated releases and **35 rejected boundary mutations** passed | `step4-architecture-final.log` |
| Offline export | `env BUILD_RELEASE=0 scripts/e2e/file_gate.sh` — real UDP/TCP DNS, PostgreSQL/Management offline, snapshot/lifecycle recovery passed | `step4-offline-export-final.log`; `/tmp/yellow-dog-file-gate-opcjhlep` |
| Release smoke | `env BUILD_RELEASE=0 scripts/e2e/phase1_postgres.sh scripts/e2e/release_smoke.sh yellow_dog_management` and `env BUILD_RELEASE=0 scripts/e2e/release_smoke.sh yellow_dog_worker` — both passed | `step4-release-management-final.log`, `step4-release-worker-final.log` |
| Nix x86 packages/images | Both packages and both images built with strict hashes; packaged release boundaries inspected successfully | `step4-nix-x86-build.log`, `step4-nix-x86-results.json`, `step4-nix-boundary.log` |
| Nix package runtime | The actual built Management and Worker binaries passed their complete existing release smokes, including process restarts | `step4-nix-management-smoke-final.log`, `step4-nix-worker-smoke.log` |
| CI wiring | Existing Management and both JS suites retained; new OpenAPI and official SDK job added; actionlint 1.7.7 and shell syntax passed | `.github/workflows/phase1.yml` |

The SDK flow uses actual OAuth discovery, token acquisition and the selected MCP
lifecycle. It registers two logical Workers/DNS services and a Zone through UI,
edits via HTTP, confirms/assigns/publishes via MCP, then checks the same canonical
objects and exact immutable export in UI/HTTP. Stale writes/publication reject;
a discarded response retried through a fresh SDK connection and HTTP creates
exactly one receipt/audit. Read-only replay is denied. Successful fixture IP sync
and failed replacement preserve the correct selected artifact. Fresh clients after
Management restart recover the same draft, assignments, version, target, export,
artifact, audit and receipt. No real Worker is required for that control-plane flow.

The optional Node screenshot-specific assertions were not enabled; the navigation
and full browser flows exercised responsive/mobile navigation. Browser artifact
names above expand beneath `/tmp/yellow-dog-management-browser.<name>`.
Fixture signing credentials were removed, and wrappers stopped their owned
Management/PostgreSQL/issuer/source processes. Existing development processes
were left running.

## Nix inputs and artifacts

A forced rebuild of the old fixed-output dependency derivation exposed the new
hash after the Step 4 dependencies were added. `default.nix` now uses
`sha256-FVYGe6e6XbnTGwd5nscfpguflwlIgnr/58VnWSl8YlU=`.
The strict final package builds verified that hash; integrity checking remains
enabled. The earlier Step 3 hash remains documented only as historical evidence.

The clean source snapshot is
`/tmp/yellow-dog-step3-step4/nix-step4-final-source`, with a SHA-256 manifest in
`nix-step4-final-manifest.json`. It includes new source files without staging the
supplied plans. A final comparison confirmed **1014 runtime/build source files**
match that snapshot. Subsequent changes were limited to regression tests and
documentation.

```sh
nix build -L --no-link --json --max-jobs 2 --cores 2 \
  path:/tmp/yellow-dog-step3-step4/nix-step4-final-source#packages.x86_64-linux.yellow_dog_management \
  path:/tmp/yellow-dog-step3-step4/nix-step4-final-source#packages.x86_64-linux.yellow_dog_worker \
  path:/tmp/yellow-dog-step3-step4/nix-step4-final-source#packages.x86_64-linux.docker-management \
  path:/tmp/yellow-dog-step3-step4/nix-step4-final-source#packages.x86_64-linux.docker-worker
```

| Product | Package | Image SHA-256 |
| --- | --- | --- |
| Management | `/nix/store/0fny0ccwid3dwykg7f4qxsszwx3527zb-yellow_dog_management-1.2.12` | `66060b49cab0361e05e29249b8d50d8d67699c0609270f2b1996fd2c043ef366` |
| Worker | `/nix/store/vm0l50x1pplp3339z0ydljgf6xmjmpl5-yellow_dog_worker-1.2.12` | `5447e91a9a77290813037da492b08b3b4459db9f27caf154d6b461d6f31cdccf` |

Image paths and inspected architecture/entrypoints are in `step4-nix-images.json`:
both are Linux/amd64, with their corresponding `/bin/yellow_dog_*` entrypoints.
The Management image is
`/nix/store/v8yjp0jia3bxw73q0rh2qbij6kqb24lv-yellow_dog_management.tar.gz`;
Worker is `/nix/store/kqamw5hc0vpnsnblb0p81m7sx4llx69w-yellow_dog_worker.tar.gz`.
No container engine execution is claimed. Both actual Nix package binaries were
executed successfully. Nix's immutable store requires an operator-provided
`RELEASE_COOKIE`, even with distribution disabled. The first Management package
smoke omitted that existing setting and stopped before boot; the final passing
run supplied a disposable cookie without logging it.

## Explicitly unverified

The same four attributes under `packages.aarch64-linux` were attempted against
the final snapshot. They stopped on platform mismatch: required `aarch64-linux`,
current `x86_64-linux`, with no configured native builder. See
`step4-nix-arm-final.log`. The ARM native input checksum was independently checked
during Step 3; it does not establish an ARM build or runtime. Both architectures
remain enabled in CI. No host-key bypass or architecture/hash relaxation was used.

GitHub Actions was wired and locally validated; remote execution had not been
observed at verification time. A production identity provider/gateway, named desktop MCP
clients, ARM execution and real target-host deployment remain unverified. These
limits do not change the exercised local SDK protocol/authentication evidence or
the configured-only status of Views, ACLs and IP artifacts.
