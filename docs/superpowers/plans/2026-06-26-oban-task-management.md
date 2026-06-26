# Oban Task Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the PRD MVP for Oban-backed YellowDog data synchronization tasks: SQLite-backed Oban, scheduled/manual sync workers, task status APIs, and a console task-management page.

**Architecture:** Add a new umbrella app, `yellow_dog_tasks`, that owns the Ecto repo, Oban supervision, task config mapping, worker modules, region-data store, and status/enqueue APIs. Keep console UI in `yellow_dog_console`, but make it enqueue jobs through `YellowDog.Tasks` instead of running download work in LiveView processes. Add small test seams to existing GeoIP and OUI download modules so worker tests can prove atomic failure behavior without external HTTP.

**Tech Stack:** Elixir umbrella, Oban OSS 2.23, Ecto SQL, Ecto SQLite3, Phoenix LiveView, ExUnit, YellowDog TOML config, DuskMoon/PhoenixDuskmoon UI components.

## Global Constraints

- Work in `/home/gao/Workspace/gsmlg-dev/yellow-dog/.trees/codex-oban-task-management` on branch `codex/oban-task-management`.
- PRD source is `/home/gao/Workspace/gsmlg-dev/yellow-dog/docs/prd/oban.md`; do not require that untracked file to be committed.
- Use SQLite by default with database path `${YELLOW_DOG_DATA_DIR}/tasks/yellow_dog_tasks.db`.
- Add dependencies `{:oban, "~> 2.23"}`, `{:ecto_sql, "~> 3.12"}`, and `{:ecto_sqlite3, "~> 0.21"}` to `apps/yellow_dog_tasks/mix.exs`.
- Oban config must use `engine: Oban.Engines.Lite`, `repo: YellowDog.Tasks.Repo`, and `queues: [data_sync: 1]`.
- Test config must use Oban manual testing mode.
- Cron timezone default is `"Etc/UTC"`.
- Default schedules: region `0 2 * * SUN`, IP country `0 3 2 * *`, IP city `30 3 2 * *`, MAC `0 4 * * SUN`.
- If `[tasks] enabled = false`, scheduled execution is disabled and manual enqueue remains available.
- Only known task keys are allowed: `:region`, `:ip_country`, `:ip_city`, `:mac`.
- Job args are JSON; worker `perform/1` must pattern match string keys such as `%{"type" => "city"}`.
- Do not catch and swallow worker errors; return `{:error, reason}` or raise so Oban can retry.
- Preserve the previously working dataset when a sync fails.
- Do not use Oban Pro.
- Do not add arbitrary user-defined task execution.
- Do not use `:gen_udp`.
- Do not override DuskMoon design tokens or patch PhoenixDuskmoon internals.
- Use `devenv shell -- ...` for Mix commands.
- Run scoped tests as tasks are completed; stop if in-scope tests fail repeatedly.

---

## File Structure

- Create `apps/yellow_dog_tasks/`: new umbrella OTP app that owns task repo, Oban, workers, status/query APIs, region data, migration, and tests.
- Modify `mix.exs`: include `:yellow_dog_tasks` in `yellow_dog_server` and `yellow_dog` releases, not `yellow_dog_netman`.
- Modify `config/config.exs`, `config/runtime.exs`, `config/test.exs`: wire task repo and Oban config, default SQLite path, and test mode.
- Modify `apps/yellow_dog_config/lib/yellow_dog/config/schema.ex` and default TOML files: add `[tasks]` defaults and validation.
- Modify `apps/geo_ip_db/lib/geo_ip_db/download.ex` and `apps/yellow_dog_fingerprint/lib/yellow_dog/fingerprint/oui_database.ex`: add small injectable download seams and atomic write support for deterministic worker tests.
- Modify `apps/yellow_dog_console/`: add task UI routes/sidebar/LiveViews and change IP/MAC manual downloads to enqueue jobs.
- Modify `Dockerfile`: include `apps/yellow_dog_tasks/mix.exs` in dependency-manifest copy list.
- Modify `default.nix`: refresh `mixFodDeps.hash` after dependency changes if `nix build` reports a new hash.

---

### Task 1: Oban Foundation App

