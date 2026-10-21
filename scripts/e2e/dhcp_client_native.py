#!/usr/bin/env python3
"""Validate the retained production adapter using fresh, published Hex packages.

Run inside devenv. Build state and upstream validation sources stay in --output
(a fresh temporary directory by default), separate from the supported umbrella.
The wire gate only uses the upstream fixture's disposable Linux namespaces.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
CLIENT = ROOT / "apps/yellow_dog_dhcp_client"


def run(command, directory, environment):
    print("+ " + " ".join(map(str, command)), flush=True)
    subprocess.run(command, cwd=directory, env=environment, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--no-wire", action="store_true")
    args = parser.parse_args()
    stage = args.output.resolve() if args.output else Path(tempfile.mkdtemp(prefix="yellow-dog-dhcp-"))
    stage.mkdir(parents=True, exist_ok=True)
    consumer = stage / "consumer"
    consumer.mkdir()  # Refuse reused build state.
    environment = dict(os.environ, MIX_ENV="prod", CI="true")
    for key in ("MIX_BUILD_PATH", "MIX_DEPS_PATH", "MIX_LOCKFILE", "ERL_LIBS", "CARGO_TARGET_DIR"):
        environment.pop(key, None)
    print("DHCP_CLIENT_STAGE=" + str(stage), flush=True)

    # Evaluate the real manifest rather than duplicating its production policy.
    declaration = stage / "dependencies.exs"
    environment.update(YD_CLIENT=str(CLIENT), YD_DECLARATION=str(declaration))
    run(["elixir", "-e", '''
      Mix.start()
      Mix.Project.in_project(:yellow_dog_dhcp_client, System.fetch_env!("YD_CLIENT"), fn _ ->
        deps = Mix.Project.config()[:deps]
        false = Enum.any?(deps, &(elem(&1, 0) in [:abyss_dhcp_socket, :rustler]))
        selected = Enum.filter(deps, &(elem(&1, 0) in [:abyss, :abyss_raw]))
        [{:abyss, requirement}, {:abyss_raw, requirement, [only: :prod]}] = selected
        File.write!(System.fetch_env!("YD_DECLARATION"), inspect(selected))
      end)
    '''], stage, environment)
    dependencies = declaration.read_text()
    (consumer / "mix.exs").write_text('''defmodule DhcpAdapterConsumer.MixProject do
      use Mix.Project
      def project, do: [app: :dhcp_adapter_consumer, version: "0.0.0",
        releases: [dhcp_adapter_consumer: [include_executables_for: [:unix]]],
        deps: ''' + dependencies + ''']
      def application, do: [extra_applications: [:logger]]
    end
    ''')
    (consumer / "lib").mkdir()
    for path in ("dhcp_socket.ex", "dhcp_socket/native.ex"):
        shutil.copy2(CLIENT / "lib/yellow_dog/dhcp_client" / path,
                     consumer / "lib" / Path(path).name)
    run(["mix", "deps.get"], consumer, environment)
    run(["mix", "compile", "--warnings-as-errors"], consumer, environment)

    smoke = stage / "native_smoke.exs"
    smoke.write_text('''
      alias YellowDog.DhcpClient.DhcpSocket.Native
      lock = Code.eval_file("mix.lock") |> elem(0)
      {:hex, :abyss, version, _, _, _, "hexpm", _} = lock.abyss
      {:hex, :abyss_raw, ^version, _, _, _, "hexpm", _} = lock.abyss_raw
      false = Map.has_key?(lock, :abyss_dhcp_socket)
      true = Code.ensure_loaded?(AbyssDhcpSocket.Native)
      :abyss_raw = Application.get_application(AbyssDhcpSocket.Native)
      true = File.regular?(Path.join(:code.priv_dir(:abyss_raw), "native/dhcp_socket.so"))
      {:error, "invalid interface name: " <> _} = Native.open("bad" <> <<0>>, self())
      {:error, reason} = Native.open("abyss-no-iface", self())
      true = is_binary(reason) and String.contains?(reason, "abyss-no-iface")
      IO.puts("NATIVE_ADAPTER_HEX_PASS " <> version)
    ''')
    run(["mix", "run", str(smoke)], consumer, environment)

    # Reuse the released upstream contract/cleanup and wire checks. Only the
    # wire driver's calls are adapted to YellowDog's {:ok, resource} behaviour;
    # package sources and the fixture's packet/cleanup assertions are unchanged.
    version = subprocess.check_output(
        ["mix", "run", "--no-compile", "-e", 'IO.write(Application.spec(:abyss, :vsn))'],
        cwd=consumer, env=environment, text=True).strip()
    upstream = stage / "upstream"
    checksums = {}
    paths = ["test/abyss/dhcp_socket_native_test.exs", "packages/abyss_raw/test/native_test.exs",
             "scripts/udp/network_fixture.py", "scripts/udp/dhcp_fixture.py",
             "scripts/udp/p5_native_consumer.exs"]
    for path in paths:
        payload = urllib.request.urlopen(
            f"https://raw.githubusercontent.com/gsmlg-dev/abyss/{version}/{path}").read()
        checksums[path] = hashlib.sha256(payload).hexdigest()
        destination = upstream / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(payload)
    facade = upstream / "lib/abyss/dhcp_socket"
    facade.mkdir(parents=True)
    shutil.copy2(consumer / "deps/abyss/lib/abyss/dhcp_socket/native.ex", facade / "native.ex")
    wire = upstream / "scripts/udp/p5_native_consumer.exs"
    source = wire.read_text().replace("alias Abyss.DhcpSocket.Native",
                                     "alias YellowDog.DhcpClient.DhcpSocket.Native")
    source = source.replace('socket = Native.open("eth0", self())',
                            '{:ok, socket} = Native.open("eth0", self())')
    source = source.replace('resource = Native.open("eth0", self())',
                            '{:ok, resource} = Native.open("eth0", self())')
    wire.write_text(source)
    runner = stage / "contracts.exs"
    tests = [CLIENT / "test/dhcp_socket_test.exs", CLIENT / "test/native_adapter_test.exs",
             upstream / paths[0], upstream / paths[1]]
    runner.write_text("ExUnit.start()\n" + "\n".join(
        "Code.require_file(" + json.dumps(str(path)) + ")" for path in tests))
    run(["mix", "run", str(runner)], consumer, environment)
    run(["mix", "release"], consumer, environment)
    release = consumer / "_build/prod/rel/dhcp_adapter_consumer"
    native = release / f"lib/abyss_raw-{version}/priv/native/dhcp_socket.so"
    assert native.is_file(), native
    assert not list((release / "lib").glob("abyss_dhcp_socket-*"))
    environment["YD_NATIVE_SMOKE"] = str(smoke)
    run([str(release / "bin/dhcp_adapter_consumer"), "eval",
         'Code.require_file(System.fetch_env!("YD_NATIVE_SMOKE"))'], consumer, environment)
    evidence = {"version": version, "consumer": str(consumer), "release": str(release),
                "native_sha256": hashlib.sha256(native.read_bytes()).hexdigest(),
                "upstream_test_sha256": checksums,
                "gates": ["production_manifest", "coordinated_hex_resolution", "actual_adapter_compile",
                          "native_loading", "adapter_and_upstream_contracts", "explicit_native_release"],
                "wire": "NOT RUN"}
    if not args.no_wire:
        result = subprocess.run(["python3", str(upstream / "scripts/udp/dhcp_fixture.py"),
                                 "--consumer", str(consumer)], env=environment)
        evidence["wire"] = "PASS" if result.returncode == 0 else (
            "BLOCKED_ENV" if result.returncode == 77 else "FAIL")
    (stage / "evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
    print(json.dumps(evidence, indent=2), flush=True)
    if evidence["wire"] == "BLOCKED_ENV":
        return 77
    return 1 if evidence["wire"] == "FAIL" else 0


if __name__ == "__main__":
    raise SystemExit(main())
