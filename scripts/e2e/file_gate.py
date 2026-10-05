"""Authenticated Management exports consumed by an offline, independent Worker."""
import json
import os
import pathlib
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
import tomllib
import urllib.request
import uuid


def free_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


management, worker = [pathlib.Path(argument).resolve() for argument in sys.argv[1:]]
root = pathlib.Path(tempfile.mkdtemp(prefix="yellow-dog-file-gate-"))
source, state = root / "target.toml", root / "state"
http_port, dns_port = free_port(), free_port()
base = f"http://127.0.0.1:{http_port}/api"
token = "disposable-file-gate-operator-token-0001"
management_env = dict(os.environ, YELLOW_DOG_MANAGEMENT_PORT=str(http_port),
                      YELLOW_DOG_MANAGEMENT_OPERATOR_TOKEN=token,
                      RELEASE_DISTRIBUTION="none", RELEASE_COOKIE=token)
worker_env = {key: value for key, value in os.environ.items()
              if not key.upper().startswith("PG") and not any(
                  word in key.upper() for word in ("MANAGEMENT", "POSTGRES", "DATABASE_URL", "_PG_"))}
bootstrap = root / "bootstrap.toml"
bootstrap.write_text(f'worker_id = "logical-0"\ndata_dir = "{state}"\nsource = "{source}"\n')
worker_env.update(YELLOW_DOG_WORKER_BOOTSTRAP=str(bootstrap),
                  RELEASE_DISTRIBUTION="sname", RELEASE_NODE=f"file_gate_{os.getpid()}",
                  RELEASE_COOKIE=token, ERL_FLAGS="+S 2:2 +A 2")
management_process = worker_process = None
logs, exports = [], {}


def command(binary, arguments, environment):
    result = subprocess.run([str(binary), *arguments], env=environment,
                            capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, (arguments, result.stdout, result.stderr)
    return result.stdout


def request(path, body=None, raw=False):
    headers = {"Authorization": "Bearer " + token}
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers.update({"Content-Type": "application/json", "Idempotency-Key": str(uuid.uuid4())})
    with urllib.request.urlopen(urllib.request.Request(base + path, data=data, headers=headers), timeout=10) as response:
        result = response.read()
    return result if raw else json.loads(result)["data"]


def mutate(operation, body):
    return request("/commands/" + operation, body)


def worker_mutation(operation, body):
    current = request("/workers/logical-0")
    return mutate(operation, dict(body, worker_id="logical-0", expected_revision=current["revision"]))


def zone(name, address):
    return {"name": name, "records": [
        {"name": name, "type": "SOA", "ttl": 300, "data": {
            "mname": "ns." + name, "rname": "hostmaster." + name, "serial": 1,
            "refresh": 3600, "retry": 600, "expire": 86400, "minimum": 300}},
        {"name": name, "type": "NS", "ttl": 300, "data": {"host": "ns." + name}},
        {"name": "ns." + name, "type": "A", "ttl": 300, "data": {"address": address}}]}


def confirm_zone(record):
    return mutate("confirm_zone", {"id": record["id"], "expected_revision": record["revision"]})


def export_target(label):
    target = worker_mutation("confirm_target", {})
    assert target["actual_state"] == "unknown" and target["status"] == "prepared"
    contents = request(f'/workers/logical-0/targets/{target["revision"]}/export', raw=True)
    plan = tomllib.loads(contents.decode())
    assert plan == target["plan"], (label, plan, target["plan"])
    (root / f"{label}.toml").write_bytes(contents)
    (root / f"{label}.json").write_text(json.dumps(target, indent=2))
    exports[label] = contents, plan
    return plan


def service(desired_state):
    return {"id": "dns", "type": "dns", "desired_state": desired_state,
            "config": {"listen_address": "127.0.0.1", "port": dns_port}}


def launch(binary, environment, label):
    log = open(root / f"{label}-{len(logs)}.log", "w")
    logs.append(log)
    return subprocess.Popen([str(binary), "start"], env=environment, stdout=log,
                            stderr=subprocess.STDOUT, start_new_session=True)


def terminate(process, force=False):
    if process is not None and process.poll() is None:
        os.killpg(process.pid, signal.SIGKILL if force else signal.SIGTERM)
        process.wait(timeout=15)


def await_ready(process, check):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        assert process.poll() is None, f"release exited {process.returncode}; evidence: {root}"
        try:
            if check():
                return
        except (OSError, AssertionError, subprocess.TimeoutExpired):
            pass
        time.sleep(0.1)
    raise AssertionError(f"release readiness timeout; evidence: {root}")


def rpc(expression):
    return command(worker, ["rpc", expression], worker_env)


def assert_worker(expression):
    assert "PASS" in rpc(f'if ({expression}), do: IO.puts("PASS"), else: raise("file gate assertion failed")')


def start_worker():
    global worker_process
    worker_process = launch(worker, worker_env, "worker")
    await_ready(worker_process, lambda: "PASS" in rpc(
        'IO.puts(if YellowDog.Worker.status().ready, do: "PASS", else: "WAIT")'))


def receive_exact(connection, count):
    contents = b""
    while len(contents) < count:
        chunk = connection.recv(count - len(contents))
        assert chunk, "truncated DNS response"
        contents += chunk
    return contents


def decode_name(packet, offset, depth=0):
    assert depth < 16, "DNS compression loop"
    labels = []
    while packet[offset]:
        size = packet[offset]
        if size & 0xC0 == 0xC0:
            pointer = ((size & 0x3F) << 8) | packet[offset + 1]
            suffix, _ = decode_name(packet, pointer, depth + 1)
            return ".".join(labels + [suffix.rstrip(".")]) + ".", offset + 2
        offset += 1
        labels.append(packet[offset:offset + size].decode())
        offset += size
    return ".".join(labels) + ".", offset + 1


def query(name, record_type, tcp):
    encoded = b"".join(bytes([len(label)]) + label.encode() for label in name.rstrip(".").split(".")) + b"\0"
    packet = struct.pack("!6H", 4321, 0x0100, 1, 0, 0, 0) + encoded + struct.pack("!HH", record_type, 1)
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM if tcp else socket.SOCK_DGRAM) as connection:
        connection.settimeout(1)
        if tcp:
            connection.connect(("127.0.0.1", dns_port))
            connection.sendall(struct.pack("!H", len(packet)) + packet)
            response = receive_exact(connection, struct.unpack("!H", receive_exact(connection, 2))[0])
        else:
            connection.sendto(packet, ("127.0.0.1", dns_port))
            response = connection.recv(65535)
    identity, flags, questions, answers, _, _ = struct.unpack("!6H", response[:12])
    assert identity == 4321 and flags & 0x8000 and not flags & 0x0080
    offset, records = 12, []
    for _ in range(questions):
        _, offset = decode_name(response, offset)
        offset += 4
    for _ in range(answers):
        owner, offset = decode_name(response, offset)
        kind, record_class, ttl, size = struct.unpack("!HHIH", response[offset:offset + 10])
        offset += 10
        assert record_class == 1
        if kind == 1:
            value = {"address": socket.inet_ntoa(response[offset:offset + size])}
        elif kind == 2:
            host, _ = decode_name(response, offset)
            value = {"host": host}
        elif kind == 6:
            mname, after_mname = decode_name(response, offset)
            rname, after_rname = decode_name(response, after_mname)
            fields = struct.unpack("!5I", response[after_rname:after_rname + 20])
            value = dict(zip(("serial", "refresh", "retry", "expire", "minimum"), fields),
                         mname=mname, rname=rname)
        else:
            raise AssertionError(f"unexpected DNS answer type {kind}")
        records.append({"name": owner, "type": {1: "A", 2: "NS", 6: "SOA"}[kind], "ttl": ttl, "data": value})
        offset += size
    return flags, records


