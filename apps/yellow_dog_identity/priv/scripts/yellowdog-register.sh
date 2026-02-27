#!/usr/bin/env bash
# yellowdog-register.sh — Host identity registration for YellowDog
#
# Runs on first boot to register the host's SSH public key with the
# YellowDog identity registry. Supports AWS, GCP, Azure cloud VMs
# and bare-metal/on-prem hosts.
#
# Usage:
#   YELLOWDOG_REGISTRATION_URL=http://yellowdog:4270 ./yellowdog-register.sh
#
# Environment variables:
#   YELLOWDOG_REGISTRATION_URL  — Required. Base URL of the YellowDog server.
#   YELLOWDOG_TOKEN             — Optional. Provisioning token for out-of-band auth.
#   YELLOWDOG_ROLE              — Optional. Host role metadata.
#   YELLOWDOG_DATACENTER        — Optional. Datacenter metadata.

set -euo pipefail

REGISTRATION_URL="${YELLOWDOG_REGISTRATION_URL:?YELLOWDOG_REGISTRATION_URL must be set}"
HOSTNAME=$(hostname)
KEY_PATH="/etc/ssh/ssh_host_ed25519_key"

# Generate SSH host key if not present
if [ ! -f "$KEY_PATH" ]; then
  echo "Generating SSH ed25519 host key..."
  ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -q
fi

SSH_PUBKEY=$(cat "${KEY_PATH}.pub")

# Derive age recipient (requires ssh-to-age)
AGE_RECIPIENT=""
if command -v ssh-to-age >/dev/null 2>&1; then
  AGE_RECIPIENT=$(ssh-to-age < "${KEY_PATH}.pub" 2>/dev/null || true)
fi

# Detect cloud provider and fetch attestation document
ATTESTATION="{}"

detect_cloud_provider() {
  # AWS Instance Metadata Service (IMDSv1)
  if curl -sf -m 2 http://169.254.169.254/latest/meta-data/ >/dev/null 2>&1; then
    echo "Detected AWS instance, fetching identity document..."
    local doc sig
    doc=$(curl -sf -m 5 http://169.254.169.254/latest/dynamic/instance-identity/document | base64 -w0)
    sig=$(curl -sf -m 5 http://169.254.169.254/latest/dynamic/instance-identity/pkcs7 | base64 -w0)
    if [ -n "$doc" ] && [ -n "$sig" ]; then
      ATTESTATION=$(printf '{"provider":"aws","document":"%s","signature":"%s"}' "$doc" "$sig")
      return
    fi
  fi

  # GCP Metadata Service
  if curl -sf -m 2 -H "Metadata-Flavor: Google" \
       http://metadata.google.internal/computeMetadata/v1/ >/dev/null 2>&1; then
    echo "Detected GCP instance, fetching identity token..."
    local token
    token=$(curl -sf -m 5 -H "Metadata-Flavor: Google" \
      "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=yellowdog&format=full")
    if [ -n "$token" ]; then
      ATTESTATION=$(printf '{"provider":"gcp","token":"%s"}' "$token")
      return
    fi
  fi

  # Azure Instance Metadata Service
  if curl -sf -m 2 -H "Metadata: true" \
       "http://169.254.169.254/metadata/instance?api-version=2021-02-01" >/dev/null 2>&1; then
    echo "Detected Azure instance, fetching attested document..."
    local response doc sig
    response=$(curl -sf -m 5 -H "Metadata: true" \
      "http://169.254.169.254/metadata/attested/document?api-version=2021-02-01")
    if [ -n "$response" ]; then
      doc=$(echo "$response" | jq -r '.encoding // empty' 2>/dev/null || true)
      sig=$(echo "$response" | jq -r '.signature // empty' 2>/dev/null || true)
      if [ -n "$sig" ]; then
        ATTESTATION=$(printf '{"provider":"azure","document":"%s","signature":"%s"}' \
          "$(echo "$response" | base64 -w0)" "$sig")
        return
      fi
    fi
  fi

  echo "No cloud provider detected, registering as bare metal host."
}

detect_cloud_provider

# Build metadata
METADATA="{}"
if [ -n "${YELLOWDOG_ROLE:-}" ] || [ -n "${YELLOWDOG_DATACENTER:-}" ]; then
  METADATA=$(jq -n \
    --arg role "${YELLOWDOG_ROLE:-}" \
    --arg dc "${YELLOWDOG_DATACENTER:-}" \
    '{role: (if $role != "" then $role else null end), datacenter: (if $dc != "" then $dc else null end)} | with_entries(select(.value != null))')
fi

# Build request payload
PAYLOAD=$(jq -n \
  --arg h "$HOSTNAME" \
  --arg k "$SSH_PUBKEY" \
  --arg a "$AGE_RECIPIENT" \
  --argjson att "$ATTESTATION" \
  --argjson meta "$METADATA" \
  '{hostname: $h, ssh_pubkey: $k, age_recipient: $a, attestation: $att, metadata: $meta}')

# Build auth header
AUTH_HEADER=""
if [ -n "${YELLOWDOG_TOKEN:-}" ]; then
  AUTH_HEADER="-H \"Authorization: Bearer ${YELLOWDOG_TOKEN}\""
fi

# Register with YellowDog
echo "Registering host '$HOSTNAME' with $REGISTRATION_URL..."
RESPONSE=$(eval curl -sf -X POST \
  "$REGISTRATION_URL/api/hosts/register" \
  -H "Content-Type: application/json" \
  ${AUTH_HEADER:+"$AUTH_HEADER"} \
  -d "'$(echo "$PAYLOAD" | jq -c .)'") || {
    echo "ERROR: Registration failed. Check YELLOWDOG_REGISTRATION_URL and network connectivity." >&2
    exit 1
  }

STATUS=$(echo "$RESPONSE" | jq -r '.status // "unknown"')
TRUST=$(echo "$RESPONSE" | jq -r '.trust_level // "unknown"')

echo "Registration complete: status=$STATUS, trust_level=$TRUST"