**Files:**
- Create: `apps/yellow_dog_tasks/mix.exs`
- Create: `apps/yellow_dog_tasks/lib/yellow_dog/tasks.ex`
- Create: `apps/yellow_dog_tasks/lib/yellow_dog/tasks/application.ex`
- Create: `apps/yellow_dog_tasks/lib/yellow_dog/tasks/repo.ex`
- Create: `apps/yellow_dog_tasks/lib/yellow_dog/tasks/config.ex`
- Create: `apps/yellow_dog_tasks/lib/yellow_dog/tasks/migrator.ex`
- Create: `apps/yellow_dog_tasks/priv/repo/migrations/20260626000000_add_oban_jobs.exs`
- Create: `apps/yellow_dog_tasks/test/test_helper.exs`
- Create: `apps/yellow_dog_tasks/test/support/repo_case.ex`
- Create: `apps/yellow_dog_tasks/test/yellow_dog/tasks/config_test.exs`
- Modify: `mix.exs`
- Modify: `config/config.exs`
- Modify: `config/runtime.exs`
- Modify: `config/test.exs`
- Modify: `Dockerfile`

**Interfaces:**
- Produces: `YellowDog.Tasks.Config.load/0 :: YellowDog.Tasks.Config.t()`
- Produces: `YellowDog.Tasks.Config.oban_config/1 :: keyword()`
- Produces: `YellowDog.Tasks.Config.database_path/1 :: Path.t()`
- Produces: `YellowDog.Tasks.Repo`
- Produces: `YellowDog.Tasks.Migrator.migrate/0 :: :ok`

- [ ] **Step 1: Write failing config and repo tests**

Create `apps/yellow_dog_tasks/test/test_helper.exs`:

```elixir
ExUnit.start()
```

Create `apps/yellow_dog_tasks/test/yellow_dog/tasks/config_test.exs`:

```elixir
defmodule YellowDog.Tasks.ConfigTest do
  use ExUnit.Case, async: false

  alias YellowDog.Tasks.Config

  setup do
    previous_yellow_dog_data_dir = Application.get_env(:yellow_dog, :data_dir)

    on_exit(fn ->
      if previous_yellow_dog_data_dir do
        Application.put_env(:yellow_dog, :data_dir, previous_yellow_dog_data_dir)
      else
        Application.delete_env(:yellow_dog, :data_dir)
      end
    end)

    :ok
  end

  test "uses a SQLite database under the YellowDog data dir by default" do
    data_dir = Path.join(System.tmp_dir!(), "yellow_dog_tasks_config_test")
    Application.put_env(:yellow_dog, :data_dir, data_dir)

    config = Config.load()

    assert config.enabled?
    assert config.timezone == "Etc/UTC"
    assert Config.database_path(config) == Path.join([data_dir, "tasks", "yellow_dog_tasks.db"])
  end

  test "builds Oban config with Lite engine and one data_sync worker" do
    config = Config.load()
    oban_config = Config.oban_config(config)

    assert oban_config[:engine] == Oban.Engines.Lite
    assert oban_config[:repo] == YellowDog.Tasks.Repo
    assert oban_config[:queues] == [data_sync: 1]
  end

  test "omits cron plugin when tasks scheduling is disabled" do
    Application.put_env(:yellow_dog_tasks, :tasks_config, %{"enabled" => false})

    config = Config.load()

    refute config.enabled?
    refute Enum.any?(Config.oban_config(config)[:plugins], &match?({Oban.Plugins.Cron, _}, &1))
  after
    Application.delete_env(:yellow_dog_tasks, :tasks_config)
  end

  test "rejects invalid cron expressions with a clear error" do
    Application.put_env(:yellow_dog_tasks, :tasks_config, %{
      "sync" => %{"ip_city" => %{"cron" => "60 * * * *"}}
    })

    assert_raise ArgumentError, ~r/tasks.sync.ip_city.cron/, fn ->
      Config.load()
    end
  after
    Application.delete_env(:yellow_dog_tasks, :tasks_config)
  end
end
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
devenv shell -- mix cmd --app yellow_dog_tasks mix test test/yellow_dog/tasks/config_test.exs
```

Expected: fails because `yellow_dog_tasks` app and `YellowDog.Tasks.Config` do not exist.

- [ ] **Step 3: Add the new OTP app and Oban foundation**

Implement the app with these exact module responsibilities:

