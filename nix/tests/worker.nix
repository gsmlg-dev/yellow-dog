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

    with subtest("URL-only bootstrap persists identity and joins the Management WebSocket channel"):
        stop()
        worker.succeed("rm -rf /var/lib/yellow-dog-worker")
        write("/run/secrets/worker-bootstrap.toml", 'management_url = "http://127.0.0.1:4270"\n')
        worker.succeed("systemctl start yellow-dog-worker")
        ready()
        worker.wait_until_succeeds("test -f /var/lib/yellow-dog-worker/connection.toml")
        identity = worker.succeed("sha256sum /var/lib/yellow-dog-worker/connection.toml")
        pid = worker.succeed("systemctl show yellow-dog-worker -p MainPID --value")
        stopped()
        # Record real WebSocket channel joins after an initial outage. The fake
        # endpoint is a minimal Phoenix V2 channel server (upgrade, phx_join,
        # report, heartbeat); it supplies no plan and never starts a service.
        write("/run/fake-management.py", """
    import base64, hashlib, json, pathlib, socket, struct, threading, tomllib
    identity = tomllib.loads(pathlib.Path('/var/lib/yellow-dog-worker/connection.toml').read_text())
    token, worker_id = identity['token'], identity['worker_id']
    expected_report = {'worker_id': worker_id, 'capabilities': ['dns'], 'services': {},
                       'applied_revision': None, 'applied_digest': None, 'apply_error': None}
    lock = threading.Lock()
    def bump(name):
        path = pathlib.Path('/run/worker-' + name)
        with lock:
            path.write_text(str(int(path.read_text()) + 1) if path.exists() else '1')
    def session(connection):
        buffer = b""
        while b"\\r\\n\\r\\n" not in buffer:
            chunk = connection.recv(4096)
            if not chunk:
                return
            buffer += chunk
        head, buffer = buffer.split(b"\\r\\n\\r\\n", 1)
        head = head.decode()
        request = head.split("\\r\\n")[0]
        assert request == 'GET /api/worker/connect?vsn=2.0.0&worker_id=' + worker_id + ' HTTP/1.1', request
        # The token travels only in the join payload, never in the URL or headers.
        assert token not in head and 'authorization:' not in head.lower(), head
        key = next(line.split(':', 1)[1].strip() for line in head.split("\\r\\n")
                   if line.lower().startswith('sec-websocket-key:'))
        accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        connection.sendall(('HTTP/1.1 101 Switching Protocols\\r\\nUpgrade: websocket\\r\\n'
                            'Connection: Upgrade\\r\\nSec-WebSocket-Accept: ' + accept + '\\r\\n\\r\\n').encode())
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
            length = bytes([len(data)]) if len(data) < 126 else bytes([126]) + struct.pack('!H', len(data))
            connection.sendall(bytes([0x81]) + length + data)
        while True:
            first, second = read(2)
            size = second & 0x7F
            if size == 126:
                size = struct.unpack('!H', read(2))[0]
            elif size == 127:
                size = struct.unpack('!Q', read(8))[0]
            mask = read(4) if second & 0x80 else bytes(4)
            data = bytes(b ^ mask[i % 4] for i, b in enumerate(read(size)))
            if first & 0x0F == 8:
                return
            if first & 0x0F != 1:
                continue
            join_ref, ref, topic, event, payload = json.loads(data)
            if topic == 'phoenix':
                send([None, ref, topic, 'phx_reply', {'status': 'ok', 'response': {}}])
                continue
            assert topic == 'worker:' + worker_id, topic
            if event == 'phx_join':
                assert payload == {'token': token, 'report': expected_report}, payload
                bump('joins')
            elif event == 'report':
                assert payload == expected_report, payload
                bump('reports')
            send([join_ref, ref, topic, 'phx_reply', {'status': 'ok', 'response': {}}])
            if event == 'phx_join':
                send([join_ref, None, topic, 'target', {'target': None}])
    def guarded(connection):
        with connection:
            try:
                session(connection)
            except (EOFError, OSError):
                pass
            except AssertionError as error:
                pathlib.Path('/run/worker-protocol-error').write_text(str(error))
    listener = socket.create_server(('127.0.0.1', 4270))
    while True:
        connection, _ = listener.accept()
        threading.Thread(target=guarded, args=(connection,), daemon=True).start()
    """)
        worker.succeed("systemd-run --unit=fake-management python3 /run/fake-management.py")
        worker.wait_until_succeeds("test -f /run/worker-joins && test -f /run/worker-reports")
        worker.succeed("test ! -e /run/worker-protocol-error || (cat /run/worker-protocol-error; false)")
        assert worker.succeed("systemctl show yellow-dog-worker -p MainPID --value") == pid
        joins = int(worker.succeed("cat /run/worker-joins").strip())
        restart()
        assert worker.succeed("sha256sum /var/lib/yellow-dog-worker/connection.toml") == identity
        worker.wait_until_succeeds(f"test $(cat /run/worker-joins) -gt {joins}")
        worker.succeed("test ! -e /run/worker-protocol-error || (cat /run/worker-protocol-error; false)")
        worker.succeed("test -z \"$(find /var/lib/yellow-dog-worker/snapshots -name '*.toml' -print -quit)\"")
        stopped()
        worker.succeed("systemctl stop fake-management")
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
