"""Verify fresh and existing Management databases in a disposable PostgreSQL cluster."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid


if len(sys.argv) != 2:
    raise SystemExit("Usage: netman_removal_migration_smoke.py RELEASE_BINARY")

cluster_directory = os.environ.get("YELLOW_DOG_PHASE1_PG_DATA_DIR")
cluster_port = os.environ.get("YELLOW_DOG_PHASE1_PG_PORT")
if not cluster_directory or not cluster_port:
    raise SystemExit("Use scripts/e2e/phase1_postgres.sh with disposable PostgreSQL")

cluster = Path(cluster_directory).resolve()
if not cluster.parent.name.startswith("yellow-dog-phase1-pg.") or not (cluster / "PG_VERSION").is_file():
    raise SystemExit("Expected the disposable helper cluster directory")
if not cluster_port.isdecimal() or not 1 <= int(cluster_port) <= 65535:
    raise SystemExit("Invalid disposable PostgreSQL port")

binary = Path(sys.argv[1]).resolve()
if not binary.is_file() or not os.access(binary, os.X_OK):
    raise SystemExit("Release binary must exist and be executable")

pg_env = dict(os.environ, PGHOST="127.0.0.1", PGPORT=cluster_port,
              PGUSER="postgres", PGDATABASE="postgres")
for variable in ["PGPASSWORD", "PGSERVICE", "PGSERVICEFILE", "PGOPTIONS"]:
    pg_env.pop(variable, None)


def sql(statement):
    return subprocess.check_output(
        ["psql", "-XAt", "-v", "ON_ERROR_STOP=1", "-c", statement],
        env=pg_env, text=True, timeout=30,
    ).strip()


if Path(sql("SHOW data_directory")).resolve() != cluster:
    raise SystemExit("Connected PostgreSQL is not the disposable helper cluster")

directory = Path(tempfile.mkdtemp(prefix="management-netman-removal-"))
env = dict(os.environ, RELEASE_DISTRIBUTION="none")
operations = ["create_netman", "update_netman", "update_netman_config",
              "confirm_netman_config", "rollback_netman_config"]
removed_tables = {"public.management_netmans", "public.management_netman_config_drafts",
                  "public.management_netman_config_versions"}


def evaluate(expression, log_name):
    with (directory / log_name).open("w") as log:
        subprocess.run([str(binary), "eval", expression], env=env,
                       stdout=log, stderr=subprocess.STDOUT, check=True, timeout=120)


def migrate(version, log_name):
    target = "all: true" if version is None else f"to: {version}"
    evaluate("""
        Application.load(:yellow_dog_management)
        Application.put_env(:yellow_dog_management, YellowDog.Management.Repo,
                            YellowDog.Management.Settings.repo())
        {:ok, _, _} = Ecto.Migrator.with_repo(YellowDog.Management.Repo, fn repo ->
          Ecto.Migrator.run(repo, :up, TARGET)
        end)
    """.replace("TARGET", target), log_name)


def snapshot():
    tables = json.loads(sql("""
        SELECT COALESCE(json_agg(json_build_array(schemaname, tablename)
                                ORDER BY schemaname, tablename), '[]'::json)
        FROM pg_tables WHERE schemaname IN ('public', 'management_jobs')
    """))
    result = {}
    for schema, table in tables:
        quoted = ".".join('"' + value.replace('"', '""') + '"' for value in [schema, table])
        result[f"{schema}.{table}"] = json.loads(sql(f"""
            SELECT COALESCE(json_agg(data ORDER BY data::text), '[]'::json)
            FROM (SELECT row_to_json(stored) data FROM {quoted} stored) records
        """))
    return result


def check_schema():
    for table in removed_tables:
        assert sql(f"SELECT to_regclass('{table}') IS NULL") == "t", table
    assert sql("SELECT count(*) FROM schema_migrations WHERE version=20261024000000") == "1"
    assert sql("""
        SELECT tgenabled FROM pg_trigger
        WHERE tgrelid = 'management_audits'::regclass AND tgname = 'management_audits_immutable'
    """) == "O"


try:
    for scenario in ["fresh", "upgrade"]:
        database = "netman_removal_" + scenario + "_" + uuid.uuid4().hex
        pg_env["PGDATABASE"] = "postgres"
        subprocess.run(["createdb", "--template=template0", "--encoding=UTF8", database],
                       env=pg_env, check=True, timeout=30)
        pg_env["PGDATABASE"] = database
        env["YELLOW_DOG_MANAGEMENT_DATABASE_URL"] = f"postgres://postgres@127.0.0.1:{cluster_port}/{database}"
        if scenario == "fresh":
            migrate(None, "fresh-migration.log")
            check_schema()
            print("PASS fresh Management schema has no standalone Netman tables", flush=True)
            continue

        migrate(20261023000000, "upgrade-initial-migration.log")
        evaluate("""
          Application.load(:yellow_dog_management)
          Application.put_env(:yellow_dog_management, YellowDog.Management.Repo,
                              YellowDog.Management.Settings.repo())
          {:ok, _, _} = Ecto.Migrator.with_repo(YellowDog.Management.Repo, fn repo ->
            alias YellowDog.Management.Domain
            mutate = fn operation, params ->
              {:ok, result} = Domain.mutate(operation, params, "fixture", Ecto.UUID.generate())
              result
            end
            worker = mutate.("create_worker", %{"id" => "preserved-worker", "name" => "Worker"})
            service = mutate.("create_service", %{
              "worker_id" => worker["id"], "expected_revision" => worker["revision"],
              "instance_id" => "dns", "type" => "dns", "desired_state" => "stopped",
              "config" => %{"listen_address" => "127.0.0.1", "port" => 5300}
            })
            scope = %{"worker_id" => worker["id"], "service_id" => service["id"]}
            _acl = mutate.("create_dns_acl", Map.merge(scope, %{
              "name" => "preserved_acl", "description" => "Migration fixture",
              "rules" => [%{"action" => "allow", "kind" => "networks", "networks" => ["192.0.2.0/24"]}]
            }))
            _view = mutate.("create_dns_view", Map.merge(scope, %{"name" => "preserved"}))
            zone = mutate.("create_zone", %{
              "name" => "preserved.test.",
              "records" => [
                %{"name" => "preserved.test.", "type" => "SOA", "ttl" => 300,
                  "data" => %{"mname" => "ns.preserved.test.", "rname" => "hostmaster.preserved.test.",
                    "serial" => 1, "refresh" => 3600, "retry" => 600, "expire" => 86400, "minimum" => 300}},
                %{"name" => "preserved.test.", "type" => "NS", "ttl" => 300,
                  "data" => %{"host" => "ns.preserved.test."}},
                %{"name" => "ns.preserved.test.", "type" => "A", "ttl" => 300,
                  "data" => %{"address" => "192.0.2.10"}}
              ]
            })
            _version = mutate.("confirm_zone", %{"id" => zone["id"], "expected_revision" => 1})
            _target = mutate.("confirm_target", %{"worker_id" => worker["id"], "expected_revision" => service["worker_revision"]})

            canonical = fn recurse, value ->
              cond do
                is_map(value) -> value |> Enum.map(fn {key, item} -> {key, recurse.(recurse, item)} end) |> Enum.sort()
                is_list(value) -> Enum.map(value, &recurse.(recurse, &1))
                true -> value
              end
            end
            seed = fn key, operation, request, audit_request, result, audit_result ->
              fingerprint = :crypto.hash(:sha256,
                :erlang.term_to_binary({operation, "fixture", canonical.(canonical, request)}, [:deterministic]))
                |> Base.encode16(case: :lower)
              repo.query!("INSERT INTO management_idempotency (key, request_digest, result, inserted_at) VALUES ($1, $2, $3, now())",
                          [key, fingerprint, result])
              repo.query!("INSERT INTO management_audits (id, actor, operation, request, result, inserted_at) VALUES ($1, 'fixture', $2, $3, $4, now())",
                          [Ecto.UUID.bingenerate(), operation, audit_request, audit_result])
            end
            error = %{"code" => "invalid_request", "message" => "Invalid request", "details" => %{}}
            node = %{"id" => "removed-netman", "profile_name" => "custom", "apply_mode" => "managed", "features" => %{}}
            seed.("netman-node", "create_netman", %{"name" => "Netman"}, %{}, %{"ok" => node}, %{})
            seed.("netman-draft", "update_netman_config", %{"document" => %{}}, %{}, %{"ok" => %{"netman_id" => "removed-netman", "document" => %{}}}, %{})
            seed.("netman-version", "confirm_netman_config", %{"expected_revision" => 1}, %{}, %{"ok" => %{"netman_id" => "removed-netman", "version" => 1}}, %{})
            seed.("netman-raw-failure", "update_netman", %{"id" => "removed-netman", "name" => "Rejected"},
                  %{"id" => "removed-netman", "name" => "Rejected"}, %{"error" => error}, %{"error" => error})
            seed.("opaque-failure", "rollback_netman_config", %{"id" => "removed-netman", "target_version" => 42},
                  %{"id" => "removed-netman"}, %{"error" => error}, %{"error" => %{"code" => "invalid_request"}})
          end)
        """, "upgrade-fixtures.log")
        sql("""
          INSERT INTO management_netmans
            (id, name, profile_name, apply_mode, features, inserted_at, updated_at)
          VALUES ('removed-netman', 'Netman', 'custom', 'managed', '{}'::jsonb, now(), now());
          INSERT INTO management_netman_config_drafts (netman_id, document, inserted_at, updated_at)
          VALUES ('removed-netman', '{}'::jsonb, now(), now());
          INSERT INTO management_netman_config_versions
            (id, netman_id, version, source_revision, operation, document, digest, inserted_at)
          VALUES ('11111111-1111-4111-8111-111111111111', 'removed-netman', 1, 1,
                  'confirm_netman_config', '{}'::jsonb, 'fixture', now());
          INSERT INTO management_netman_config_versions
            (id, netman_id, version, source_revision, operation, document, digest, rollback_source_id, inserted_at)
          VALUES ('22222222-2222-4222-8222-222222222222', 'removed-netman', 2, 2,
                  'rollback_netman_config', '{}'::jsonb, 'fixture',
                  '11111111-1111-4111-8111-111111111111', now());
          INSERT INTO management_backups (id, label, state, inserted_at, updated_at)
          VALUES ('33333333-3333-4333-8333-333333333333', 'Preserved backup', 'pending', now(), now());
          INSERT INTO management_geoip_artifacts
            (digest, path, size, source_url, metadata, kind, format, inserted_at)
          VALUES (repeat('a', 64), '/fixture/preserved-country.mmdb', 42,
                  'https://example.test/country.mmdb', '{"fixture":true}'::jsonb,
                  'country', 'mmdb', now());
          UPDATE management_task_definitions
          SET enabled = true, cron = '15 2 * * *', revision = 7
          WHERE key = 'ip_country';
        """)
        before = snapshot()
        (directory / "before.json").write_text(json.dumps(before, sort_keys=True), encoding="utf-8")
        migrate(None, "upgrade-current-migration.log")
        check_schema()
        after = snapshot()
        (directory / "after.json").write_text(json.dumps(after, sort_keys=True), encoding="utf-8")

        excluded = removed_tables | {"public.management_audits", "public.management_idempotency", "public.schema_migrations"}
        assert {key: value for key, value in before.items() if key not in excluded} == {
            key: value for key, value in after.items() if key not in excluded
        }, "Migration changed unrelated persistent data"
        assert after["public.management_audits"] == [
            row for row in before["public.management_audits"] if row["operation"] not in operations
        ]
        removed_receipts = {"netman-node", "netman-draft", "netman-version", "netman-raw-failure"}
        assert after["public.management_idempotency"] == [
            row for row in before["public.management_idempotency"] if row["key"] not in removed_receipts
        ]
        assert any(row["key"] == "opaque-failure" for row in after["public.management_idempotency"])
        receipts = {row["version"]: row for row in after["public.schema_migrations"]}
        for receipt in before["public.schema_migrations"]:
            assert receipts[receipt["version"]] == receipt
        print("PASS existing database upgrade removes Netman tables/audits/proven receipts; preserves Worker/DNS/Target/task/backup data and unattributable receipts", flush=True)
finally:
    print(f"Netman removal migration evidence: {directory}", flush=True)
