#!/usr/bin/env python3
"""Clean Linux archive acceptance using only the bundled release and OS tools."""
import os
import errno
import base64
import hashlib
import json
import pathlib
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import tomllib
import uuid


def rpc(binary, env, expression):
    result = subprocess.run([str(binary), "rpc", expression], env=env, text=True,
                            capture_output=True, timeout=45)
    if result.returncode:
        raise AssertionError(f"release RPC failed: {result.stdout}\n{result.stderr}")
    return result.stdout


def recv_exact(sock, size):
    result = b""
    while len(result) < size:
        block = sock.recv(size - len(result))
        assert block, "truncated DNS TCP response"
        result += block
    return result


def skip_name(data, offset):
    while data[offset]:
        size = data[offset]
        if size & 0xC0 == 0xC0:
            return offset + 2
        offset += size + 1
    return offset + 1


def dns(port, tcp):
    question = b"\x03ns1\x07example\x03com\0" + struct.pack("!HH", 1, 1)
    packet = struct.pack("!6H", 1234, 0x0100, 1, 0, 0, 0) + question
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM if tcp else socket.SOCK_DGRAM) as sock:
        sock.settimeout(0.7)
        if tcp:
            sock.connect(("127.0.0.1", port))
            sock.sendall(struct.pack("!H", len(packet)) + packet)
            response = recv_exact(sock, struct.unpack("!H", recv_exact(sock, 2))[0])
        else:
            sock.sendto(packet, ("127.0.0.1", port))
            response = sock.recv(65535)
    identity, flags, questions, answers, _, _ = struct.unpack("!6H", response[:12])
    assert identity == 1234 and flags & 0x8000 and flags & 0x0400 and flags & 15 == 0
    offset = 12
    for _ in range(questions):
        offset = skip_name(response, offset) + 4
    addresses = set()
    for _ in range(answers):
        offset = skip_name(response, offset)
        kind, _, _, size = struct.unpack("!HHIH", response[offset:offset + 10])
        offset += 10
        if kind == 1:
            assert size == 4
            addresses.add(socket.inet_ntoa(response[offset:offset + size]))
        offset += size
    return addresses


def answers(port, expected):
    for tcp in (False, True):
        assert dns(port, tcp) == {expected}


def closed(port):
    try:
        connection = socket.create_connection(("127.0.0.1", port), timeout=0.7)
    except OSError as error:
        if error.errno != errno.ECONNREFUSED:
            raise
    else:
        connection.close()
        raise AssertionError("stopped DNS still accepted a TCP connection")
    try:
        dns(port, False)
    except (ConnectionRefusedError, TimeoutError):
        return
    raise AssertionError("stopped DNS still answered UDP")


