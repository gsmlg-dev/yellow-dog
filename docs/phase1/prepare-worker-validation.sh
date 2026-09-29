#!/usr/bin/env bash
# Assemble only Worker and the existing proposed C0; never mutate shared files.
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
validation_root=${1:?Usage: prepare-worker-validation.sh /absolute/temporary-directory}
case "$validation_root" in /tmp/*) ;; *) echo 'Use a directory under /tmp' >&2; exit 1;; esac
mkdir -p "$validation_root/apps" "$validation_root/config"
for app in yellow_dog_worker abyss ex_dns; do
  mkdir -p "$validation_root/apps/$app"
  cp -a "$repo_root/apps/$app/." "$validation_root/apps/$app/"
done
mkdir -p "$validation_root/apps/yellow_dog_config_spec"
cp -a "$repo_root/docs/phase1/shared-baseline/apps/yellow_dog_config_spec/." "$validation_root/apps/yellow_dog_config_spec/"
if [ ! -f "$validation_root/mix.lock" ]; then cp "$repo_root/mix.lock" "$validation_root/mix.lock"; fi
if [ ! -e "$validation_root/deps" ]; then cp -a "$repo_root/deps" "$validation_root/deps"; fi
cat > "$validation_root/mix.exs" <<'MIX'
defmodule WorkerValidation.MixProject do
  use Mix.Project
  def project, do: [apps_path: "apps", version: "0.1.0", releases: [yellow_dog_worker: [applications: [yellow_dog_worker: :permanent], runtime_config_path: "apps/yellow_dog_worker/config/runtime.exs"]]]
end
MIX
cat > "$validation_root/config/config.exs" <<'CONFIG'
import Config
import_config "../apps/yellow_dog_worker/config/config.exs"
CONFIG