def verify_answers(plan):
    for resource in plan["resources"]:
        for record in resource["content"]["records"]:
            for tcp in (False, True):
                flags, answers = query(record["name"], {"A": 1, "NS": 2, "SOA": 6}[record["type"]], tcp)
                assert flags & 0x0400 and flags & 0xF == 0 and answers == [record], (record, tcp, flags, answers)
    assert_worker(f'YellowDog.Worker.status().desired["revision"] == {plan["revision"]}')


def no_listeners():
    for tcp in (False, True):
        try:
            query("ns.example.test.", 1, tcp)
        except (OSError, TimeoutError):
            continue
        raise AssertionError("stopped service still answers")


def offline():
    assert management_process.poll() is not None
    assert not pathlib.Path(os.environ["YELLOW_DOG_PHASE1_PG_DATA_DIR"], "postmaster.pid").exists()
    for port in (http_port, int(os.environ["YELLOW_DOG_PHASE1_PG_PORT"])):
        with socket.socket() as connection:
            connection.settimeout(1)
            assert connection.connect_ex(("127.0.0.1", port)) != 0


def apply_export(label):
    offline()
    source.write_bytes(exports[label][0])
    assert "{:ok," in rpc("IO.inspect(YellowDog.Worker.reload(), limit: :infinity)")
    assert_worker("YellowDog.Worker.status().ready")


