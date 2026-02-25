# PRD: Host Identity Registry for Yellowdog

## 1. Overview

The Host Identity Registry provides a secure, identity-first mechanism for registering, approving, and managing machine identities for NixOS hosts within the Yellowdog infrastructure.

Hosts generate their own SSH host keys locally and register their public keys with Yellowdog. The registry becomes the authoritative source of machine identity and authorization for encrypted secret access (e.g., sops-nix recipients).

A key differentiator is the **pluggable trust provider** architecture. Registration trust is established through interchangeable providers — DHCP lease correlation for on-prem hosts, cloud instance identity attestation for cloud VMs, and provisioning tokens as a universal fallback. All providers feed into a unified approval policy engine.

**Umbrella App:** `yellow_dog_identity`

---

## 2. Goals

- Allow hosts to self-generate cryptographic identity
- Register host public keys securely
- Provide an approval workflow for machine authorization
- **Establish trust via pluggable providers: DHCP correlation, cloud attestation, tokens**
- **Support cloud VMs (AWS, GCP, Azure) via instance identity documents**
- Integrate with GitOps workflows
- Automatically update sops recipients
- Enable revocation of machine access
- Avoid distributing private keys
- Support stateless and netboot installations

---

## 3. Non-Goals

- Not a secret storage system (not a replacement for Vault)
- Does not store private keys
- Does not manage runtime credentials
- Does not transmit key material over DHCP (size/security constraints)

---

## 4. Architecture

### High-Level Flow

```
  On-Prem Host                          Cloud VM (AWS/GCP/Azure)
 ┌──────────┐    DHCP     ┌─────────┐  ┌──────────┐
 │   Host   │────────────▶│ yd_dhcp │  │ Cloud VM │
 │  (boot)  │◀────────────│ (lease) │  │  (boot)  │
 └────┬─────┘  IP + URL   └────┬────┘  └────┬─────┘
      │                        │             │
      │ Generate key           │ Lease       │ Generate key
      │ POST /register         │ event       │ Fetch instance identity doc
      │                        │             │ POST /register + attestation
      │                        ▼             │
      │              ┌───────────────────────────────────┐
      └─────────────▶│       yellow_dog_identity          │
                     │                                   │
                     │  ┌─────────────────────────────┐  │
                     │  │    Trust Provider Router     │  │
                     │  │                             │  │
                     │  │  ┌─────────┐ ┌───────────┐ │  │
                     │  │  │  DHCP   │ │   Cloud   │ │  │
                     │  │  │ Correl. │ │  Attest.  │ │  │
                     │  │  └────┬────┘ └─────┬─────┘ │  │
                     │  │       │             │       │  │
                     │  │  ┌────┴─────────────┴────┐ │  │
                     │  │  │   Token Verification  │ │  │
                     │  │  └───────────┬───────────┘ │  │
                     │  └──────────────┼─────────────┘  │
                     │                 ▼                 │
                     │        Approval Policy Engine     │
                     │         → auto-approve            │
                     │         → pending review          │
                     │         → reject                  │
                     └──────────────────┬────────────────┘
                                       ▼
                            ┌──────────────────────┐
                            │  GitOps / CI          │
                            │  Export recipients    │
                            │  Update .sops.yaml   │
                            │  Re-encrypt secrets  │
                            └──────────────────────┘
```

### Components

| Component | App | Responsibility |
|-----------|-----|----------------|
| Identity API | `yellow_dog_identity` | Registration, approval, export |
| Trust Provider Router | `yellow_dog_identity` | Dispatches to appropriate trust provider |
| DHCP Correlation | `yellow_dog_identity` | Lease↔registration matching (on-prem) |
| Cloud Attestation | `yellow_dog_identity` | Instance identity verification (cloud) |
| Host Registry | `yellow_dog_identity` | TOML-based identity storage |
| Approval Engine | `yellow_dog_identity` | Policy-driven trust decisions |
| Console UI | `yellow_dog_console` | Approval workflow, audit view |
| DHCP Events | `yellow_dog_dhcp` | Lease event telemetry |
| GitOps Export | `yellow_dog_identity` | Recipient list generation |

---

## 5. Pluggable Trust Provider Framework

### 5.1 Design

Trust verification is abstracted behind a behaviour that all providers implement. The registration endpoint doesn't know or care which provider establishes trust — it receives a uniform trust result.

**Behaviour:**

```
@callback verify(registration_context) :: trust_result

registration_context :: %{
  source_ip: ip_address,
  hostname: string,
  attestation: attestation_document | nil,
  metadata: map
}

trust_result ::
  | {:trusted, trust_level, provider_evidence}
  | {:untrusted, reason}
  | {:skip, :not_applicable}
```

**Provider dispatch:** On registration, the router tries each configured provider in priority order. First `{:trusted, ...}` wins. If all return `{:skip, ...}`, the result is `unverified`.

