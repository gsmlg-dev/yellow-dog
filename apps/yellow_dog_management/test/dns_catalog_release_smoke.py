"""Current DNS catalog controls, downloads and immutable history; disposable only."""

import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid

assert os.environ.get("YELLOW_DOG_PHASE1_PG_DATA_DIR"), "Use disposable PostgreSQL"
binary = Path(sys.argv[1]).resolve()
directory = Path(tempfile.mkdtemp(prefix="management-dns-catalog-release-"))
with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    port = listener.getsockname()[1]
base = f"http://127.0.0.1:{port}"
env = dict(os.environ, RELEASE_DISTRIBUTION="none", MANAGEMENT_UI_URL=base,
           YELLOW_DOG_MANAGEMENT_BIND_ADDRESS="127.0.0.1", YELLOW_DOG_MANAGEMENT_PORT=str(port),
           YELLOW_DOG_MANAGEMENT_ARTIFACT_DIRECTORY=str(directory / "artifacts"),
           YELLOW_DOG_MANAGEMENT_BACKUP_DIRECTORY=str(directory / "backups"),
           MANAGEMENT_DNS_CATALOG_EVIDENCE=str(directory / "browser.json"))
env.pop("YELLOW_DOG_MANAGEMENT_OPERATOR_TOKEN", None)
pg_env = dict(env, PGHOST="127.0.0.1", PGPORT=env["YELLOW_DOG_PHASE1_PG_PORT"], PGUSER="postgres", PGDATABASE="yellow_dog_phase1")
process = None
log = (directory / "server.log").open("w")


def request(path, body=None):
    headers = {} if body is None else {"Content-Type": "application/json", "Idempotency-Key": str(uuid.uuid4())}
    with urllib.request.urlopen(urllib.request.Request(base + "/api" + path, headers=headers,
        data=None if body is None else json.dumps(body).encode()), timeout=15) as response:
        return json.loads(response.read())["data"]


def sql(query):
    return subprocess.check_output(["psql", "-XAt", "-v", "ON_ERROR_STOP=1", "-c", query], env=pg_env, text=True).strip()


def snapshot():
    tables = json.loads(sql("SELECT json_agg(json_build_array(schemaname,tablename) ORDER BY schemaname,tablename) FROM pg_tables WHERE schemaname IN ('public','management_jobs') AND tablename <> 'oban_peers'"))
    return {f"{schema}.{table}": json.loads(sql(f'SELECT COALESCE(json_agg(data ORDER BY data::text),\'[]\'::json) FROM (SELECT row_to_json(stored) data FROM "{schema}"."{table}" stored) records')) for schema, table in tables}


def record_signatures(records):
    return sorted(json.dumps(record, sort_keys=True) for record in records)


def new_rows(before, after, table, identity):
    original = {row[identity]: row for row in before[table]}
    stored = {row[identity]: row for row in after[table]}
    assert all(stored.get(key) == row for key, row in original.items()), f"Existing {table} rows changed"
    return [row for key, row in stored.items() if key not in original]


def start():
    global process
    process = subprocess.Popen([str(binary), "start"], env=env, stdout=log, stderr=log, start_new_session=True)
    for attempt in range(150):
        assert process.poll() is None, str(directory / "server.log")
        try:
            request("/workers")
            return
        except OSError:
            time.sleep(.1)
    raise AssertionError("Management startup timed out")


def stop(force=False):
    if process is None:
        return
    try:
        os.killpg(process.pid, signal.SIGKILL if force else signal.SIGTERM)
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=10)
    except ProcessLookupError:
        pass


def zone(name, extra=False):
    records = [
        {"name": name, "type": "SOA", "ttl": 300, "data": {"mname": "ns1." + name,
         "rname": "hostmaster." + name, "serial": 1, "refresh": 3600, "retry": 600, "expire": 86400, "minimum": 300}},
        {"name": name, "type": "NS", "ttl": 300, "data": {"host": "ns1." + name}},
        {"name": "ns1." + name, "type": "A", "ttl": 300, "data": {"address": "192.0.2.10"}},
    ]
    if extra:
        records.append({"name": "www." + name, "type": "A", "ttl": 300, "data": {"address": "192.0.2.20"}})
    return request("/commands/create_zone", {"name": name, "records": records})


def browser(verify_only=False):
    with tempfile.TemporaryDirectory(prefix="management-dns-catalog-browser-") as profile:
        subprocess.run(["node", str(Path(__file__).with_name("dns_catalog_browser_smoke.mjs"))],
            env=dict(env, MANAGEMENT_DNS_CATALOG_BROWSER_PROFILE=profile, MANAGEMENT_DNS_CATALOG_VERIFY_ONLY="1" if verify_only else "0"), check=True, timeout=150)


