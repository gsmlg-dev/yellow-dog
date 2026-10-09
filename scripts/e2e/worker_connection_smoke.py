"""Real independent releases, disposable PostgreSQL, authenticated polling and DNS sockets."""
import json
import os
from pathlib import Path
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid

assert os.environ.get("YELLOW_DOG_PHASE1_PG_DATA_DIR"), "Disposable PostgreSQL required"
os.umask(0o077)
management_binary, worker_binary = (str(Path(arg).resolve()) for arg in sys.argv[1:])
evidence = Path(tempfile.mkdtemp(prefix="yellow-dog-worker-connection-"))
processes = {}
logs = []


def free_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


port, dns_port = free_port(), free_port()
base = f"http://127.0.0.1:{port}"
enrollment_path = evidence / "enrollment.json"
bootstrap_path = evidence / "bootstrap.toml"
env = dict(os.environ, RELEASE_DISTRIBUTION="none", YELLOW_DOG_MANAGEMENT_PORT=str(port),
           YELLOW_DOG_MANAGEMENT_BIND_ADDRESS="127.0.0.1", YELLOW_DOG_WORKER_SMOKE_BASE=base,
           YELLOW_DOG_WORKER_SMOKE_ENROLLMENT=str(enrollment_path),
           YELLOW_DOG_WORKER_SMOKE_BOOTSTRAP=str(bootstrap_path),
           YELLOW_DOG_WORKER_BOOTSTRAP=str(bootstrap_path),
           YELLOW_DOG_MANAGEMENT_ARTIFACT_DIRECTORY=str(evidence / "artifacts"),
           YELLOW_DOG_MANAGEMENT_BACKUP_DIRECTORY=str(evidence / "backups"))


def command(arguments, extra=None):
    result = subprocess.run(arguments, env=dict(env, **(extra or {})), stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, timeout=90)
    assert result.returncode == 0, result.stdout


def start(name, binary):
    log = open(evidence / f"{name}-{time.monotonic_ns()}.log", "w")
    logs.append(log)
    processes[name] = subprocess.Popen([binary, "start"], env=env, stdout=log, stderr=log,
                                       start_new_session=True)


def stop(name):
    process = processes.pop(name, None)
    if process:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=10)
        finally:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass


def request(path, body=None):
    headers = {}
    if body is not None:
        headers = {"Content-Type": "application/json", "Idempotency-Key": str(uuid.uuid4())}
    data = None if body is None else json.dumps(body).encode()
    with urllib.request.urlopen(urllib.request.Request(base + path, data=data, headers=headers), timeout=5) as response:
        if response.headers.get_content_type() == "text/html":
            return response.read().decode()
        return json.load(response).get("data", {})


def until(check, message, seconds=25):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        for name, process in processes.items():
            assert process.poll() is None, f"{name} exited; logs: {evidence}"
        try:
            if check():
                return
        except (OSError, ValueError, AssertionError):
            pass
        time.sleep(0.1)
    raise AssertionError(f"{message}; logs: {evidence}")


def mutate(operation, body):
    return request("/api/commands/" + operation, body)


def worker():
    return request("/api/workers/" + worker_id)


def publish(state, listen_port=dns_port):
    mutate("put_service", {"worker_id": worker_id, "expected_revision": worker()["revision"],
                           "id": "dns", "type": "dns", "desired_state": state,
                           "config": {"listen_address": "127.0.0.1", "port": listen_port}})
    target = mutate("confirm_target", {"worker_id": worker_id, "expected_revision": worker()["revision"]})
    return target["revision"]


def applied(revision, state):
    value = worker()
    return value["applied_revision"] == revision and value["reported_services"].get("dns", {}).get("state") == state


def read_exact(connection, size):
    result = b""
    while len(result) < size:
        packet = connection.recv(size - len(result))
        assert packet, "Unexpected DNS TCP EOF"
        result += packet
    return result


def dns_query(tcp=False):
    query = struct.pack("!6H", 1234, 0, 1, 0, 0, 0)
    query += b"".join(bytes([len(label)]) + label.encode() for label in "ns.worker-smoke.test".split("."))
    query += b"\x00" + struct.pack("!2H", 1, 1)
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM if tcp else socket.SOCK_DGRAM) as client:
        client.settimeout(1)
        if tcp:
            client.connect(("127.0.0.1", dns_port))
            client.sendall(struct.pack("!H", len(query)) + query)
            response = read_exact(client, struct.unpack("!H", read_exact(client, 2))[0])
        else:
            client.sendto(query, ("127.0.0.1", dns_port))
            response = client.recv(65535)
    identifier, flags, questions, answers, _, _ = struct.unpack("!6H", response[:12])
    assert identifier == 1234 and flags & 0x0400 and flags & 15 == 0 and questions == 1 and answers == 1
    assert b"\xc0\x00\x02\x2c" in response, "Expected A 192.0.2.44"


def stopped():
    try:
        with socket.create_connection(("127.0.0.1", dns_port), timeout=0.3):
            return False
    except OSError:
        try:
            dns_query()
            return False
        except OSError:
            return True


