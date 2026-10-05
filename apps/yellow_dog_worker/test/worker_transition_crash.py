#!/usr/bin/env python3
"""Deterministic release SIGKILL boundaries; not physical power-loss evidence."""
import os
import pathlib
import select
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import tomllib


class Scenario:
    def __init__(self, release, boundary, stopped=False, first_boot=False):
        self.release = release
        self.boundary = boundary
        self.stopped = stopped
        self.first_boot = first_boot
        self.root = pathlib.Path(tempfile.mkdtemp(prefix=f"phase1-worker-transition-journal-{boundary}-"))
        self.source = self.root / "plan.toml"
        self.state = self.root / "state"
        self.fifo = self.root / "barrier"
        os.mkfifo(self.fifo)
        self.fifo_fd = os.open(self.fifo, os.O_RDWR | os.O_NONBLOCK)
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            self.port = sock.getsockname()[1]
        self.fixture = (pathlib.Path(__file__).parents[1] / "examples/plan.toml").read_text()
        self.fixture = self.fixture.replace("port = 1053", f"port = {self.port}")
        self.source.write_text("invalid source" if first_boot else self.fixture)
        bootstrap = self.root / "bootstrap.toml"
        bootstrap.write_text(f'worker_id = "edge-01"\nsource = "{self.source}"\ndata_dir = "{self.state}"\n')
        self.env = {key: value for key, value in os.environ.items()
                    if not key.upper().startswith("PG") and
                    not any(word in key.upper() for word in ("MANAGEMENT", "POSTGRES", "DATABASE_URL"))}
        self.env.update(YELLOW_DOG_WORKER_BOOTSTRAP=str(bootstrap), RELEASE_DISTRIBUTION="sname",
                        RELEASE_NODE=f"journal_{os.getpid()}", RELEASE_COOKIE=f"journal_cookie_{os.getpid()}",
                        ERL_FLAGS="+S 2:2 +A 2")
        self.process = None
        self.reload_process = None
        self.logs = []

    def rpc(self, expression):
        result = subprocess.run([str(self.release), "rpc", expression], env=self.env,
                                text=True, capture_output=True, timeout=25)
        assert result.returncode == 0, (result.stdout, result.stderr, self.root)
        return result.stdout.strip()

    def assertion(self, expression):
        assert "PASS" in self.rpc(f'if ({expression}), do: IO.puts("PASS"), else: raise("assertion failed")')

    def start(self):
        log = open(self.root / f"boot-{len(self.logs)}.log", "w")
        self.logs.append(log)
        self.process = subprocess.Popen([str(self.release), "start"], env=self.env, stdout=log,
                                        stderr=subprocess.STDOUT, start_new_session=True)
        for _ in range(80):
            assert self.process.poll() is None, self.root
            try:
                self.rpc('IO.inspect(YellowDog.Worker.status().ready)')
                return
            except (AssertionError, subprocess.TimeoutExpired):
                continue
        raise AssertionError(f"startup timeout: {self.root}")

    def stop(self, crash=False):
        if self.process and self.process.poll() is None:
            os.killpg(self.process.pid, signal.SIGKILL if crash else signal.SIGTERM)
            self.process.wait(timeout=15)
        self.process = None
        if self.reload_process:
            try:
                self.reload_process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.reload_process.kill()
                self.reload_process.wait(timeout=10)
            self.reload_process = None

    def query(self, tcp, qtype=1):
        name = "ns1.example.com" if qtype == 1 else "example.com"
        encoded = b"".join(bytes([len(label)]) + label.encode() for label in name.split(".")) + b"\0"
        packet = struct.pack("!6H", 1234, 0x0100, 1, 0, 0, 0) + encoded + struct.pack("!HH", qtype, 1)
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM if tcp else socket.SOCK_DGRAM) as sock:
            sock.settimeout(0.5)
            if tcp:
                sock.connect(("127.0.0.1", self.port))
                sock.sendall(struct.pack("!H", len(packet)) + packet)
                data = self.recv_exact(sock, struct.unpack("!H", self.recv_exact(sock, 2))[0])
            else:
                sock.sendto(packet, ("127.0.0.1", self.port))
                data = sock.recv(65535)
        identity, flags, questions, answers, _, _ = struct.unpack("!6H", data[:12])
        assert identity == 1234 and flags & 0x8400 == 0x8400 and answers == 1
        offset = 12
        for _ in range(questions):
            offset = self.skip_name(data, offset) + 4
        offset = self.skip_name(data, offset)
        kind, _, _, size = struct.unpack("!HHIH", data[offset:offset + 10])
        assert kind == qtype
        return socket.inet_ntoa(data[offset + 10:offset + 10 + size]) if kind == 1 else kind

    @staticmethod
    def recv_exact(sock, count):
        result = b""
        while len(result) < count:
            part = sock.recv(count - len(result))
            assert part, "truncated TCP answer"
            result += part
        return result

    @staticmethod
    def skip_name(data, offset):
        while data[offset]:
            size = data[offset]
            if size & 0xC0 == 0xC0:
                return offset + 2
            offset += size + 1
        return offset + 1

    def answers(self, address):
        for tcp in (False, True):
            assert self.query(tcp) == address, self.root
            for qtype in (2, 6):
                assert self.query(tcp, qtype) == qtype

    def no_listeners(self):
        for tcp in (False, True):
            try:
                self.query(tcp)
            except OSError:
                continue
            raise AssertionError(f"stopped service answered: {self.root}")

    def run(self):
        try:
            self.start()
            self.assertion(f'YellowDog.Worker.status().ready == {str(not self.first_boot).lower()}')
            if not self.first_boot:
                self.answers("192.0.2.53")
            hooks = pathlib.Path(__file__).with_name("transition_crash_hooks.exs").resolve()
            self.rpc(f'Code.compile_file("{hooks}"); YellowDog.Worker.TransitionCrashOps.arm("{self.boundary}", "{self.fifo}")')
            candidate = self.fixture.replace("192.0.2.53", "192.0.2.99").replace("revision = 1", "revision = 2")
            if self.stopped:
                candidate = candidate.replace('desired_state = "running"', 'desired_state = "stopped"')
            self.source.write_text(candidate)
            log = open(self.root / "reload.log", "w")
            self.logs.append(log)
            self.reload_process = subprocess.Popen([str(self.release), "rpc", 'IO.inspect(YellowDog.Worker.reload())'],
                                                   env=self.env, stdout=log, stderr=subprocess.STDOUT)
            readable, _, _ = select.select([self.fifo_fd], [], [], 20)
            assert readable, f"barrier not reached: {self.root}"
            assert os.read(self.fifo_fd, 4096).decode().strip() == self.boundary
            record = tomllib.loads((self.state / "journal/transition.toml").read_text())
            (self.root / "crash-record.toml").write_text((self.state / "journal/transition.toml").read_text())
            if self.boundary in ("during_action", "after_action"):
                assert record["actions"][-1]["status"] == "dispatched"
            if self.boundary == "after_action" and not self.stopped:
                self.answers("192.0.2.99")
            self.stop(crash=True)
            self.source.unlink()
            self.start()
            if self.first_boot:
                self.assertion('not YellowDog.Worker.status().ready and YellowDog.Worker.status().desired == nil')
                self.no_listeners()
                self.source.write_text(candidate)
                assert "{:ok, :committed}" in self.rpc('IO.inspect(YellowDog.Worker.reload())')
                self.answers("192.0.2.99")
            else:
                self.assertion('YellowDog.Worker.status().ready')
                committed = self.boundary in ("pointer_committed", "finalization", "after_finalization")
                expected = "192.0.2.99" if committed else "192.0.2.53"
                if committed and self.stopped:
                    self.no_listeners()
                    self.source.write_text(candidate)
                    assert ":unchanged" in self.rpc('IO.inspect(YellowDog.Worker.reload())')
                    self.no_listeners()
                    self.source.write_text(candidate.replace('desired_state = "stopped"', 'desired_state = "running"'))
                    assert ":committed" in self.rpc('IO.inspect(YellowDog.Worker.reload())')
                    self.answers("192.0.2.99")
                else:
                    self.answers(expected)
                self.assertion('YellowDog.Worker.status().transition["phase"] == "complete"')
            print(f"PASS OS SIGKILL {self.boundary} stopped={self.stopped} first_boot={self.first_boot}: {self.root}", flush=True)
        finally:
            self.stop()
            os.close(self.fifo_fd)
            for log in self.logs:
                log.close()


if __name__ == "__main__":
    binary = pathlib.Path(sys.argv[1]).resolve()
    boundaries = ("before_dispatch", "during_action", "after_action", "commit_intent", "pointer_rename",
                  "pointer_sync", "pointer_committed", "finalization", "after_finalization")
    for boundary in boundaries:
        Scenario(binary, boundary).run()
    Scenario(binary, "pointer_committed", stopped=True).run()
    Scenario(binary, "before_dispatch", first_boot=True).run()
    print("PASS 11 deterministic OS crash scenarios; real independent UDP/TCP; no editable-source fallback", flush=True)
