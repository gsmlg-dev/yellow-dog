# Worker Management Implementation Plan

> **For agentic workers:** Implement the approved design with parallel backend/client ownership and coordinating UI/integration work. Review each deliverable before cross-product verification.

**Goal:** Name-only Worker registration, generated connection configuration, real authenticated connection and DNS control.

**Architecture:** Management adds a dedicated machine API and credential/status persistence. Worker adds an opt-in supervised client that submits confirmed complete plans through the existing ServiceManager and reports sanitized runtime observations.

**Tech Stack:** Elixir/OTP, Ecto/PostgreSQL, Phoenix LiveView, DuskMoon, Mint HTTP and OTP TLS, existing ConfigSpec and DNS execution.

## Global constraints

- Two independent business releases; no legacy Agents, Management network execution or credential fields in ConfigSpec.
- Only DNS is implemented. New Workers have no services until explicitly configured and published.
- Keep secrets out of audit/idempotency data, application status and logs; store hashes only.
- Preserve untracked supplied `docs/yellow-dog-codex-management-plan.md`.

### Task 1: Management enrollment and machine API

Files: `management/worker_connections.ex`, `management/worker_api.ex`, `management/schemas.ex`, `management/domain.ex`, `management_ui/router.ex`, a new PostgreSQL migration, and scoped `worker_connections_test.exs`.

Interface: `WorkerConnections.create(name)` returns `{:ok, %{"worker" => worker, "token" => token}}`; `rotate(worker_id)` returns the same shape. `bootstrap(worker, token, management_url)` returns managed TOML. `connection_fields(worker)` returns safe list/detail fields. POST `/api/worker/connect` authenticates Bearer token and accepts JSON report (`worker_id`, `capabilities`, `services`, `applied_revision`, `applied_digest`, `apply_error`). Returns `{"worker_id": id, "target": null | {"revision": integer, "digest": string, "plan": complete_plan}}`. Invalid token/identity returns 401; invalid report returns 422. Contact expiry is 45 seconds with 10-second default polling.

- [x] Add credential hash/contact/report fields and migrate with disposable PostgreSQL.
- [x] Test name validation, name-only creation, no secrets in normal/audit storage, token isolation/rotation, expired contact and validated reports.
- [x] Implement the API scoped entirely by the credential; targets come from `Domain.get_target(id)` and never drafts.
- [x] Run `devenv shell -- scripts/e2e/phase1_postgres.sh mix cmd --app yellow_dog_management mix test test/worker_connections_test.exs`.

### Task 2: Worker managed bootstrap and supervised connection

Files: `worker/bootstrap.ex`, `worker/application.ex`, `worker/service_manager.ex`, `worker/connection.ex`, `worker/connection_http.ex`, Worker Mix/config/readme and scoped connection tests.

Interface: managed bootstrap returns `worker_id`, `data_dir`, `source: nil`, and `connection: [management_url: url, token: token, ...TLS paths]`. Client sends the Task 1 report and validates identity, plan digest and monotonic target revision. It calls only `Worker.submit_plan/2`, reports safe strings/states rather than internal processes, and retries after failure. Managed initial boot has no local plan; restart restores committed state before reconnecting.

- [x] Test exact bootstrap modes, missing/invalid credentials, HTTPS and optional TLS files.
- [x] Implement HTTP timeouts, verified HTTPS, safe failure logging, polling and capability/state serialization.
- [x] Test real loopback HTTP exchange, target identity/digest/stale rejection, rotation rejection and continued runtime on disconnect.
- [x] Run `devenv shell -- mix cmd --app yellow_dog_worker mix test test/connection_test.exs test/bootstrap_test.exs test/service_manager_test.exs`.

### Task 3: Worker management UI and integration

Files: `management_ui/live/workers_live.ex`, `management_ui/live/worker_live.ex`, `management_ui/components/sidebar.ex`, scoped LiveView tests, Management README and cross-product smoke script.

- [x] Replace registration with name-only form and Worker table; show generated bootstrap once and allow explicit token rotation.
- [x] Display observed contact/service states and supported DNS capability; retain explicit preview/confirm publication and meaningful service configuration.
- [x] Replace obsolete ID/profile creation assertions; retain concurrent submission, profile edit and assignment tests.
- [x] Verify actual separate Worker process against disposable Management: connect, DNS socket start/stop, restart, offline snapshot and reconnect.
- [x] Run scoped tests, `mix compile --warnings-as-errors`, scoped `mix format --check-formatted`, `git diff --check`; report results without claiming deployment.

## Validation evidence

- Management scoped registration/connection/profile-edit/submission tests: 30 tests, 0 failures. Includes actual LiveView crash-log credential redaction.
- Worker scoped connection/bootstrap/ServiceManager tests: 29 tests, 0 failures. After limiting polling to 100..15000 ms, bootstrap tests passed again (3/0). Includes real private-CA/mTLS, oversized error body and HTTP 206 rejection checks.
- Fresh isolated production build and both independent releases: warnings-as-errors compile and assembly succeeded.
- Real Chromium name-only creation, generated configuration, clipboard hook, one-time token and dashboard: PASS. Browser focus/user gesture is required for the clipboard automation.
- Separate-release authenticated connection, real authoritative DNS UDP/TCP, actual stop, persisted stopped state, Management outage, offline Worker restart, reconnect, token reset and failed-target rollback: PASS. Evidence at `/tmp/yellow-dog-worker-connection-36d9sewc`; synthetic credential files removed during cleanup.
- Scope excludes other network service implementations and production deployment. Changes remain on `codex/worker-management`; supplied untracked Management plan is preserved.

### Executed checks

```sh
# Root; disposable PostgreSQL:
devenv shell -- scripts/e2e/phase1_postgres.sh mix do --app yellow_dog_management cmd mix test test/workers_connection_live_test.exs test/worker_profiles_live_test.exs test/worker_submission_live_test.exs test/worker_connections_test.exs
# Worker app directory:
devenv shell -- mix test test/connection_test.exs test/bootstrap_test.exs test/service_manager_test.exs
# Root; isolated output avoids replacing a running development release:
MIX_BUILD_PATH=/tmp/yellow-dog-worker-connection-build.g8dNAL devenv shell -- scripts/e2e/phase1_postgres.sh scripts/e2e/worker_connection_smoke.sh
MIX_BUILD_PATH=/tmp/yellow-dog-worker-connection-build.g8dNAL MIX_ENV=prod devenv shell -- mix compile --warnings-as-errors
```

Final changed Elixir files passed scoped `mix format --check-formatted` in both product directories. Both product directories passed `mix credo --strict` (Management: 293 source files; Worker: 25). Asset regeneration `devenv shell -- npm run assets.management`, Python/Bash syntax checks and `git diff --check` passed. No unrelated test suite was run.
