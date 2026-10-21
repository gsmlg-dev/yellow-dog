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
manifest = worker / f"releases/{version}/yellow_dog_worker.rel"
[abyss_app] = worker.glob("lib/abyss-*/ebin/abyss.app")
original_manifest = replace_once(
    manifest, r'\{abyss,\s*"[^"]+",\s*\w+\},?', '')
original_abyss_app = abyss_app.read_text()
abyss_app.unlink()
check("missing_abyss", "Abyss runtime dependency is missing")
manifest.write_text(original_manifest)
abyss_app.write_text(original_abyss_app)

replace_once(abyss_app, r'(\{vsn,\s*)"[^"]+"', r'\1"0.0.0"')
check("wrong_abyss_version", "packaged Abyss does not match the Hex lock")
abyss_app.write_text(original_abyss_app)

for product in (management, worker):
    _erts, version = (product / "releases/start_erl.data").read_text().split()
    manifest = product / f"releases/{version}/{product.name}.rel"

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

for optional in ("abyss_raw", "abyss_dhcp_socket", "rustler"):
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
    check(f"active_graph_{optional}", "optional native dependency in active graph", project)

print(f"ARCHITECTURE NEGATIVE SMOKE PASSED: positive fixture and {checks - 1} rejected mutations")