```
Provider priority (configurable):
  1. Cloud Attestation  — if attestation document present
  2. DHCP Correlation   — if source IP matches active lease
  3. Token Verification — if Authorization header present
  4. → unverified       — fallback
```

### 5.2 Trust Levels (Unified)

| Trust Level | Provider | Evidence | Strength |
|-------------|----------|----------|----------|
| `cloud_verified` | Cloud Attestation | Cryptographically signed instance identity | Strongest (cloud) |
| `netboot_verified` | DHCP + TFTP | DHCP lease + boot profile + registration | Strongest (on-prem) |
| `network_verified` | DHCP Correlation | Active lease + fingerprint match | Strong |
| `network_partial` | DHCP Correlation | Active lease, no fingerprint | Medium |
| `token_verified` | Token | Valid provisioning token | Medium |
| `unverified` | None | No trust signal | Manual approval |

### 5.3 Provider Evidence

Each provider attaches evidence to the trust result for audit and policy evaluation. Evidence is stored on the host record as `trust_evidence`.

---

## 6. Trust Provider: DHCP Correlation

### 6.1 Problem

The registration endpoint accepts identity submissions from the network. Without authentication, any device could register a key and potentially gain access to encrypted secrets.

DHCP does **not** carry key material — options are limited to 255 bytes per option (~1232 bytes practical payload), and DHCP is unauthenticated plaintext. SSH ed25519 pubkeys exceed this, and the channel is untrusted.

### 6.2 Solution: Network-Based Trust

Yellowdog already manages the DHCP lifecycle. The correlation chain provides implicit authentication:

```
MAC address → DHCP lease → IP assignment → registration source IP → host identity
```

When a host registers, the DHCP provider checks:

1. **Active lease exists** for the source IP of the registration request
2. **Lease is current** (not expired)
3. **Device fingerprint** matches an expected class (optional, from DHCP fingerprinting)
4. **No conflicting registration** exists for this lease

This eliminates pre-shared tokens for hosts on managed networks.

### 6.3 DHCP Registration URL Delivery

DHCP responses include the registration endpoint URL via:

- **Option 114 (Default URL)** — standard DHCP option for URL delivery
- **iPXE `registration-url` setting** — for netboot scenarios, embedded in the boot script

The host's boot/provisioning script reads this URL and performs identity registration as part of first-boot.

### 6.4 Correlation Module

The correlation module subscribes to DHCP lease events and maintains a time-windowed view of active leases for identity verification.

**Telemetry subscription (from `yellow_dog_dhcp`):**

```
[:yellow_dog, :dhcp, :lease, :commit]
  metadata: %{
    mac: mac_address,
    ip: assigned_ip,
    hostname: client_hostname,
    fingerprint_class: device_class,
    lease_duration: seconds,
    interface: network_interface
  }

[:yellow_dog, :dhcp, :lease, :release]
  metadata: %{mac: mac_address, ip: released_ip}

[:yellow_dog, :dhcp, :lease, :expire]
  metadata: %{mac: mac_address, ip: expired_ip}
```

**Correlation lookup on registration:**

```
verify(context) →
  | {:trusted, :network_verified, lease_evidence}
  | {:trusted, :network_partial, lease_evidence}
  | {:untrusted, :no_lease}
  | {:untrusted, :expired}
  | {:untrusted, :fingerprint_mismatch}
  | {:skip, :not_applicable}           — no DHCP configured
```

**Evidence:**

```
%{
  provider: :dhcp,
  mac: "aa:bb:cc:dd:ee:ff",
  assigned_ip: {192, 168, 1, 50},
  fingerprint_class: "nixos-workstation",
  lease_start: ~U[2025-01-01 12:00:00Z],
  lease_duration: 3600,
  dhcp_interface: "eth0"
}
```

### 6.5 Netboot Integration

For netboot/iPXE hosts, the trust chain is even stronger:

1. Device PXE boots → DHCP lease assigned
2. iPXE script loaded from TFTP (managed by `yellow_dog_tftp`)
3. Boot script includes registration step:
   ```
   #!ipxe
   # ... kernel/initrd loading ...
   set registration-url ${yellow_dog_registration_url}
   ```
4. First-boot script runs: generate key → register → continue boot
5. Yellowdog correlates: DHCP lease + TFTP boot profile + registration = high trust

---

## 7. Trust Provider: Cloud Instance Attestation

### 7.1 Problem

Cloud VMs receive IP addresses from the cloud provider's infrastructure, not from Yellowdog's DHCP. There is no lease to correlate. However, cloud providers offer something stronger: cryptographically signed instance identity documents.

### 7.2 Solution: Instance Identity Verification

Each major cloud provider exposes a metadata service at `169.254.169.254` that returns a signed identity document proving the VM's account, instance ID, region, and other properties. The signature is verifiable against the provider's published public keys — no pre-shared secrets needed.

**Trust analogy:**

