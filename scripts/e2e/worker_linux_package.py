#!/usr/bin/env python3
"""Clean Linux archive acceptance using only the bundled release and OS tools."""
import os
import errno
import pathlib
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time


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
        if self.process and self.process.poll() is None:
            start = time.monotonic()
            os.killpg(self.process.pid, signal.SIGKILL if crash else signal.SIGTERM)
            try:
                self.process.wait(timeout=45)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait(timeout=5)
                raise AssertionError(f"release graceful shutdown exceeded 45 seconds; logs in {self.root}")
            if not crash:
                print(f"PASS graceful shutdown ({time.monotonic() - start:.2f}s)", flush=True)
        self.process = None
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
    assert not shutil.which("elixir") and not shutil.which("mix") and not pathlib.Path("/nix").exists()
    native = list(release.glob("lib/abyss-*/priv/native/dhcp_socket.so"))
    assert native, "archive must include Abyss native socket library"
    for elf in [*release.glob("erts-*/bin/beam.smp"), *native]:
        result = subprocess.run(["ldd", str(elf)], capture_output=True, text=True)
        links = result.stdout + result.stderr
        assert result.returncode == 0 and "not found" not in links, links
    version = subprocess.run([str(binary), "eval",
        'Application.load(:yellow_dog_worker); {:module, Abyss.DhcpSocket.Native} = Code.ensure_loaded(Abyss.DhcpSocket.Native); IO.puts("NIF=loaded"); IO.puts("WORKER=" <> to_string(Application.spec(:yellow_dog_worker, :vsn))); IO.puts("ERTS=" <> to_string(:erlang.system_info(:version))); IO.puts("RELEASE=" <> System.get_env("RELEASE_VSN"))'],
        env=dict(os.environ, ERL_FLAGS="+S 2:2 +A 2"), capture_output=True, text=True, timeout=30)
    assert version.returncode == 0, version.stdout + version.stderr
    assert "NIF=loaded" in version.stdout and "WORKER=" in version.stdout and "ERTS=" in version.stdout and "RELEASE=" in version.stdout
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
            'token = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"\npoll_interval_ms = 100\n')
        managed = Worker(binary, managed_bootstrap, root, "managed")
        managed.start("YellowDog.Worker.status().live and YellowDog.Worker.status().origin == :awaiting_connection")
        time.sleep(0.3)
        assert "WAITING" in managed.eval('if YellowDog.Worker.status().desired == nil and YellowDog.Worker.status().error == nil, do: IO.puts("WAITING")')
        managed.stop()
        print("PASS managed package boot waits safely when Management is unavailable", flush=True)
        print("LINUX WORKER PACKAGE SMOKE PASSED", flush=True)
    except BaseException:
        for worker in [local, managed]:
            if worker:
                for log in worker.logs:
                    print(f"Runtime evidence {log.name}:\n" + pathlib.Path(log.name).read_text()[-16384:],
                          file=sys.stderr, flush=True)
        raise
    finally:
        try:
            if managed:
                managed.close()
        finally:
            local.close()
            shutil.rmtree(root)


if __name__ == "__main__":
    main()
