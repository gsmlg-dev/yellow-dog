"""Real independent releases, disposable PostgreSQL, the Worker WebSocket channel and DNS sockets."""
import base64
import http.client
import json
import os
from pathlib import Path
import signal
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import time
import tomllib
import urllib.request
import uuid

assert os.environ.get("YELLOW_DOG_PHASE1_PG_DATA_DIR"), "Disposable PostgreSQL required"
os.umask(0o077)
management_binary, worker_binary = (str(Path(arg).resolve()) for arg in sys.argv[1:])
evidence = Path(tempfile.mkdtemp(prefix="yellow-dog-worker-connection-"))
processes = {}
worker_envs = {}
logs = []
tokens = []


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
    process_env = dict(env)
    if name == "worker":
        process_env.update(RELEASE_DISTRIBUTION="sname",
                           RELEASE_NODE=f"connection_worker_{os.getpid()}_{len(logs)}",
                           RELEASE_COOKIE=uuid.uuid4().hex)
    processes[name] = subprocess.Popen([binary, "start"], env=process_env, stdout=log, stderr=log,
                                       start_new_session=True)
    if name == "worker":
        worker_envs[name] = process_env
        process = processes[name]
        until(lambda: worker_booted(process, process_env), "New Worker VM did not finish booting")


def worker_booted(process, process_env):
    # Management may still report the previous VM's stopped revision. Require
    # the new OS process to finish booting before any persisted-state predicate
    # can succeed or shutdown can send SIGTERM during early BEAM initialization.
    expression = (
        "status = YellowDog.Worker.status(); "
        "if List.keymember?(Application.started_applications(), :yellow_dog_worker, 0) and "
        "(status.desired == nil or status.ready), do: IO.puts(System.pid())"
    )
    try:
        result = subprocess.run([worker_binary, "rpc", expression], env=process_env,
                                capture_output=True, text=True, timeout=5)
        return result.returncode == 0 and result.stdout.strip() == str(process.pid)
    except subprocess.TimeoutExpired:
        return False


def worker_connection():
    """The live Worker's own view of its Management channel."""
    expression = (
        "pid = Enum.find_value(Supervisor.which_children(YellowDog.Worker.Supervisor), "
        "fn {id, pid, _, _} -> if id == YellowDog.Worker.Connection, do: pid end); "
        "IO.puts(Jason.encode!(YellowDog.Worker.Connection.status(pid)))"
    )
    result = subprocess.run([worker_binary, "rpc", expression], env=worker_envs["worker"],
                            capture_output=True, text=True, timeout=5)
    assert result.returncode == 0, result.stdout + result.stderr
    return json.loads(result.stdout.strip().splitlines()[-1])


class Frames:
    """Minimal RFC 6455 client framing over a plain TCP socket."""

    def __init__(self, connection, buffered):
        self.connection, self.buffer = connection, buffered

    def read(self, size):
        while len(self.buffer) < size:
            chunk = self.connection.recv(65536)
            assert chunk, "Unexpected WebSocket EOF"
            self.buffer += chunk
        result, self.buffer = self.buffer[:size], self.buffer[size:]
        return result

    def receive(self):
        first, second = self.read(2)
        size = second & 0x7F
        if size == 126:
            size = struct.unpack("!H", self.read(2))[0]
        elif size == 127:
            size = struct.unpack("!Q", self.read(8))[0]
        return first & 0x0F, self.read(size)

    def send(self, value):
        data = json.dumps(value).encode()
        mask = os.urandom(4)
        length = bytes([0x80 | len(data)]) if len(data) < 126 else bytes([0x80 | 126]) + struct.pack("!H", len(data))
        self.connection.sendall(b"\x81" + length + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))