| On-Prem (DHCP) | Cloud (Attestation) |
|-----------------|---------------------|
| DHCP lease proves "I'm on this network" | Identity document proves "I'm in this account" |
| MAC + IP + fingerprint | Instance ID + account ID + signature |
| Implicitly signed by Yellowdog | Cryptographically signed by cloud provider |

### 7.3 Attestation Flow

```
Cloud VM                          Yellowdog
   │                                 │
   │ 1. Fetch identity doc           │
   │    from 169.254.169.254         │
   │                                 │
   │ 2. POST /api/hosts/register     │
   │    + attestation field           │
   │    ──────────────────────────▶   │
   │                                 │
   │               3. Verify signature│
   │                  against cloud   │
   │                  provider pubkey │
   │                                 │
   │               4. Extract claims: │
   │                  account_id      │
   │                  instance_id     │
   │                  region          │
   │                  image_id        │
   │                                 │
   │               5. Match against   │
   │                  allowed accounts│
   │                  and policies    │
   │                                 │
   │  {:ok, cloud_verified}          │
   │    ◀──────────────────────────  │
```

### 7.4 Provider-Specific Details

#### AWS

**Identity source:** Instance Identity Document + PKCS7 signature

```
# Host fetches:
GET http://169.254.169.254/latest/dynamic/instance-identity/document
GET http://169.254.169.254/latest/dynamic/instance-identity/pkcs7
```

**Attestation payload:**

```json
{
  "provider": "aws",
  "document": "<base64 instance identity document>",
  "signature": "<base64 PKCS7 signature>"
}
```

**Verification:**
1. Decode PKCS7 signature
2. Verify against AWS public certificate (published per-region)
3. Extract: `accountId`, `instanceId`, `region`, `imageId`, `instanceType`
4. Check `accountId` ∈ allowed accounts
5. Check document `pendingTime` is recent (prevent replay)

**Claims extracted:**

| Claim | Policy Use |
|-------|-----------|
| `accountId` | Must match allowed AWS accounts |
| `region` | Geographic policy |
| `instanceId` | Uniqueness constraint |
| `imageId` | AMI allowlist (optional) |
| `instanceType` | Role inference (optional) |

#### GCP

**Identity source:** OIDC identity token (signed JWT)

```
# Host fetches:
GET http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=yellowdog&format=full
Header: Metadata-Flavor: Google
```

**Attestation payload:**

```json
{
  "provider": "gcp",
  "token": "<JWT identity token>"
}
```

**Verification:**
1. Decode JWT, extract header `kid`
2. Fetch Google public keys from `https://www.googleapis.com/oauth2/v3/certs`
3. Verify RS256 signature
4. Validate `aud` = configured audience (e.g., `yellowdog`)
5. Extract: `google.compute_engine.project_id`, `google.compute_engine.instance_id`, `google.compute_engine.zone`
6. Check `project_id` ∈ allowed projects

**Claims extracted:**

| Claim | Policy Use |
|-------|-----------|
| `project_id` | Must match allowed GCP projects |
| `zone` | Geographic policy |
| `instance_id` | Uniqueness constraint |
| `instance_name` | Hostname correlation |

#### Azure

**Identity source:** Attested data from IMDS

```
# Host fetches:
GET http://169.254.169.254/metadata/attested/document?api-version=2021-02-01
Header: Metadata: true
```

**Attestation payload:**

```json
{
  "provider": "azure",
  "document": "<base64 attested document>",
  "signature": "<base64 signature>"
}
```

**Verification:**
1. Verify signature against Azure's intermediate certificate chain
2. Validate certificate chain roots to known Azure CA
3. Extract: `subscriptionId`, `vmId`, `resourceGroupName`, `location`
4. Check `subscriptionId` ∈ allowed subscriptions

**Claims extracted:**

| Claim | Policy Use |
|-------|-----------|
| `subscriptionId` | Must match allowed Azure subscriptions |
| `location` | Geographic policy |
| `vmId` | Uniqueness constraint |
| `resourceGroupName` | Role/environment inference |

### 7.5 Anti-Replay Protection

Instance identity documents could be captured and replayed. Mitigations:

| Attack | Mitigation |
|--------|-----------|
| Document replay | Check timestamp/`pendingTime` — reject if older than configurable window (default: 5 minutes) |
| Cross-instance replay | Bind `instance_id` to registration — one identity doc per host record |
| Stolen document | Instance ID uniqueness constraint — second registration with same instance ID is conflict |
| Provider key rotation | Cache provider public keys with TTL, refresh on verification failure |

### 7.6 Cloud Provider Configuration

```toml
[identity.cloud]
enabled = true
replay_window_seconds = 300  # 5 minute max age for attestation docs

[identity.cloud.aws]
enabled = true
allowed_accounts = ["123456789012", "987654321098"]
allowed_regions = ["us-east-1", "us-west-2"]  # optional
allowed_amis = []  # optional, empty = any

[identity.cloud.gcp]
enabled = true
allowed_projects = ["my-project-123", "infra-prod"]
audience = "yellowdog"  # must match token request
allowed_zones = []  # optional

[identity.cloud.azure]
enabled = true
allowed_subscriptions = ["sub-uuid-1", "sub-uuid-2"]
allowed_locations = []  # optional
```

