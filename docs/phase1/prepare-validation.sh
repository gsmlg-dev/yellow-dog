#!/usr/bin/env bash
# Assemble Track A with the proposed C0, leaving shared checkout files untouched.
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
validation_root=${1:?Usage: prepare-validation.sh /absolute/temporary-directory}
case "$validation_root" in /tmp/*) ;; *) echo 'Use a temporary directory under /tmp' >&2; exit 1;; esac
mkdir -p "$validation_root/apps" "$validation_root/config"
cp -R "$repo_root/apps/yellow_dog_management" "$validation_root/apps/"
mkdir -p "$validation_root/apps/yellow_dog_config_spec"
cp "$repo_root/docs/phase1/shared-baseline/apps/yellow_dog_config_spec/mix.exs" "$validation_root/apps/yellow_dog_config_spec/"
cp -R "$repo_root/docs/phase1/shared-baseline/apps/yellow_dog_config_spec/lib" "$validation_root/apps/yellow_dog_config_spec/"
for entry in test priv .formatter.exs; do
  source_path="$repo_root/docs/phase1/shared-baseline/apps/yellow_dog_config_spec/$entry"
  if [ -e "$source_path" ]; then cp -R "$source_path" "$validation_root/apps/yellow_dog_config_spec/"; fi
done
if [ ! -f "$validation_root/mix.lock" ]; then cp "$repo_root/mix.lock" "$validation_root/mix.lock"; fi
cat > "$validation_root/mix.exs" <<'MIX'
defmodule Validation.MixProject do
  use Mix.Project
  def project, do: [apps_path: "apps", version: "0.1.0", releases: [yellow_dog_management: [applications: [yellow_dog_management: :permanent]]]]
end
MIX
cat > "$validation_root/config/config.exs" <<'CONFIG'
import Config
import_config "../apps/yellow_dog_management/config/config.exs"
CONFIG