class ChannelEndpoint:
    """Minimal Management stand-in: WebSocket upgrade plus Phoenix V2 channel frames."""

    def __init__(self):
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen()
        self.port = self.listener.getsockname()[1]
        self.lock = threading.Lock()
        self.upgrades, self.messages = [], []
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        while True:
            try:
                connection, _ = self.listener.accept()
            except OSError:
                return
            threading.Thread(target=self.session, args=(connection,), daemon=True).start()

    def session(self, connection):
        with connection:
            try:
                connection.settimeout(60)
                buffer = b""
                while b"\r\n\r\n" not in buffer:
                    chunk = connection.recv(4096)
                    if not chunk:
                        return
                    buffer += chunk
                head, buffer = buffer.split(b"\r\n\r\n", 1)
                head = head.decode()
                with self.lock:
                    self.upgrades.append(head)
                key = next(line.split(":", 1)[1].strip() for line in head.split("\r\n")
                           if line.lower().startswith("sec-websocket-key:"))
                accept = base64.b64encode(hashlib.sha1(
                    (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
                connection.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                                    f"Connection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n").encode())

                def read(size):
                    nonlocal buffer
                    while len(buffer) < size:
                        chunk = connection.recv(65536)
                        if not chunk:
                            raise EOFError
                        buffer += chunk
                    result, buffer = buffer[:size], buffer[size:]
                    return result

                def send(value):
                    data = json.dumps(value).encode()
                    length = bytes([len(data)]) if len(data) < 126 else bytes([126]) + struct.pack("!H", len(data))
                    connection.sendall(b"\x81" + length + data)

                while True:
                    first, second = read(2)
                    size = second & 0x7F
                    if size == 126:
                        size = struct.unpack("!H", read(2))[0]
                    elif size == 127:
                        size = struct.unpack("!Q", read(8))[0]
                    mask = read(4) if second & 0x80 else b"\0\0\0\0"
                    data = bytes(b ^ mask[i % 4] for i, b in enumerate(read(size)))
                    if first & 0x0F == 8:
                        return
                    if first & 0x0F != 1:
                        continue
                    join_ref, ref, topic, event, payload = json.loads(data)
                    if topic == "phoenix":
                        send([None, ref, topic, "phx_reply", {"status": "ok", "response": {}}])
                        continue
                    with self.lock:
                        self.messages.append((topic, event, payload))
                    send([join_ref, ref, topic, "phx_reply", {"status": "ok", "response": {}}])
                    if event == "phx_join":
                        send([join_ref, None, topic, "target", {"target": None}])
            except (EOFError, OSError):
                return

    def snapshot(self):
        with self.lock:
            return list(self.upgrades), list(self.messages)

    def close(self):
        try:
            self.listener.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.listener.close()
        self.thread.join(timeout=5)


class Worker:
    def __init__(self, binary, bootstrap, root, label):
        self.binary, self.root, self.label = binary, root, label
        self.env = dict(os.environ, YELLOW_DOG_WORKER_BOOTSTRAP=str(bootstrap),
                        RELEASE_DISTRIBUTION="sname", RELEASE_NODE=f"package_{label}_{os.getpid()}",
                        RELEASE_COOKIE=f"package_cookie_{os.getpid()}", ERL_FLAGS="+S 2:2 +A 2")
        self.process = None
        self.logs = []

    def start(self, ready="YellowDog.Worker.status().ready"):
        log = open(self.root / f"{self.label}-{len(self.logs)}.log", "w")
        self.logs.append(log)
        self.process = subprocess.Popen([str(self.binary), "start"], env=self.env, stdout=log,
                                        stderr=subprocess.STDOUT, start_new_session=True)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise AssertionError(f"release exited; {log.name}:\n{pathlib.Path(log.name).read_text()}")
            try:
                if "READY" in self.eval(f'if ({ready}), do: IO.puts("READY")'):
                    return
            except (AssertionError, subprocess.TimeoutExpired):
                pass
            time.sleep(0.1)
        raise AssertionError(f"release boot timed out; logs in {self.root}")

    def eval(self, expression):
        return rpc(self.binary, self.env, expression)

    def stop(self, crash=False):
        process, self.process = self.process, None
        if process:
            assert process.poll() is None, f"release unexpectedly exited {process.returncode}"
            start = time.monotonic()
            if crash:
                os.killpg(process.pid, signal.SIGKILL)
            else:
                # Keep lock helpers alive while BEAM performs owned shutdown.
                os.kill(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=45)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
                raise AssertionError(f"release graceful shutdown exceeded 45 seconds; logs in {self.root}")
            if not crash:
                assert process.returncode == 0, f"release shutdown exited {process.returncode}"
                evidence = pathlib.Path(self.logs[-1].name).read_text()
                assert "owned_shutdown_failed" not in evidence and "lock_lost" not in evidence, evidence
                print(f"PASS graceful shutdown ({time.monotonic() - start:.2f}s)", flush=True)
        time.sleep(0.2)

    def close(self):
        self.stop()
        for log in self.logs:
            log.close()


def main():
    package = pathlib.Path(sys.argv[1]).resolve()
    binaries = list(package.rglob("bin/yellow_dog_worker"))
    assert len(binaries) == 1, binaries
    binary = binaries[0]
    release = binary.parent.parent
    assert list(release.glob("erts-*/bin/beam.smp")), "archive must contain its ERTS runtime"
    assert (release / "README.md").is_file(), "archive must include operator instructions"
    assert (release / "examples/anonymous-bootstrap.toml").is_file(), "archive must include URL-only example"
    assert not shutil.which("elixir") and not shutil.which("mix") and not pathlib.Path("/nix").exists()
    abyss_apps = list(release.glob("lib/abyss-*/ebin/abyss.app"))
    assert len(abyss_apps) == 1, "archive must include the Abyss runtime"
    for optional in ("abyss_raw", "abyss_dhcp_socket", "rustler", "rustler_precompiled"):
        assert not list(release.glob(f"lib/{optional}-*")), f"archive must exclude {optional}"
    assert not list(release.glob("lib/**/Elixir.AbyssDhcpSocket.Native.beam")), "archive must exclude native DHCP implementation"
    assert not list(release.glob("lib/**/priv/**/*dhcp_socket*.so")), "archive must exclude native DHCP artifacts"
    abyss_version = abyss_apps[0].parent.parent.name.removeprefix("abyss-")
    for elf in release.glob("erts-*/bin/beam.smp"):
        result = subprocess.run(["ldd", str(elf)], capture_output=True, text=True)
        links = result.stdout + result.stderr
        assert result.returncode == 0 and "not found" not in links, links
    version = subprocess.run([str(binary), "eval",
        'Application.load(:yellow_dog_worker); Application.load(:abyss); '
        '{:module, Abyss.Server} = Code.ensure_loaded(Abyss.Server); '
        '{:module, Abyss.Transport.UDP} = Code.ensure_loaded(Abyss.Transport.UDP); '
        '{:error, {:missing_optional_dependency, :abyss_raw}} = Abyss.DhcpSocket.Native.open("package-check", self()); '
        'IO.puts("ABYSS=" <> to_string(Application.spec(:abyss, :vsn))); '
        'IO.puts("DHCP=optional_dependency_absent"); '
        'IO.puts("WORKER=" <> to_string(Application.spec(:yellow_dog_worker, :vsn))); '
        'IO.puts("ERTS=" <> to_string(:erlang.system_info(:version))); '
        'IO.puts("RELEASE=" <> System.get_env("RELEASE_VSN"))'],
        env=dict(os.environ, ERL_FLAGS="+S 2:2 +A 2"), capture_output=True, text=True, timeout=30)
    assert version.returncode == 0, version.stdout + version.stderr
    assert f"ABYSS={abyss_version}" in version.stdout
    assert "DHCP=optional_dependency_absent" in version.stdout
    assert "WORKER=" in version.stdout and "ERTS=" in version.stdout and "RELEASE=" in version.stdout
    print("PASS bundled executable version/eval: " + version.stdout.strip().replace("\n", "; "), flush=True)
    fixture = (release / "examples/plan.toml").read_text()
    with socket.socket() as selector:
        selector.bind(("127.0.0.1", 0))
        port = selector.getsockname()[1]
    assert "port = 1053" in fixture
    fixture = fixture.replace("port = 1053", f"port = {port}")
    root = pathlib.Path(tempfile.mkdtemp(prefix="worker-package-"))
    source = root / "plan.toml"
    bootstrap = root / "bootstrap.toml"
    source.write_text(fixture)
    bootstrap.write_text(f'worker_id = "edge-01"\ndata_dir = "{root / "state"}"\nsource = "{source}"\n')
    local = Worker(binary, bootstrap, root, "local")
    managed = None
    anonymous = None
    endpoint = None
    try:
        local.start()
        answers(port, "192.0.2.53")
        print("PASS package authoritative DNS over real UDP and TCP", flush=True)
        changed = fixture.replace("192.0.2.53", "192.0.2.93")
        source.write_text(changed)
        assert "{:ok," in local.eval("IO.inspect(YellowDog.Worker.reload())")
        answers(port, "192.0.2.93")
        local.stop(crash=True)
        source.unlink()
        local.start()
        answers(port, "192.0.2.93")
        assert "SNAPSHOT" in local.eval('if YellowDog.Worker.status().origin == :snapshot, do: IO.puts("SNAPSHOT")')
        print("PASS SIGKILL recovery retains committed DNS without source", flush=True)
        source.write_text(changed.replace('desired_state = "running"', 'desired_state = "stopped"'))
        assert "{:ok," in local.eval("IO.inspect(YellowDog.Worker.reload())")
        closed(port)
        local.stop(crash=True)
        source.write_text(fixture)
        local.start()
        closed(port)
        print("PASS stopped-state durability ignores uncommitted running source on restart", flush=True)
        assert "{:ok," in local.eval("IO.inspect(YellowDog.Worker.reload())")
        answers(port, "192.0.2.53")
        local.stop()
        closed(port)
        local.start()
        answers(port, "192.0.2.53")
        local.stop()
        print("PASS graceful live stop/restart retains committed DNS", flush=True)
        with socket.socket() as unused:
            unused.bind(("127.0.0.1", 0))
            unavailable_port = unused.getsockname()[1]
        managed_bootstrap = root / "managed-bootstrap.toml"
        managed_bootstrap.write_text('worker_id = "edge-managed"\n' +
            f'data_dir = "{root / "managed-state"}"\nmanagement_url = "http://127.0.0.1:{unavailable_port}"\n' +
            'token = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"\n')
        managed = Worker(binary, managed_bootstrap, root, "managed")
        managed.start("YellowDog.Worker.status().live and YellowDog.Worker.status().origin == :awaiting_connection")
        time.sleep(0.3)
        assert "WAITING" in managed.eval('if YellowDog.Worker.status().desired == nil and YellowDog.Worker.status().error == nil, do: IO.puts("WAITING")')
        managed.stop()
        print("PASS managed package boot waits safely when Management is unavailable", flush=True)

        endpoint = ChannelEndpoint()
        url = f"http://127.0.0.1:{endpoint.port}"
        anonymous_bootstrap = root / "anonymous-bootstrap.toml"
        # Exactly the URL is configured; the package must resolve XDG state itself.
        anonymous_bootstrap.write_text(f'management_url = "{url}"\n')
        anonymous = Worker(binary, anonymous_bootstrap, root, "anonymous")
        anonymous.env.pop("STATE_DIRECTORY", None)
        anonymous.env["XDG_STATE_HOME"] = str(root / "xdg-state")
        anonymous.start("YellowDog.Worker.status().live and YellowDog.Worker.status().origin == :awaiting_connection")
        credential = root / "xdg-state/yellow-dog-worker/connection.toml"
        assert credential.is_file() and not credential.is_symlink()
        before = credential.read_bytes()
        auth = tomllib.loads(before.decode())
        assert set(auth) == {"management_url", "worker_id", "token"}
        assert auth["management_url"] == url
        identity = uuid.UUID(auth["worker_id"])
        assert identity.version == 4 and str(identity) == auth["worker_id"]
        assert credential.stat().st_mode & 0o777 == 0o600
        assert credential.parent.stat().st_mode & 0o777 == 0o700
        token_bytes = base64.urlsafe_b64decode(auth["token"] + "=")
        assert len(token_bytes) == 32
        assert base64.urlsafe_b64encode(token_bytes).decode().rstrip("=") == auth["token"]

        expected_report = {"worker_id": auth["worker_id"], "capabilities": ["dns"], "services": {},
                           "applied_revision": None, "applied_digest": None, "apply_error": None}

        def checked_joins(minimum):
            # Each session: one upgrade without credentials, a join carrying the
            # token, then a report answering the pushed (empty) target.
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                upgrades, messages = endpoint.snapshot()
                joins = [payload for _, event, payload in messages if event == "phx_join"]
                reports = [payload for _, event, payload in messages if event == "report"]
                if len(joins) >= minimum and len(reports) >= minimum:
                    for head in upgrades:
                        assert head.startswith("GET /api/worker/connect?vsn=2.0.0&worker_id="
                                               + auth["worker_id"] + " HTTP/1.1\r\n"), head
                        assert auth["token"] not in head and "authorization" not in head.lower(), head
                    assert {topic for topic, _, _ in messages} == {"worker:" + auth["worker_id"]}
                    assert all(join == {"token": auth["token"], "report": expected_report} for join in joins)
                    assert all(report == expected_report for report in reports)
                    return len(joins)
                time.sleep(0.1)
            raise AssertionError("anonymous package did not join the Worker channel and report")

        count = checked_joins(1)
        connected = ('pid = Enum.find_value(Supervisor.which_children(YellowDog.Worker.Supervisor), '
                     'fn {id, pid, _, _} -> if id == YellowDog.Worker.Connection, do: pid end); '
                     'if YellowDog.Worker.Connection.status(pid) == '
                     '%{connected: true, connection_error: nil, apply_error: nil}, '
                     'do: IO.puts("CONNECTED"), else: raise("connection response was not accepted")')
        assert "CONNECTED" in anonymous.eval(connected)
        anonymous.stop()
        anonymous.start("YellowDog.Worker.status().live and YellowDog.Worker.status().origin == :awaiting_connection")
        checked_joins(count + 1)
        assert "CONNECTED" in anonymous.eval(connected)
        assert credential.read_bytes() == before
        assert credential.stat().st_mode & 0o777 == 0o600
        anonymous.stop()
        print("PASS URL-only package initialization: private stable identity, token-in-join WebSocket channel reports and graceful restart", flush=True)
        print("LINUX WORKER PACKAGE SMOKE PASSED", flush=True)
    except BaseException:
        for worker in [local, managed, anonymous]:
            if worker:
                for log in worker.logs:
                    print(f"Runtime evidence {log.name}:\n" + pathlib.Path(log.name).read_text()[-16384:],
                          file=sys.stderr, flush=True)
        raise
    finally:
        try:
            try:
                if anonymous:
                    anonymous.close()
            finally:
                if managed:
                    managed.close()
        finally:
            try:
                local.close()
            finally:
                if endpoint:
                    endpoint.close()
                shutil.rmtree(root)


if __name__ == "__main__":
    main()
