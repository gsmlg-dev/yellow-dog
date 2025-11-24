# Root Zone Management Configuration Examples

This directory contains example TOML configuration files for YellowDog DNS root zone management.

## Strategies

YellowDog DNS supports three strategies for managing root zone data:

### 1. Hints Strategy (`hints.toml`)

**Use Case**: Standard recursive resolver deployment

**Description**: Uses embedded root server addresses (a-m.root-servers.net) compiled into the application.

**Advantages**:
- No external dependencies
- Zero configuration required
- Instant startup
- No internet connectivity needed

**Configuration**:
```toml
[dns.root_zone]
strategy = "hints"
```

**Recommended For**: Most deployments, especially production recursive resolvers

---

### 2. Fetch Strategy (`fetch.toml`)

**Use Case**: Dynamic environments requiring up-to-date root zone data

**Description**: Periodically downloads the complete root zone from IANA's InterNIC service.

**Advantages**:
- Always up-to-date root zone data
- Automatic updates
- Full root zone available for analysis

**Configuration**:
```toml
[dns.root_zone]
strategy = "fetch"
fetch_url = "https://www.internic.net/domain/root.zone"
fetch_interval_hours = 24
fallback_to_hints = true
```

**Recommended For**: Development environments, testing, monitoring systems

**Requirements**: Internet connectivity to IANA or a mirror

---

### 3. Authoritative Strategy (`auth.toml`)

**Use Case**: Air-gapped networks or environments with strict control requirements

**Description**: Loads root zone from a local zone file in BIND format.

**Advantages**:
- No internet dependency
- Full control over root zone content
- Suitable for isolated networks

**Configuration**:
```toml
[dns.root_zone]
strategy = "auth"
zone_file = "/etc/yellowdog/zones/root.zone"
fallback_to_hints = true
```

**Recommended For**: Air-gapped deployments, security-critical environments

**Requirements**:
- Manual root zone file management
- Zone file in BIND format
- Updates must be performed manually

---

## Fallback Behavior

All strategies (except hints) support fallback to embedded hints:

```toml
fallback_to_hints = true
```

When enabled:
- **Fetch Strategy**: Falls back to hints if download fails
- **Auth Strategy**: Falls back to hints if zone file is missing or invalid

This ensures service continuity even when external dependencies fail.

## Downloading Root Zone

To obtain the latest root zone file:

```bash
# Download from IANA
curl -o root.zone https://www.internic.net/domain/root.zone

# Or using wget
wget https://www.internic.net/domain/root.zone

# Verify the zone file
named-checkzone . root.zone
```

## Recommendations

| Deployment Type | Recommended Strategy | Reason |
|----------------|---------------------|---------|
| Production Recursive Resolver | `hints` | Simple, reliable, no dependencies |
| Development/Testing | `fetch` | Always current, automatic updates |
| Air-gapped Network | `auth` | No external connectivity needed |
| Monitoring System | `fetch` | Full zone data available |
| High-security Environment | `auth` | Full control over content |

## API Usage

Once configured, use the Root Zone Manager API:

```elixir
# Get root servers
servers = YellowDog.Dns.RootZone.Manager.get_root_servers()

# Get current strategy
strategy = YellowDog.Dns.RootZone.Manager.get_strategy()

# Reload root zone
:ok = YellowDog.Dns.RootZone.Manager.reload_root_zone()

# Get statistics
stats = YellowDog.Dns.RootZone.Manager.stats()
```

## Performance Considerations

- **Hints**: Zero overhead, instant access
- **Fetch**: Initial delay on first fetch, periodic network activity
- **Auth**: File I/O on startup and reload

## Updates

- **Hints**: Updated with each YellowDog release
- **Fetch**: Automatic based on `fetch_interval_hours`
- **Auth**: Manual - administrator must update zone file

## See Also

- [IANA Root Zone Database](https://www.iana.org/domains/root)
- [Root Server Technical Operations](https://root-servers.org/)
- [RFC 8806 - Running a Root Server Local to a Resolver](https://www.rfc-editor.org/rfc/rfc8806.html)