### 7.7 Cloud Attestation Evidence

Stored on host record for audit:

```
%{
  provider: :aws,
  account_id: "123456789012",
  instance_id: "i-0abcdef1234567890",
  region: "us-east-1",
  image_id: "ami-0123456789abcdef0",
  instance_type: "t3.medium",
  verified_at: ~U[2025-01-01 12:00:00Z],
  document_time: ~U[2025-01-01 11:59:58Z]
}
```

### 7.8 Host-Side Registration Script (NixOS)

A minimal NixOS module/script for cloud hosts:

```bash
#!/usr/bin/env bash
# yellowdog-register.sh — runs on first boot

REGISTRATION_URL="${YELLOWDOG_REGISTRATION_URL}"
HOSTNAME=$(hostname)

# Generate key if not present
if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
  ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N ""
fi

SSH_PUBKEY=$(cat /etc/ssh/ssh_host_ed25519_key.pub)
AGE_RECIPIENT=$(ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub)

# Detect cloud provider and fetch attestation
ATTESTATION="{}"
if curl -sf -m 1 http://169.254.169.254/latest/meta-data/ >/dev/null 2>&1; then
  # AWS
  DOC=$(curl -sf http://169.254.169.254/latest/dynamic/instance-identity/document | base64 -w0)
  SIG=$(curl -sf http://169.254.169.254/latest/dynamic/instance-identity/pkcs7 | base64 -w0)
  ATTESTATION=$(jq -n --arg d "$DOC" --arg s "$SIG" \
    '{"provider":"aws","document":$d,"signature":$s}')
elif curl -sf -m 1 -H "Metadata-Flavor: Google" \
     http://metadata.google.internal/computeMetadata/v1/ >/dev/null 2>&1; then
  # GCP
  TOKEN=$(curl -sf -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=yellowdog&format=full")
  ATTESTATION=$(jq -n --arg t "$TOKEN" '{"provider":"gcp","token":$t}')
fi

# Register
curl -sf -X POST "$REGISTRATION_URL/api/hosts/register" \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg h "$HOSTNAME" \
    --arg k "$SSH_PUBKEY" \
    --arg a "$AGE_RECIPIENT" \
    --argjson att "$ATTESTATION" \
    '{hostname:$h, ssh_pubkey:$k, age_recipient:$a, attestation:$att}')"
```

---

## 8. Functional Requirements

### 8.1 Host Registration

**Endpoint:** `POST /api/hosts/register`

**Payload:**

```json
{
  "hostname": "node-01",
  "ssh_pubkey": "ssh-ed25519 AAAA...",
  "age_recipient": "age1xxxx",
  "machine_id": "optional-dbus-machine-id",
  "attestation": {
    "provider": "aws",
    "document": "<base64>",
    "signature": "<base64>"
  },
  "metadata": {
    "role": "worker",
    "datacenter": "dc1"
  }
}
```

The `attestation` field is optional. When present, the cloud attestation provider processes it. When absent, DHCP correlation and token verification are tried.

**Behavior:**

1. Validate key format (ed25519 pubkey, age recipient format)
2. Compute `key_fingerprint` from pubkey
3. Check uniqueness on `(key_fingerprint)` — reject duplicates
4. Check for conflicting hostname with different key:
   - If same hostname + different key → require explicit `force: true` or reject
   - Store previous key in `previous_keys` audit trail
5. **Route through trust provider chain** (cloud attestation → DHCP → token → unverified)
6. Apply approval policy with trust result
7. Store identity record with provider evidence
8. Emit telemetry event

**Response:**

```json
{
  "id": "uuid",
  "status": "approved | pending",
  "trust_level": "cloud_verified | network_verified | unverified",
  "trust_provider": "aws | gcp | azure | dhcp | token | none",
  "message": "Registration accepted"
}
```

### 8.2 Approval Workflow

**States:**

```
                ┌──────────┐
    register    │          │   approve
   ────────────▶│ pending  │──────────────┐
                │          │              │
                └────┬─────┘              ▼
                     │            ┌──────────────┐
                     │            │   approved   │
                     │            └──────┬───────┘
                     │                   │
                     │    revoke         │  revoke
                     ▼                   ▼
              ┌──────────────────────────────┐
              │           revoked            │
              └──────────────────────────────┘
```

**Approval methods (ordered by trust):**

1. **Auto-approve via cloud attestation** — `cloud_verified` trust level
2. **Auto-approve via DHCP correlation** — `network_verified` trust level
3. **Provisioning token** — pre-generated, single-use, time-limited
4. **Auto-approve policy** — rules based on metadata (role, datacenter, hostname pattern)
5. **Manual UI approval** — operator action in console

