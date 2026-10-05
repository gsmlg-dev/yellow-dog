"""Overview acceptance against a disposable PostgreSQL database and real Chromium."""
import json
import os
import signal
from datetime import datetime
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid

assert os.environ.get("YELLOW_DOG_PHASE1_PG_DATA_DIR"), "Use disposable PG helper"
binary = Path(sys.argv[1]).resolve()
directory = Path(tempfile.mkdtemp(prefix="management-overview-release-"))
with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    port = listener.getsockname()[1]
base = f"http://127.0.0.1:{port}"
env = dict(os.environ, RELEASE_DISTRIBUTION="none", YELLOW_DOG_MANAGEMENT_BIND_ADDRESS="127.0.0.1",
           YELLOW_DOG_MANAGEMENT_PORT=str(port), MANAGEMENT_UI_URL=base,
           MANAGEMENT_OVERVIEW_EVIDENCE=str(directory / "browser.json"),
           YELLOW_DOG_MANAGEMENT_ARTIFACT_DIRECTORY=str(directory / "artifacts"),
           YELLOW_DOG_MANAGEMENT_BACKUP_DIRECTORY=str(directory / "backups"))
env.pop("YELLOW_DOG_MANAGEMENT_OPERATOR_TOKEN", None)
process = None
log = (directory / "server.log").open("w")
pg_env = dict(env, PGHOST="127.0.0.1", PGPORT=os.environ["YELLOW_DOG_PHASE1_PG_PORT"],
              PGUSER="postgres", PGDATABASE="yellow_dog_phase1")
pg_env.pop("PGPASSWORD", None)


def request(path, body=None):
    headers = {} if body is None else {"Content-Type": "application/json", "Idempotency-Key": str(uuid.uuid4())}
    payload = None if body is None else json.dumps(body).encode()
    with urllib.request.urlopen(urllib.request.Request(base + "/api" + path, data=payload, headers=headers), timeout=15) as response:
        assert response.status == 200
        return json.load(response)["data"]


def sql(query):
    return subprocess.check_output(["psql", "-XAt", "-v", "ON_ERROR_STOP=1", "-c", query], env=pg_env, text=True).strip()


def database_state():
    tables = json.loads(sql("SELECT json_agg(json_build_array(schemaname, tablename) ORDER BY schemaname, tablename) FROM pg_tables WHERE schemaname IN ('public', 'management_jobs') AND NOT (schemaname='management_jobs' AND tablename='oban_peers')"))
    state = {}
    for schema, table in tables:
        quoted = '.'.join('"' + identifier.replace('"', '""') + '"' for identifier in [schema, table])
        state[f"{schema}.{table}"] = json.loads(sql(f"SELECT COALESCE(json_agg(data ORDER BY data::text), '[]'::json) FROM (SELECT row_to_json(stored) AS data FROM {quoted} AS stored) records"))
    return state


def start():
    global process
    process = subprocess.Popen([str(binary), "start"], env=env, stdout=log, stderr=log, start_new_session=True)
    for _attempt in range(150):
        if process.poll() is not None:
            raise AssertionError(f"Release exited; inspect {directory / 'server.log'}")
        try:
            request("/workers")
            return
        except OSError:
            time.sleep(.1)
    raise AssertionError("Management did not start")


def stop_group(child, force=False):
    try:
        os.killpg(child.pid, signal.SIGKILL if force else signal.SIGTERM)
    except ProcessLookupError:
        child.wait(timeout=5)
        return
    try:
        child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    child.wait(timeout=5)


def browser(verify_only=False):
    browser_env = dict(env, MANAGEMENT_OVERVIEW_VERIFY_ONLY="1" if verify_only else "0")
    with tempfile.TemporaryDirectory(prefix="management-overview-browser-") as profile:
        browser_env["MANAGEMENT_OVERVIEW_BROWSER_PROFILE"] = profile
        arguments = ["node", str(Path(__file__).with_name("overview_browser_smoke.mjs"))]
        browser_process = subprocess.Popen(arguments, env=browser_env, start_new_session=True)
        try:
            status = browser_process.wait(timeout=90)
            if status:
                raise subprocess.CalledProcessError(status, arguments)
        finally:
            stop_group(browser_process)
    evidence = json.loads((directory / "browser.json").read_text())
    actual = json.loads(sql("SELECT COALESCE(json_agg(event ORDER BY event.inserted_at DESC, event.id DESC), '[]'::json) FROM (SELECT id, actor, operation, inserted_at FROM management_audits ORDER BY inserted_at DESC, id DESC LIMIT 5) event"))
    assert evidence["event_ids"] == [event["id"] for event in actual], (evidence, actual)
    for observed, stored in zip(evidence["events"], actual, strict=True):
        assert {key: observed[key] for key in ["id", "actor", "operation"]} == {key: stored[key] for key in ["id", "actor", "operation"]}
        assert datetime.fromisoformat(observed["inserted_at"]).replace(tzinfo=None) == datetime.fromisoformat(stored["inserted_at"]).replace(tzinfo=None)
    assert evidence["worker_count"] == int(sql("SELECT count(*) FROM management_workers"))
    assert evidence["netman_count"] == int(sql("SELECT count(*) FROM management_netmans"))
    assert evidence["zone_count"] == int(sql("SELECT count(*) FROM management_zones WHERE deleted_at IS NULL"))
    assert evidence["profile_count"] == 13
    outcomes = json.loads(sql("SELECT COALESCE(json_agg(event ORDER BY event.inserted_at DESC, event.id DESC), '[]'::json) FROM (SELECT id, operation, CASE WHEN jsonb_typeof(result->'error')='object' AND result->'error' ? 'code' AND result->'error' ? 'message' THEN 'rejected' ELSE 'committed' END AS outcome, inserted_at FROM management_audits ORDER BY inserted_at DESC, id DESC LIMIT 100) event"))
    assert evidence["outcomes"] == [{key: event[key] for key in ["id", "outcome", "operation"]} for event in outcomes]
    return evidence


try:
    start()
    assert request("/workers") == [] and request("/netmans") == [] and request("/zones") == []
    zone_name = "overview.test."
    request("/commands/create_zone", {"name": zone_name, "records": [
        {"name": zone_name, "type": "SOA", "ttl": 300, "data": {"mname": "ns.overview.test.", "rname": "hostmaster.overview.test.", "serial": 1, "refresh": 3600, "retry": 600, "expire": 86400, "minimum": 300}},
        {"name": zone_name, "type": "NS", "ttl": 300, "data": {"host": "ns.overview.test."}},
        {"name": "ns.overview.test.", "type": "A", "ttl": 300, "data": {"address": "192.0.2.10"}}
    ]})
    for index in range(6):
        request("/commands/create_worker", {"id": f"overview-seed-{index}", "name": f"Overview Seed {index}", "expected_capabilities": ["dns"]})
    evidence = browser()
    before = database_state()
    (directory / "database-before.json").write_text(json.dumps(before, sort_keys=True))
    stop_group(process, force=True)
    start()
    assert database_state() == before, "Business data/audits changed across SIGKILL restart"
    assert browser(verify_only=True) == evidence
    assert database_state() == before, "Read-only Overview/catalog/events/refresh changed persisted data"
    print("PASS real PostgreSQL/Chromium Overview/Events: exact latest-five audits, committed/rejected command outcomes, read-only refresh/catalog/navigation and SIGKILL restart persistence", flush=True)
finally:
    if process:
        stop_group(process)
    log.close()
    print(f"Management overview artifacts: {directory}", flush=True)