```elixir
defmodule YellowDog.Tasks.Repo do
  use Ecto.Repo,
    otp_app: :yellow_dog_tasks,
    adapter: Ecto.Adapters.SQLite3
end
```

```elixir
defmodule YellowDog.Tasks.Repo.Migrations.AddObanJobs do
  use Ecto.Migration

  def up do
    Oban.Migration.up(version: 14)
  end

  def down do
    Oban.Migration.down(version: 1)
  end
end
```

`YellowDog.Tasks.Application` must start `YellowDog.Tasks.Repo`, run `YellowDog.Tasks.Migrator.migrate/0`, then start `{Oban, Application.fetch_env!(:yellow_dog_tasks, Oban)}`.

`YellowDog.Tasks.Config.load/0` must merge defaults with `Application.get_env(:yellow_dog_tasks, :tasks_config, %{})`, validate cron expressions with `Oban.Plugins.Cron.parse/1`, and build static cron plugin config only for enabled schedules.

- [ ] **Step 4: Wire umbrella, release, runtime, and Docker manifests**

Add `:yellow_dog_tasks` to the `yellow_dog_server` and `yellow_dog` releases in root `mix.exs`.

Add runtime repo database config:

```elixir
task_db_path =
  YellowDog.Tasks.Config.load()
  |> YellowDog.Tasks.Config.database_path()

config :yellow_dog_tasks, YellowDog.Tasks.Repo,
  database: task_db_path,
  pool_size: 5
```

Add test config:

```elixir
config :yellow_dog_tasks,
  ecto_repos: [YellowDog.Tasks.Repo]

config :yellow_dog_tasks, YellowDog.Tasks.Repo,
  database: Path.expand("../tmp/yellow_dog_tasks_test.db", __DIR__),
  pool_size: 1

config :yellow_dog_tasks, Oban, testing: :manual
```

- [ ] **Step 5: Fetch deps and run scoped foundation tests**

Run:

```bash
devenv shell -- mix deps.get
devenv shell -- mix cmd --app yellow_dog_tasks mix test test/yellow_dog/tasks/config_test.exs
devenv shell -- mix compile --warnings-as-errors
```

Expected: tests pass and compile exits 0.

---

### Task 2: Task Config In YellowDog TOML Schema

**Files:**
- Modify: `apps/yellow_dog_config/lib/yellow_dog/config/schema.ex`
- Modify: `apps/yellow_dog_config/test/yellow_dog/config/schema_test.exs`
- Modify: `apps/yellow_dog/priv/yellowdogdns_default_config.toml`
- Modify: `priv/yellowdogdns_default_config.toml`

**Interfaces:**
- Produces TOML defaults under `"tasks"` with scheduler and sync task config.
- Produces schema validation for tasks booleans, cron expressions, max attempts, timezone, and database path type.

- [ ] **Step 1: Write failing schema tests**

Add tests asserting:

```elixir
defaults = YellowDog.Config.Schema.defaults()
assert defaults["tasks"]["enabled"] == true
assert defaults["tasks"]["timezone"] == "Etc/UTC"
assert defaults["tasks"]["database_path"] == "tasks/yellow_dog_tasks.db"
assert defaults["tasks"]["sync"]["ip_city"]["cron"] == "30 3 2 * *"
```

Add invalid tests:

```elixir
assert {:error, errors} =
         YellowDog.Config.Schema.validate(%{
           "tasks" => %{"enabled" => "yes", "sync" => %{"mac" => %{"max_attempts" => 0}}}
         })

assert {"tasks.enabled", _} = Enum.find(errors, &(elem(&1, 0) == "tasks.enabled"))
assert {"tasks.sync.mac.max_attempts", _} =
         Enum.find(errors, &(elem(&1, 0) == "tasks.sync.mac.max_attempts"))
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
devenv shell -- mix cmd --app yellow_dog_config mix test test/yellow_dog/config/schema_test.exs
```

Expected: fails because tasks defaults/validation do not exist.

- [ ] **Step 3: Add schema defaults and validation**

Add `"tasks"` to `defaults/0`, `minimal/0`, `section_comments/0`, and validation helpers. Validation must call `Oban.Plugins.Cron.parse/1` only from `yellow_dog_tasks` if introducing a dependency is acceptable; otherwise put cron validation in `YellowDog.Tasks.Config` and validate only type/shape in `yellow_dog_config` to avoid a dependency cycle. Prefer no new dependency in `yellow_dog_config`.

