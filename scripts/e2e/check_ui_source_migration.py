"""Verify the UI source transfer without compiling or starting business applications."""
import hashlib
import json
import pathlib
import subprocess


repo_root = pathlib.Path(__file__).resolve().parents[2]
manifest = json.loads((repo_root / "docs/phase1/ui-source-migration.json").read_text())
entries = manifest["files"]
sources = set()
source_hashes = {}
targets = set()

for entry in entries:
    source = entry["source"]
    target = entry["target"]
    assert target not in targets, f"Duplicate destination: {target}"
    sources.add(source)
    targets.add(target)

    if entry["revision"] == "working-tree":
        original = (repo_root / source).read_bytes()
    else:
        original = subprocess.check_output(
            ["git", "show", f'{entry["revision"]}:{source}'], cwd=repo_root
        )

    assert hashlib.sha256(original).hexdigest() == entry["source_sha256"], source
    source_hashes.setdefault(source, set()).add(entry["source_sha256"])
    content = original.decode()
    for before, after in entry["replacements"]:
        content = content.replace(before, after)
    expected = (content.rstrip() + "\n").encode()
    actual = (repo_root / target).read_bytes()
    assert actual == expected, f"Incomplete or unexpected transformation: {target}"
    assert hashlib.sha256(actual).hexdigest() == entry["target_sha256"], target

ui_root = "apps/yellow_dog_console/lib/yellow_dog/console"
expected_sources = set(manifest["shared_sources"])
for group in ("live", "components", "hooks"):
    expected_sources.update(
        str(path.relative_to(repo_root))
        for path in (repo_root / ui_root / group).rglob("*")
        if path.is_file()
    )

expected_sources.update(
    str(path.relative_to(repo_root))
    for path in (repo_root / "apps/yellow_dog_console/assets").rglob("*")
    if path.is_file()
)
historical_sources = subprocess.check_output(
    [
        "git", "ls-tree", "-r", "--name-only", manifest["historical_revision"],
        f"{ui_root}/live", f"{ui_root}/components", f"{ui_root}/hooks",
        "apps/yellow_dog_console/assets"
    ],
    cwd=repo_root, text=True
).splitlines()
expected_sources.update(historical_sources)
assert sources == expected_sources, (
    "Source coverage mismatch", sorted(expected_sources - sources), sorted(sources - expected_sources)
)

for source in sorted(expected_sources):
    if not source.startswith((f"{ui_root}/live/", f"{ui_root}/controllers/")):
        continue
    required_hashes = set()
    current_source = repo_root / source
    if current_source.exists():
        required_hashes.add(hashlib.sha256(current_source.read_bytes()).hexdigest())
    historical_exists = source in historical_sources or subprocess.run(
        ["git", "cat-file", "-e", f'{manifest["historical_revision"]}:{source}'],
        cwd=repo_root, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    ).returncode == 0
    if historical_exists:
        historical_content = subprocess.check_output(
            ["git", "show", f'{manifest["historical_revision"]}:{source}'], cwd=repo_root
        )
        required_hashes.add(hashlib.sha256(historical_content).hexdigest())
    assert required_hashes <= source_hashes[source], f"Missing presentation revision: {source}"

destination_root = repo_root / "apps/yellow_dog_management/lib/yellow_dog/management_ui"
actual_targets = {
    str(path.relative_to(repo_root))
    for path in (destination_root / "redesign").rglob("*") if path.is_file()
}
actual_targets.add(str((destination_root / "redesign.ex").relative_to(repo_root)))
actual_targets.update(
    str(path.relative_to(repo_root))
    for path in (repo_root / "apps/yellow_dog_management/assets/redesign").rglob("*")
    if path.is_file()
)
assert targets == actual_targets, ("Destination inventory mismatch", sorted(targets ^ actual_targets))
print(f"UI SOURCE MIGRATION PASSED: {len(entries)} complete files; no runtime acceptance claimed")
