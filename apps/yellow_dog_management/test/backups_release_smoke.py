"""Real backup queue and consistent snapshot checks, restricted to disposable PostgreSQL."""
import base64
from concurrent.futures import ThreadPoolExecutor
import gzip
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid

binary = Path(sys.argv[1]).resolve()
assert os.environ.get("YELLOW_DOG_PHASE1_PG_DATA_DIR"), "Use disposable PG helper"
directory = Path(tempfile.mkdtemp(prefix="management-backups-release-"))
database = base64.b64decode((Path(__file__).parent / "fixtures/geoip/GeoIP2-City-Test.mmdb.base64").read_text())
compressed = gzip.compress(database)
process = None
writer_stop = threading.Event()
writer_errors = []
writer_count = []


class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", str(len(compressed)))
        self.end_headers()
        self.wfile.write(compressed)

    def log_message(self, *_args):
        pass


fixture = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
threading.Thread(target=fixture.serve_forever, daemon=True).start()
with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    port = listener.getsockname()[1]
base = f"http://127.0.0.1:{port}"
env = dict(os.environ, RELEASE_DISTRIBUTION="none", YELLOW_DOG_MANAGEMENT_BIND_ADDRESS="127.0.0.1",
           YELLOW_DOG_MANAGEMENT_PORT=str(port), YELLOW_DOG_MANAGEMENT_BACKUP_DIRECTORY=str(directory / "backups"),
           YELLOW_DOG_MANAGEMENT_ARTIFACT_DIRECTORY=str(directory / "artifacts"),
           YELLOW_DOG_MANAGEMENT_GEOIP_CITY_URL=f"http://127.0.0.1:{fixture.server_port}/city", MANAGEMENT_UI_URL=base)
for name in ["YELLOW_DOG_MANAGEMENT_OPERATOR_TOKEN", "YELLOW_DOG_MANAGEMENT_GEOIP_CITY_PATH", "YELLOW_DOG_MANAGEMENT_GEOIP_COUNTRY_PATH"]:
    env.pop(name, None)
log = (directory / "server.log").open("w")


def request(path, body=None, key=None, raw=False, expected=200):
    headers = {}
    if body is not None:
        headers = {"Content-Type": "application/json", "Idempotency-Key": key or str(uuid.uuid4())}
    payload = None if body is None else json.dumps(body).encode()
    try:
        response = urllib.request.urlopen(urllib.request.Request(base + "/api" + path, data=payload, headers=headers), timeout=15)
    except urllib.error.HTTPError as error:
        response = error
    payload = response.read()
    assert response.status == expected, (path, response.status, payload)
    return payload if raw else json.loads(payload).get("data")


def wait(check, message):
    for _attempt in range(300):
        if check():
            return
        if process and process.poll() is not None:
            raise AssertionError(f"Release exited; inspect {directory / 'server.log'}")
        time.sleep(.1)
    raise AssertionError(message)


def start():
    global process
    process = subprocess.Popen([str(binary), "start"], env=env, stdout=log, stderr=log)
    def ready():
        try:
            request("/backups")
            return True
        except OSError:
            return False
    wait(ready, "Management did not expose backup API")


def writer():
    try:
        while not writer_stop.is_set():
            identity = f"writer-{len(writer_count)}"
            request("/commands/create_worker", {"id": identity, "name": identity, "expected_capabilities": ["dns"]})
            writer_count.append(identity)
            time.sleep(.01)
    except Exception as error:
        writer_errors.append(error)


