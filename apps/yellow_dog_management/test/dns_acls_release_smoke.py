"""Desired ACL data acceptance; no Worker ACL execution is claimed."""
from concurrent.futures import ThreadPoolExecutor
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
directory = Path(tempfile.mkdtemp(prefix="management-dns-acls-release-"))
with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    port = listener.getsockname()[1]
base = f"http://127.0.0.1:{port}"
env = dict(os.environ, RELEASE_DISTRIBUTION="none", MANAGEMENT_UI_URL=base,
           YELLOW_DOG_MANAGEMENT_BIND_ADDRESS="127.0.0.1", YELLOW_DOG_MANAGEMENT_PORT=str(port),
           YELLOW_DOG_MANAGEMENT_ARTIFACT_DIRECTORY=str(directory / "artifacts"),
           YELLOW_DOG_MANAGEMENT_BACKUP_DIRECTORY=str(directory / "backups"),
           MANAGEMENT_DNS_ACLS_EVIDENCE=str(directory / "browser.json"))
env.pop("YELLOW_DOG_MANAGEMENT_OPERATOR_TOKEN", None)
pg_env = dict(env, PGHOST="127.0.0.1", PGPORT=env["YELLOW_DOG_PHASE1_PG_PORT"],
              PGUSER="postgres", PGDATABASE="yellow_dog_phase1")
pg_env.pop("PGPASSWORD", None)
process = None
log = (directory / "server.log").open("w")


def request(path, body=None, expected=200, raw=False):
    headers = {} if body is None else {"Content-Type": "application/json", "Idempotency-Key": str(uuid.uuid4())}
    payload = None if body is None else json.dumps(body).encode()
    try:
        response = urllib.request.urlopen(urllib.request.Request(base + "/api" + path, data=payload, headers=headers), timeout=15)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        payload = response.read()
        assert response.status == expected, (path, response.status, payload)
        if raw:
            return payload
        result = json.loads(payload)
        return result["data"] if expected == 200 else result["error"]


def sql(query):
    return subprocess.check_output(["psql", "-XAt", "-v", "ON_ERROR_STOP=1", "-c", query], env=pg_env, text=True).strip()


def snapshot():
    tables = json.loads(sql("SELECT json_agg(json_build_array(schemaname,tablename) ORDER BY schemaname,tablename) FROM pg_tables WHERE schemaname IN ('public','management_jobs') AND NOT (schemaname='management_jobs' AND tablename='oban_peers')"))
    result = {}
    for schema, table in tables:
        quoted = '.'.join('"' + value.replace('"', '""') + '"' for value in [schema, table])
        result[f"{schema}.{table}"] = json.loads(sql(f"SELECT COALESCE(json_agg(data ORDER BY data::text),'[]'::json) FROM (SELECT row_to_json(stored) data FROM {quoted} stored) records"))
    return result


def stop(child, force=False):
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


def start():
    global process
    process = subprocess.Popen([str(binary), "start"], env=env, stdout=log, stderr=log, start_new_session=True)
    for attempt in range(150):
        assert process.poll() is None, f"Release exited: {directory / 'server.log'}"
        try:
            request("/workers")
            return
        except OSError:
            time.sleep(.1)
    raise AssertionError("Management startup timed out")


def browser(verify_only=False):
    with tempfile.TemporaryDirectory(prefix="management-dns-acls-browser-") as profile:
        browser_env = dict(env, MANAGEMENT_DNS_ACLS_BROWSER_PROFILE=profile,
                           MANAGEMENT_DNS_ACLS_VERIFY_ONLY="1" if verify_only else "0")
        arguments = ["node", str(Path(__file__).with_name("dns_acls_browser_smoke.mjs"))]
        child = subprocess.Popen(arguments, env=browser_env, start_new_session=True)
        try:
            assert child.wait(timeout=150) == 0, "Chromium acceptance failed"
        finally:
            stop(child)


def create_worker(identifier):
    return request("/commands/create_worker", {"id": identifier, "name": identifier, "expected_capabilities": ["dns"]})


def create_service(worker, identifier, port):
    return request("/commands/put_service", {"worker_id": worker["id"], "id": identifier,
                   "type": "dns", "desired_state": "stopped", "config": {"listen_address": "127.0.0.1", "port": port},
                   "expected_revision": worker["revision"]})


