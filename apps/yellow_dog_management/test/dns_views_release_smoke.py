"""Native desired View workflows against a disposable PostgreSQL release."""

from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid

if len(sys.argv) != 2:
    raise SystemExit("Usage: dns_views_release_smoke.py RELEASE_BINARY")
cluster_directory = os.environ.get("YELLOW_DOG_PHASE1_PG_DATA_DIR")
cluster_port = os.environ.get("YELLOW_DOG_PHASE1_PG_PORT", "")
if not cluster_directory or not cluster_port.isdecimal() or not 1 <= int(cluster_port) <= 65535:
    raise SystemExit("Use scripts/e2e/phase1_postgres.sh with disposable PostgreSQL")
cluster = Path(cluster_directory).resolve()
if not cluster.parent.name.startswith("yellow-dog-phase1-pg.") or not (cluster / "PG_VERSION").is_file():
    raise SystemExit("Expected the disposable helper cluster directory")
binary = Path(sys.argv[1]).resolve()
if not binary.is_file() or not os.access(binary, os.X_OK):
    raise SystemExit("Release binary must exist and be executable")
directory = Path(tempfile.mkdtemp(prefix="management-dns-views-release-"))
with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    port = listener.getsockname()[1]
base = f"http://127.0.0.1:{port}"
env = dict(os.environ, RELEASE_DISTRIBUTION="none", MANAGEMENT_UI_URL=base,
           YELLOW_DOG_MANAGEMENT_DATABASE_URL=f"postgres://postgres@127.0.0.1:{cluster_port}/yellow_dog_phase1",
           YELLOW_DOG_MANAGEMENT_BIND_ADDRESS="127.0.0.1", YELLOW_DOG_MANAGEMENT_PORT=str(port),
           YELLOW_DOG_MANAGEMENT_ARTIFACT_DIRECTORY=str(directory / "artifacts"),
           YELLOW_DOG_MANAGEMENT_BACKUP_DIRECTORY=str(directory / "backups"),
           MANAGEMENT_DNS_VIEWS_EVIDENCE=str(directory / "browser.json"))
env.pop("YELLOW_DOG_MANAGEMENT_OPERATOR_TOKEN", None)
pg_env = dict(env, PGHOST="127.0.0.1", PGPORT=cluster_port,
              PGUSER="postgres", PGDATABASE="yellow_dog_phase1")
for variable in ["PGPASSWORD", "PGSERVICE", "PGSERVICEFILE", "PGOPTIONS"]:
    pg_env.pop(variable, None)
process = None
log = (directory / "server.log").open("w")


def sql(query):
    return subprocess.check_output(["psql", "-XAt", "-v", "ON_ERROR_STOP=1", "-c", query], env=pg_env, text=True, timeout=30).strip()


def snapshot():
    tables = json.loads(sql("SELECT COALESCE(json_agg(json_build_array(schemaname,tablename) ORDER BY schemaname,tablename),'[]'::json) FROM pg_tables WHERE schemaname IN ('public','management_jobs') AND NOT (schemaname='management_jobs' AND tablename='oban_peers')"))
    return {f"{schema}.{table}": json.loads(sql(f'SELECT COALESCE(json_agg(data ORDER BY data::text),\'[]\'::json) FROM (SELECT row_to_json(stored) data FROM "{schema}"."{table}" stored) records'))
            for schema, table in tables}


def evaluate(expression):
    subprocess.run([str(binary), "eval", expression], env=env, stdout=log, stderr=log, check=True, timeout=90)


def request(path, body=None, expected=200, key=None, raw=False):
    headers = {} if body is None else {"Content-Type": "application/json", "Idempotency-Key": key or str(uuid.uuid4())}
    try:
        response = urllib.request.urlopen(urllib.request.Request(base + "/api" + path,
            data=None if body is None else json.dumps(body).encode(), headers=headers), timeout=15)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        contents = response.read()
        payload = contents if raw else json.loads(contents)
        if expected is not None:
            assert response.status == expected, (path, response.status, payload)
            if raw:
                return payload
            return payload["data"] if expected == 200 else payload["error"]
        return response.status, payload


def stop(force=False):
    if process is not None:
        try:
            os.killpg(process.pid, signal.SIGKILL if force else signal.SIGTERM)
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=10)
        except ProcessLookupError:
            pass