### 8.3 Re-registration Policy

When a host registers with the **same hostname but different key**:

| Scenario | Behavior |
|----------|----------|
| Same key, same hostname | Idempotent — return existing record |
| Different key, `force: true` | Archive old key in `previous_keys`, update, set pending |
| Different key, no `force` | Reject with `409 Conflict` |
| Same key, different hostname | Allow — hostname is a label, key is identity |

### 8.4 Recipient Export

**Endpoint:** `GET /api/hosts/recipients`

**Output (YAML):**

```yaml
age:
  - age1hostA
  - age1hostB
```

**Endpoint:** `GET /api/hosts/recipients?format=sops`

**Output (.sops.yaml fragment):**

```yaml
creation_rules:
  - age: >-
      age1hostA,
      age1hostB
```

### 8.5 Revocation

1. Mark host as `revoked` (with reason, operator, timestamp)
2. Remove from recipient export immediately
3. Emit telemetry event
4. Trigger CI webhook for secret re-encryption (if configured)
5. Expose revocation check endpoint:

**Endpoint:** `GET /api/hosts/:id/status`

This provides real-time revocation verification without waiting for CI pipeline propagation.

---

## 9. Data Model

### Host Identity

| Field | Type | Description |
|-------|------|-------------|
| `id` | UUID | Primary key |
| `hostname` | string | Display name (not authoritative identifier) |
| `machine_id` | string | dbus machine-id (optional, stable across reboots) |
| `ssh_pubkey` | string | SSH ed25519 public key |
| `key_fingerprint` | string | SHA256 fingerprint of pubkey (indexed, unique) |
| `age_recipient` | string | Derived age identity |
| `status` | enum | `pending` / `approved` / `revoked` |
| `trust_level` | enum | See §5.2 unified trust levels |
| `trust_provider` | enum | `dhcp` / `aws` / `gcp` / `azure` / `token` / `none` |
| `trust_evidence` | map | Provider-specific evidence (see below) |
| `role` | string | Host role (promoted from metadata) |
| `datacenter` | string | Datacenter/region (promoted from metadata) |
| `metadata` | map | Additional arbitrary info |
| `previous_keys` | list | Audit trail of replaced keys |
| `created_at` | timestamp | |
| `approved_at` | timestamp | |
| `approved_by` | string | Operator or `auto:policy_name` |
| `revoked_at` | timestamp | |
| `revoked_by` | string | |
| `revoke_reason` | string | |

### Trust Evidence (by provider)

**DHCP:**

```
%{
  provider: :dhcp,
  mac: "aa:bb:cc:dd:ee:ff",
  assigned_ip: {192, 168, 1, 50},
  fingerprint_class: "nixos-workstation",
  lease_start: ~U[2025-01-01 12:00:00Z],
  lease_duration: 3600,
  dhcp_interface: "eth0"
}
```

**AWS:**

```
%{
  provider: :aws,
  account_id: "123456789012",
  instance_id: "i-0abcdef1234567890",
  region: "us-east-1",
  image_id: "ami-0123456789abcdef0",
  instance_type: "t3.medium",
  verified_at: ~U[2025-01-01 12:00:00Z],
  document_time: ~U[2025-01-01 11:59:58Z]
}
```

**GCP:**

```
%{
  provider: :gcp,
  project_id: "my-project-123",
  instance_id: "1234567890123456789",
  instance_name: "node-01",
  zone: "us-central1-a",
  verified_at: ~U[2025-01-01 12:00:00Z]
}
```

**Azure:**

```
%{
  provider: :azure,
  subscription_id: "sub-uuid-1",
  vm_id: "vm-uuid",
  resource_group: "infra-prod",
  location: "eastus",
  verified_at: ~U[2025-01-01 12:00:00Z]
}
```

### Provisioning Token

| Field | Type | Description |
|-------|------|-------------|
| `id` | UUID | Primary key |
| `token_hash` | string | bcrypt hash of token value |
| `hostname_pattern` | string | Glob pattern for allowed hostnames |
| `role` | string | Assigned role on use |
| `max_uses` | integer | Usage limit (1 = single-use) |
| `use_count` | integer | Current usage |
| `expires_at` | timestamp | Expiry |
| `created_by` | string | Operator |

---

## 10. Approval Policy Engine

Policies are evaluated in order; first match wins.

### Policy Configuration (TOML)