def channel_join(identity, token, report):
    """Join worker:<id> exactly as the Worker does; return the join reply."""
    key = base64.b64encode(os.urandom(16)).decode()
    with socket.create_connection(("127.0.0.1", port), timeout=5) as connection:
        connection.sendall((f"GET /api/worker/connect?vsn=2.0.0&worker_id={identity} HTTP/1.1\r\n"
                            f"Host: 127.0.0.1:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                            f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = connection.recv(4096)
            assert chunk, "Upgrade closed early"
            head += chunk
        head, rest = head.split(b"\r\n\r\n", 1)
        assert head.startswith(b"HTTP/1.1 101"), head
        frames = Frames(connection, rest)
        topic = "worker:" + identity
        frames.send(["1", "1", topic, "phx_join", {"token": token, "report": report}])
        while True:
            opcode, data = frames.receive()
            assert opcode == 1, f"Unexpected WebSocket opcode {opcode}"
            message = json.loads(data)
            if message[1] == "1" and message[3] == "phx_reply":
                return message[4]


def stop(name):
    process = processes.pop(name, None)
    if process:
        try:
            # BEAM owns the store-lock helper; let it close children itself.
            os.kill(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            status = process.wait(timeout=20)
            if name != "browser":
                assert status == 0, f"{name} failed to stop cleanly; logs: {evidence}"
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=10)
            raise AssertionError(f"{name} timed out stopping; logs: {evidence}")
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
                           "config": {"listen_address": "127.0.0.1", "port": listen_port, "allow_query": ["127.0.0.0/8"]}})
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
    query = dns_request()
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM if tcp else socket.SOCK_DGRAM) as client:
        client.settimeout(1)
        if tcp:
            client.connect(("127.0.0.1", dns_port))
            client.sendall(struct.pack("!H", len(query)) + query)
            response = read_exact(client, struct.unpack("!H", read_exact(client, 2))[0])
        else:
            client.sendto(query, ("127.0.0.1", dns_port))
            response = client.recv(65535)
    assert_dns_answer(response)


def dns_request(identifier=1234):
    query = struct.pack("!6H", identifier, 0, 1, 0, 0, 0)
    query += b"".join(bytes([len(label)]) + label.encode() for label in "ns.worker-smoke.test".split("."))
    return query + b"\x00" + struct.pack("!2H", 1, 1)


def assert_dns_answer(response, expected_id=1234):
    identifier, flags, questions, answers, _, _ = struct.unpack("!6H", response[:12])
    assert identifier == expected_id and flags & 0x0400 and flags & 15 == 0 and questions == 1 and answers == 1
    assert b"\xc0\x00\x02\x2c" in response, "Expected A 192.0.2.44"


def browser(action=None, payload=None):
    args = ["node", "apps/yellow_dog_management/test/worker_connection_browser_smoke.mjs", base, str(evidence)]
    input_path = evidence / "dns-browser-input.json"
    if action:
        args.append(action)
        input_path.write_text(json.dumps({"worker_id": worker_id, **(payload or {})}))
    process = subprocess.Popen(args, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, start_new_session=True)
    processes["browser"] = process
    try:
        output, _ = process.communicate(timeout=90)
        assert process.returncode == 0, output
        print(output.strip(), flush=True)
    finally:
        input_path.unlink(missing_ok=True)
        stop("browser")


def test_certificate(label):
    cert, key = evidence / f"{label}.pem", evidence / f"{label}.key"
    command(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
             "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost",
             "-days", "1", "-keyout", str(key), "-out", str(cert)])
    try:
        return {"certificate": cert.read_text(), "private_key": key.read_text()}
    finally:
        key.unlink()


def tls_context():
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    return context


def dot_query(port, certificate):
    with socket.create_connection(("127.0.0.1", port), timeout=1) as tcp:
        with tls_context().wrap_socket(tcp, server_hostname="localhost") as client:
            assert client.getpeercert(binary_form=True) == ssl.PEM_cert_to_DER_cert(certificate)
            query = dns_request()
            client.sendall(struct.pack("!H", len(query)) + query)
            response = read_exact(client, struct.unpack("!H", read_exact(client, 2))[0])
            assert_dns_answer(response)


def doh_query(port):
    client = http.client.HTTPSConnection("127.0.0.1", port, context=tls_context(), timeout=1)
    try:
        client.request("POST", "/dns-query", dns_request(), {"Content-Type": "application/dns-message"})
        response = client.getresponse()
        assert response.status == 200 and response.headers["Content-Type"] == "application/dns-message"
        assert_dns_answer(response.read())
    finally:
        client.close()