try:
    start()
    assert request("/workers") == []
    worker = create_worker("acl-fixture")
    service = create_service(worker, "dns", 5300)
    worker = request("/workers/acl-fixture")
    second = create_service(worker, "dns-secondary", 5301)
    other = create_worker("acl-other")
    other_service = create_service(other, "dns", 5302)
    env.update(MANAGEMENT_DNS_ACLS_SERVICE_ID=service["id"], MANAGEMENT_DNS_ACLS_SECOND_SERVICE_ID=second["id"],
               MANAGEMENT_DNS_ACLS_OTHER_SERVICE_ID=other_service["id"])
    zone = request("/commands/create_zone", {"name": "acl.test.", "records": [
        {"name": "acl.test.", "type": "SOA", "ttl": 300, "data": {"mname": "ns.acl.test.", "rname": "hostmaster.acl.test.", "serial": 1, "refresh": 3600, "retry": 600, "expire": 86400, "minimum": 300}},
        {"name": "acl.test.", "type": "NS", "ttl": 300, "data": {"host": "ns.acl.test."}},
        {"name": "ns.acl.test.", "type": "A", "ttl": 300, "data": {"address": "192.0.2.10"}}
    ]})
    version = request("/commands/confirm_zone", {"id": zone["id"], "expected_revision": zone["revision"]})
    worker = request("/workers/acl-fixture")
    assignment = request("/commands/assign", {"worker_id": worker["id"], "service_id": service["id"], "resource_version_id": version["id"], "expected_revision": worker["revision"]})
    request("/commands/confirm_target", {"worker_id": worker["id"], "expected_revision": assignment["worker_revision"]})
    scope = {"worker_id": worker["id"], "service_id": service["id"]}
    concurrent = request("/commands/create_dns_acl", dict(scope, name="concurrent", description="Concurrent edits", rules=[{"action": "allow", "kind": "networks", "networks": ["192.0.2.0/24"]}]))

    def attempt(action):
        body = dict(scope, id=concurrent["id"], expected_revision=concurrent["revision"], name=f"concurrent-{action}", description="Concurrent edits", rules=[{"action": action, "kind": "networks", "networks": ["192.0.2.0/24"]}])
        headers = {"Content-Type": "application/json", "Idempotency-Key": str(uuid.uuid4())}
        try:
            response = urllib.request.urlopen(urllib.request.Request(base + "/api/commands/update_dns_acl", data=json.dumps(body).encode(), headers=headers), timeout=15)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            return response.status, json.load(response)
    with ThreadPoolExecutor(max_workers=2) as pool:
        outcomes = list(pool.map(attempt, ["allow", "deny"]))
    assert sorted(status for status, result in outcomes) == [200, 409], outcomes
    winner = next(result["data"] for status, result in outcomes if status == 200)
    loser = next(result["error"] for status, result in outcomes if status == 409)
    assert loser["code"] == "revision_conflict", loser
    assert winner["revision"] == concurrent["revision"] + 1
    assert request(f"/workers/{worker['id']}/dns-services/{service['id']}/acls/{concurrent['id']}") == winner
    for change, constraint in [
        ("rules=ARRAY['{\"action\":\"invalid\",\"kind\":\"any\"}'::jsonb]", "management_dns_acl_rules"),
        ("rules=ARRAY['{\"action\":\"allow\",\"kind\":\"networks\",\"networks\":[\"not-a-cidr\"]}'::jsonb]", "management_dns_acl_rules"),
        ("rules=ARRAY['{\"action\":\"allow\",\"kind\":\"countries\",\"countries\":[null]}'::jsonb]", "management_dns_acl_rules"),
        ("description=repeat('界',256)", "management_dns_acl_description"),
    ]:
        rejected = subprocess.run(["psql", "-XAt", "-v", "ON_ERROR_STOP=1", "-c", f"UPDATE management_dns_acls SET {change} WHERE id='{concurrent['id']}'"], env=pg_env, text=True, capture_output=True)
        assert rejected.returncode != 0 and constraint in rejected.stderr, rejected.stderr
    before = snapshot()
    target = request("/workers/acl-fixture/targets/1")
    exported = request("/workers/acl-fixture/targets/1/export", raw=True)
    print("PASS independent HTTP/PG ACL CAS: one commit/one conflict; native action/CIDR validation", flush=True)
    browser()
    after = snapshot()
    mutable_tables = {"public.management_dns_acls", "public.management_audits", "public.management_idempotency"}
    assert {key: value for key, value in before.items() if key not in mutable_tables} == {key: value for key, value in after.items() if key not in mutable_tables}
    assert request("/workers/acl-fixture/targets/1") == target
    assert request("/workers/acl-fixture/targets/1/export", raw=True) == exported
    (directory / "database-before-restart.json").write_text(json.dumps(after, sort_keys=True))
    stop(process, force=True)
    start()
    assert snapshot() == after
    browser(verify_only=True)
    assert snapshot() == after, "Read-only replay mutated persisted data"
    assert request("/workers/acl-fixture/targets/1/export", raw=True) == exported
    print("PASS real Chromium desired ACL CRUD/scoping/CAS/deletion plus SIGKILL data/history/export persistence; enforcement remains unimplemented", flush=True)
finally:
    if process:
        stop(process)
    log.close()
    print(f"DNS ACL evidence: {directory}", flush=True)