```toml
[identity.approval]
default_action = "pending"  # pending | reject

# On-prem: auto-approve DHCP-verified hosts
[[identity.approval.policies]]
name = "trusted-network-auto"
description = "Auto-approve hosts with verified DHCP correlation"
match.trust_level = "network_verified"
match.role = ["worker", "storage"]
action = "approve"

# Cloud: auto-approve verified AWS instances in allowed accounts
[[identity.approval.policies]]
name = "aws-prod-auto"
description = "Auto-approve AWS instances from prod account"
match.trust_level = "cloud_verified"
match.trust_provider = "aws"
match.cloud_account = "123456789012"
match.cloud_region = ["us-east-1", "us-west-2"]
action = "approve"

# Cloud: auto-approve verified GCP instances
[[identity.approval.policies]]
name = "gcp-infra-auto"
description = "Auto-approve GCP instances from infra project"
match.trust_level = "cloud_verified"
match.trust_provider = "gcp"
match.cloud_account = "my-project-123"
action = "approve"

# On-prem: dc1 workstations
[[identity.approval.policies]]
name = "dc1-workstations"
description = "Auto-approve workstations in dc1"
match.trust_level = ["network_verified", "network_partial"]
match.datacenter = "dc1"
match.hostname_pattern = "ws-*"
action = "approve"

# Token-verified
[[identity.approval.policies]]
name = "token-approved"
description = "Auto-approve token-verified registrations"
match.trust_level = "token_verified"
action = "approve"

# Reject unverified
[[identity.approval.policies]]
name = "reject-unverified"
description = "Reject registrations with no trust signal"
match.trust_level = "unverified"
action = "reject"
```

### Policy Matching Fields

| Field | Operators | Description |
|-------|-----------|-------------|
| `trust_level` | exact, list | Trust level from provider |
| `trust_provider` | exact, list | Which provider verified (`aws`, `gcp`, `azure`, `dhcp`, `token`) |
| `cloud_account` | exact, list | AWS account ID, GCP project ID, or Azure subscription ID |
| `cloud_region` | exact, list | Provider region/zone |
| `cloud_image` | exact, list | AMI ID, GCP image, etc. |
| `role` | exact, list | Host role |
| `datacenter` | exact, list | Datacenter |
| `hostname_pattern` | glob | Hostname pattern |
| `fingerprint_class` | exact, list | DHCP device fingerprint class |
| `mac_prefix` | prefix | OUI-based vendor matching |

---

## 11. Persistence

Consistent with Yellowdog's TOML-based file persistence pattern.

### File Layout

```
/var/lib/yellowdog/identity/
├── config.toml              # Approval policies, correlation settings
├── hosts/
│   ├── <uuid>.toml          # One file per registered host
│   └── ...
├── tokens/
│   ├── <uuid>.toml          # Provisioning tokens
│   └── ...
└── audit.log                # Append-only audit trail
```

### Host File Format

```toml
[host]
id = "550e8400-e29b-41d4-a716-446655440000"
hostname = "node-01"
machine_id = "a1b2c3d4"
ssh_pubkey = "ssh-ed25519 AAAA..."
key_fingerprint = "SHA256:xyzabc..."
age_recipient = "age1xxxx"
status = "approved"
trust_level = "cloud_verified"
trust_provider = "aws"
role = "worker"
datacenter = "us-east-1"
created_at = 2025-01-01T12:00:00Z
approved_at = 2025-01-01T12:00:01Z
approved_by = "auto:aws-prod-auto"

[host.trust_evidence]
provider = "aws"
account_id = "123456789012"
instance_id = "i-0abcdef1234567890"
region = "us-east-1"
image_id = "ami-0123456789abcdef0"
instance_type = "t3.medium"
verified_at = 2025-01-01T12:00:00Z
document_time = 2025-01-01T11:59:58Z

[host.metadata]
kernel = "6.1.0"
```

### Write Safety

File operations use the copy-validate-replace pattern consistent with other Yellowdog TOML stores:

1. Write to `<uuid>.toml.tmp`
2. Validate written content
3. Rename atomically to `<uuid>.toml`

---

## 12. Telemetry Events

```
[:yellow_dog, :identity, :register, :start]
  metadata: %{hostname, source_ip, trust_level}

[:yellow_dog, :identity, :register, :stop]
  measurements: %{duration: native_time}
  metadata: %{hostname, status, trust_level, trust_provider, policy_applied}

[:yellow_dog, :identity, :register, :exception]
  measurements: %{duration: native_time}
  metadata: %{hostname, reason}

[:yellow_dog, :identity, :approve]
  metadata: %{host_id, approved_by, trust_level}

[:yellow_dog, :identity, :revoke]
  metadata: %{host_id, revoked_by, reason}

[:yellow_dog, :identity, :correlation, :match]
  metadata: %{source_ip, mac, fingerprint_class, trust_level}

[:yellow_dog, :identity, :correlation, :miss]
  metadata: %{source_ip, reason}

[:yellow_dog, :identity, :attestation, :verify]
  measurements: %{duration: native_time}
  metadata: %{provider, account_id, instance_id, result}

[:yellow_dog, :identity, :attestation, :reject]
  metadata: %{provider, reason, source_ip}

[:yellow_dog, :identity, :export, :recipients]
  measurements: %{count: integer, duration: native_time}
```

---

## 13. Console UI

### Pages

