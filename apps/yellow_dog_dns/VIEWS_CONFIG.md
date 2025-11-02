# DNS Views Configuration Guide

This guide explains how to configure DNS Views for split-horizon DNS in YellowDog DNS server.

## Table of Contents

1. [Overview](#overview)
2. [Enabling Views](#enabling-views)
3. [Configuration Format](#configuration-format)
4. [Built-in ACLs](#built-in-acls)
5. [Custom ACLs](#custom-acls)
6. [View Matching Behavior](#view-matching-behavior)
7. [Common Scenarios](#common-scenarios)
8. [API Reference](#api-reference)
9. [Troubleshooting](#troubleshooting)

---

## Overview

DNS Views enable split-horizon DNS - serving different DNS responses to different clients based on their IP addresses. This is useful for:

- **Network Segmentation**: Internal vs external clients see different records
- **Security**: Hiding internal infrastructure from external queries
- **Multi-tenant**: Different DNS answers for different customer networks
- **Development**: Separate dev/staging/prod DNS namespaces

### Key Features

- **ACL-based Client Matching**: IPv4 and IPv6 subnet matching with CIDR notation
- **First-Match-Wins**: Views are evaluated in order, first matching view is used
- **Per-View Zone Collections**: Each view can restrict which zones are accessible
- **Per-View Recursion Control**: Enable/disable recursion per view
- **Built-in ACLs**: Common ACL patterns (any, none, localhost, localnets)
- **Custom ACLs**: Define complex allow/deny rules with CIDR ranges
- **Hot-Reload Ready**: Configuration can be reloaded without restart (future feature)

---

## Enabling Views

### 1. Create Configuration File

Create a TOML configuration file with your view definitions. See [examples/views.toml](examples/views.toml) for a complete example:

```toml
# views.toml
[[view]]
name = "internal"
match_clients = "localnets"
recursion = true
zones = ["corp.example.com", "internal.example.com"]

[[view]]
name = "external"
match_clients = "any"
recursion = false
zones = ["public.example.com"]
```

### 2. Configure Application

Set the views configuration path in your application config:

**config/config.exs:**
```elixir
config :yellow_dog_dns,
  views_config_path: "config/views.toml"
```

**Runtime Configuration:**
```elixir
Application.put_env(:yellow_dog_dns, :views_config_path, "/etc/yellowdog/views.toml")
```

### 3. Start Server

When the DNS handler starts, it will:
1. Try to load views from the configured path
2. Log success/failure to telemetry
3. Fall back to default view if loading fails

**Default Behavior (No Configuration):**
- Creates a single "default" view
- Matches all clients (`:all`)
- Allows access to all loaded zones
- Recursion enabled

---

## Configuration Format

### View Structure

Each view is defined with a `[[view]]` section in TOML:

```toml
[[view]]
name = "view_name"              # Required: Unique view identifier
match_clients = "acl_name"      # Required: Built-in ACL name or custom ACL
recursion = true                # Optional: Enable/disable recursion (default: true)
zones = ["zone1.com", "zone2"]  # Optional: Accessible zones (default: all zones)
```

### View Fields

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `name` | String | No | `"view_N"` | View identifier (generated from index if omitted) |
| `match_clients` | String or ACL | No | `:all` | ACL for client matching (built-in name or custom) |
| `recursion` | Boolean | No | `true` | Enable/disable recursion for this view |
| `zones` | Array[String] | No | `[]` | List of accessible zone names (empty = all zones) |

### Minimal Configuration

```toml
# Minimal view - uses all defaults
[[view]]
name = "minimal"
# match_clients defaults to :all (matches all clients)
# recursion defaults to true
# zones defaults to [] (all zones accessible)
```

---

## Built-in ACLs

YellowDog DNS provides four built-in ACLs that can be referenced by name:

### `"any"` - Match All Clients

Matches any client IP address (IPv4 and IPv6).

```toml
[[view]]
name = "public"
match_clients = "any"
zones = ["public.example.com"]
```

**Use Cases:**
- Public-facing views
- Catch-all default views
- Development/testing

### `"none"` - Match No Clients

Never matches any client (effectively disables the view).

```toml
[[view]]
name = "disabled"
match_clients = "none"
zones = []
```

**Use Cases:**
- Temporarily disable a view
- Placeholder views

### `"localhost"` - Match Local Clients

Matches only localhost addresses:
- IPv4: `127.0.0.1/32`
- IPv6: `::1/128`

```toml
[[view]]
name = "local"
match_clients = "localhost"
recursion = true
zones = ["localhost.test"]
```

**Use Cases:**
- Local testing
- Administrative queries
- Monitoring/health checks

### `"localnets"` - Match RFC 1918 Private Networks

Matches RFC 1918 private IPv4 address ranges:
- `10.0.0.0/8` (Class A)
- `172.16.0.0/12` (Class B)
- `192.168.0.0/16` (Class C)

```toml
[[view]]
name = "internal"
match_clients = "localnets"
recursion = true
zones = ["corp.example.com", "internal.example.com"]
```

**Use Cases:**
- Internal corporate networks
- Private infrastructure
- Development environments

---

## Custom ACLs

Custom ACLs allow you to define complex access control rules with allow/deny patterns and CIDR subnet matching.

### Basic Custom ACL

Define inline ACL rules using `[[view.acl]]` sections:

```toml
[[view]]
name = "dmz"
zones = ["dmz.example.com"]

[[view.acl]]
action = "allow"
network = "10.0.0.0/8"
```

### ACL Rule Structure

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `action` | String | Yes | `"allow"` or `"deny"` |
| `network` | String | Yes | CIDR notation (e.g., "192.168.1.0/24") |

### Multiple Rules - Order Matters!

ACL rules are evaluated in order (first-match-wins). More specific rules should come **before** broader rules:

```toml
[[view]]
name = "complex"
zones = ["special.example.com"]

# CORRECT ORDER: Specific to broad
[[view.acl]]
action = "allow"
network = "10.1.1.0/24"    # Most specific - exception

[[view.acl]]
action = "deny"
network = "10.1.0.0/16"    # Broader deny

[[view.acl]]
action = "allow"
network = "10.0.0.0/8"     # Broadest allow
```

**How It Works:**
- `10.1.1.5` → Matches first rule → **Allowed** (exception)
- `10.1.0.5` → Matches second rule → **Denied**
- `10.0.0.5` → Matches third rule → **Allowed**
- `8.8.8.8` → No match → **Denied** (default deny)

### IPv4 and IPv6 Support

Custom ACLs support both IPv4 and IPv6 CIDR notation:

```toml
[[view]]
name = "dual_stack"
zones = ["example.com"]

# IPv4 subnet
[[view.acl]]
action = "allow"
network = "192.168.1.0/24"

# IPv6 subnet
[[view.acl]]
action = "allow"
network = "2001:db8::/32"
```

**Supported CIDR Formats:**
- IPv4: `192.168.1.0/24`, `10.0.0.0/8`, `172.16.0.0/12`
- IPv6: `2001:db8::/32`, `fe80::/10`, `::1/128`

---

## View Matching Behavior

### Matching Order

Views are evaluated **in the order they appear** in the configuration file. The **first matching view** is used for the query.

```toml
# Order matters!
[[view]]
name = "specific"      # Checked FIRST
match_clients = "localhost"
zones = ["test.local"]

[[view]]
name = "general"       # Checked SECOND
match_clients = "localnets"
zones = ["corp.example.com"]

[[view]]
name = "catch_all"     # Checked LAST
match_clients = "any"
zones = ["public.example.com"]
```

**Query from 127.0.0.1:**
1. Check "specific" → Matches `localhost` → **Use this view**
2. "general" and "catch_all" are not checked

**Query from 192.168.1.100:**
1. Check "specific" → No match (not localhost)
2. Check "general" → Matches `localnets` → **Use this view**
3. "catch_all" is not checked

**Query from 8.8.8.8:**
1. Check "specific" → No match
2. Check "general" → No match
3. Check "catch_all" → Matches `any` → **Use this view**

### Zone Filtering

Each view can restrict which zones are accessible:

**Empty zones list (`zones = []`):**
- All loaded zones are accessible

**Non-empty zones list:**
- Only specified zones are accessible
- Queries for other zones return NXDOMAIN

```toml
[[view]]
name = "internal"
match_clients = "localnets"
zones = ["corp.example.com", "internal.example.com"]
# Internal clients can ONLY query these two zones
# Queries for "public.example.com" return NXDOMAIN

[[view]]
name = "external"
match_clients = "any"
zones = ["public.example.com"]
# External clients can ONLY query public.example.com
```

### Recursion Control

Each view can enable or disable recursion independently:

```toml
[[view]]
name = "internal"
match_clients = "localnets"
recursion = true           # Internal clients can perform recursive queries
zones = []

[[view]]
name = "external"
match_clients = "any"
recursion = false          # External clients get authoritative-only responses
zones = ["public.example.com"]
```

**When recursion is disabled:**
- The server acts as authoritative-only for this view
- Queries for unknown zones return NXDOMAIN (not recursive resolution)
- Even if server mode is `:recursive`, this view overrides it

---

## Common Scenarios

### Scenario 1: Corporate Network (Internal + External)

Serve different DNS records to internal employees vs external clients:

```toml
# Internal employees see everything
[[view]]
name = "internal"
match_clients = "localnets"
recursion = true
zones = [
  "corp.example.com",
  "internal.example.com",
  "dev.example.com",
  "public.example.com"
]

# External clients see only public services
[[view]]
name = "external"
match_clients = "any"
recursion = false
zones = ["public.example.com"]
```

**Results:**
- Internal client (192.168.1.100) queries `intranet.corp.example.com` → **Resolved** (internal view)
- External client (8.8.8.8) queries `intranet.corp.example.com` → **NXDOMAIN** (zone not in external view)
- External client queries `www.public.example.com` → **Resolved** (public zone)

### Scenario 2: Multi-Datacenter Setup

Different DNS answers based on datacenter location:

```toml
# US Datacenter clients
[[view]]
name = "us_dc"
zones = ["us.example.com", "example.com"]

[[view.acl]]
action = "allow"
network = "10.1.0.0/16"     # US DC network

# EU Datacenter clients
[[view]]
name = "eu_dc"
zones = ["eu.example.com", "example.com"]

[[view.acl]]
action = "allow"
network = "10.2.0.0/16"     # EU DC network

# Default - route to nearest DC
[[view]]
name = "default"
match_clients = "any"
zones = ["example.com"]
```

### Scenario 3: DMZ Network with Exceptions

Complex ACL with specific subnet exceptions:

```toml
[[view]]
name = "dmz"
recursion = true
zones = ["dmz.example.com", "public.example.com"]

# Allow specific admin subnet (exception)
[[view.acl]]
action = "allow"
network = "10.100.1.0/24"

# Deny broader DMZ range
[[view.acl]]
action = "deny"
network = "10.100.0.0/16"

# Allow overall datacenter network
[[view.acl]]
action = "allow"
network = "10.0.0.0/8"
```

**Matching:**
- `10.100.1.5` → **Allowed** (admin exception)
- `10.100.2.5` → **Denied** (broader DMZ deny)
- `10.50.0.5` → **Allowed** (datacenter network)

### Scenario 4: Development Environment

Separate dev, staging, and production DNS:

```toml
# Development network
[[view]]
name = "dev"
match_clients = "localnets"
recursion = true
zones = [
  "dev.example.com",
  "staging.example.com",
  "prod.example.com"
]

# CI/CD pipeline (specific subnet)
[[view]]
name = "ci"
recursion = true
zones = ["ci.example.com", "dev.example.com"]

[[view.acl]]
action = "allow"
network = "10.200.0.0/24"

# Production (external)
[[view]]
name = "prod"
match_clients = "any"
recursion = false
zones = ["prod.example.com"]
```

### Scenario 5: Guest Network Isolation

Restrict guest network access:

```toml
# Corporate network - full access
[[view]]
name = "corporate"
recursion = true
zones = []  # All zones

[[view.acl]]
action = "allow"
network = "192.168.1.0/24"

# Guest network - limited access
[[view]]
name = "guest"
recursion = true
zones = ["guest.example.com"]

[[view.acl]]
action = "allow"
network = "192.168.100.0/24"

# Deny all others
[[view]]
name = "blocked"
match_clients = "none"
zones = []
```

---

## API Reference

### Configuration Functions

**YellowDog.Dns.View.Config Module:**

```elixir
# Load views from TOML file
{:ok, views} = YellowDog.Dns.View.Config.load_file("config/views.toml")

# Parse TOML string
toml = """
[[view]]
name = "test"
match_clients = "any"
zones = ["example.com"]
"""
{:ok, views} = YellowDog.Dns.View.Config.parse_toml(toml)

# Convert configuration map
config = %{"view" => [%{"name" => "test", "match_clients" => "any"}]}
{:ok, views} = YellowDog.Dns.View.Config.from_map(config)
```

### View Functions

**YellowDog.Dns.View Module:**

```elixir
# Create a view programmatically
view = YellowDog.Dns.View.new("internal", "localnets", ["corp.example.com"], true)

# Match client to view
{:ok, view} = YellowDog.Dns.View.match_client({192, 168, 1, 100}, views)

# Check if client matches view
YellowDog.Dns.View.matches?(view, {192, 168, 1, 100})  # true/false

# Zone management
view = YellowDog.Dns.View.add_zone(view, "newzone.com")
view = YellowDog.Dns.View.remove_zone(view, "oldzone.com")
YellowDog.Dns.View.has_zone?(view, "corp.example.com")  # true/false
```

### ACL Functions

**YellowDog.Dns.View.ACL Module:**

```elixir
# Create custom ACL
acl = YellowDog.Dns.View.ACL.new("dmz", [
  {:allow, {10, 0, 0, 0}, 8},
  {:deny, {10, 1, 0, 0}, 16}
])

# Check if IP matches ACL
YellowDog.Dns.View.ACL.matches?(acl, {10, 0, 0, 1})      # true
YellowDog.Dns.View.ACL.matches?("localnets", {192, 168, 1, 1})  # true

# Parse CIDR string
{:ok, {{192, 168, 1, 0}, 24}} = YellowDog.Dns.View.ACL.parse_cidr("192.168.1.0/24")
```

### Application Configuration

**config/config.exs:**

```elixir
config :yellow_dog_dns,
  # Path to views configuration file
  views_config_path: "config/views.toml"
```

**Runtime:**

```elixir
# Set configuration path
Application.put_env(:yellow_dog_dns, :views_config_path, "/etc/yellowdog/views.toml")

# Get current path
path = Application.get_env(:yellow_dog_dns, :views_config_path)
```

---

## Troubleshooting

### Views Not Loading

**Symptom:** Handler creates default view instead of loading from config.

**Possible Causes:**
1. Configuration path not set
2. File doesn't exist
3. TOML syntax error
4. Permission denied

**Solution:**

```bash
# Check if config path is set
iex> Application.get_env(:yellow_dog_dns, :views_config_path)
nil  # ← Not set!

# Set the path
iex> Application.put_env(:yellow_dog_dns, :views_config_path, "config/views.toml")
:ok

# Check file exists and is readable
iex> File.exists?("config/views.toml")
true

# Try loading manually
iex> YellowDog.Dns.View.Config.load_file("config/views.toml")
{:ok, [%YellowDog.Dns.View{...}]}
```

**Check Telemetry Logs:**

```elixir
# Look for view loading messages
# Success: "Loaded N views from configuration"
# Failure: "Failed to load views from configuration, using default view"
```

### ACL Not Matching Clients

**Symptom:** Clients match wrong view or no view.

**Possible Causes:**
1. View order incorrect (put specific views first!)
2. ACL CIDR notation wrong
3. IP address format mismatch

**Solution:**

```elixir
# Test ACL matching manually
iex> acl = YellowDog.Dns.View.ACL.new("test", [{:allow, {192, 168, 1, 0}, 24}])
iex> YellowDog.Dns.View.ACL.matches?(acl, {192, 168, 1, 100})
true  # ← IP matches!

# Test view matching
iex> view = YellowDog.Dns.View.new("test", acl, [], true)
iex> YellowDog.Dns.View.matches?(view, {192, 168, 1, 100})
true

# Test CIDR parsing
iex> YellowDog.Dns.View.ACL.parse_cidr("192.168.1.0/24")
{:ok, {{192, 168, 1, 0}, 24}}
```

**Check View Order:**

```toml
# WRONG - broad view first will catch everything!
[[view]]
name = "catch_all"
match_clients = "any"

[[view]]
name = "specific"      # ← Never reached!
match_clients = "localhost"

# CORRECT - specific views first
[[view]]
name = "specific"
match_clients = "localhost"

[[view]]
name = "catch_all"
match_clients = "any"
```

### Invalid TOML Syntax

**Symptom:** Configuration fails to load with parse error.

**Solution:**

```bash
# Validate TOML syntax
$ cat config/views.toml | toml-validator

# Common errors:
# - Missing quotes around strings
# - Invalid CIDR format
# - Typos in field names (match_client vs match_clients)
```

**Test Parsing:**

```elixir
iex> toml = File.read!("config/views.toml")
iex> Toml.decode(toml)
{:ok, %{"view" => [...]}}  # ← Success!
# or
{:error, {:toml_parse_error, ...}}  # ← Syntax error
```

### Zone Not Accessible in View

**Symptom:** Query returns NXDOMAIN even though zone is loaded.

**Possible Causes:**
1. Zone not listed in view's zones array
2. Zone name mismatch (case-sensitive? trailing dot?)

**Solution:**

```elixir
# Check view's zones
iex> view = YellowDog.Dns.View.new("test", "any", ["example.com"], true)
iex> YellowDog.Dns.View.has_zone?(view, "example.com")
true
iex> YellowDog.Dns.View.has_zone?(view, "other.com")
false  # ← Not in zones list!

# Remember: Empty zones list = all zones accessible
iex> view_all = YellowDog.Dns.View.new("test", "any", [], true)
iex> YellowDog.Dns.View.has_zone?(view_all, "anything.com")
# Will check against loaded zones, not restricted
```

### Recursion Not Working

**Symptom:** Recursive queries fail even though recursion is enabled.

**Possible Causes:**
1. View has `recursion = false`
2. Server mode is `:authoritative`
3. No upstream servers configured

**Solution:**

```elixir
# Check view recursion setting
iex> view.recursion_enabled
false  # ← Recursion disabled for this view!

# Check server mode
iex> # Handler state includes :mode field
# If mode is :authoritative, recursion won't work

# Check upstream servers configured
iex> # Handler state includes :upstream_servers field
# If empty list, forwarding won't work
```

---

## Best Practices

### 1. Order Views from Specific to General

```toml
# CORRECT ORDER
[[view]]
name = "admin"
match_clients = "localhost"

[[view]]
name = "internal"
match_clients = "localnets"

[[view]]
name = "external"
match_clients = "any"
```

### 2. Use Descriptive View Names

```toml
# GOOD
[[view]]
name = "corporate_internal"
name = "dmz_restricted"
name = "public_internet"

# AVOID
[[view]]
name = "view1"
name = "test"
name = "new"
```

### 3. Document Complex ACLs

```toml
# Network topology:
# 10.1.1.0/24 - Admin network (full access)
# 10.1.0.0/16 - DMZ network (restricted)
# 10.0.0.0/8  - Corporate network (standard access)

[[view]]
name = "complex_acl"
zones = ["example.com"]

# Admin exception
[[view.acl]]
action = "allow"
network = "10.1.1.0/24"

# DMZ restriction
[[view.acl]]
action = "deny"
network = "10.1.0.0/16"

# Corporate access
[[view.acl]]
action = "allow"
network = "10.0.0.0/8"
```

### 4. Test Configuration Before Deployment

```elixir
# Load and validate configuration
{:ok, views} = YellowDog.Dns.View.Config.load_file("config/views.toml")

# Test client matching
test_ips = [
  {192, 168, 1, 100},   # Internal
  {8, 8, 8, 8},         # External
  {127, 0, 0, 1}        # Localhost
]

Enum.each(test_ips, fn ip ->
  {:ok, view} = YellowDog.Dns.View.match_client(ip, views)
  IO.puts("#{inspect(ip)} → #{view.name}")
end)
```

### 5. Monitor View Usage

Enable telemetry to track which views are being used:

```elixir
# Telemetry events emitted by Handler:
# - View matching: [:yellow_dog, :dns, :handler, :view_match]
# - View loading: [:yellow_dog, :dns, :handler, :view_load]

# Attach handler to track view usage
:telemetry.attach(
  "view-usage-tracker",
  [:yellow_dog, :dns, :handler, :view_match],
  fn _event, measurements, metadata, _config ->
    IO.puts("View matched: #{metadata.view_name} for client #{metadata.client_ip}")
  end,
  nil
)
```

---

## Performance Considerations

### View Matching Performance

- **O(n)** complexity where n = number of views
- Views are checked sequentially until first match
- Keep total number of views reasonable (<50)
- Put most commonly matched views first

### ACL Matching Performance

- **O(m)** complexity where m = number of ACL rules per view
- Rules are checked sequentially until first match
- Bitwise IP operations are very fast
- Complex ACLs (many rules) have minimal impact

### Zone Lookup Performance

- **O(1)** ETS lookup for zone records
- Zone filtering adds minimal overhead
- Empty zones list (all zones) is slightly faster than explicit list

### Optimization Tips

1. **Order views by frequency:**
   ```toml
   [[view]]
   name = "most_common"    # Matched 80% of the time

   [[view]]
   name = "less_common"    # Matched 15% of the time

   [[view]]
   name = "rare"           # Matched 5% of the time
   ```

2. **Use built-in ACLs when possible:**
   - Faster than custom ACLs
   - Pre-optimized matching logic
   - Fewer allocations

3. **Minimize number of views:**
   - Combine similar views where possible
   - Use ACL rules instead of multiple views

---

## Migration Guide

### From No Views → Views

If you're currently running without views, adding views is backward compatible:

**Before (No Views):**
- Single default view matching all clients
- All zones accessible
- Recursion enabled

**After (With Views):**
```toml
# This configuration is functionally identical to the default
[[view]]
name = "default"
match_clients = "any"
recursion = true
zones = []  # All zones
```

**Migration Steps:**

1. Create minimal configuration file
2. Test with `YellowDog.Dns.View.Config.load_file/1`
3. Set `:views_config_path` in config
4. Restart DNS handler
5. Monitor telemetry logs for view loading
6. Gradually add more specific views

---

## Future Enhancements

Planned features for view configuration:

- [ ] **Hot Reload**: Reload views without restarting handler
- [ ] **Named ACL References**: Define ACLs separately and reference by name
- [ ] **ACL Composition**: Combine ACLs with AND/OR logic
- [ ] **Per-View Caching**: Separate cache namespaces per view
- [ ] **View-Specific RPZ**: Different RPZ policies per view
- [ ] **GeoIP Support**: Match clients by geographic location
- [ ] **Statistics API**: Runtime view matching statistics
- [ ] **Management API**: Programmatically add/remove views

---

## Support

For issues, questions, or feature requests:

- **Documentation**: [README.md](README.md)
- **Examples**: [examples/views.toml](examples/views.toml)
- **Tests**: [test/yellow_dog/dns/view/config_test.exs](test/yellow_dog/dns/view/config_test.exs)
- **Source**: [lib/yellow_dog/dns/view/config.ex](lib/yellow_dog/dns/view/config.ex)

---

**Last Updated**: 2025-11-02
**Version**: YellowDog DNS 0.1.0
