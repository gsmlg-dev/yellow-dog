#!/usr/bin/env python3
"""Verify packaged Management setup/migrate using disposable Docker resources.

Usage: python3 scripts/e2e/management_release_commands.py --image <management-image>
Requires Docker and an already built image; never touches existing databases.
"""

import argparse
import json
from pathlib import Path
import re
import subprocess
import time
import urllib.error
import urllib.request
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True)
    parser.add_argument("--postgres-image", default="pgvector/pgvector:pg17")
    args = parser.parse_args()
    prefix = "yd-release-commands-" + uuid.uuid4().hex[:12]
    network, postgres, volume = (prefix + suffix for suffix in ("-net", "-pg", "-data"))
    password = uuid.uuid4().hex
    containers = []
    network_created = volume_created = False
    migrations = Path(__file__).resolve().parents[2] / "apps/yellow_dog_management/priv/repo/migrations"
    versions = sorted(int(path.name.split("_", 1)[0]) for path in migrations.glob("*.exs"))
    assert versions, "No Management migrations found"

    def docker(*arguments, timeout=120, expect_success=True):
        result = subprocess.run(["docker", *arguments], capture_output=True, text=True, timeout=timeout)
        output = (result.stdout + result.stderr).replace(password, "<redacted>").strip()
        if expect_success:
            assert result.returncode == 0, output
        return result.returncode, output

    def sql(statement, database="postgres"):
        return docker("exec", postgres, "psql", "-v", "ON_ERROR_STOP=1", "-U", "postgres",
                      "-d", database, "-Atc", statement)[1]

    def run(command, database="management_commands", user="postgres", port=5432, success=True,
            entrypoint=None, expected_exit=None):
        name = prefix + "-task-" + str(len(containers))
        containers.append(name)
        url = f"postgres://{user}:{password}@{postgres}:{port}/{database}"
        docker("create", "--name", name, "--network", network,
               "-e", "YELLOW_DOG_MANAGEMENT_DATABASE_URL=" + url,
               "-e", "YELLOW_DOG_MANAGEMENT_SECRET_KEY_BASE=" + "release-smoke-" * 8,
               "-e", "RELEASE_DISTRIBUTION=none", "-e", "ERL_FLAGS=+S 2:2 +A 2",
               *(["--entrypoint", entrypoint] if entrypoint else []), args.image, *command)
        code, output = docker("start", "-a", name, expect_success=False)
        state = json.loads(docker("inspect", "--format", "{{json .State}}", name)[1])
        assert not state["Running"], "Release task did not terminate"
        assert (code == 0 and state["ExitCode"] == 0) if success else state["ExitCode"] != 0, output
        if not success:
            assert state["ExitCode"] != 137, "Failure was an OOM/SIGKILL, not task error"
        if expected_exit is not None:
            assert state["ExitCode"] == expected_exit, (state["ExitCode"], output)
        return output

    def check_schema():
        applied = [int(version) for version in sql("SELECT version FROM schema_migrations ORDER BY version",
                                                  "management_commands").splitlines()]
        assert applied == versions, (applied, versions)

    def probe(task):
        # eval loads code without starting the business application. Probe the same
        # function the packaged shell command invokes, before and after execution.
        expression = (
            "probe = fn -> %{supervisor: Process.whereis(YellowDog.Management.Supervisor) != nil, "
            "endpoint: Process.whereis(YellowDog.ManagementUI.Endpoint) != nil, "
            "applications: Enum.map(Application.started_applications(), fn {app, _, _} -> app end), "
            "sockets: Enum.map([\"tcp\", \"tcp6\", \"udp\", \"udp6\"], "
            "fn name -> File.read!(\"/proc/net/\" <> name) end)} end; "
            f"before = probe.(); :ok = YellowDog.Management.Release.{task}(); "
            'IO.puts("YD_RELEASE_PROBE=" <> Jason.encode!(%{before: before, after: probe.()}))'
        )
        output = run(["eval", expression])
        matches = re.findall(r"YD_RELEASE_PROBE=(\{[^\n]+\})", output)
        assert len(matches) == 1, output
        forbidden = {
            "yellow_dog_management", "yellow_dog_worker", "yellow_dog", "yellow_dog_dns",
            "yellow_dog_dhcpv4", "yellow_dog_dhcpv6", "yellow_dog_mdns", "yellow_dog_netboot",
            "yellow_dog_identity", "yellow_dog_console", "yellow_dog_management_core",
            "yellow_dog_sync", "yellow_dog_server_agent", "yellow_dog_netman_agent", "abyss",
        }
        for snapshot in json.loads(matches[0]).values():
            assert not snapshot["supervisor"] and not snapshot["endpoint"], snapshot
            assert not forbidden.intersection(snapshot["applications"]), snapshot
            for table in snapshot["sockets"]:
                assert not re.search(r":(?:10AE|0035)\s", table), table

    try:
        docker("image", "inspect", args.image)
        docker("image", "inspect", args.postgres_image)
        docker("network", "create", network)
        network_created = True
        docker("volume", "create", volume)
        volume_created = True
        containers.append(postgres)
        docker("run", "-d", "--name", postgres, "--network", network,
               "-e", "POSTGRES_PASSWORD=" + password,
               "-v", volume + ":/var/lib/postgresql/data", args.postgres_image)
        deadline = time.monotonic() + 60
        while True:
            ready, _ = docker("exec", postgres, "pg_isready", "-h", "127.0.0.1", "-U", "postgres",
                              timeout=10, expect_success=False)
            if ready == 0:
                break
            assert time.monotonic() < deadline, "Disposable PostgreSQL did not become ready"
            time.sleep(0.25)

        assert sql("SELECT count(*) FROM pg_database WHERE datname='management_commands'") == "0"
        output = run(["setup"])
        assert "database=created" in output and f"applied_migrations={len(versions)}" in output, output
        check_schema()
        print("PASS packaged setup creates absent database and applies all migrations", flush=True)

        zone_id = str(uuid.uuid4())
        sql(f"INSERT INTO management_zones (id, name, revision, inserted_at, updated_at) "
            f"VALUES ('{zone_id}', 'release-commands.example.test.', 1, now(), now())", "management_commands")

        def check_zone():
            assert sql(f"SELECT name || ':' || revision FROM management_zones WHERE id='{zone_id}'",
                       "management_commands") == "release-commands.example.test.:1"

        output = run(["setup"])
        assert "database=already_exists" in output and "applied_migrations=0" in output, output
        output = run(["migrate"])
        assert "applied_migrations=0" in output, output
        output = run(["migrate"], entrypoint="/app/bin/yellow_dog_management")
        assert "applied_migrations=0" in output, output
        check_schema()
        check_zone()
        print("PASS repeated setup and migrate preserve business data", flush=True)

        rollback = (
            "Application.load(:yellow_dog_management); "
            "Application.put_env(:yellow_dog_management, YellowDog.Management.Repo, "
            "YellowDog.Management.Settings.repo()); "
            "{:ok, _, _} = Ecto.Migrator.with_repo(YellowDog.Management.Repo, "
            "fn repo -> Ecto.Migrator.run(repo, :down, step: 1) end)"
        )
        run(["eval", rollback])
        assert sql("SELECT max(version) FROM schema_migrations", "management_commands") == str(versions[-2])
        output = run(["migrate"])
        assert "applied_migrations=1" in output, output
        check_schema()
        check_zone()
        print("PASS migrate applies pending real migration and preserves business data", flush=True)

        probe("setup")
        probe("migrate")
        print("PASS release tasks leave Management/HTTP/Worker/legacy runtime stopped", flush=True)

        output = run(["migrate"], database="missing_migrate", success=False)
        assert "does not exist" in output, output
        assert sql("SELECT count(*) FROM pg_database WHERE datname='missing_migrate'") == "0"
        print("PASS migrate fails for an absent database without creating it", flush=True)

        sql(f"CREATE ROLE limited LOGIN PASSWORD '{password}' NOCREATEDB")
        output = run(["setup"], database="denied_setup", user="limited", success=False)
        assert "permission denied" in output.lower(), output
        assert sql("SELECT count(*) FROM pg_database WHERE datname='denied_setup'") == "0"
        print("PASS setup fails when database creation is forbidden", flush=True)

        output = run(["setup"], port=1, success=False)
        assert "econnrefused" in output or "connection refused" in output.lower(), output
        print("PASS setup fails when PostgreSQL is unavailable", flush=True)
        for task in ("setup", "migrate"):
            output = run([task, "unexpected"], success=False, expected_exit=64)
            assert "Usage:" in output, output
        print("PASS setup and migrate reject extra arguments", flush=True)

        app = prefix + "-app"
        containers.append(app)
        docker("create", "--name", app, "--network", network, "-p", "127.0.0.1::4270",
               "-e", f"YELLOW_DOG_MANAGEMENT_DATABASE_URL=postgres://postgres:{password}@{postgres}:5432/management_commands",
               "-e", "YELLOW_DOG_MANAGEMENT_SECRET_KEY_BASE=" + "release-smoke-" * 8,
               "-e", "YELLOW_DOG_MANAGEMENT_BIND_ADDRESS=0.0.0.0",
               "-e", "RELEASE_DISTRIBUTION=none", "-e", "ERL_FLAGS=+S 2:2 +A 2", args.image)
        docker("start", app)
        port = json.loads(docker("inspect", "--format", "{{json .NetworkSettings.Ports}}", app)[1])["4270/tcp"][0]["HostPort"]
        deadline = time.monotonic() + 60
        while True:
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/zones/{zone_id}", timeout=5) as response:
                    zone = json.load(response)["data"]
                break
            except (OSError, urllib.error.URLError):
                state = json.loads(docker("inspect", "--format", "{{json .State}}", app)[1])
                assert state["Running"], "Default Management start failed: " + docker("logs", app)[1]
                assert time.monotonic() < deadline, "Default Management start did not serve HTTP"
                time.sleep(0.25)
        assert zone["id"] == zone_id and zone["name"] == "release-commands.example.test." and zone["revision"] == 1, zone
        output = docker("exec", app, "/usr/local/bin/yellow_dog_release", "migrate")[1]
        assert "applied_migrations=0" in output, output
        print("PASS default container starts HTTP and in-container migrate preserves business data", flush=True)
        print("MANAGEMENT RELEASE COMMANDS PASSED: " + args.image, flush=True)
    finally:
        errors = []
        for name in reversed(containers):
            code, output = docker("rm", "-fv", name, expect_success=False, timeout=30)
            if code != 0 and "No such container" not in output:
                errors.append(output)
        if volume_created:
            code, output = docker("volume", "rm", volume, expect_success=False, timeout=30)
            if code != 0:
                errors.append(output)
        if network_created:
            code, output = docker("network", "rm", network, expect_success=False, timeout=30)
            if code != 0:
                errors.append(output)
        assert not errors, "Owned resource cleanup failed: " + repr(errors)
        print("Owned Docker containers, volumes and network removed", flush=True)


if __name__ == "__main__":
    main()