try:
    start()
    assert request("/backups") == []
    request("/commands/create_worker", {"id": "before-backup", "name": "Before Backup", "expected_capabilities": ["dns"]})
    queued = request("/commands/run_task", {"key": "ip_city"})
    wait(lambda: request("/tasks/ip_city/jobs")[0]["state"] == "completed", "GeoIP artifact seed did not complete")
    writer_thread = threading.Thread(target=writer)
    writer_thread.start()
    key = str(uuid.uuid4())
    with ThreadPoolExecutor(max_workers=4) as pool:
        created = list(pool.map(lambda _index: request("/commands/create_backup", {"label": "consistent snapshot"}, key), range(4)))
    assert len({item["id"] for item in created}) == 1
    backup_id = created[0]["id"]
    wait(lambda: request(f"/backups/{backup_id}")["state"] == "ready", "Native PG backup did not become ready")
    writer_stop.set()
    writer_thread.join(timeout=10)
    assert writer_count and not writer_errors, writer_errors
    backup = request(f"/backups/{backup_id}")
    proof = request(f"/backups/{backup_id}/verify")
    assert proof["valid"] and proof["level"] == "byte_integrity" and proof["artifact_count"] == 1
    archive = request(f"/backups/{backup_id}/download", raw=True)
    assert hashlib.sha256(archive).hexdigest() == backup["digest"]
    package = directory / "backups" / backup_id
    manifest = json.loads((package / "manifest.json").read_text())
    assert manifest["row_count"] == sum(manifest["tables"].values())
    assert len(manifest["artifacts"]) == 1
    saved_artifact = package / manifest["artifacts"][0]["path"]
    assert saved_artifact.read_bytes() == database
    request("/commands/create_worker", {"id": "after-backup", "name": "Not in Snapshot", "expected_capabilities": ["dns"]})

    restored_name = f"backup_check_{uuid.uuid4().hex}"
    pg_env = dict(env, PGHOST="127.0.0.1", PGPORT=os.environ["YELLOW_DOG_PHASE1_PG_PORT"], PGUSER="postgres", PGDATABASE=restored_name)
    pg_env.pop("PGPASSWORD", None)
    subprocess.run(["createdb", restored_name], env=pg_env, check=True)
    subprocess.run(["pg_restore", "--single-transaction", "--exit-on-error", "--no-owner", "--no-privileges", "--dbname", restored_name, str(package / "database.dump")], env=pg_env, check=True)
    def sql(query):
        return subprocess.check_output(["psql", "-XAt", "-c", query], env=pg_env, text=True).strip()
    for table, expected in manifest["tables"].items():
        schema, name = table.split(".", 1)
        assert int(sql(f'SELECT count(*) FROM "{schema}"."{name}"')) == expected, table
    assert sql("SELECT name FROM management_workers WHERE id='before-backup'") == "Before Backup"
    assert sql("SELECT count(*) FROM management_workers WHERE id='after-backup'") == "0"
    assert sql("SELECT count(*) FROM pg_trigger WHERE tgname='management_task_receipts_immutable' AND tgenabled='O'") == "1"
    assert sql("SELECT state FROM management_backups WHERE id='" + backup_id + "'") == "pending"
    assert "public.schema_migrations" in manifest["tables"] and "management_jobs.oban_jobs" in manifest["tables"]
    print("PASS real PG snapshot restores into isolated DB: concurrent writer counts, precompletion capture, schema/queue/immutable triggers and artifact bytes", flush=True)

    source_pg_env = dict(pg_env, PGDATABASE="yellow_dog_phase1")
    def source_sql(query):
        return subprocess.check_output(["psql", "-XAt", "-v", "ON_ERROR_STOP=1", "-c", query], env=source_pg_env, text=True).strip()
    source_sql("CREATE FUNCTION backup_smoke_fail_ready() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.label='publication-fault' AND NEW.state='ready' THEN RAISE EXCEPTION 'injected catalog publication failure'; END IF; RETURN NEW; END $$; CREATE TRIGGER backup_smoke_fail_ready BEFORE UPDATE ON management_backups FOR EACH ROW EXECUTE FUNCTION backup_smoke_fail_ready()")
    faulted = request("/commands/create_backup", {"label": "publication-fault"})
    fault_id = faulted["id"]
    wait(lambda: (directory / "backups" / fault_id / "package.tar").exists() and request(f"/backups/{fault_id}")["error"], "Publication fault was not retained")
    assert request(f"/backups/{fault_id}")["state"] == "pending"
    published = (directory / "backups" / fault_id / "package.tar").read_bytes()
    source_sql("DROP TRIGGER backup_smoke_fail_ready ON management_backups; DROP FUNCTION backup_smoke_fail_ready()")
    source_sql("UPDATE management_jobs.oban_jobs SET scheduled_at=now() AT TIME ZONE 'UTC' WHERE id=(SELECT job_id FROM management_backups WHERE id='" + fault_id + "') AND state='retryable'")
    wait(lambda: request(f"/backups/{fault_id}")["state"] == "ready", "Published package was not adopted by a genuine retry")
    assert request(f"/backups/{fault_id}")["digest"] == hashlib.sha256(published).hexdigest()
    assert (directory / "backups" / fault_id / "package.tar").read_bytes() == published
    assert request(f"/backups/{fault_id}/verify")["valid"]
    print("PASS publication fault: real failed PG commit leaves no ready claim; retry verifies/adopts existing immutable package without overwrite", flush=True)

    original_dump = (package / "database.dump").read_bytes()
    os.chmod(package / "database.dump", 0o600)
    with (package / "database.dump").open("ab") as dump:
        dump.write(b"corrupt")
    request(f"/backups/{backup_id}/verify", expected=422)
    (package / "database.dump").write_bytes(original_dump)
    os.chmod(package / "database.dump", 0o400)
    assert request(f"/backups/{backup_id}/verify")["valid"]
    subprocess.run(["node", str(Path(__file__).with_name("backups_browser_smoke.mjs"))], env=env, check=True, timeout=90)
    process.kill()
    process.wait(timeout=15)
    start()
    assert request(f"/backups/{backup_id}") == backup
    assert request(f"/backups/{backup_id}/download", raw=True) == archive
    assert request(f"/backups/{backup_id}/verify")["valid"]
    assert (directory / "artifacts" / saved_artifact.name).read_bytes() == database
    print("PASS Management backup create/verify/download/delete/browser and SIGKILL catalog/package persistence; live destructive restore remains unimplemented", flush=True)
finally:
    writer_stop.set()
    if process and process.poll() is None:
        process.terminate()
        process.wait(timeout=15)
    fixture.shutdown()
    fixture.server_close()
    log.close()
    print(f"Management backup artifacts: {directory}", flush=True)