- [ ] **Step 4: Add TOML defaults**

Add this section to both default TOML files:

```toml
[tasks]
enabled = true
timezone = "Etc/UTC"
database_path = "tasks/yellow_dog_tasks.db"

[tasks.sync.region]
enabled = true
cron = "0 2 * * SUN"
max_attempts = 3

[tasks.sync.ip_country]
enabled = true
cron = "0 3 2 * *"
max_attempts = 3

[tasks.sync.ip_city]
enabled = true
cron = "30 3 2 * *"
max_attempts = 3

[tasks.sync.mac]
enabled = true
cron = "0 4 * * SUN"
max_attempts = 3
```

- [ ] **Step 5: Run scoped config tests**

Run:

```bash
devenv shell -- mix cmd --app yellow_dog_config mix test test/yellow_dog/config/schema_test.exs
```

Expected: tests pass.

---

### Task 3: Download Seams And Atomic File Safety

**Files:**
- Modify: `apps/geo_ip_db/lib/geo_ip_db/download.ex`
- Modify: `apps/geo_ip_db/test/geo_ip_db/download_test.exs`
- Modify: `apps/yellow_dog_fingerprint/lib/yellow_dog/fingerprint/oui_database.ex`
- Create: `apps/yellow_dog_fingerprint/test/yellow_dog/fingerprint/oui_database_test.exs`
- Create: `apps/yellow_dog_tasks/lib/yellow_dog/tasks/atomic_file.ex`
- Create: `apps/yellow_dog_tasks/test/yellow_dog/tasks/atomic_file_test.exs`

**Interfaces:**
- Produces: `GeoIpDb.Download.download/2` option `:fetcher`, a unary function returning an HTTP-like response.
- Produces: `YellowDog.Fingerprint.OuiDatabase.download/1` option `:fetcher`.
- Produces: `YellowDog.Tasks.AtomicFile.replace/3 :: {:ok, Path.t()} | {:error, term()}`.

- [ ] **Step 1: Write failing atomic-file tests**

Create tests that call `YellowDog.Tasks.AtomicFile.replace(path, contents, validator)` and assert:

```elixir
assert {:ok, ^path} = AtomicFile.replace(path, "new", fn tmp_path -> File.read(tmp_path) end)
assert File.read!(path) == "new"
```

and:

```elixir
File.write!(path, "old")
assert {:error, :invalid} = AtomicFile.replace(path, "bad", fn _tmp_path -> {:error, :invalid} end)
assert File.read!(path) == "old"
```

- [ ] **Step 2: Write failing download seam tests**

For GeoIP, assert a fake fetcher is used without network:

```elixir
fetcher = fn _url -> %HTTP.Response{ok: true, body: :zlib.gzip("not-mmdb")} end
assert {:ok, path} = GeoIpDb.Download.download(:city, target_dir: tmp_dir, fetcher: fetcher)
assert File.exists?(path)
```

For OUI, start the GenServer in a temp dir and assert fake download data can be written and loaded:

```elixir
fetcher = fn _url -> %{ok: true, body: "00:00:0A\tTEST\tTest Vendor\n"} end
start_supervised!({YellowDog.Fingerprint.OuiDatabase, data_dir: tmp_dir})
assert {:ok, path} = YellowDog.Fingerprint.OuiDatabase.download(fetcher: fetcher)
assert File.exists?(path)
assert {:ok, "TEST", "Test Vendor"} = YellowDog.Fingerprint.OuiDatabase.lookup("00:00:0A:00:00:01")
```

- [ ] **Step 3: Run tests and verify failure**

Run:

```bash
devenv shell -- mix cmd --app yellow_dog_tasks mix test test/yellow_dog/tasks/atomic_file_test.exs
devenv shell -- mix cmd --app geo_ip_db mix test test/geo_ip_db/download_test.exs
devenv shell -- mix cmd --app yellow_dog_fingerprint mix test test/yellow_dog/fingerprint/oui_database_test.exs
```

Expected: fail because seams and atomic helper do not exist.

- [ ] **Step 4: Implement seams and atomic helper**

