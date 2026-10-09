# Anonymous Worker initialization implementation plan

> **For agentic workers:** Use subagent-driven-development to implement these tasks.

**Goal:** Allow an operator to enable URL-only Worker initialization over VPN.

**Architecture:** Persist a default-off enrollment setting in PostgreSQL and use
the existing Bearer connection route to register new empty Workers. Worker creates
its durable private UUID/credential under the existing LocalStore lock before any
request. Retain the Management configuration / Worker execution boundary.

**Tech Stack:** Elixir/OTP, Ecto/PostgreSQL, Phoenix LiveView, NixOS/systemd.

## Global constraints

- Only Management/Worker enrollment, its tests, and deployment documentation change.
- Tokens are excluded from ordinary state, audit/idempotency parameters and logs.
- Existing IDs cannot be enrolled again with a different credential.
- HTTP VPN origins are allowed; HTTPS and optional client TLS files remain valid.
- Mix commands run in devenv; preserve the supplied untracked Management plan.

## Task 1: Management enrollment setting, connection gate and Workers UI

Files: Management schemas/Domain/WorkerConnections/WorkersLive, new enrollment
settings module and migration, worker_connections_test.exs and
workers_connection_live_test.exs.

- [ ] Add tests: new UUID rejected by default without rows; enabled empty report
  creates exactly one Worker/hash/audit/receipt; identical and concurrent retries
  reuse it; wrong and rotated credentials cannot replace it; persisted toggle
  survives LiveView reload and closing the toggle leaves registered Workers usable.
- [ ] Implement `Domain.worker_enrollment_settings/0` and idempotent command
  `set_worker_enrollment` with `%{"allow_anonymous" => boolean}`. Lock the singleton
  setting while admitting new IDs, recheck Worker identity, create with stable
  Domain receipt and save only token hash in the same transaction.
- [ ] Add Workers page checkbox form and refresh persisted state.
- [ ] Verify with `devenv shell -- scripts/e2e/phase1_postgres.sh mix cmd --app
  yellow_dog_management mix test test/worker_connections_test.exs
  test/workers_connection_live_test.exs`.

## Task 2: Worker URL-only bootstrap and durable installation credentials

Files: Worker Bootstrap/Application/LocalStore/ServiceManager/Connection, new
Credentials module and scoped credentials/bootstrap/connection tests.

- [ ] Test URL-only valid HTTP/HTTPS bootstrap and default persistent state path,
  paired optional ID/token validation, same credentials across restart, damaged
  state and wrong-origin rejection, sync/write failures, secret redaction.
- [ ] Add LocalStore-owned credential resolution delegating to Credentials.
  UUID/token and origin must be written privately, read back, atomically renamed
  and synchronized before any HTTP. Recover saved bytes instead of regenerating.
- [ ] Resolve the manager identity before snapshot restore; Connection obtains
  credentials through an internal manager call, never public status or child specs.
- [ ] Verify with `devenv shell -- mix cmd --app yellow_dog_worker mix test
  test/bootstrap_test.exs test/credentials_test.exs test/connection_test.exs
  test/service_manager_test.exs test/local_store_test.exs`.

## Task 3: Integration, Nix instructions and delivery

Files: scripts/e2e/worker_connection_smoke.py, docs/deployment/worker-nixos.md,
README.md, Worker anonymous bootstrap example.

- [ ] Exercise independent releases: URL-only bootstrap while enrollment disabled,
  enable setting, connect one Worker, configure/publish DNS, query UDP/TCP, restart
  without changing identity, close enrollment, stop/publish, preserve stopped state.
- [ ] Document VPN HTTP endpoint, default systemd state directory, automatic
  private credentials, optional TLS and token-reset recovery.
- [ ] Run `devenv shell -- mix compile --warnings-as-errors`, scoped format checks,
  and `devenv shell -- scripts/e2e/phase1_postgres.sh
  scripts/e2e/worker_connection_smoke.sh`.
- [ ] Review both ownership boundaries, commit and merge/push main after checks.
