"""Browser, release restart and durable artifact acceptance on disposable PostgreSQL.

devenv shell -- scripts/e2e/phase1_postgres.sh python3 \
  apps/yellow_dog_management/test/management_configuration_smoke.py \
  _build/prod/rel/yellow_dog_management/bin/yellow_dog_management [--p1-only]
Build the current Management release before invoking this harness. No Worker starts.
"""
import argparse
import base64
import gzip
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import tempfile
import threading
import time
import urllib.request
import uuid


def encode_mmdb(value):
    if isinstance(value, dict):
        return bytes([224 + len(value)]) + b"".join(encode_mmdb(k) + encode_mmdb(v) for k, v in value.items())
    if isinstance(value, str):
        encoded = value.encode()
        assert len(encoded) < 29
        return bytes([64 + len(encoded)]) + encoded
    if isinstance(value, int):
        return bytes([196]) + value.to_bytes(4, "big")
    if isinstance(value, list):
        return bytes([len(value), 4]) + b"".join(map(encode_mmdb, value))
    raise TypeError(value)


def country_fixture():
    metadata = {"binary_format_major_version": 2, "binary_format_minor_version": 0,
                "build_epoch": 1750000000, "database_type": "GeoIP2-Country",
                "description": {"en": "Synthetic test database"}, "ip_version": 4,
                "languages": ["en"], "node_count": 1, "record_size": 24}
    return bytes([0, 0, 1, 0, 0, 1]) + bytes(16) + b"\xab\xcd\xefMaxMind.com" + encode_mmdb(metadata)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--p1-only", action="store_true")
    args = parser.parse_args()
    binary = args.binary.resolve()
    pg_directory = Path(os.environ["YELLOW_DOG_PHASE1_PG_DATA_DIR"])
    assert pg_directory.joinpath("PG_VERSION").is_file(), "Use the disposable PostgreSQL helper"
    assert binary.is_file(), "Build the current Management release first"
    directory = Path(tempfile.mkdtemp(prefix="yellow-dog-management-configuration-"))
    evidence = directory / "browser-evidence.json"
    fixtures = {
        "city": base64.b64decode((Path(__file__).parent / "fixtures/geoip/GeoIP2-City-Test.mmdb.base64").read_text()),
        "country": country_fixture(),
    }
    digests = {kind: hashlib.sha256(contents).hexdigest() for kind, contents in fixtures.items()}
    failed_source = threading.Event()

    class Fixture(BaseHTTPRequestHandler):
        def do_GET(self):
            kind = self.path.removeprefix("/")
            success = kind in fixtures and not failed_source.is_set()
            body = gzip.compress(fixtures[kind]) if success else b"fixture source unavailable"
            self.send_response(200 if success else 503)
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
    env = dict(os.environ, RELEASE_DISTRIBUTION="none", YELLOW_DOG_MANAGEMENT_BIND_ADDRESS="127.0.0.1",
               YELLOW_DOG_MANAGEMENT_PORT=str(port), YELLOW_DOG_MANAGEMENT_ARTIFACT_DIRECTORY=str(directory / "artifacts"),
               YELLOW_DOG_MANAGEMENT_BACKUP_DIRECTORY=str(directory / "backups"), MANAGEMENT_UI_URL=base,
               MANAGEMENT_CONFIGURATION_EVIDENCE=str(evidence), MANAGEMENT_CONFIGURATION_DIGESTS=json.dumps(digests),
               MANAGEMENT_CONFIGURATION_P1_ONLY="1" if args.p1_only else "0",
               YELLOW_DOG_MANAGEMENT_GEOIP_CITY_URL=f"http://127.0.0.1:{fixture.server_port}/city",
               YELLOW_DOG_MANAGEMENT_GEOIP_COUNTRY_URL=f"http://127.0.0.1:{fixture.server_port}/country")
    for key in ["YELLOW_DOG_MANAGEMENT_GEOIP_CITY_PATH", "YELLOW_DOG_MANAGEMENT_GEOIP_COUNTRY_PATH", "YELLOW_DOG_MANAGEMENT_MAC_DATABASE_PATH"]:
        env.pop(key, None)
    process = None
    log_path = directory / "management.log"
    log = log_path.open("w")

    def api(path, raw=False):
        with urllib.request.urlopen(base + "/api" + path, timeout=10) as response:
            payload = response.read()
            return payload if raw else json.loads(payload)["data"]

    def wait(check, message):
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if process and process.poll() is not None:
                raise AssertionError(f"Management exited; inspect {log_path}")
            if check():
                return
            time.sleep(.1)
        raise AssertionError(message)

    def start():
        nonlocal process
        process = subprocess.Popen([str(binary), "start_iex"], env=env, stdin=subprocess.PIPE,
                                   stdout=log, stderr=log, text=True)

        def ready():
            try:
                api("/workers")
                return True
            except OSError:
                return False
        wait(ready, "Management HTTP listener did not become ready")
        listeners = subprocess.check_output(["ss", "-lntup"], text=True)
        own = [line for line in listeners.splitlines() if f"pid={process.pid}," in line]
        assert len(own) == 1 and own[0].startswith("tcp ") and f"127.0.0.1:{port} " in own[0], own

    def stop(force=False):
        if process and process.poll() is None:
            process.kill() if force else process.terminate()
            process.wait(timeout=15)

    def probe():
        marker = "YD_CONFIGURATION_" + uuid.uuid4().hex + ":"
        expression = ('IO.puts("' + marker + '" <> Base.encode64(Jason.encode!(%{'
                      'geoip_process: Process.whereis(YellowDog.Management.GeoIP) != nil,'
                      'children: Enum.map(Supervisor.which_children(YellowDog.Management.Supervisor),'
                      'fn {id, pid, type, _modules} -> %{id: inspect(id), alive: is_pid(pid) and Process.alive?(pid), type: type} end),'
                      'applications: Enum.map(Application.started_applications(), fn {name, _, _} -> name end),'
                      'catalog: ' + ('[]' if args.p1_only else 'YellowDog.Management.TaskArtifacts.catalog()') + '})))')
        process.stdin.write(expression + "\n")
        process.stdin.flush()
        matches = []

        def received():
            matches[:] = re.findall(re.escape(marker) + r"([A-Za-z0-9+/=]+)", log_path.read_text())
            return bool(matches)
        wait(received, "Read-only probe did not execute in the running Management process")
        result = json.loads(base64.b64decode(matches[-1]))
        assert not result["geoip_process"], result
        assert not any("GeoIP" in child["id"] for child in result["children"]), result
        forbidden = {"yellow_dog_worker", "yellow_dog_dns", "yellow_dog_dhcpv4", "yellow_dog_dhcpv6",
                     "yellow_dog_management_core", "yellow_dog_console", "yellow_dog_sync", "abyss", "ex_dns"}
        assert not forbidden.intersection(result["applications"]), result
        return result

    def browser(phase):
        profile = tempfile.mkdtemp(prefix="chromium-", dir=directory)
        browser_env = dict(env, MANAGEMENT_CONFIGURATION_PHASE=phase,
                           MANAGEMENT_CONFIGURATION_BROWSER_PROFILE=profile)
        try:
            subprocess.run(["node", str(Path(__file__).with_name("management_configuration_browser_smoke.mjs"))],
                           env=browser_env, check=True, timeout=120)
        except subprocess.TimeoutExpired:
            pid_file = Path(profile) / "browser.pid"
            if pid_file.exists():
                try:
                    os.killpg(int(pid_file.read_text()), signal.SIGKILL)
                except ProcessLookupError:
                    pass
            raise

    def persistent_state():
        saved = json.loads(evidence.read_text())
        return {"workers": [api("/workers/" + wid) for wid in saved["workers"]],
                "zone": api("/zones/" + saved["zone_id"]),
                "versions": api("/zones/" + saved["zone_id"] + "/versions"),
                "assignments": api("/zones/" + saved["zone_id"] + "/assignments"),
                "views": api(f'/workers/{saved["workers"][0]}/dns-services/{saved["service_ids"][0]}/views'),
                "target": api(saved["target_path"]), "export": api(saved["target_path"] + "/export", raw=True).decode()}

    try:
        subprocess.run([str(binary), "eval", "YellowDog.Management.Release.migrate()"], env=env, stdout=log, stderr=log, check=True)
        start()
        assert api("/workers") == [] and api("/zones") == [], "Fresh disposable database required"
        browser("create")
        if not args.p1_only:
            browser("sync")
        before = persistent_state()
        runtime_before = probe()
        (directory / "before-restart.json").write_text(json.dumps({"state": before, "runtime": runtime_before}, indent=2))
        stop(force=True)
        start()
        assert persistent_state() == before, "Management restart changed persisted configuration or historical export"
        assert probe()["catalog"] == runtime_before["catalog"], "Restart changed durable artifact catalog"
        browser("verify")
        assert persistent_state() == before, "Fresh-session readback changed persistent configuration"
        database = env["YELLOW_DOG_MANAGEMENT_DATABASE_URL"]

        def sql(statement):
            subprocess.run(["psql", database, "-X", "-v", "ON_ERROR_STOP=1", "-c", statement],
                           stdout=log, stderr=log, check=True)

        sql("""CREATE FUNCTION reject_configuration_zone_save() RETURNS trigger LANGUAGE plpgsql
               AS $$ BEGIN RAISE EXCEPTION 'fixture rejects Zone save'; END $$;
               CREATE TRIGGER reject_configuration_zone_save BEFORE UPDATE ON management_zones
               FOR EACH ROW EXECUTE FUNCTION reject_configuration_zone_save();""")
        try:
            browser("editor-failures")
            assert persistent_state() == before, "Rejected browser edits changed persistent configuration"
        finally:
            sql("""DROP TRIGGER reject_configuration_zone_save ON management_zones;
                   DROP FUNCTION reject_configuration_zone_save();""")
        browser("advance")
        saved = json.loads(evidence.read_text())
        assert api(saved["target_path"]) == before["target"]
        assert api(saved["target_path"] + "/export", raw=True).decode() == before["export"]
        if not args.p1_only:
            failed_source.set()
            browser("failed-sync")
            final = probe()
            assert final["catalog"] == runtime_before["catalog"], "Failed sync replaced the prior catalog selection"
            for entry in final["catalog"]:
                selected = entry["selected"]
                contents = (directory / "artifacts" / f'{selected["digest"]}.mmdb').read_bytes()
                assert selected["available"] and contents == fixtures[entry["kind"]]
                assert hashlib.sha256(contents).hexdigest() == selected["digest"] == digests[entry["kind"]]
            (directory / "final-runtime.json").write_text(json.dumps(final, indent=2))
        print("PASS Management configuration: browser persistence, retained rejected edits, stable retries, scoped View, shared assignments, SIGKILL recovery, immutable versions/exports and selective removal" +
              ("; durable City/Country artifacts and failed-sync preservation without a query process" if not args.p1_only else " (configuration only)"), flush=True)
    finally:
        stop()
        fixture.shutdown()
        fixture.server_close()
        log.close()
        print(f"Management configuration evidence: {directory}", flush=True)


if __name__ == "__main__":
    main()