Keep changes small:

- `GeoIpDb.Download.download/2` reads `fetcher = Keyword.get(opts, :fetcher, &default_fetch/1)`.
- `OuiDatabase.download/1` sends options through the GenServer call and uses `fetcher` in `do_download/2`.
- Use `AtomicFile.replace/3` for OUI writes before loading the new file.

- [ ] **Step 5: Run scoped tests**

Run the same three scoped test commands. Expected: pass.

---

### Task 4: Region Data MVP

**Files:**
- Create: `apps/yellow_dog_tasks/lib/yellow_dog/tasks/region_data/provider.ex`
- Create: `apps/yellow_dog_tasks/lib/yellow_dog/tasks/region_data/countries_provider.ex`
- Create: `apps/yellow_dog_tasks/lib/yellow_dog/tasks/region_data/store.ex`
- Create: `apps/yellow_dog_tasks/test/yellow_dog/tasks/region_data/store_test.exs`

**Interfaces:**
- Produces: `YellowDog.Tasks.RegionData.Provider` behavior.
- Produces: `YellowDog.Tasks.RegionData.Store.sync/1 :: {:ok, map()} | {:error, term()}`.
- Produces: `YellowDog.Tasks.RegionData.Store.info/1 :: map()`.
- Produces: `YellowDog.Tasks.RegionData.Store.list_countries/1 :: [map()]`.
- Produces: `YellowDog.Tasks.RegionData.Store.list_regions/2 :: [map()]`.
- Produces: `YellowDog.Tasks.RegionData.Store.lookup/3 :: {:ok, map()} | :error`.

- [ ] **Step 1: Write failing region store tests**

Use a temp data dir and the default countries provider:

```elixir
assert {:ok, info} = Store.sync(data_dir: tmp_dir)
assert info.source == "geo-ip-countries"
assert info.record_count > 0
assert File.exists?(Path.join([tmp_dir, "region", "regions.json"]))
assert File.exists?(Path.join([tmp_dir, "region", "metadata.json"]))

countries = Store.list_countries(data_dir: tmp_dir)
assert Enum.any?(countries, &(&1["code"] == "US"))
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
devenv shell -- mix cmd --app yellow_dog_tasks mix test test/yellow_dog/tasks/region_data/store_test.exs
```

Expected: fails because modules do not exist.

- [ ] **Step 3: Implement default provider and JSON store**

Use `GeoIpDb.Countries.list/0` as the MVP source because the PRD leaves the authoritative upstream source open. Persist countries with empty `"regions"` lists so the data model supports subdivisions without inventing an unapproved source.

- [ ] **Step 4: Run scoped region tests**

Run:

```bash
devenv shell -- mix cmd --app yellow_dog_tasks mix test test/yellow_dog/tasks/region_data/store_test.exs
```

Expected: pass.

---

### Task 5: Workers, Enqueue API, Status API, And Telemetry

**Files:**
- Create: `apps/yellow_dog_tasks/lib/yellow_dog/tasks/data_sync.ex`
- Create: `apps/yellow_dog_tasks/lib/yellow_dog/tasks/task_status.ex`
- Create: `apps/yellow_dog_tasks/lib/yellow_dog/tasks/workers/sync_ip_database_worker.ex`
- Create: `apps/yellow_dog_tasks/lib/yellow_dog/tasks/workers/sync_mac_database_worker.ex`
- Create: `apps/yellow_dog_tasks/lib/yellow_dog/tasks/workers/sync_region_data_worker.ex`
- Modify: `apps/yellow_dog_tasks/lib/yellow_dog/tasks.ex`
- Create: `apps/yellow_dog_tasks/test/yellow_dog/tasks/data_sync_test.exs`
- Create: `apps/yellow_dog_tasks/test/yellow_dog/tasks/workers/sync_ip_database_worker_test.exs`
- Create: `apps/yellow_dog_tasks/test/yellow_dog/tasks/workers/sync_mac_database_worker_test.exs`
- Create: `apps/yellow_dog_tasks/test/yellow_dog/tasks/workers/sync_region_data_worker_test.exs`