- **Host Registry List** — table of all hosts with status, trust level, filters
- **Host Detail** — full identity record, lease correlation, audit history
- **Pending Approvals** — filtered view with approve/reject actions
- **Provisioning Tokens** — create, view, revoke tokens
- **Approval Policies** — view/edit policy rules (read from config.toml)

### LiveView Events

Registration and approval state changes pushed to console via PubSub for real-time updates.

---

## 14. Security Model

**Principles:**

- Private keys never leave the host
- Registry stores only public identity material
- Authorization is separate from identity creation
- Trust is layered and provider-agnostic
- Cloud attestation is cryptographically verified, not IP-based
- Revocation propagates immediately to export endpoint

**Trust hierarchy:**

```
Strongest ──▶ Cloud attestation (cryptographic proof from provider)
              Netboot chain (DHCP + TFTP + registration)
              DHCP correlation + fingerprint match
              DHCP correlation only
              Provisioning token
Weakest ────▶ Unverified (manual approval required)
```

**Threat mitigations:**

| Threat | Mitigation |
|--------|-----------|
| Rogue device on network | DHCP fingerprint filtering, approval policy |
| IP spoofing registration | Lease correlation checks MAC↔IP binding |
| Stolen cloud identity doc | Anti-replay (timestamp window), instance ID uniqueness |
| Cross-account cloud VM | Account/project/subscription allowlist |
| Key replacement attack | Conflict detection, `force` flag, audit trail |
| Stale approved host | Lease expiry correlation, periodic re-verification |
| Auto-approve misconfiguration | Policy audit log, default-deny posture |

---

## 15. GitOps Integration

### CI Pipeline

1. Webhook or cron triggers pipeline
2. Fetch recipients: `GET /api/hosts/recipients?format=sops`
3. Generate/update `.sops.yaml`
4. Run `sops updatekeys -r secrets/`
5. Commit and push changes
6. Emit telemetry on completion

### Webhook

`POST` webhook on approval/revocation state changes:

```json
{
  "event": "host.approved",
  "host_id": "uuid",
  "hostname": "node-01",
  "age_recipient": "age1xxxx",
  "timestamp": "2025-01-01T12:00:01Z"
}
```

---

## 16. Operational Workflows

### Provisioning (Managed Network — On-Prem)

1. Host boots on managed network
2. DHCP assigns IP, delivers registration URL (option 114)
3. Host generates SSH key, derives age recipient
4. Host POSTs to registration endpoint
5. Yellowdog correlates source IP ↔ DHCP lease → `network_verified`
6. Policy auto-approves
7. CI updates sops recipients
8. Host can decrypt secrets on next config deploy

### Provisioning (Cloud VM)

1. Cloud VM boots, receives IP from provider
2. First-boot script runs `yellowdog-register.sh` (or NixOS module)
3. Script fetches instance identity document from metadata service (`169.254.169.254`)
4. Script generates SSH key, derives age recipient
5. Script POSTs to registration endpoint with attestation document
6. Yellowdog verifies signature against provider public keys
7. Yellowdog extracts claims, checks account ∈ allowed accounts → `cloud_verified`
8. Policy auto-approves
9. CI updates sops recipients

### Provisioning (Unmanaged Network — Token)

1. Operator creates provisioning token with hostname pattern
2. Token delivered out-of-band (e.g., in NixOS config)
3. Host boots, registers with token in header
4. Yellowdog validates token → `token_verified`
5. Policy auto-approves

### Netboot Provisioning (On-Prem)

1. Device PXE boots → DHCP lease + boot profile assigned
2. iPXE loads from TFTP, includes registration step
3. First-boot registers identity
4. Full trust chain: DHCP + TFTP profile + registration IP correlation
5. Highest on-prem trust level, auto-approve

### Reinstall

1. Host preserves SSH host key across reinstall (persist in /etc)
2. Re-registration is idempotent (same key → same record)
3. If key regenerated: re-register with `force: true`, enters pending

### Decommission

1. Operator revokes host in console or API
2. Recipient removed from export immediately
3. CI re-encrypts secrets
4. Revocation queryable via status endpoint

---

## 17. Future Enhancements

- SSH CA integration for short-lived certificates
- TPM-based enrollment and measured boot validation
- Periodic re-attestation (host proves it still holds private key)
- Geographic policy (auto-approve only from known datacenter subnets)
- Integration with NixOS `system.stateVersion` for drift detection
- **Additional cloud providers** (Hetzner, DigitalOcean, Oracle Cloud)
- **Kubernetes pod identity** via service account tokens (for containerized hosts)

---

## 18. Acceptance Criteria

