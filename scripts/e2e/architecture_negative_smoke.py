"""Check release isolation with disposable manifests, without starting applications."""
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile


if len(sys.argv) != 2:
    raise SystemExit("Usage: architecture_negative_smoke.py <built-release-root>")

release_root = pathlib.Path(sys.argv[1]).resolve(strict=True)
repo_root = pathlib.Path(__file__).resolve().parents[2]
fixture_root = pathlib.Path(tempfile.mkdtemp(prefix="yellow-dog-architecture-negative-"))
print(f"Architecture negative artifacts: {fixture_root}", flush=True)

for product in ("yellow_dog_management", "yellow_dog_worker"):
    source_product = release_root / product
    start_file = source_product / "releases/start_erl.data"
    _erts, version = start_file.read_text().split()
    sources = [start_file, source_product / f"releases/{version}/{product}.rel"]
    sources.extend(path for path in source_product.glob("lib/*/ebin/*")
                   if path.is_file() and path.suffix in (".app", ".beam"))

    for source in sources:
        destination = fixture_root / product / source.relative_to(source_product)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)


checks = 0


def check(label, expected_error=None, project_root=repo_root):
    global checks
    result = subprocess.run(
        ["mix", "run", "--no-start", "--no-compile", "--no-deps-check",
         str(repo_root / "scripts/e2e/check_release_boundary.exs"), str(fixture_root)],
        cwd=project_root, capture_output=True, text=True, timeout=120)
    output = result.stdout + result.stderr
    (fixture_root / f"{label}.log").write_text(output)

    if expected_error is None:
        assert result.returncode == 0, (label, result.returncode, output)
        assert "ARCHITECTURE BOUNDARY PASSED" in output, (label, output)
    else:
        assert result.returncode != 0, f"{label}: invalid fixture was accepted"
        assert expected_error in output, (label, expected_error, output)

    print(f"PASS {label}", flush=True)
    checks += 1


def replace_once(path, pattern, replacement):
    original = path.read_text()
    changed, count = re.subn(pattern, replacement, original)
    assert count == 1, (path, pattern, count)
    path.write_text(changed)
    return original


check("positive")
management = fixture_root / "yellow_dog_management"
_erts, version = (management / "releases/start_erl.data").read_text().split()
manifest = management / f"releases/{version}/yellow_dog_management.rel"
[product_app] = management.glob("lib/*/ebin/yellow_dog_management.app")

legacy_ebin = management / "lib/yellow_dog-0.0.0/ebin"
legacy_ebin.mkdir(parents=True)
(legacy_ebin / "yellow_dog.app").write_text(
    '{application,yellow_dog,[{vsn,"0.0.0"},{modules,[]},'
    '{applications,[kernel,stdlib]}]}.\n')
original_manifest = replace_once(
    manifest, r'(\{erts,\s*"[^"]+"\},\s*\[)',
    r'\1{yellow_dog,"0.0.0",load},')
check("legacy_app", "another business runtime is packaged")
manifest.write_text(original_manifest)
shutil.rmtree(legacy_ebin.parent)

misplaced_beam = product_app.parent / "Elixir.YellowDog.Netboot.Server.beam"
assert not misplaced_beam.exists()
misplaced_beam.write_bytes(b"disposable misplaced execution-module fixture")
check("misplaced_module", "misplaced execution module")
misplaced_beam.unlink()

original_app = replace_once(
    product_app, r"(\{mod,\s*\{)'Elixir\.YellowDog\.Management\.Application'",
    r"\1'Elixir.YellowDog.Worker.Application'")
check("wrong_callback", "application callback mismatch")
product_app.write_text(original_app)

original_manifest = replace_once(
    manifest, r'(\{yellow_dog_management,\s*"[^"]+",\s*)permanent(\s*\})',
    r'\1load\2')
check("wrong_startup_mode", "startup mode mismatch")
manifest.write_text(original_manifest)