def start():
    global process
    process = subprocess.Popen([str(binary), "start"], env=env, stdout=log, stderr=log, start_new_session=True)
    for attempt in range(150):
        assert process.poll() is None, f"Release exited: {directory / 'server.log'}"
        try:
            request("/workers")
            return
        except OSError:
            time.sleep(.1)
    raise AssertionError("Management startup timed out")


def browser(verify_only=False):
    with tempfile.TemporaryDirectory(prefix="management-dns-views-browser-") as profile:
        subprocess.run(["node", str(Path(__file__).with_name("dns_views_browser_smoke.mjs"))],
            env=dict(env, MANAGEMENT_DNS_VIEWS_BROWSER_PROFILE=profile,
                     MANAGEMENT_DNS_VIEWS_VERIFY_ONLY="1" if verify_only else "0"), check=True, timeout=180)


try:
    assert Path(sql("SHOW data_directory")).resolve() == cluster, "Not the disposable helper cluster"
    assert sql("SHOW server_encoding") == "UTF8"
    assert snapshot() == {}, "Expected a fresh disposable database"
    evaluate('Application.load(:yellow_dog_management); {:ok, _, _} = Ecto.Migrator.with_repo(YellowDog.Management.Repo, fn repo -> Ecto.Migrator.run(repo, :up, to: 20261001050000) end)')
    existing_service = str(uuid.uuid4())
    sql(f"""INSERT INTO management_workers (id,name,revision,expected_capabilities,inserted_at,updated_at)
      VALUES ('view-existing','Existing',4,ARRAY['dns'],now(),now());
      INSERT INTO management_services (id,worker_id,instance_id,type,desired_state,config,inserted_at,updated_at)
      VALUES ('{existing_service}','view-existing','dns','dns','stopped','{{"listen_address":"127.0.0.1","port":5300}}',now(),now());""")
    migration_before = snapshot()
    evaluate('YellowDog.Management.Release.migrate()')
    migration_after = snapshot()
    for table, data in migration_before.items():
        if table != "public.schema_migrations":
            assert migration_after[table] == data, f"View provisioning changed {table}"
    assert len(migration_after["public.management_dns_views"]) == 1
    default = migration_after["public.management_dns_views"][0]
    assert default["service_id"] == existing_service and default["is_default"] and default["priority"] is None
    assert default["client_rules"] == [{"action": "allow", "kind": "any"}]
    evaluate('YellowDog.Management.Release.migrate()')
    assert snapshot() == migration_after, "Repeated migration modified desired data"
    (directory / "migration.json").write_text(json.dumps(migration_after, sort_keys=True))

    start()
    worker = request("/commands/create_worker", {"id": "view-fixture", "name": "Views", "expected_capabilities": ["dns"]})
    other = request("/commands/create_worker", {"id": "view-other", "name": "Other", "expected_capabilities": ["dns"]})

    def service(owner, identifier, listener_port):
        return request("/commands/put_service", {"worker_id": owner["id"], "expected_revision": owner["revision"],
            "id": identifier, "type": "dns", "desired_state": "stopped", "config": {"listen_address": "127.0.0.1", "port": listener_port}})

    first = service(worker, "dns", 5301)
    worker = request("/workers/view-fixture")
    second = service(worker, "dns-two", 5302)
    third = service(other, "dns", 5303)
    env.update(MANAGEMENT_DNS_VIEWS_SERVICE_ID=first["id"], MANAGEMENT_DNS_VIEWS_SECOND_SERVICE_ID=second["id"], MANAGEMENT_DNS_VIEWS_OTHER_SERVICE_ID=third["id"])
    scope = {"worker_id": "view-fixture", "service_id": first["id"]}
    path = f'/workers/view-fixture/dns-services/{first["id"]}/views'
    for owner, created in [("view-fixture", first), ("view-fixture", second), ("view-other", third)]:
        defaults = request(f'/workers/{owner}/dns-services/{created["id"]}/views')
        assert len(defaults) == 1 and defaults[0]["is_default"] and defaults[0]["priority"] is None
        assert defaults[0]["client_rules"] == [{"action": "allow", "kind": "any"}]
    zone = request("/commands/create_zone", {"name": "view.test.", "records": [
        {"name": "view.test.", "type": "SOA", "ttl": 300, "data": {"mname": "ns.view.test.", "rname": "hostmaster.view.test.", "serial": 1, "refresh": 3600, "retry": 600, "expire": 86400, "minimum": 300}},
        {"name": "view.test.", "type": "NS", "ttl": 300, "data": {"host": "ns.view.test."}},
        {"name": "ns.view.test.", "type": "A", "ttl": 300, "data": {"address": "192.0.2.10"}}
    ]})
    version = request("/commands/confirm_zone", {"id": zone["id"], "expected_revision": zone["revision"]})
    worker = request("/workers/view-fixture")
    assignment = request("/commands/assign", dict(scope, resource_version_id=version["id"], expected_revision=worker["revision"]))
    confirmed = request("/commands/confirm_target", {"worker_id": worker["id"], "expected_revision": assignment["worker_revision"]})
    target_path = f'/workers/view-fixture/targets/{confirmed["revision"]}'
    target = request(target_path)
    exported = request(target_path + "/export", raw=True)
    assert exported, "Expected a nonempty immutable export"
    baseline = snapshot()
    (directory / "baseline.json").write_text(json.dumps(baseline, sort_keys=True))
    preview = request("/workers/view-fixture/preview")
    browser()
    after_ui = snapshot()
    for table, data in baseline.items():
        if table not in {"public.management_dns_views", "public.management_audits", "public.management_idempotency"}:
            assert after_ui[table] == data, f"View editing changed unrelated {table}"
    assert request("/workers/view-fixture/preview") == preview
    assert request(target_path) == target
    assert request(target_path + "/export", raw=True) == exported
    (directory / "after-ui.json").write_text(json.dumps(after_ui, sort_keys=True))

    candidate = dict(scope, name="concurrent", client_rules=[], fallback_forwarders=[{"address": "2001:db8::1", "port": 5353}])
    key = str(uuid.uuid4())
    with ThreadPoolExecutor(max_workers=2) as pool:
        duplicates = list(pool.map(lambda _index: request("/commands/create_dns_view", candidate, key=key), range(2)))
    assert duplicates[0] == duplicates[1], "Idempotency created different Views"
    concurrent = duplicates[0]
    assert [view for view in request(path) if view["name"] == "concurrent"] == [concurrent]

    def update(enabled):
        return request("/commands/update_dns_view", dict(scope, id=concurrent["id"], expected_revision=concurrent["revision"], enabled=enabled), expected=None)

    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(update, [True, False]))
    assert sorted(status for status, payload in results) == [200, 409], results
    winner = next(payload["data"] for status, payload in results if status == 200)
    loser = next(payload["error"] for status, payload in results if status == 409)
    assert loser["code"] == "revision_conflict", loser
    assert winner["revision"] == 2 and winner["client_rules"] == [] and winner["fallback_forwarders"] == concurrent["fallback_forwarders"]
    assert request(path + "/" + concurrent["id"]) == winner
    (directory / "concurrency.json").write_text(json.dumps(results, sort_keys=True))
    request("/commands/delete_dns_view", dict(scope, id=winner["id"], expected_revision=winner["revision"]))
    assert request(path + "/" + winner["id"], expected=404)["code"] == "not_found"
    read_before = snapshot()
    for table, data in baseline.items():
        if table not in {"public.management_dns_views", "public.management_audits", "public.management_idempotency"}:
            assert read_before[table] == data, f"Concurrent View mutations changed unrelated {table}"
    stop(force=True)
    start()
    browser(verify_only=True)
    for worker_id, service_id in [("view-fixture", first["id"]), ("view-fixture", second["id"]), ("view-other", third["id"]), ("view-existing", existing_service)]:
        request(f"/workers/{worker_id}/dns-services/{service_id}/views")
    assert snapshot() == read_before, "Restart/read-only refresh wrote persistent data"
    assert request(target_path) == target
    assert request(target_path + "/export", raw=True) == exported
    (directory / "final.json").write_text(json.dumps(read_before, sort_keys=True))
    print("PASS desired Views: default backfill/provisioning, browser CRUD/filters/CSV, no target effects, concurrent CAS/idempotency and SIGKILL read-only recovery")
finally:
    stop()
    log.close()
    print(f"DNS Views release evidence: {directory}", flush=True)