try:
    print(f"FILE GATE evidence: {root}", flush=True)
    command(management, ["eval", "YellowDog.Management.Release.migrate()"], management_env)
    management_process = launch(management, management_env, "management")
    await_ready(management_process, lambda: request("/workers") == [])
    assert worker_process is None and request("/zones") == []
    first = mutate("create_zone", zone("example.test.", "192.0.2.1"))
    first = mutate("update_zone", dict(zone("example.test.", "192.0.2.2"),
                                     id=first["id"], expected_revision=first["revision"]))
    second = mutate("create_zone", zone("second.test.", "198.51.100.53"))
    assert request("/workers") == []
    first_version, second_version = confirm_zone(first), confirm_zone(second)
    for number in range(4):
        worker_id = f"logical-{number}"
        logical = mutate("create_worker", {"id": worker_id, "name": worker_id, "expected_capabilities": ["dns"]})
        for operation, body in [("put_service", service("running")),
                                ("assign", {"service_id": "dns", "resource_version_id": first_version["id"]}),
                                ("assign", {"service_id": "dns", "resource_version_id": second_version["id"]})]:
            mutate(operation, dict(body, worker_id=worker_id, expected_revision=logical["revision"]))
            logical = request("/workers/" + worker_id)
        assert logical["actual_state"] == "unknown" and logical["status"] == "not_yet_connected"
        current = mutate("confirm_target", {"worker_id": worker_id, "expected_revision": logical["revision"]})
        assert {resource["id"] for resource in current["plan"]["resources"]} == {first["id"], second["id"]}
        assert {resource["version"] for resource in current["plan"]["resources"]} == {1}
    assert len(request("/zones")) == 2 and len(request("/workers")) == 4
    initial = export_target("initial")
    worker_mutation("put_service", service("stopped"))
    export_target("stopped")
    changed = mutate("update_zone", dict(zone("example.test.", "192.0.2.3"),
                                       id=first["id"], expected_revision=first["revision"]))
    changed_version = confirm_zone(changed)
    worker_mutation("assign", {"service_id": "dns", "resource_version_id": changed_version["id"]})
    updated = export_target("updated-stopped")
    worker_mutation("put_service", service("running"))
    running = export_target("running")
    worker_mutation("unassign", {"service_id": "dns", "resource_id": first["id"]})
    removed = export_target("removed")
    for plan in (updated, running, removed):
        assert next(resource for resource in plan["resources"] if resource["id"] == second["id"]) == next(
            resource for resource in initial["resources"] if resource["id"] == second["id"])
    assert request(f'/workers/logical-0/targets/{initial["revision"]}/export', raw=True) == exports["initial"][0]
    print("PASS: zero-Worker edits, four shared immutable assignments, authentic two-zone exports", flush=True)
    terminate(management_process)
    subprocess.run(["pg_ctl", "-D", os.environ["YELLOW_DOG_PHASE1_PG_DATA_DIR"], "-m", "fast", "-w", "stop"], check=True)
    offline()
    source.write_bytes(exports["initial"][0])
    start_worker()
    verify_answers(initial)
    before = {str(path.relative_to(state)): (path.stat().st_ino, path.stat().st_mtime_ns, path.read_bytes())
              for path in state.rglob("*") if path.is_file() and path.name != ".lock"}
    runtime = rpc('IO.inspect(YellowDog.Worker.status().services["dns"].runtime_pid)')
    source.write_bytes(exports["initial"][0] + b"\n# equivalent serialization\n")
    assert ":unchanged" in rpc("IO.inspect(YellowDog.Worker.reload(), limit: :infinity)")
    after = {str(path.relative_to(state)): (path.stat().st_ino, path.stat().st_mtime_ns, path.read_bytes())
             for path in state.rglob("*") if path.is_file() and path.name != ".lock"}
    assert before == after and runtime == rpc('IO.inspect(YellowDog.Worker.status().services["dns"].runtime_pid)')
    terminate(worker_process, force=True)
    source.unlink()
    start_worker()
    verify_answers(initial)
    assert_worker("YellowDog.Worker.status().origin == :snapshot")
    apply_export("stopped")
    no_listeners()
    terminate(worker_process, force=True)
    source.unlink()
    start_worker()
    no_listeners()
    apply_export("updated-stopped")
    no_listeners()
    terminate(worker_process)
    source.unlink()
    start_worker()
    no_listeners()
    assert_worker(f'YellowDog.Worker.status().desired["revision"] == {updated["revision"]}')
    apply_export("running")
    verify_answers(running)
    apply_export("removed")
    verify_answers(removed)
    for tcp in (False, True):
        flags, answers = query("ns.example.test.", 1, tcp)
        assert flags & 0xF == 5 and answers == [], (flags, answers)
    print("PASS: PG/Management offline; UDP/TCP SOA/NS/A match selected export; snapshot-only recovery", flush=True)
    print("PASS: stopped restart/update/start, independent zone change/removal, equivalent reload PID/no-write", flush=True)
    print("FILE-ONLY INTEROPERABILITY GATE PASSED", flush=True)
finally:
    terminate(worker_process)
    terminate(management_process)
    for log in logs:
        log.close()
