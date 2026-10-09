{
  pkgs,
  workerPackage,
  workerModule,
}:
pkgs.testers.runNixOSTest {
  name = "yellow-dog-worker";

  nodes.worker = {lib, ...}: {
    imports = [workerModule];
    services.yellow-dog-worker = {
      enable = true;
      package = workerPackage;
      bootstrapFile = "/run/secrets/worker-bootstrap.toml";
    };
    # Provision bootstrap credentials in the test at runtime, never in the store.
    systemd.services.yellow-dog-worker.wantedBy = lib.mkForce [];
    systemd.services.yellow-dog-worker.environment.PATH = lib.mkForce "/unavailable";
    environment.systemPackages = [pkgs.python3 pkgs.bind.dnsutils];
    virtualisation.memorySize = 1536;
    virtualisation.cores = 2;
    virtualisation.diskSize = 4096;
  };

  testScript = ''
    import shlex

    start_all()
    worker.wait_for_unit("multi-user.target")

    def write(path, text):
        worker.succeed("printf %s " + shlex.quote(text) + " > " + shlex.quote(path))

    def ready():
        # A BEAM PID alone appears before Application.start/2. The exclusive
        # data lock proves LocalStore has started and its helper is still alive.
        worker.wait_until_succeeds("test -f /var/lib/yellow-dog-worker/.lock && ! ${pkgs.util-linux}/bin/flock -n /var/lib/yellow-dog-worker/.lock true")
        worker.succeed("systemctl is-active yellow-dog-worker")

    def stop():
        worker.succeed("systemctl stop yellow-dog-worker")
        assert worker.succeed("systemctl show yellow-dog-worker -p Result --value").strip() == "success"
        assert worker.succeed("systemctl show yellow-dog-worker -p ExecMainStatus --value").strip() == "0"
        assert worker.succeed("systemctl show yellow-dog-worker -p ActiveState --value").strip() == "inactive"
        worker.succeed("${pkgs.util-linux}/bin/flock -n /var/lib/yellow-dog-worker/.lock true")
        journal = worker.succeed("journalctl -u yellow-dog-worker --no-pager")
        for failure in ("owned_shutdown_failed", "lock_lost", "GenServer", "timed out", "Killing process"):
            assert failure not in journal, journal

    def restart():
        stop()
        worker.succeed("systemctl start yellow-dog-worker")
        ready()

    def dns():
        for transport in ("+notcp", "+tcp"):
            result = worker.succeed("dig @127.0.0.1 -p 53 ns1.example.com A +time=1 +tries=1 " + transport)
            assert "status: NOERROR" in result and "flags: qr aa" in result, result
            assert "192.0.2.53" in result, result

    def stopped():
        worker.fail("dig @127.0.0.1 -p 53 ns1.example.com A +time=1 +tries=1 +notcp")
        worker.succeed("python3 -c " + shlex.quote("""
    import errno, socket
    with socket.socket() as sock:
        sock.settimeout(1)
        try:
            sock.connect(('127.0.0.1', 53))
        except OSError as error:
            assert error.errno == errno.ECONNREFUSED, error
        else:
            raise AssertionError('stopped DNS still accepts TCP')
    """))

    worker.succeed("install -d -m 0700 /run/secrets; install -d -m 0755 /var/lib/worker-input")
    plan = ${builtins.toJSON (builtins.replaceStrings ["port = 1053"] ["port = 53"] (builtins.readFile ../../apps/yellow_dog_worker/examples/plan.toml))}
    write("/var/lib/worker-input/plan.toml", plan)
    write("/run/secrets/worker-bootstrap.toml", 'worker_id = "edge-01"\ndata_dir = "/var/lib/yellow-dog-worker"\nsource = "/var/lib/worker-input/plan.toml"\n')
    worker.succeed("chmod 0600 /run/secrets/worker-bootstrap.toml")

    with subtest("default module startup uses runtime cookie and package helper PATH"):
        worker.succeed("systemctl start yellow-dog-worker")
        ready()
        worker.wait_for_open_port(53)
        dns()
        worker.succeed("test $(systemctl show yellow-dog-worker -p User --value) = yellow-dog-worker")
        worker.succeed("test $(stat -c %U:%a /run/secrets/worker-bootstrap.toml) = root:600")
        worker.succeed("test $(stat -c %U:%a /var/lib/yellow-dog-worker) = yellow-dog-worker:700")
        worker.succeed("python3 -c " + shlex.quote("""
    import pathlib, subprocess
    pid = subprocess.check_output(['systemctl', 'show', 'yellow-dog-worker', '-p', 'MainPID', '--value'], text=True).strip()
    root = pathlib.Path('/proc') / pid
    env = dict(item.split(b'=', 1) for item in (root / 'environ').read_bytes().split(bytes([0])) if b'=' in item)
    assert env[b'RELEASE_DISTRIBUTION'] == b'none'
    assert env[b'RELEASE_COOKIE'] and not env[b'RELEASE_COOKIE'].startswith(b'/nix/store')
    path = pathlib.Path(env[b'YELLOW_DOG_WORKER_BOOTSTRAP'].decode())
    assert str(path).startswith('/run/credentials/') and path.is_file() and not path.is_symlink()
    assert path.read_bytes() == pathlib.Path('/run/secrets/worker-bootstrap.toml').read_bytes()
    status = (root / 'status').read_text()
    assert next(line for line in status.splitlines() if line.startswith('Uid:')).split()[1] != '0'
    # The kernel must actually require the bind capability for privileged ports.
    assert pathlib.Path('/proc/sys/net/ipv4/ip_unprivileged_port_start').read_text().strip() == '1024'
    cap = int(next(line for line in status.splitlines() if line.startswith('CapEff:')).split()[1], 16)
    assert cap & (1 << 10), 'missing CAP_NET_BIND_SERVICE'
    """))

    with subtest("committed running snapshot restores without source"):
        worker.wait_until_succeeds("test -f /var/lib/yellow-dog-worker/current")
        before = worker.succeed("sha256sum /var/lib/yellow-dog-worker/snapshots/*.toml")
        worker.succeed("rm /var/lib/worker-input/plan.toml")
        restart()
        worker.wait_for_open_port(53)
        dns()
        assert worker.succeed("sha256sum /var/lib/yellow-dog-worker/snapshots/*.toml") == before

    with subtest("stopped snapshot persists across restart and uncommitted running source"):
        stop()
        worker.succeed("rm -rf /var/lib/yellow-dog-worker")
        write("/var/lib/worker-input/plan.toml", plan.replace('desired_state = "running"', 'desired_state = "stopped"').replace('revision = 1', 'revision = 2'))
        worker.succeed("systemctl start yellow-dog-worker")
        ready()
        worker.wait_until_succeeds("test -f /var/lib/yellow-dog-worker/current")
        before = worker.succeed("sha256sum /var/lib/yellow-dog-worker/snapshots/*.toml")
        pointer = worker.succeed("cat /var/lib/yellow-dog-worker/current")
        stopped()
        write("/var/lib/worker-input/plan.toml", plan.replace('revision = 1', 'revision = 3'))
        restart()
        assert worker.succeed("sha256sum /var/lib/yellow-dog-worker/snapshots/*.toml") == before
        assert worker.succeed("cat /var/lib/yellow-dog-worker/current") == pointer
        stopped()

    with subtest("URL-only bootstrap persists identity and awaits Management"):
        stop()
        worker.succeed("rm -rf /var/lib/yellow-dog-worker")
        write("/run/secrets/worker-bootstrap.toml", 'management_url = "http://127.0.0.1:4270"\n')
        worker.succeed("systemctl start yellow-dog-worker")
        ready()
        worker.wait_until_succeeds("test -f /var/lib/yellow-dog-worker/connection.toml")
        identity = worker.succeed("sha256sum /var/lib/yellow-dog-worker/connection.toml")
        pid = worker.succeed("systemctl show yellow-dog-worker -p MainPID --value")
        stopped()
        # Record real authenticated polling after an initial outage. The fake
        # endpoint supplies no plan and never starts a network service.
        write("/run/unavailable-management.py", """
    from http.server import BaseHTTPRequestHandler, HTTPServer
    import json, pathlib, tomllib
    identity = tomllib.loads(pathlib.Path('/var/lib/yellow-dog-worker/connection.toml').read_text())
    token, worker_id = identity['token'], identity['worker_id']
    class Unavailable(BaseHTTPRequestHandler):
        def do_POST(self):
            report = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            assert self.path == '/api/worker/connect'
            assert self.headers['Authorization'] == 'Bearer ' + token
            assert report['worker_id'] == worker_id and report['capabilities'] == ['dns']
            assert report['services'] == {} and report['applied_revision'] is None
            assert report['applied_digest'] is None and report['apply_error'] is None
            path = pathlib.Path('/run/worker-polls')
            path.write_text(str(int(path.read_text()) + 1) if path.exists() else '1')
            body = json.dumps({'worker_id': worker_id, 'target': None}).encode()
            self.send_response(200)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def log_message(self, *args):
            pass
    HTTPServer(('127.0.0.1', 4270), Unavailable).serve_forever()
    """)
        worker.succeed("systemd-run --unit=unavailable-management python3 /run/unavailable-management.py")
        worker.wait_until_succeeds("test -f /run/worker-polls && test $(cat /run/worker-polls) -ge 3")
        assert worker.succeed("systemctl show yellow-dog-worker -p MainPID --value") == pid
        polls = int(worker.succeed("cat /run/worker-polls").strip())
        restart()
        assert worker.succeed("sha256sum /var/lib/yellow-dog-worker/connection.toml") == identity
        worker.wait_until_succeeds(f"test $(cat /run/worker-polls) -gt {polls}")
        worker.succeed("test -z \"$(find /var/lib/yellow-dog-worker/snapshots -name '*.toml' -print -quit)\"")
        stopped()
        worker.succeed("systemctl stop unavailable-management")
        stopped()
        worker.succeed("python3 -c " + shlex.quote("""
    import pathlib, subprocess, tomllib
    bootstrap = pathlib.Path('/run/secrets/worker-bootstrap.toml')
    identity = pathlib.Path('/var/lib/yellow-dog-worker/connection.toml')
    token = tomllib.loads(identity.read_text())['token']
    assert identity.stat().st_mode & 0o777 == 0o600
    assert pathlib.Path('/var/lib/yellow-dog-worker').stat().st_mode & 0o777 == 0o700
    assert bootstrap.stat().st_uid == 0 and bootstrap.stat().st_mode & 0o777 == 0o600
    assert token not in subprocess.check_output(['journalctl', '-u', 'yellow-dog-worker'], text=True)
    assert token not in subprocess.check_output(['systemctl', 'cat', 'yellow-dog-worker'], text=True)
    pid = subprocess.check_output(['systemctl', 'show', 'yellow-dog-worker', '-p', 'MainPID', '--value'], text=True).strip()
    environment = pathlib.Path('/proc', pid, 'environ').read_bytes()
    assert token.encode() not in environment
    env = dict(item.split(b'=', 1) for item in environment.split(bytes([0])) if b'=' in item)
    assert env[b'RELEASE_DISTRIBUTION'] == b'none'
    credential = pathlib.Path(env[b'YELLOW_DOG_WORKER_BOOTSTRAP'].decode())
    assert credential.is_file() and not credential.is_symlink()
    assert credential.read_bytes() == bootstrap.read_bytes()
    """))
        stop()
  '';
}