**Interfaces:**
- Produces: `YellowDog.Tasks.list_tasks/0 :: [map()]`
- Produces: `YellowDog.Tasks.get_task!/1 :: map()`
- Produces: `YellowDog.Tasks.enqueue/2 :: {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}`
- Produces: `YellowDog.Tasks.recent_jobs/1 :: [Oban.Job.t()]`
- Produces workers for task keys `:region`, `:ip_country`, `:ip_city`, `:mac`.

- [ ] **Step 1: Write failing enqueue/status tests**

Use `Oban.Testing` with `repo: YellowDog.Tasks.Repo` and assert:

```elixir
assert {:ok, %Oban.Job{worker: worker, queue: "data_sync"}} = YellowDog.Tasks.enqueue(:ip_city)
assert worker == "YellowDog.Tasks.Workers.SyncIpDatabaseWorker"
assert_enqueued worker: YellowDog.Tasks.Workers.SyncIpDatabaseWorker, args: %{"type" => "city", "force" => true}
```

Assert `YellowDog.Tasks.enqueue(:unknown)` raises or returns `{:error, :unknown_task}` without accepting arbitrary modules.

- [ ] **Step 2: Write failing worker tests**

IP worker tests:

```elixir
assert :ok = perform_job(SyncIpDatabaseWorker, %{"type" => "city", "force" => true})
assert {:error, {:invalid_type, "bogus"}} = perform_job(SyncIpDatabaseWorker, %{"type" => "bogus"})
```

MAC worker tests:

```elixir
assert :ok = perform_job(SyncMacDatabaseWorker, %{"force" => true})
```

Region worker tests:

```elixir
assert :ok = perform_job(SyncRegionDataWorker, %{"force" => true})
assert YellowDog.Tasks.RegionData.Store.info()[:record_count] > 0
```

Attach telemetry handlers in tests and assert start/stop or exception events include `task`, `source`, and `job_id`.

- [ ] **Step 3: Run tests and verify failure**

Run:

```bash
devenv shell -- mix cmd --app yellow_dog_tasks mix test test/yellow_dog/tasks/data_sync_test.exs test/yellow_dog/tasks/workers
```

Expected: fail because APIs/workers do not exist.

- [ ] **Step 4: Implement minimal worker and status APIs**

Worker rules:

- Validate JSON string args.
- Use unique job settings from the PRD.
- Emit `[:yellow_dog, :tasks, :sync, :start]`, `:stop`, and `:exception`.
- Return errors to Oban instead of swallowing them.
- Query recent jobs from `Oban.Job` via `YellowDog.Tasks.Repo`.

For the IP worker, call `GeoIpDb.Database.download(type_atom)` initially, then validate metadata via `GeoIpDb.Database.get_metadata/1` and file info via `GeoIpDb.Database.file_info/1`. Preserve failure behavior by relying on Task 3 atomic writes for direct file updates where used.

For the MAC worker, ensure `YellowDog.Fingerprint.OuiDatabase` is running, call `download/1`, then validate `info.entry_count > 0`.

For the region worker, call `YellowDog.Tasks.RegionData.Store.sync/1`.

- [ ] **Step 5: Run scoped worker tests**

Run:

```bash
devenv shell -- mix cmd --app yellow_dog_tasks mix test test/yellow_dog/tasks/data_sync_test.exs test/yellow_dog/tasks/workers
```

Expected: pass.

---

### Task 6: Console Task Management UI And Manual Enqueue Integration

