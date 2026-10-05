"""Real Management task queue, download, failure and restart checks on disposable PG."""
import base64
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
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
assert os.environ.get("YELLOW_DOG_PHASE1_PG_DATA_DIR"), "Use disposable PostgreSQL helper"
directory = Path(tempfile.mkdtemp(prefix="management-tasks-release-"))
contents = base64.b64decode((Path(__file__).parent / "fixtures/geoip/GeoIP2-City-Test.mmdb.base64").read_text())
digest = hashlib.sha256(contents).hexdigest()
compressed = gzip.compress(contents)
downloads = []
process = None


class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        downloads.append(self.path)
        body = compressed if self.path == "/city" else b"source unavailable"
        self.send_response(200 if self.path == "/city" else 503)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


fixture = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
threading.Thread(target=fixture.serve_forever, daemon=True).start()
with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    port = listener.getsockname()[1]
base = f"http://127.0.0.1:{port}"
env = dict(os.environ, RELEASE_DISTRIBUTION="none", YELLOW_DOG_MANAGEMENT_BIND_ADDRESS="0.0.0.0",
           YELLOW_DOG_MANAGEMENT_PORT=str(port), YELLOW_DOG_MANAGEMENT_ARTIFACT_DIRECTORY=str(directory / "artifacts"),
           YELLOW_DOG_MANAGEMENT_GEOIP_CITY_URL=f"http://127.0.0.1:{fixture.server_port}/city",
           YELLOW_DOG_MANAGEMENT_GEOIP_COUNTRY_URL=f"http://127.0.0.1:{fixture.server_port}/country",
           MANAGEMENT_UI_URL=base)
for variable in ["YELLOW_DOG_MANAGEMENT_OPERATOR_TOKEN", "YELLOW_DOG_MANAGEMENT_GEOIP_CITY_PATH", "YELLOW_DOG_MANAGEMENT_GEOIP_COUNTRY_PATH"]:
    env.pop(variable, None)
log = (directory / "server.log").open("w")


def request(path, body=None, key=None, expected=200):
    headers = {}
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers = {"Content-Type": "application/json", "Idempotency-Key": key or str(uuid.uuid4())}
    try:
        response = urllib.request.urlopen(urllib.request.Request(base + path, data=data, headers=headers), timeout=5)
    except urllib.error.HTTPError as error:
        response = error
    payload = response.read()
    statuses = expected if isinstance(expected, tuple) else (expected,)
    assert response.status in statuses, (path, response.status, payload)
    return json.loads(payload).get("data")


def wait(check, message):
    for _attempt in range(200):
        if check():
            return
        if process and process.poll() is not None:
            raise AssertionError(f"Management exited; inspect {directory / 'server.log'}")
        time.sleep(.1)
    raise AssertionError(message)


def start():
    global process
    process = subprocess.Popen([str(binary), "start"], env=env, stdout=log, stderr=log)
    def ready():
        try:
            request("/api/tasks")
            return True
        except OSError:
            return False
    wait(ready, "Management did not start")
    own = [line for line in subprocess.check_output(["ss", "-lntup"], text=True).splitlines() if f"pid={process.pid}," in line]
    assert len(own) == 1 and f"0.0.0.0:{port}" in own[0], own


def job(job_id):
    return next(item for item in request("/api/task-history") if item["id"] == job_id)


try:
    start()
    assert request("/api/task-history") == []
    assert all(not task["enabled"] for task in request("/api/tasks"))
    key = str(uuid.uuid4())
    def enqueue(_index):
        return request("/api/commands/run_task", {"key": "ip_city"}, key)
    with ThreadPoolExecutor(max_workers=4) as pool:
        queued = list(pool.map(enqueue, range(4)))
    assert len({item["id"] for item in queued}) == 1, queued
    city_id = queued[0]["id"]
    wait(lambda: job(city_id)["state"] == "completed", "Real synchronization job did not complete")
    assert job(city_id)["result"]["digest"] == digest
    assert downloads == ["/city"], downloads
    artifact = directory / "artifacts" / f"{digest}.mmdb"
    assert artifact.read_bytes() == contents
    assert not artifact.stat().st_mode & 0o222
    def edit_schedule(_index):
        return request("/api/commands/update_task", {"key": "ip_city", "expected_revision": 1,
                                                   "enabled": False, "cron": "*/10 * * * *"}, expected=(200, 409))
    with ThreadPoolExecutor(max_workers=2) as pool:
        edited = list(pool.map(edit_schedule, range(2)))
    assert sum(result is not None for result in edited) == 1, edited
    failed = request("/api/commands/run_task", {"key": "ip_country"})
    wait(lambda: job(failed["id"])["state"] == "retryable", "Failed source was not retained for retry")
    assert job(failed["id"])["errors"] and job(failed["id"])["result"] is None
    assert request("/api/tasks/mac")["status"] == "unavailable"
    request("/api/commands/run_task", {"key": "mac"}, expected=422)
    subprocess.run(["node", str(Path(__file__).with_name("tasks_browser_smoke.mjs"))], env=env, check=True, timeout=90)
    now = datetime.now(timezone.utc)
    if now.second >= 45:
        time.sleep(60 - now.second)
        now = datetime.now(timezone.utc)
    schedule = request("/api/tasks/ip_city")
    cron = f"{now.minute} {now.hour} {now.day} {now.month} *"
    schedule = request("/api/commands/update_task", {"key": "ip_city", "expected_revision": schedule["revision"],
                                                   "enabled": True, "cron": cron})
    prior_ids = {item["id"] for item in request("/api/task-history")}
    process.terminate()
    process.wait(timeout=15)
    start()
    wait(lambda: any(item["id"] not in prior_ids and item["task_key"] == "ip_city" and item["state"] == "completed"
                     for item in request("/api/task-history")), "Real scheduler did not enqueue its due occurrence")
    request("/api/commands/update_task", {"key": "ip_city", "expected_revision": schedule["revision"],
                                         "enabled": False, "cron": cron})
    history = request("/api/task-history")
    schedule = request("/api/tasks/ip_city")
    process.kill()
    process.wait(timeout=15)
    start()
    recovered = {item["id"]: item for item in request("/api/task-history")}
    for previous in history:
        current = recovered[previous["id"]]
        assert current["result"] == previous["result"]
        assert current["inserted_at"] == previous["inserted_at"]
        if previous["state"] == "completed":
            assert current == previous
        else:
            assert all(error in current["errors"] for error in previous["errors"])
    assert request("/api/tasks/ip_city")["revision"] == schedule["revision"]
    subprocess.run(["node", str(Path(__file__).with_name("tasks_browser_smoke.mjs")), "--restart-check"], env=env, check=True, timeout=60)
    assert artifact.read_bytes() == contents
    print("Management tasks: real queue/download/error/scheduler, concurrent idempotency/CAS, browser and SIGKILL recovery passed", flush=True)
finally:
    if process and process.poll() is None:
        process.terminate()
        process.wait(timeout=15)
    fixture.shutdown()
    fixture.server_close()
    log.close()
    print(f"Management task artifacts: {directory}", flush=True)