- [ ] Host can register identity without pre-shared secrets
- [ ] **Trust provider router dispatches to correct provider based on registration context**
- [ ] DHCP correlation correctly matches registration to active lease
- [ ] **AWS instance identity documents verified against AWS public certificates**
- [ ] **GCP OIDC identity tokens verified against Google public keys**
- [ ] **Azure attested documents verified against Azure certificate chain**
- [ ] **Anti-replay protection rejects stale attestation documents**
- [ ] **Cloud account/project/subscription allowlists enforced**
- [ ] Trust levels correctly derived from provider result
- [ ] Approval policies evaluate and auto-approve/reject as configured
- [ ] **Cloud-specific policy fields (cloud_account, cloud_region) match correctly**
- [ ] Re-registration with same key is idempotent
- [ ] Re-registration with different key requires `force` flag
- [ ] Approved hosts appear in recipient export
- [ ] Revoked hosts removed from recipient export immediately
- [ ] Provisioning tokens work for out-of-band registration
- [ ] Console UI shows pending approvals with approve/reject actions
- [ ] Telemetry events emitted for all state transitions (including attestation)
- [ ] TOML persistence uses safe write patterns
- [ ] Netboot integration delivers registration URL via iPXE
- [ ] CI webhook fires on approval/revocation
- [ ] **Host-side registration script works on AWS, GCP, Azure, and bare metal**

---

## 19. File Structure

```
apps/yellow_dog_identity/
├── lib/
│   └── yellow_dog_identity/
│       ├── identity.ex              # Public API
│       ├── host.ex                  # Host identity struct
│       ├── registry.ex              # TOML-based host storage
│       ├── trust/
│       │   ├── provider.ex          # Trust provider behaviour
│       │   ├── router.ex            # Provider dispatch chain
│       │   ├── dhcp/
│       │   │   ├── correlation.ex   # DHCP↔registration correlation
│       │   │   ├── lease_cache.ex   # Active lease state (from telemetry)
│       │   │   └── matcher.ex       # IP↔lease matching logic
│       │   ├── cloud/
│       │   │   ├── attestation.ex   # Cloud attestation dispatch
│       │   │   ├── aws.ex           # AWS instance identity verification
│       │   │   ├── gcp.ex           # GCP OIDC token verification
│       │   │   └── azure.ex         # Azure attested document verification
│       │   └── token/
│       │       └── verifier.ex      # Provisioning token verification
│       ├── approval/
│       │   ├── engine.ex            # Policy evaluation
│       │   └── policy.ex            # Policy struct and parsing
│       ├── token.ex                 # Provisioning token management
│       ├── export.ex                # Recipient export (YAML, sops)
│       ├── webhook.ex               # Outbound webhook notifications
│       └── telemetry.ex             # Telemetry event helpers
├── test/
│   └── yellow_dog_identity/
│       ├── registry_test.exs
│       ├── trust/
│       │   ├── router_test.exs
│       │   ├── dhcp_correlation_test.exs
│       │   ├── aws_attestation_test.exs
│       │   ├── gcp_attestation_test.exs
│       │   └── azure_attestation_test.exs
│       ├── approval_engine_test.exs
│       ├── token_test.exs
│       └── export_test.exs
└── mix.exs
```

---

## 20. Dependencies

| Dependency | Source | Purpose |
|-----------|--------|---------|
| `yellow_dog` | umbrella | Core config, telemetry |
| `yellow_dog_dhcp` | umbrella | Lease events (telemetry subscription only) |
| `yellow_dog_console` | umbrella | LiveView UI (optional) |
| `toml` | hex | TOML parsing |
| `yaml_elixir` | hex | Recipient YAML export |
| `jose` | hex | JWT verification for GCP OIDC tokens |
| `x509` | hex | Certificate chain verification for AWS/Azure |

No dependency on `yellow_dog_dhcp` at the module level — correlation subscribes to telemetry events only, maintaining clean app boundaries. Cloud provider public keys are fetched and cached at startup; no runtime dependency on external services for verification after initial key fetch.

---

## 21. Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|-----------|
| Auto-approve misconfiguration | Medium | High | Default-deny, policy audit log |
| DHCP correlation race (register before lease propagates) | Medium | Low | Configurable grace window, retry |
| Registry file corruption | Low | High | Atomic writes, backup on change |
| IP reuse after lease expiry | Low | Medium | Strict lease expiry checking |
| Spoofed MAC in registration correlation | Low | Medium | Layered trust, not MAC-only |
| Cloud provider key rotation | Low | Low | Cached keys with TTL, refresh on verify failure |
| Attestation document replay | Low | Medium | Timestamp window, instance ID uniqueness |
| Cloud metadata service spoofing | Very Low | High | Only relevant if attacker controls hypervisor — out of threat model |

---

## 22. Open Questions

- Should the correlation grace window be configurable per-policy or global?
- What metadata schema beyond `role` and `datacenter` should be first-class?
- Should re-attestation be periodic or event-driven (e.g., on config deploy)?
- Integration with NixOS activation scripts — should Yellowdog provide a NixOS module?
- Should cloud provider public key caching use ETS or a dedicated GenServer?
- Should the registration script be distributed as a Nix flake package?
- Support for multi-cloud hosts (e.g., VM migrated between providers)?