worker = fixture_root / "yellow_dog_worker"
_erts, version = (worker / "releases/start_erl.data").read_text().split()
for product in (management, worker):
    _erts, version = (product / "releases/start_erl.data").read_text().split()
    manifest = product / f"releases/{version}/{product.name}.rel"

    [abyss_app] = product.glob("lib/abyss-*/ebin/abyss.app")
    original_manifest = replace_once(
        manifest, r'\{abyss,\s*"[^"]+",\s*\w+\},?', '')
    original_abyss_app = abyss_app.read_text()
    abyss_app.unlink()
    check(f"{product.name}_missing_abyss", "Abyss runtime dependency is missing")
    manifest.write_text(original_manifest)
    abyss_app.write_text(original_abyss_app)

    replace_once(abyss_app, r'(\{vsn,\s*)"[^"]+"', r'\1"0.0.0"')
    check(f"{product.name}_wrong_abyss_version", "packaged Abyss does not match the Hex lock")
    abyss_app.write_text(original_abyss_app)

    for retired in ("bandit", "thousand_island"):
        retired_ebin = product / f"lib/{retired}-0.0.0/ebin"
        retired_ebin.mkdir(parents=True)
        (retired_ebin / f"{retired}.app").write_text(
            f'{{application,{retired},[{{vsn,"0.0.0"}},{{modules,[]}},'
            '{applications,[kernel,stdlib]}]}.\n')
        original_manifest = replace_once(
            manifest, r'(\{erts,\s*"[^"]+"\},\s*\[)',
            rf'\1{{{retired},"0.0.0",load}},')
        check(f"{product.name}_{retired}", "retired HTTP dependency is packaged")
        manifest.write_text(original_manifest)
        shutil.rmtree(retired_ebin.parent)

    for optional in ("abyss_raw", "abyss_dhcp_socket", "rustler"):
        optional_ebin = product / f"lib/{optional}-0.0.0/ebin"
        optional_ebin.mkdir(parents=True)
        (optional_ebin / f"{optional}.app").write_text(
            f'{{application,{optional},[{{vsn,"0.0.0"}},{{modules,[]}},'
            '{applications,[kernel,stdlib]}]}.\n')
        original_manifest = replace_once(
            manifest, r'(\{erts,\s*"[^"]+"\},\s*\[)',
            rf'\1{{{optional},"0.0.0",load}},')
        check(f"{product.name}_{optional}", "optional native dependency is packaged")
        manifest.write_text(original_manifest)
        shutil.rmtree(optional_ebin.parent)

    [product_app] = product.glob(f"lib/*/ebin/{product.name}.app")
    native_beam = product_app.parent / "Elixir.AbyssDhcpSocket.Native.beam"
    native_beam.write_bytes(b"disposable native implementation fixture")
    check(f"{product.name}_native_module", "optional native implementation is packaged")
    native_beam.unlink()

    native_artifact = product_app.parent.parent / "priv/native/libdhcp_socket.so"
    native_artifact.parent.mkdir(parents=True)
    native_artifact.write_bytes(b"disposable native artifact fixture")
    check(f"{product.name}_native_artifact", "optional native artifact is packaged")
    native_artifact.unlink()

for app in ("gaoxy_http", "gaoxy", "websock_adapter"):
    [cohort_app] = management.glob(f"lib/{app}-*/ebin/{app}.app")
    original_app = replace_once(cohort_app, r'(\{vsn,\s*)"[^"]+"', r'\1"0.0.0"')
    check(f"wrong_{app}_version", "packaged Gaoxy HTTP cohort does not match the Hex lock")
    cohort_app.write_text(original_app)

[management_app] = management.glob("lib/*/ebin/yellow_dog_management.app")
original_app = replace_once(
    management_app, r'(\{applications,\s*\[[^\]]*),\s*gaoxy_http\b', r'\1')
