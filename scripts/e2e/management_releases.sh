#!/usr/bin/env bash
set -euo pipefail
echo 'The mixed Management Core/Server/Netman connected campaign is retired.' >&2
echo 'Phase 1 uses independent Management/Worker releases and file-only interoperability.' >&2
echo 'Use scripts/e2e/release_smoke.sh; live Agents and connected reconciliation belong to Phase 2.' >&2
exit 64