seed = '''
Application.put_env(:yellow_dog_management, :http_enabled, false)
Application.put_env(:yellow_dog_management, :task_scheduler_enabled, false)
{:ok, _} = Application.ensure_all_started(:yellow_dog_management)
alias YellowDog.Management.WorkerConnections
path = System.fetch_env!("YELLOW_DOG_WORKER_SMOKE_ENROLLMENT")
result = if File.exists?(path) do
  previous = path |> File.read!() |> Jason.decode!()
  {:ok, connection} = WorkerConnections.rotate(previous["worker"]["id"])
  connection
else
  {:ok, connection} = WorkerConnections.create("Connection smoke Worker")
  connection
end
File.write!(path, Jason.encode!(result))
bootstrap = WorkerConnections.bootstrap(result["worker"], result["token"], System.fetch_env!("YELLOW_DOG_WORKER_SMOKE_BASE"))
File.write!(System.fetch_env!("YELLOW_DOG_WORKER_SMOKE_BOOTSTRAP"), String.replace(bootstrap, "poll_interval_ms = 10000", "poll_interval_ms = 200"))
'''

try:
    command([management_binary, "migrate"])
    command([management_binary, "eval", seed])
    worker_id = json.loads(enrollment_path.read_text())["worker"]["id"]
    start("management", management_binary)
    until(lambda: worker()["connection_status"] == "not_yet_connected", "Management did not start")
    html = request("/management/servers")
    assert "worker[name]" in html and "worker[id]" not in html and "worker[profile_name]" not in html
    assert "Workers" in html and "server-selector-records" in html and "worker-bootstrap" not in html
    browser = subprocess.Popen(["node", "apps/yellow_dog_management/test/worker_connection_browser_smoke.mjs", base, str(evidence)],
                               env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
    processes["browser"] = browser
    try:
        browser_output, _ = browser.communicate(timeout=90)
        assert browser.returncode == 0, browser_output
        print(browser_output.strip(), flush=True)
    finally:
        stop("browser")
    start("worker", worker_binary)
    until(lambda: worker()["connection_status"] == "connected", "Worker did not authenticate")
    assert worker()["services"] == [] and worker()["reported_services"] == {}
    print("Name-only creation, real authenticated connection, no initial services: PASS", flush=True)

    zone = mutate("create_zone", {"name": "worker-smoke.test.", "records": [
        {"name": "worker-smoke.test.", "type": "SOA", "ttl": 300,
         "data": {"mname": "ns.worker-smoke.test.", "rname": "hostmaster.worker-smoke.test.",
                  "serial": 1, "refresh": 3600, "retry": 600, "expire": 86400, "minimum": 300}},
        {"name": "worker-smoke.test.", "type": "NS", "ttl": 300, "data": {"host": "ns.worker-smoke.test."}},
        {"name": "ns.worker-smoke.test.", "type": "A", "ttl": 300, "data": {"address": "192.0.2.44"}}]})
    version = mutate("confirm_zone", {"id": zone["id"], "expected_revision": zone["revision"]})
    service = mutate("put_service", {"worker_id": worker_id, "expected_revision": worker()["revision"],
                                     "id": "dns", "type": "dns", "desired_state": "stopped",
                                     "config": {"listen_address": "127.0.0.1", "port": dns_port}})
    mutate("assign", {"worker_id": worker_id, "expected_revision": worker()["revision"],
                      "service_id": service["id"], "resource_version_id": version["id"]})
    running_revision = publish("running")
    until(lambda: applied(running_revision, "running"), "DNS running state not reported")
    dns_query()
    dns_query(tcp=True)
    print("Confirmed target delivered; actual DNS UDP/TCP answer: PASS", flush=True)

    stop("management")
    dns_query()
    stop("worker")
    start("worker", worker_binary)
    until(lambda: dns_query(tcp=True) is None, "Offline snapshot did not restore DNS")
    start("management", management_binary)
    until(lambda: worker()["connection_status"] == "connected" and applied(running_revision, "running"), "Worker did not reconnect")
    print("Management outage, offline Worker restart, committed runtime and reconnect: PASS", flush=True)

    stopped_revision = publish("stopped")
    until(lambda: applied(stopped_revision, "stopped") and stopped(), "DNS did not stop")
    stop("worker")
    start("worker", worker_binary)
    until(lambda: applied(stopped_revision, "stopped") and stopped(), "Stopped state did not survive restart")
    print("DNS actual socket shutdown and persisted stopped state: PASS", flush=True)

    command([management_binary, "eval", seed])
    until(lambda: worker()["connection_status"] == "not_yet_connected", "Token reset retained a connection")
    time.sleep(0.5)
    assert worker()["connection_status"] == "not_yet_connected", "Revoked token still authenticates"
    stop("worker")
    start("worker", worker_binary)
    until(lambda: worker()["connection_status"] == "connected" and applied(stopped_revision, "stopped"), "New token did not reconnect")
    print("Token reset rejects previous client; new connection configuration works: PASS", flush=True)

    with socket.socket() as occupied:
        occupied.bind(("127.0.0.1", 0))
        occupied.listen()
        bad_revision = publish("running", occupied.getsockname()[1])
        until(lambda: worker()["apply_error"] == "apply_failed", "Failed configuration not reported")
        assert applied(stopped_revision, "stopped") and stopped()
        assert worker()["applied_revision"] < bad_revision
    print("Failed target preserves last committed stopped runtime and revision: PASS", flush=True)
    (evidence / "result.json").write_text(json.dumps({"result": "PASS", "worker_id": worker_id,
                                                   "running_revision": running_revision,
                                                   "stopped_revision": stopped_revision}))
    print(f"Worker connection smoke: PASS; evidence: {evidence}", flush=True)
finally:
    stop("browser")
    stop("worker")
    stop("management")
    for log in logs:
        log.close()
    enrollment_path.unlink(missing_ok=True)
    bootstrap_path.unlink(missing_ok=True)
