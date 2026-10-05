"""Catalog-label business acceptance with disposable PostgreSQL and real Chromium."""
from concurrent.futures import ThreadPoolExecutor
import hashlib
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

assert os.environ.get("YELLOW_DOG_PHASE1_PG_DATA_DIR"), "Use disposable PG helper"
binary = Path(sys.argv[1]).resolve()
directory = Path(tempfile.mkdtemp(prefix="management-worker-profiles-release-"))
with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    port = listener.getsockname()[1]
base = f"http://127.0.0.1:{port}"
env = dict(os.environ, RELEASE_DISTRIBUTION="none", YELLOW_DOG_MANAGEMENT_BIND_ADDRESS="127.0.0.1",
           YELLOW_DOG_MANAGEMENT_PORT=str(port), MANAGEMENT_UI_URL=base,
           MANAGEMENT_WORKER_PROFILES_EVIDENCE=str(directory / "browser.json"),
           YELLOW_DOG_MANAGEMENT_ARTIFACT_DIRECTORY=str(directory / "artifacts"),
           YELLOW_DOG_MANAGEMENT_BACKUP_DIRECTORY=str(directory / "backups"))
env.pop("YELLOW_DOG_MANAGEMENT_OPERATOR_TOKEN", None)
process = None
log = (directory / "server.log").open("w")
pg_env = dict(env, PGHOST="127.0.0.1", PGPORT=os.environ["YELLOW_DOG_PHASE1_PG_PORT"],
              PGUSER="postgres", PGDATABASE="yellow_dog_phase1")
pg_env.pop("PGPASSWORD", None)


def request(path, body=None, expected=200, raw=False, key=None):
    headers = {} if body is None else {"Content-Type": "application/json", "Idempotency-Key": key or str(uuid.uuid4())}
    payload = None if body is None else json.dumps(body).encode()
    try:
        response = urllib.request.urlopen(urllib.request.Request(base + "/api" + path, data=payload, headers=headers), timeout=15)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        payload = response.read()
        assert response.status == expected, (path, response.status, payload)
        return payload if raw else json.loads(payload).get("data", json.loads(payload).get("error"))


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
    browser_env = dict(env, MANAGEMENT_WORKER_PROFILES_VERIFY_ONLY="1" if verify_only else "0")
    with tempfile.TemporaryDirectory(prefix="management-worker-profiles-browser-") as profile:
        browser_env["MANAGEMENT_WORKER_PROFILES_BROWSER_PROFILE"] = profile
        arguments = ["node", str(Path(__file__).with_name("worker_profiles_browser_smoke.mjs"))]
        browser_process = subprocess.Popen(arguments, env=browser_env, start_new_session=True)
        try:
            status = browser_process.wait(timeout=120)
            if status:
                raise subprocess.CalledProcessError(status, arguments)
        finally:
            stop_group(browser_process)


try:
    start()
    assert request("/workers") == []
    worker = request("/commands/create_worker", {"id": "profile-fixture", "name": "Profile Fixture", "expected_capabilities": ["dns"], "profile_name": "dns_only"})
    zone = request("/commands/create_zone", {"name": "worker-profile.test.", "records": [
        {"name": "worker-profile.test.", "type": "SOA", "ttl": 300, "data": {"mname": "ns.worker-profile.test.", "rname": "hostmaster.worker-profile.test.", "serial": 1, "refresh": 3600, "retry": 600, "expire": 86400, "minimum": 300}},
        {"name": "worker-profile.test.", "type": "NS", "ttl": 300, "data": {"host": "ns.worker-profile.test."}},
        {"name": "ns.worker-profile.test.", "type": "A", "ttl": 300, "data": {"address": "192.0.2.10"}}
    ]})
    version = request("/commands/confirm_zone", {"id": zone["id"], "expected_revision": zone["revision"]})
    service = request("/commands/put_service", {"worker_id": worker["id"], "id": "dns", "type": "dns", "desired_state": "stopped", "config": {"listen_address": "127.0.0.1", "port": 5300}, "expected_revision": worker["revision"]})
    assignment = request("/commands/assign", {"worker_id": worker["id"], "service_id": service["id"], "resource_version_id": version["id"], "expected_revision": service["worker_revision"]})
    request("/commands/confirm_target", {"worker_id": worker["id"], "expected_revision": assignment["worker_revision"]})
    target = request("/workers/profile-fixture/targets/1")
    export = request("/workers/profile-fixture/targets/1/export", raw=True)
    fixture = request("/workers/profile-fixture")

    concurrent = request("/commands/create_worker", {"id": "profile-concurrent", "name": "Concurrent", "expected_capabilities": ["dns"]})
    assert concurrent["profile_name"] == "custom"
    def attempt(profile):
        payload = {"id": concurrent["id"], "expected_revision": concurrent["revision"], "profile_name": profile, "name": profile}
        headers = {"Content-Type": "application/json", "Idempotency-Key": str(uuid.uuid4())}
        try:
            response = urllib.request.urlopen(urllib.request.Request(base + "/api/commands/update_worker", data=json.dumps(payload).encode(), headers=headers), timeout=15)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            return profile, response.status, json.load(response)
    with ThreadPoolExecutor(max_workers=2) as pool:
        outcomes = list(pool.map(attempt, ["cloud_dns", "local_network"]))
    assert sorted(status for _profile, status, _body in outcomes) == [200, 409], outcomes
    current = request("/workers/profile-concurrent")
    winner = next(profile for profile, status, _body in outcomes if status == 200)
    loser = next(profile for profile, status, _body in outcomes if status == 409)
    assert current["profile_name"] == current["name"] == winner
    retry = request("/commands/update_worker", {"id": current["id"], "expected_revision": current["revision"], "profile_name": loser})
    assert retry["profile_name"] == loser and retry["name"] == winner
    rejected_sql = subprocess.run(["psql", "-XAt", "-v", "ON_ERROR_STOP=1", "-c", "UPDATE management_workers SET profile_name='invalid' WHERE id='profile-fixture'"], env=pg_env, text=True, capture_output=True)
    assert rejected_sql.returncode != 0 and "management_worker_catalog_profile" in rejected_sql.stderr
    assert request("/workers/profile-fixture") == fixture
    print("PASS real independent PG/HTTP profile CAS: one commit/one conflict, retry preserves concurrent name; native catalog constraint rejects invalid profile", flush=True)

    browser()
    edited = request("/workers/profile-fixture")
    for field in ["services", "assignments", "expected_capabilities", "actual_state", "status"]:
        assert edited[field] == fixture[field], field
    assert edited["profile_name"] == "dhcp_only"
    assert request("/workers/profile-fixture/targets/1") == target
    assert request("/workers/profile-fixture/targets/1/export", raw=True) == export
    assert request(f"/zones/{zone['id']}/versions") == [version]
    before = database_state()
    (directory / "database-before.json").write_text(json.dumps(before, sort_keys=True))
    print("Immutable export sha256:", hashlib.sha256(export).hexdigest(), flush=True)
    stop_group(process, force=True)
    start()
    assert database_state() == before, "Business rows/history changed across SIGKILL restart"
    assert request("/workers/profile-fixture") == edited
    assert request("/workers/profile-fixture/targets/1/export", raw=True) == export
    browser(verify_only=True)
    assert database_state() == before, "Read-only browser verification mutated persisted data"
    print("PASS real Chromium profile registration/edit/reset/CAS/rejection/scoped identity plus SIGKILL metadata/history/export persistence; catalog labels execute no Worker service", flush=True)
finally:
    if process:
        stop_group(process)
    log.close()
    print(f"Management Worker profile artifacts: {directory}", flush=True)
