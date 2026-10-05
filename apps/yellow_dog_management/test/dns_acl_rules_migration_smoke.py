"""Integrity check for reshaping current Management ACL data, not compatibility."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid


if len(sys.argv) != 2:
    raise SystemExit("Usage: dns_acl_rules_migration_smoke.py RELEASE_BINARY")

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
if sql("SHOW server_encoding") != "UTF8":
    raise SystemExit("Disposable PostgreSQL must use UTF8")

database = "dns_acl_rules_" + uuid.uuid4().hex
subprocess.run(["createdb", "--template=template0", "--encoding=UTF8", database],
               env=pg_env, check=True, timeout=30)
pg_env["PGDATABASE"] = database
assert sql("SHOW server_encoding") == "UTF8"

directory = Path(tempfile.mkdtemp(prefix="management-dns-acl-rules-migration-"))
env = dict(os.environ, RELEASE_DISTRIBUTION="none",
           YELLOW_DOG_MANAGEMENT_DATABASE_URL=f"postgres://postgres@127.0.0.1:{cluster_port}/{database}")


def evaluate(expression, log_name):
    with (directory / log_name).open("w") as log:
        subprocess.run([str(binary), "eval", expression], env=env,
                       stdout=log, stderr=subprocess.STDOUT, check=True, timeout=120)


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


try:
    evaluate("""
        Application.load(:yellow_dog_management)
        Application.put_env(:yellow_dog_management, YellowDog.Management.Repo,
                            YellowDog.Management.Settings.repo())
        {:ok, _, _} = Ecto.Migrator.with_repo(YellowDog.Management.Repo, fn repo ->
          Ecto.Migrator.run(repo, :up, to: 20261001040000)
        end)
    """, "initial-migration.log")
    assert sql("SELECT max(version) FROM schema_migrations") == "20261001040000"

    service_id = str(uuid.uuid4())
    sql(f"""
        BEGIN;
        INSERT INTO management_workers
          (id, name, expected_capabilities, revision, inserted_at, updated_at)
        VALUES ('migration-worker', 'Migration Worker', ARRAY['dns'], 7,
                '2026-10-01 00:00:00.123456', '2026-10-01 01:00:00.654321');
        INSERT INTO management_services
          (id, worker_id, instance_id, type, desired_state, config, inserted_at, updated_at)
        VALUES ('{service_id}', 'migration-worker', 'dns', 'dns', 'stopped',
                '{{"listen_address":"127.0.0.1","port":5300}}'::jsonb,
                '2026-10-01 00:00:00.123456', '2026-10-01 01:00:00.654321');
        COMMIT;
    """)
    seeds = [
        ("empty-allow", "allow", [], 3),
        ("empty-deny", "deny", [], 4),
        ("ipv4", "allow", ["192.0.2.0/24", "198.51.100.23/32", "0.0.0.0/0"], 5),
        ("ipv6", "deny", ["2001:db8::/32", "::1/128", "::/0"], 6),
    ]
    for name, action, networks, revision in seeds:
        network_array = "ARRAY[" + ",".join("'" + network + "'" for network in networks) + "]::text[]"
        sql(f"""
            INSERT INTO management_dns_acls
              (id, service_id, name, action, networks, revision, inserted_at, updated_at)
            VALUES ('{uuid.uuid4()}', '{service_id}', '{name}', '{action}', {network_array},
                    {revision}, '2026-10-01 00:00:00.123456', '2026-10-01 01:00:00.654321')
        """)

    before = snapshot()
    (directory / "before.json").write_text(json.dumps(before, ensure_ascii=False, sort_keys=True), encoding="utf-8")
    evaluate("""
      Application.load(:yellow_dog_management)
      {:ok, _, _} = Ecto.Migrator.with_repo(YellowDog.Management.Repo, fn repo ->
        Ecto.Migrator.run(repo, :up, to: 20261001050000)
      end)
    """, "current-migration.log")
    after = snapshot()
    (directory / "after.json").write_text(json.dumps(after, ensure_ascii=False, sort_keys=True), encoding="utf-8")

    columns = json.loads(sql("""
        SELECT json_agg(column_name ORDER BY ordinal_position)
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'management_dns_acls'
    """))
    assert "action" not in columns and "networks" not in columns, columns
    assert "description" in columns and "rules" in columns, columns
    assert sql("SHOW server_encoding") == "UTF8"
    assert sql("SELECT count(*) FROM schema_migrations WHERE version=20261001050000") == "1"

    transformed = {row["id"]: row for row in after["public.management_dns_acls"]}
    original = before["public.management_dns_acls"]
    assert len(original) == len(seeds) == len(transformed)
    for row in original:
        expected = {key: value for key, value in row.items() if key not in {"action", "networks"}}
        expected.update(description="", rules=[{"action": row["action"], "kind": "networks", "networks": row["networks"]}])
        assert transformed[row["id"]] == expected, (row, transformed[row["id"]])

    excluded = {"public.management_dns_acls", "public.schema_migrations"}
    assert {key: value for key, value in before.items() if key not in excluded} == {
        key: value for key, value in after.items() if key not in excluded
    }, "Migration changed non-ACL persistent data"
    receipts = {row["version"]: row for row in after["public.schema_migrations"]}
    for receipt in before["public.schema_migrations"]:
        assert receipts[receipt["version"]] == receipt
    print("PASS current Management ACL reshaping: identity/revision/timestamps, empty actions, IPv4/IPv6 and non-ACL data preserved")
finally:
    print(f"DNS ACL migration evidence: {directory}; disposable database: {database}", flush=True)