check("missing_direct_http_dependency", "Gaoxy HTTP runtime dependency is missing")
management_app.write_text(original_app)

[gaoxy_app] = management.glob("lib/gaoxy-*/ebin/gaoxy.app")
original_app = replace_once(
    gaoxy_app, r'(\{applications,\s*\[[^\]]*),\s*abyss\b', r'\1')
check("missing_gaoxy_transport_dependency", "Gaoxy HTTP runtime links are missing")
gaoxy_app.write_text(original_app)

_erts, version = (worker / "releases/start_erl.data").read_text().split()
manifest = worker / f"releases/{version}/yellow_dog_worker.rel"
worker_http = worker / "lib/gaoxy_http-0.0.0/ebin"
worker_http.mkdir(parents=True)
(worker_http / "gaoxy_http.app").write_text(
    '{application,gaoxy_http,[{vsn,"0.0.0"},{modules,[]},'
    '{applications,[kernel,stdlib]}]}.\n')
original_manifest = replace_once(
    manifest, r'(\{erts,\s*"[^"]+"\},\s*\[)', r'\1{gaoxy_http,"0.0.0",load},')
check("worker_http_stack", "forbidden dependency")
manifest.write_text(original_manifest)
shutil.rmtree(worker_http.parent)

for optional in ("abyss_raw", "abyss_dhcp_socket", "rustler", "bandit", "thousand_island"):
    project = fixture_root / f"graph_{optional}"
    native = project / "native"
    native.mkdir(parents=True)
    shutil.copy2(repo_root / "mix.lock", project / "mix.lock")
    (native / "mix.exs").write_text(
        'defmodule BoundaryNative.MixProject do\n  use Mix.Project\n'
        f'  def project, do: [app: :{optional}, version: "0.0.0"]\nend\n')
    dependency = f'{{:{optional}, path: "native", runtime: false}}'
    if optional == "rustler":
        # A build-only transitive dependency must be rejected before release inspection.
        parent = project / "parent"
        parent.mkdir()
        (parent / "mix.exs").write_text(
            'defmodule BoundaryParent.MixProject do\n  use Mix.Project\n'
            '  def project, do: [app: :boundary_parent, version: "0.0.0",\n'
            '    deps: [{:rustler, path: "../native", runtime: false}]]\nend\n')
        dependency = '{:boundary_parent, path: "parent", runtime: false}'
    (project / "mix.exs").write_text(
        'defmodule BoundaryGraph.MixProject do\n  use Mix.Project\n'
        '  def project, do: [app: :boundary_graph, version: "0.0.0",\n'
        f'    deps: [{dependency}]]\nend\n')
    error = ("retired HTTP dependency in active graph" if optional in ("bandit", "thousand_island")
             else "optional native dependency in active graph")
    check(f"active_graph_{optional}", error, project)


def lock_fixture(label):
    project = fixture_root / label
    project.mkdir()
    shutil.copy2(repo_root / "mix.exs", project / "mix.exs")
    shutil.copy2(repo_root / "mix.lock", project / "mix.lock")
    for directory in ("apps", "deps"):
        (project / directory).symlink_to(repo_root / directory, target_is_directory=True)
    return project


project = lock_fixture("wrong_websock_package")
replace_once(project / "mix.lock", r'("websock_adapter":\s*\{:hex,\s*):gaoxy_websock_adapter',
             r'\1:websock_adapter')
check("wrong_websock_package", "websock_adapter must be locked to Hex package gaoxy_websock_adapter",
      project)

project = lock_fixture("wrong_http_cohort")
replace_once(project / "mix.lock", r'("gaoxy":\s*\{:hex,\s*:gaoxy,\s*)"[^"]+"',
             r'\1"0.0.0"')
check("wrong_http_cohort", "Gaoxy HTTP and WebSock cohort versions differ", project)

print(f"ARCHITECTURE NEGATIVE SMOKE PASSED: positive fixture and {checks - 1} rejected mutations")