def doq_query(port, certificate, ipv6=False):
    query = base64.b64encode(dns_request(0)).decode()
    der = base64.b64encode(ssl.PEM_cert_to_DER_cert(certificate)).decode()
    ip = "{0, 0, 0, 0, 0, 0, 0, 1}" if ipv6 else "{127, 0, 0, 1}"
    expression = f'''
    ip = {ip}
    {{:ok, endpoint}} = Quic.client(ip: ip, tls: [alpn: ["doq"], cacerts: [Base.decode64!("{der}")], reference_identity: {{:dns_id, "localhost"}}])
    try do
      {{:ok, connection}} = Quic.connect(endpoint, {{ip, {port}}})
      :ok = Quic.attach(connection, self())
      receive do
        {{:quic_ready, ^connection, %{{alpn: "doq"}}}} -> :ok
        {{:quic_closed, ^connection, reason}} -> raise "DoQ handshake failed: #{{inspect(reason)}}"
      after
        3_000 -> raise "DoQ handshake timed out"
      end
      {{:ok, stream}} = Quic.open_stream(connection, :bidi)
      packet = Base.decode64!("{query}")
      {{:ok, _}} = Quic.send_stream(stream, <<byte_size(packet)::16, packet::binary>>, true)
      read = fn
        _read, _buffer, 0 -> raise "DoQ answer timed out"
        read, buffer, attempts ->
          {{:ok, events}} = Quic.read(stream, 16_384)
          {{buffer, fin?}} = Enum.reduce(events, {{buffer, false}}, fn
            {{:data, _, bytes}}, {{acc, _}} -> {{acc <> bytes, false}}
            {{:fin, _}}, {{acc, _}} -> {{acc, true}}
          end)
          if fin?, do: buffer, else: (Process.sleep(20); read.(read, buffer, attempts - 1))
      end
      <<length::16, answer::binary-size(length)>> = read.(read, <<>>, 100)
      IO.puts(Base.encode64(answer))
    after
      GenServer.stop(endpoint)
    end
'''
    result = subprocess.run([worker_binary, "rpc", expression], env=worker_envs["worker"],
                            capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stdout + result.stderr
    assert_dns_answer(base64.b64decode(result.stdout.strip().splitlines()[-1]), expected_id=0)


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
File.write!(System.fetch_env!("YELLOW_DOG_WORKER_SMOKE_BOOTSTRAP"), bootstrap)
'''


def seed_worker():
    command([management_binary, "eval", seed])
    enrollment = json.loads(enrollment_path.read_text())
    tokens.append(enrollment["token"])
    return enrollment["worker"]["id"]

try:
    command([management_binary, "migrate"])
    worker_id = seed_worker()
    start("management", management_binary)
    until(lambda: worker()["connection_status"] == "not_yet_connected", "Management did not start")
    html = request("/management/servers")
    assert "worker[name]" in html and "worker[id]" not in html and "worker[profile_name]" not in html
    assert "Workers" in html and "server-selector-records" in html and "worker-bootstrap" not in html
    browser()
    start("worker", worker_binary)
    until(lambda: worker()["connection_status"] == "connected", "Worker did not authenticate")
    assert worker()["services"] == [] and worker()["reported_services"] == {}
    assert worker_connection() == {"connected": True, "connection_error": None, "apply_error": None}
    assert "poll_interval_ms" not in bootstrap_path.read_text()
    print("Name-only creation, real authenticated WebSocket join, no initial services: PASS", flush=True)

    zone = mutate("create_zone", {"name": "worker-smoke.test.", "records": [
        {"name": "worker-smoke.test.", "type": "SOA", "ttl": 300,
         "data": {"mname": "ns.worker-smoke.test.", "rname": "hostmaster.worker-smoke.test.",
                  "serial": 1, "refresh": 3600, "retry": 600, "expire": 86400, "minimum": 300}},
        {"name": "worker-smoke.test.", "type": "NS", "ttl": 300, "data": {"host": "ns.worker-smoke.test."}},
        {"name": "ns.worker-smoke.test.", "type": "A", "ttl": 300, "data": {"address": "192.0.2.44"}}]})
    version = mutate("confirm_zone", {"id": zone["id"], "expected_revision": zone["revision"]})
    service = mutate("put_service", {"worker_id": worker_id, "expected_revision": worker()["revision"],
                                     "id": "dns", "type": "dns", "desired_state": "stopped",
                                     "config": {"listen_address": "127.0.0.1", "port": dns_port, "allow_query": ["127.0.0.0/8"]}})
    mutate("assign", {"worker_id": worker_id, "expected_revision": worker()["revision"],
                      "service_id": service["id"], "resource_version_id": version["id"]})
    running_revision = publish("running")
    published_at = time.monotonic()
    # Pushed over the channel: no polling interval between confirm and apply.
    until(lambda: applied(running_revision, "running"), "Pushed target was not applied within 3 seconds", seconds=3)
    push_latency = time.monotonic() - published_at
    dns_query()
    dns_query(tcp=True)
    print("Confirmed target delivered; actual DNS UDP/TCP answer: PASS", flush=True)
    print(f"Pushed target applied and reported in {push_latency:.2f}s (< 3s): PASS", flush=True)

    stop("management")
    dns_query()
    stop("worker")
    start("worker", worker_binary)
    until(lambda: dns_query(tcp=True) is None, "Offline snapshot did not restore DNS")
    start("management", management_binary)
    # Reconnect backoff grows to at most 30s while Management is down.
    until(lambda: worker()["connection_status"] == "connected" and applied(running_revision, "running"),
          "Worker did not reconnect", seconds=45)
    print("Management outage, offline Worker restart, committed runtime and reconnect: PASS", flush=True)

    stopped_revision = publish("stopped")
    until(lambda: applied(stopped_revision, "stopped") and stopped(), "DNS did not stop")
    stop("worker")
    start("worker", worker_binary)
    until(lambda: applied(stopped_revision, "stopped") and stopped(), "Stopped state did not survive restart")
    print("DNS actual socket shutdown and persisted stopped state: PASS", flush=True)

    seed_worker()
    until(lambda: worker()["connection_status"] == "not_yet_connected", "Token reset retained a connection")
    # The online channel is re-verified on its next heartbeat report (15s) and
    # every rejoin with the previous token is refused.
    until(lambda: worker_connection()["connection_error"] == "unauthorized",
          "Online Worker with a revoked token was not disconnected", seconds=40)
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

    original, rotated, offline = [test_certificate(label) for label in ("original", "rotated", "offline")]
    dot_port, doh_port, doq_port = (free_port() for _ in range(3))
    old_service = worker()["services"][0]

    with socket.socket() as occupied:
        occupied.bind(("127.0.0.1", 0))
        occupied.listen()
        blocked_port = occupied.getsockname()[1]
        ports = {"udp": dns_port, "tcp": blocked_port, "dot": dot_port, "doh": doh_port, "doq": doq_port}
        browser("setup", {**original, "ports": ports})
        saved = worker()["services"]
        assert len(saved) == 1 and saved[0]["id"] == old_service["id"]
        assert saved[0]["config"]["listen"] == {"mode": "specific", "addresses": ["127.0.0.1", "::1"]}
        assert saved[0]["config"]["transports"]["tcp"]["listen"] == {"mode": "all_ipv4"}
        assert {name: saved[0]["config"]["transports"][name]["port"] for name in ports} == ports
        assert worker()["applied_revision"] == stopped_revision and stopped()

        browser("publish")
        modern_revision = request(f"/api/workers/{worker_id}/targets/latest")["revision"]
        until(lambda: applied(modern_revision, "partial"), "TCP failure did not leave other protocols running")
        reported = worker()["reported_services"]["dns"]["protocols"]
        assert reported["tcp"]["failure"] == {"address": "0.0.0.0", "reason": "eaddrinuse"}
        assert reported["tcp"]["port"] == blocked_port
        assert all(reported[name]["state"] == "running" for name in ("udp", "dot", "doh", "doq"))
        dns_query()
        dot_query(dot_port, original["certificate"])
        doh_query(doh_port)
        doq_query(doq_port, original["certificate"], ipv6=True)
        print("Browser DNS configuration, publication, protocol-specific failure and real queries: PASS", flush=True)

        browser("fix-tcp", {"ports": {"tcp": dns_port}})
        modern_revision = request(f"/api/workers/{worker_id}/targets/latest")["revision"]
        until(lambda: applied(modern_revision, "running"), "Corrected TCP listener did not start")
        dns_query(tcp=True)

    browser("delete")
    browser("rotate", {**rotated, "private_key": original["private_key"]})
    until(lambda: worker()["apply_error"] == "invalid_dns_certificate", "Worker did not report the invalid rotation")
    dot_query(dot_port, original["certificate"])
    doq_query(doq_port, original["certificate"])
    browser("rotate", rotated)
    until(lambda: worker()["reported_services"]["dns"]["protocols"]["dot"].get("certificate_revision") == 3,
          "Online certificate replacement did not reach the Worker")
    dot_query(dot_port, rotated["certificate"])
    doq_query(doq_port, rotated["certificate"])
    assert applied(modern_revision, "running")

    stop("worker")
    browser("rotate", offline)
    start("worker", worker_binary)
    until(lambda: worker()["reported_services"]["dns"]["protocols"]["doq"].get("certificate_revision") == 4,
          "Reconnecting Worker did not catch up on certificate rotation")
    assert applied(modern_revision, "running")
    dot_query(dot_port, offline["certificate"])
    doh_query(doh_port)
    doq_query(doq_port, offline["certificate"])

    stop("management")
    stop("worker")
    start("worker", worker_binary)
    dot_query(dot_port, offline["certificate"])
    doq_query(doq_port, offline["certificate"])
    start("management", management_binary)
    until(lambda: request("/management"), "Management did not restart")
    print("Certificate delete protection, failed and successful hot reload, reconnect and offline TLS restart: PASS", flush=True)

    stop("worker")
    before_ids = {value["id"] for value in request("/api/workers")}
    anonymous_bootstrap = evidence / "anonymous-bootstrap.toml"
    anonymous_dir = evidence / "anonymous-data"
    anonymous_bootstrap.write_text(f'management_url = "{base}"\n')
    env["YELLOW_DOG_WORKER_BOOTSTRAP"] = str(anonymous_bootstrap)
    env["STATE_DIRECTORY"] = str(anonymous_dir)
    start("worker", worker_binary)
    until(lambda: len(list(anonymous_dir.glob("*connection*.toml"))) == 1,
          "URL-only Worker did not persist its identity")
    identity_file = next(anonymous_dir.glob("*connection*.toml"))
    identity_before = identity_file.read_bytes()
    identity = tomllib.loads(identity_before.decode())
    # A live channel join must be rejected while anonymous enrollment is disabled.
    initial_report = {"worker_id": identity["worker_id"], "capabilities": ["dns"], "services": {},
                      "applied_revision": None, "applied_digest": None, "apply_error": None}
    reply = channel_join(identity["worker_id"], identity["token"], initial_report)
    assert reply == {"status": "error", "response": {"code": "unauthorized"}}, reply
    until(lambda: worker_connection()["connection_error"] == "unauthorized", "Worker did not report the rejected join")
    assert {value["id"] for value in request("/api/workers")} == before_ids
    mutate("set_worker_enrollment", {"allow_anonymous": True})
    # The rejected Worker retries with backoff capped at 30s.
    until(lambda: len(request("/api/workers")) == len(before_ids) + 1, "Anonymous Worker did not enroll", seconds=45)
    worker_id = next(value["id"] for value in request("/api/workers") if value["id"] not in before_ids)
    until(lambda: worker()["connection_status"] == "connected", "Anonymous Worker did not connect")
    assert worker()["services"] == [] and worker()["reported_services"] == {}
    assert identity["worker_id"] == worker_id and len(identity["token"]) == 43
    assert identity_file.stat().st_mode & 0o777 == 0o600
    assert anonymous_dir.stat().st_mode & 0o777 == 0o700

    service = mutate("put_service", {"worker_id": worker_id, "expected_revision": worker()["revision"],
                                     "id": "dns", "type": "dns", "desired_state": "stopped",
                                     "config": {"listen_address": "127.0.0.1", "port": dns_port, "allow_query": ["127.0.0.0/8"]}})
    mutate("assign", {"worker_id": worker_id, "expected_revision": worker()["revision"],
                      "service_id": service["id"], "resource_version_id": version["id"]})
    anonymous_running = publish("running")
    until(lambda: applied(anonymous_running, "running"), "URL-only Worker did not apply published DNS")
    dns_query()
    dns_query(tcp=True)
    mutate("set_worker_enrollment", {"allow_anonymous": False})
    stop("worker")
    start("worker", worker_binary)
    until(lambda: applied(anonymous_running, "running") and dns_query(tcp=True) is None,
          "Registered Worker did not restore while enrollment was disabled")
    assert identity_file.read_bytes() == identity_before
    assert len(request("/api/workers")) == len(before_ids) + 1
    anonymous_stopped = publish("stopped")
    until(lambda: applied(anonymous_stopped, "stopped") and stopped(), "URL-only Worker did not stop DNS")
    stop("worker")
    start("worker", worker_binary)
    until(lambda: applied(anonymous_stopped, "stopped") and stopped(), "URL-only stopped state did not survive restart")
    assert identity_file.read_bytes() == identity_before
    assert len(request("/api/workers")) == len(before_ids) + 1
    for log_path in evidence.glob("*.log"):
        text = log_path.read_text()
        for token in tokens + [identity["token"]]:
            assert token not in text, f"Worker credential leaked to {log_path.name}"
    print("URL-only initialization gate, stable private credentials, published DNS and stopped restart: PASS", flush=True)
    (evidence / "result.json").write_text(json.dumps({"result": "PASS", "worker_id": worker_id,
                                                   "running_revision": running_revision,
                                                   "stopped_revision": stopped_revision,
                                                   "anonymous_running_revision": anonymous_running,
                                                   "anonymous_stopped_revision": anonymous_stopped}))
    print(f"Worker connection smoke: PASS; evidence: {evidence}", flush=True)
finally:
    stop("browser")
    stop("worker")
    stop("management")
    for log in logs:
        log.close()
    enrollment_path.unlink(missing_ok=True)
    bootstrap_path.unlink(missing_ok=True)
