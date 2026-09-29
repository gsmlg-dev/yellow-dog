#!/usr/bin/env python3
"""Actual OS release, UDP/TCP, local reload and crash/restart acceptance. No mocks."""
import os
import pathlib
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

release = pathlib.Path(sys.argv[1]).resolve()
root = pathlib.Path(tempfile.mkdtemp(prefix="yellow-dog-worker-smoke-"))
source = root / "plan.toml"
bootstrap = root / "bootstrap.toml"
state = root / "state"
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
fixture = (pathlib.Path(__file__).resolve().parents[1] / "examples/plan.toml").read_text()
fixture = fixture.replace("port = 1053", f"port = {port}")
fixture += '''\n[[resources.content.records]]
name = "ns1.example.com."
type = "A"
ttl = 300
data = { address = "192.0.2.54" }
'''
second_zone = fixture[fixture.index("[[resources]]"):].replace("zone-example", "zone-other")
second_zone = second_zone.replace("example.com", "other.test").replace("192.0.2.", "198.51.100.")
fixture = fixture.replace('resources = ["zone-example"]', 'resources = ["zone-example", "zone-other"]')
fixture += "\n" + second_zone
source.write_text(fixture)
bootstrap.write_text(f'worker_id = "edge-01"\ndata_dir = "{state}"\nsource = "{source}"\n')
env = {key: value for key, value in os.environ.items()
       if not key.upper().startswith("PG") and
       not any(word in key.upper() for word in ("MANAGEMENT", "POSTGRES", "DATABASE_URL"))}
env.update(YELLOW_DOG_WORKER_BOOTSTRAP=str(bootstrap), RELEASE_DISTRIBUTION="sname",
           RELEASE_NODE=f"worker_smoke_{os.getpid()}", RELEASE_COOKIE=f"worker_smoke_cookie_{os.getpid()}",
           ERL_FLAGS="+S 2:2 +A 2")
proc = None
logs = []


def rpc(expression):
    result = subprocess.run([str(release), "rpc", expression], env=env,
                            text=True, capture_output=True, timeout=25)
    if result.returncode:
        raise AssertionError(f"rpc failed: {result.stdout}\n{result.stderr}")
    return result.stdout.strip()


def assertion(expression):
    output = rpc(f'if ({expression}), do: IO.puts("PASS"), else: raise("acceptance assertion failed")')
    assert "PASS" in output, output


def reload(ok=True):
    output = rpc('IO.inspect(YellowDog.Worker.reload(), limit: :infinity)')
    assert ("{:ok," if ok else "{:error,") in output, output
    return output


def start():
    global proc
    log = open(root / f"boot-{len(logs)}.log", "w")
    logs.append(log)
    proc = subprocess.Popen([str(release), "start"], env=env, stdout=log,
                            stderr=subprocess.STDOUT, start_new_session=True)
    for _ in range(100):
        if proc.poll() is not None:
            raise AssertionError(f"release exited {proc.returncode}; logs in {root}")
        try:
            if "PASS" in rpc('IO.puts(if Process.whereis(YellowDog.Worker.ServiceManager), do: "PASS", else: "WAIT")'):
                return
        except (AssertionError, subprocess.TimeoutExpired):
            pass
        time.sleep(0.1)
    raise AssertionError("release startup timeout")


def stop(kill=False):
    global proc
    if proc and proc.poll() is None:
        os.killpg(proc.pid, signal.SIGKILL if kill else signal.SIGTERM)
        proc.wait(timeout=15)
    proc = None
    time.sleep(0.3)


def recv_exact(sock, count):
    result = b""
    while len(result) < count:
        block = sock.recv(count - len(result))
        if not block:
            raise AssertionError("truncated TCP response")
        result += block
    return result


def skip_name(data, offset):
    while data[offset]:
        size = data[offset]
        if size & 0xC0 == 0xC0:
            return offset + 2
        offset += size + 1
    return offset + 1


def query(tcp=False, name="ns1.example.com", qtype=1):
    encoded = b"".join(bytes([len(label)]) + label.encode() for label in name.split(".")) + b"\0"
    packet = struct.pack("!6H", 1234, 0x0100, 1, 0, 0, 0) + encoded + struct.pack("!HH", qtype, 1)
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM if tcp else socket.SOCK_DGRAM) as sock:
        sock.settimeout(0.5)
        if tcp:
            sock.connect(("127.0.0.1", port))
            sock.sendall(struct.pack("!H", len(packet)) + packet)
            data = recv_exact(sock, struct.unpack("!H", recv_exact(sock, 2))[0])
        else:
            sock.sendto(packet, ("127.0.0.1", port))
            data = sock.recv(65535)
    identity, flags, qd, an, ns, ar = struct.unpack("!6H", data[:12])
    assert identity == 1234 and flags & 0x8000 and not flags & 0x0080
    offset = 12
    for _ in range(qd):
        offset = skip_name(data, offset) + 4
    addresses, types = set(), []
    for _ in range(an):
        offset = skip_name(data, offset)
        kind, cls, ttl, size = struct.unpack("!HHIH", data[offset:offset + 10])
        offset += 10
        if kind == 1:
            addresses.add(socket.inet_ntoa(data[offset:offset + size]))
        types.append(kind)
        offset += size
    return flags, addresses, types


