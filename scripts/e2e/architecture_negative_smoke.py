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


def check(label, expected_error=None):
    result = subprocess.run(
        ["mix", "run", "--no-start", "scripts/e2e/check_release_boundary.exs", str(fixture_root)],
        cwd=repo_root, capture_output=True, text=True, timeout=120)
    output = result.stdout + result.stderr
    (fixture_root / f"{label}.log").write_text(output)

    if expected_error is None:
        assert result.returncode == 0, (label, result.returncode, output)
        assert "ARCHITECTURE BOUNDARY PASSED" in output, (label, output)
    else:
        assert result.returncode != 0, f"{label}: invalid fixture was accepted"
        assert expected_error in output, (label, expected_error, output)

    print(f"PASS {label}", flush=True)


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

print("ARCHITECTURE NEGATIVE SMOKE PASSED: positive fixture and four rejected mutations")