**Files:**
- Modify: `apps/yellow_dog_console/mix.exs`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/router.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/components/sidebar.ex`
- Create: `apps/yellow_dog_console/lib/yellow_dog/console/live/tasks_live/index.ex`
- Create: `apps/yellow_dog_console/lib/yellow_dog/console/live/tasks_live/show.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/ip_database_live.ex`
- Modify: `apps/yellow_dog_console/lib/yellow_dog/console/live/mac_database_live.ex`
- Create: `apps/yellow_dog_console/test/yellow_dog/console/live/tasks_live_test.exs`
- Modify: existing console IP/MAC tests if present; otherwise add coverage to `tasks_live_test.exs`.

**Interfaces:**
- Consumes: `YellowDog.Tasks.list_tasks/0`, `get_task!/1`, `enqueue/2`, and `recent_jobs/1`.
- Produces: `/system/tasks` overview and `/system/tasks/:task` detail routes.

- [ ] **Step 1: Write failing LiveView tests**

Tests must cover:

```elixir
{:ok, view, html} = live(conn, ~p"/system/tasks")
assert html =~ "Data Sync Tasks"
assert has_element?(view, "button[phx-click='run_now'][phx-value-task='ip_city']", "Run Now")
assert has_element?(view, "a[href='/system/tasks/ip_city']", "View History")
```

Run-now enqueue:

```elixir
{:ok, view, _html} = live(conn, ~p"/system/tasks")
html = render_click(element(view, "button[phx-click='run_now'][phx-value-task='mac']"))
assert html =~ "MAC/OUI sync queued"
```

Existing page integration:

```elixir
{:ok, view, html} = live(conn, ~p"/system/ip-database")
assert html =~ "IP City sync"
assert has_element?(view, "a[href='/system/tasks/ip_city']")
```

and:

```elixir
{:ok, _view, html} = live(conn, ~p"/system/mac-database")
assert html =~ "MAC/OUI sync"
assert html =~ "/system/tasks/mac"
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
devenv shell -- bash -lc 'cd apps/yellow_dog_console && mix test test/yellow_dog/console/live/tasks_live_test.exs'
```

Expected: fails because routes/UI do not exist.

- [ ] **Step 3: Implement routes, sidebar, and overview/detail LiveViews**

Use `Layouts.app flash={@flash} current_path={@current_path}`. Do not introduce raw arbitrary styling beyond existing project utility patterns. Use icons through `<.dm_mdi>`.

Display:

- task name
- enabled/disabled
- current status
- schedule expression
- source
- last success/failure summary
- next scheduled run when available from cron metadata or config
- recent jobs table

- [ ] **Step 4: Change manual IP/MAC download actions to enqueue jobs**

`IpDatabaseLive` download event maps `"city"` to `YellowDog.Tasks.enqueue(:ip_city)` and `"country"` to `YellowDog.Tasks.enqueue(:ip_country)`.

`MacDatabaseLive` download event maps to `YellowDog.Tasks.enqueue(:mac)`.

Remove `start_async` download usage for these manual download actions; keep reload/test lookup behavior.

- [ ] **Step 5: Run scoped console tests**

Run:

```bash
devenv shell -- bash -lc 'cd apps/yellow_dog_console && mix test test/yellow_dog/console/live/tasks_live_test.exs'
```

Expected: pass.

---

### Task 7: Integration Verification And Hardening

**Files:**
- Modify only files already listed in Tasks 1-6, and only when a listed verification command fails because of that task's implementation.
- Do not expand scope unless a compile/test failure proves it is necessary.

- [ ] **Step 1: Run formatting check**

Run:

```bash
devenv shell -- mix format --check-formatted
```

Expected: pass. If it fails, run `devenv shell -- mix format`, inspect the diff, and rerun the check.

- [ ] **Step 2: Run scoped task app tests**

Run:

```bash
devenv shell -- mix cmd --app yellow_dog_tasks mix test
```

Expected: pass.

- [ ] **Step 3: Run touched dependency tests**

Run:

```bash
devenv shell -- mix cmd --app geo_ip_db mix test test/geo_ip_db/download_test.exs
devenv shell -- mix cmd --app yellow_dog_fingerprint mix test test/yellow_dog/fingerprint/oui_database_test.exs
devenv shell -- bash -lc 'cd apps/yellow_dog_console && mix test test/yellow_dog/console/live/tasks_live_test.exs'
devenv shell -- mix cmd --app yellow_dog_config mix test test/yellow_dog/config/schema_test.exs
```

Expected: pass.

- [ ] **Step 4: Run compile with warnings as errors**

Run:

```bash
devenv shell -- mix compile --warnings-as-errors
```

Expected: exit 0.

- [ ] **Step 5: Run full umbrella tests**

Run:

```bash
devenv shell -- mix test
```

Expected: all tests pass. If unrelated tests outside the PRD scope fail, list them and stop per PRD scope rules.

- [ ] **Step 6: Review dependency build metadata**

Run:

```bash
devenv shell -- mix deps.unlock --check-unused
git diff --check
git status --short
```

Expected: no unused dependencies, no whitespace errors, and only PRD-scoped files changed.

If `default.nix` hash is stale, run `nix build` long enough to capture the expected hash and update only the hash line.