def no_listeners():
    for tcp in (False, True):
        try:
            query(tcp)
        except (OSError, TimeoutError):
            continue
        raise AssertionError(f"stopped service answered over {'TCP' if tcp else 'UDP'}")


def snapshot_stats():
    return {str(p.relative_to(state)): (p.stat().st_ino, p.stat().st_mtime_ns, p.read_bytes())
            for p in state.rglob("*") if p.is_file() and p.name != ".lock"}


try:
    forbidden = ("yellow_dog_management", "yellow_dog_console", "postgrex", "ecto", "concord",
                 "yellow_dog_store", "yellow_dog_server_agent", "yellow_dog_netman_agent")
    libs = [p.name for p in release.parent.parent.joinpath("lib").iterdir()]
    assert not [name for name in libs if any(name.startswith(f"{x}-") for x in forbidden)], libs
    start()
    assertion('YellowDog.Worker.status().ready')
    for tcp in (False, True):
        flags, addresses, _ = query(tcp)
        assert flags & 0x0400 and addresses == {"192.0.2.53", "192.0.2.54"}
        for qtype in (2, 6):
            flags, _, types = query(tcp, "example.com", qtype)
            assert flags & 0x0400 and types == [qtype]
    print("PASS B1/B2: independent release; real authoritative SOA/NS/A over UDP and TCP", flush=True)

    before = snapshot_stats()
    old_pid = rpc('IO.inspect(YellowDog.Worker.status().services["dns-primary"].runtime_pid)')
    source.write_text(fixture + "\n# equivalent formatting\n")
    assert ":unchanged" in reload()
    assert snapshot_stats() == before
    assert rpc('IO.inspect(YellowDog.Worker.status().services["dns-primary"].runtime_pid)') == old_pid
    print("PASS B10: equivalent reload preserves snapshot bytes, inode, mtime and service PID", flush=True)

    changed = fixture.replace('version = 1\n\n[resources.content]', 'version = 2\n\n[resources.content]')
    changed = changed.replace("192.0.2.53", "192.0.2.93").replace("192.0.2.54", "192.0.2.94")
    errors, observed = [], []
    done = threading.Event()

    def reader():
        try:
            while not done.is_set():
                for tcp in (False, True):
                    answers = query(tcp)[1]
                    assert answers in ({"192.0.2.53", "192.0.2.54"}, {"192.0.2.93", "192.0.2.94"}), answers
                    observed.append(answers)
        except Exception as exc:
            errors.append(exc)

    thread = threading.Thread(target=reader, daemon=True)
    thread.start()
    source.write_text(changed)
    reload()
    done.set()
    thread.join(timeout=5)
    assert not errors and observed, errors
    assert query()[1] == {"192.0.2.93", "192.0.2.94"}
    assert query(True, "ns1.other.test")[1] == {"198.51.100.53", "198.51.100.54"}
    print(f"PASS B4: atomic RRset reload during {len(observed)} real queries", flush=True)

    source.write_text("invalid = [")
    reload(False)
    assert query(True)[1] == {"192.0.2.93", "192.0.2.94"}
    stop(kill=True)
    source.unlink()
    start()
    assert query()[1] == {"192.0.2.93", "192.0.2.94"}
    assertion('YellowDog.Worker.status().origin == :snapshot')
    print("PASS B7/B9: SIGKILL recovery without source or Management preserves last valid answers", flush=True)

    # Another OS process cannot share this data directory.
    duplicate_env = dict(env, RELEASE_NODE=env["RELEASE_NODE"] + "_duplicate")
    duplicate = subprocess.run([str(release), "start"], env=duplicate_env, text=True,
                               capture_output=True, timeout=20)
    assert duplicate.returncode != 0 and "directory_locked" in duplicate.stdout + duplicate.stderr
    assert query()[1] == {"192.0.2.93", "192.0.2.94"}
    print("PASS: second release rejects locked data directory", flush=True)

    stopped = changed.replace('desired_state = "running"', 'desired_state = "stopped"')
    source.write_text(stopped)
    reload()
    no_listeners()
    assertion('YellowDog.Worker.status().live and YellowDog.Worker.status().ready')
    stop(kill=True)
    source.write_text(fixture)  # uncommitted running source must lose to committed stopped state
    start()
    no_listeners()
    print("PASS B3/B5: stopped listeners stay closed after independent OS restart", flush=True)

    newest = stopped.replace("192.0.2.93", "192.0.2.103").replace("192.0.2.94", "192.0.2.104")
    newest = newest.replace('version = 2\n\n[resources.content]', 'version = 3\n\n[resources.content]')
    source.write_text(newest)
    reload()
    no_listeners()
    stop()
    start()
    no_listeners()
    source.write_text(newest.replace('desired_state = "stopped"', 'desired_state = "running"'))
    reload()
    for tcp in (False, True):
        assert query(tcp)[1] == {"192.0.2.103", "192.0.2.104"}
    print("PASS B6: stopped update persists; explicit start serves selected new data", flush=True)
    print(f"RELEASE SMOKE PASSED; evidence directory {root}", flush=True)
finally:
    stop()
    for log in logs:
        log.close()