try:
    subprocess.run([str(binary), "eval", "YellowDog.Management.Release.migrate()"], env=env, stdout=log, stderr=log, check=True, timeout=90)
    start()
    assert request("/workers") == [] and request("/zones") == [], "Expected fresh disposable database"
    first = zone("alpha.example.test.", True)
    second = zone("beta.example.test.")
    for resource in [first, second]:
        request("/commands/confirm_zone", {"id": resource["id"], "expected_revision": resource["revision"]})
    env.update(MANAGEMENT_DNS_CATALOG_ZONE_ID=first["id"], MANAGEMENT_DNS_CATALOG_OTHER_ZONE_ID=second["id"])
    before = snapshot()
    (directory / "before.json").write_text(json.dumps(before, sort_keys=True))
    browser()
    after = snapshot()
    evidence = json.loads(Path(env["MANAGEMENT_DNS_CATALOG_EVIDENCE"]).read_text())
    effects = evidence["recordEffects"]
    assert effects["original"] == first
    bulk_record = {"name": "bulk.alpha.example.test.", "type": "A", "ttl": 300, "data": {"address": "192.0.2.1"}}
    concurrent_record = {"name": "concurrent.alpha.example.test.", "type": "A", "ttl": 300, "data": {"address": "192.0.2.11"}}
    expected_bulk = first["records"] + [bulk_record]
    expected_edit = [dict(record, data={"address": "192.0.2.21"}) if record["name"] == "www.alpha.example.test." and record["type"] == "A" else record for record in expected_bulk]
    expected_concurrent = expected_edit + [concurrent_record]
    expected_delete = [record for record in expected_concurrent if not (record["name"] == "www.alpha.example.test." and record["type"] == "A")]
    for increment, key, records in [(1, "afterBulk", expected_bulk), (2, "afterEdit", expected_edit), (3, "afterConcurrent", expected_concurrent), (4, "afterDelete", expected_delete)]:
        assert effects[key]["id"] == first["id"] and effects[key]["name"] == first["name"]
        assert effects[key]["revision"] == first["revision"] + increment
        assert record_signatures(effects[key]["records"]) == record_signatures(records), key
    assert request("/zones/" + first["id"]) == effects["afterDelete"]
    assert request("/zones") == evidence["zones"] == [effects["afterDelete"]]
    assert effects["cachedOrdinal"] != effects["acceptedOrdinal"]
    assert [dialog["decision"] for dialog in effects["dialogs"]] == [False, True, True]
    assert all(dialog["handled"] and dialog["closed"] == dialog["decision"] for dialog in effects["dialogs"])

    excluded = {"public.management_zones", "public.management_rrsets", "public.management_audits", "public.management_idempotency"}
    assert {key:value for key,value in before.items() if key not in excluded} == {key:value for key,value in after.items() if key not in excluded}, "Catalog controls changed immutable versions or unrelated state"
    assert [row for row in before["public.management_rrsets"] if row["zone_id"] != first["id"]] == [row for row in after["public.management_rrsets"] if row["zone_id"] != first["id"]], "Unselected Zone records changed"
    stored_records = [{"name": row["name"], "type": row["type"], "ttl": row["ttl"], "data": data} for row in after["public.management_rrsets"] if row["zone_id"] == first["id"] for data in row["data"]]
    assert record_signatures(stored_records) == record_signatures(expected_delete), "PostgreSQL records differ from exact browser/API effects"
    stored = {row["id"]:row for row in after["public.management_zones"]}
    original = {row["id"]:row for row in before["public.management_zones"]}
    assert {key:value for key,value in stored[first["id"]].items() if key not in {"revision", "updated_at"}} == {key:value for key,value in original[first["id"]].items() if key not in {"revision", "updated_at"}}
    assert stored[first["id"]]["revision"] == original[first["id"]]["revision"] + 4
    assert stored[second["id"]]["deleted_at"] is not None
    assert stored[second["id"]]["revision"] == original[second["id"]]["revision"] + 1
    assert {key:value for key,value in stored[second["id"]].items() if key not in {"revision", "updated_at", "deleted_at"}} == {key:value for key,value in original[second["id"]].items() if key not in {"revision", "updated_at", "deleted_at"}}
    audits = new_rows(before, after, "public.management_audits", "id")
    receipts = new_rows(before, after, "public.management_idempotency", "key")
    assert len(audits) == len(receipts) == 6, "Preview/cancellation/refresh wrote receipts or a command silently retried"
    rejected = [row for row in audits if "error" in row["result"]]
    assert len(rejected) == 1
    assert rejected[0]["operation"] == "update_zone"
    assert rejected[0]["request"]["id"] == first["id"]
    assert rejected[0]["request"]["expected_revision"] == effects["afterEdit"]["revision"]
    assert rejected[0]["result"]["error"]["code"] == "revision_conflict"
    assert record_signatures(rejected[0]["request"]["records"]) == record_signatures([record for record in expected_edit if record["name"] != "www.alpha.example.test."])
    updates = sorted((row for row in audits if row["operation"] == "update_zone" and "error" not in row["result"]), key=lambda row: row["result"]["revision"])
    assert len(updates) == 4
    for row, key in zip(updates, ["afterBulk", "afterEdit", "afterConcurrent", "afterDelete"]):
        assert row["request"]["id"] == first["id"]
        assert row["request"]["expected_revision"] == effects[key]["revision"] - 1
        assert row["result"] == effects[key]
    deletes = [row for row in audits if row["operation"] == "delete_zone"]
    assert len(deletes) == 1 and deletes[0]["request"]["id"] == second["id"]
    expected_receipts = [{"error": row["result"]["error"]} if "error" in row["result"] else {"ok": row["result"]} for row in audits]
    assert sorted(json.dumps(row["result"], sort_keys=True) for row in receipts) == sorted(json.dumps(result, sort_keys=True) for result in expected_receipts)
    stop(force=True)
    start()
    browser(verify_only=True)
    assert snapshot() == after, "Read-only restart wrote persistent data"
    (directory / "final.json").write_text(json.dumps(after, sort_keys=True))
    print("PASS DNS catalog: filtered CSV/BIND export, canonical JSON preview/append, record edit, native delete cancel/accept, stale CAS rejected receipt, exact PG effects, immutable history and SIGKILL read-only replay; BIND import remains unimplemented")
finally:
    stop()
    log.close()
    print(f"DNS catalog release evidence: {directory}", flush=True)
