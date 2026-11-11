# YellowDog.Whois

A fast, production-ready Elixir library for performing WHOIS lookups on domain names, IP addresses, and AS numbers with intelligent caching and telemetry support.

## Features

- 🌐 **Universal Lookups**: Domains, IPv4/IPv6 addresses, and AS numbers
- ⚡ **Fast Caching**: Built-in ETS caching with configurable TTL
- 📊 **Telemetry Integration**: Full observability with telemetry events
- 🔄 **Automatic Referrals**: Follows WHOIS server redirects automatically
- 🎯 **Simple API**: Easy-to-use interface with both safe and bang variants
- 🏭 **Production Ready**: Battle-tested with proper error handling

## What is WHOIS?

WHOIS is a protocol for querying databases that store information about registered internet resources:
- **Domains**: Registration details, nameservers, registrar information
- **IP Addresses**: Allocation details, network ranges, abuse contacts
- **AS Numbers**: Autonomous system information, network operators

## Installation

Add `yellow_dog_whois` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:yellow_dog_whois, "~> 0.5.2"}
  ]
end
```

## Quick Start

### Domain Lookup

```elixir
# Lookup domain registration information
{:ok, results} = YellowDog.Whois.lookup_raw("google.com")

for {server, whois_data} <- results do
  IO.puts("=== #{server} ===")
  IO.puts(whois_data)
end
```

### IP Address Lookup

```elixir
# Lookup IP allocation and network information
{:ok, results} = YellowDog.Whois.lookup_raw("8.8.8.8")

# Results contain information from IANA and regional registry
[{_iana_server, iana_data}, {rir_server, rir_data}] = results

IO.puts("Regional Internet Registry: #{rir_server}")
IO.puts(rir_data)
```

### AS Number Lookup

```elixir
# Lookup autonomous system information
{:ok, results} = YellowDog.Whois.lookup_raw("13335")

for {server, whois_data} <- results do
  if whois_data =~ "Cloudflare" do
    IO.puts("Found Cloudflare AS information")
    IO.puts(whois_data)
  end
end
```

## Basic Usage

### Simple Lookup

```elixir
# Returns {:ok, results} or {:error, reason}
case YellowDog.Whois.lookup_raw("example.com") do
  {:ok, results} ->
    [{server, data} | _rest] = results
    IO.puts("Retrieved from #{server}")

  {:error, :timeout} ->
    IO.puts("Request timed out")

  {:error, reason} ->
    IO.puts("Lookup failed: #{inspect(reason)}")
end
```

### Custom WHOIS Server

```elixir
# Query a specific WHOIS server directly
{:ok, results} = YellowDog.Whois.lookup_raw("google.com",
  server: "whois.markmonitor.com"
)

# Or use a Server struct
server = %YellowDog.Whois.Server{host: "whois.markmonitor.com", port: 43}
{:ok, results} = YellowDog.Whois.lookup_raw("google.com", server: server)
```

## Caching

YellowDog.Whois includes intelligent caching to reduce load on WHOIS servers. The default ETS backend needs no additional package.

### Enabling Cache

```elixir
# Start the cache in your application supervision tree
children = [
  YellowDog.Whois.Cache
]

Supervisor.start_link(children, strategy: :one_for_one)
```

Or add to your application.ex:

```elixir
def start(_type, _args) do
  children = [
    YellowDog.Whois.Cache,
    # ... other children
  ]

  Supervisor.start_link(children, strategy: :one_for_one)
end
```

### Cache Configuration

```elixir
# Configure TTL in config/config.exs
config :yellow_dog_whois,
  cache_ttl: :timer.hours(24),        # Default: 24 hours for domains
  cache_ttl_ip: :timer.hours(1),      # Default: 1 hour for IPs
  cache_ttl_asn: :timer.hours(1)      # Default: 1 hour for AS numbers
```

### Bypassing Cache

```elixir
# Force fresh lookup, bypassing cache
{:ok, results} = YellowDog.Whois.lookup_raw("example.com", cache: false)
```

### Cache Statistics

```elixir
# Get cache statistics
stats = YellowDog.Whois.Cache.stats()
IO.inspect(stats)
# => %{size: 42, hits: 150, misses: 23, hit_rate: 0.867}

# Clear the cache
YellowDog.Whois.Cache.clear()
```

## Parsing WHOIS Output

WHOIS responses vary significantly between servers and have no standard format. Here are common patterns for extracting information:

### Domain Information

```elixir
{:ok, results} = YellowDog.Whois.lookup_raw("example.com")
{_server, whois_data} = List.last(results)  # Get final authoritative response

# Extract registrar
registrar = whois_data
  |> String.split("\n")
  |> Enum.find_value(fn line ->
    case line do
      "Registrar:" <> value -> String.trim(value)
      "registrar:" <> value -> String.trim(value)
      _ -> nil
    end
  end)

# Extract creation date
creation_date = whois_data
  |> String.split("\n")
  |> Enum.find_value(fn line ->
    cond do
      String.contains?(line, "Creation Date:") ->
        line |> String.split(":") |> Enum.at(1) |> String.trim()
      String.contains?(line, "created:") ->
        line |> String.split(":") |> Enum.at(1) |> String.trim()
      true -> nil
    end
  end)

# Extract nameservers
nameservers = whois_data
  |> String.split("\n")
  |> Enum.filter(&String.contains?(&1, "Name Server:"))
  |> Enum.map(fn line ->
    line |> String.split(":") |> Enum.at(1) |> String.trim() |> String.downcase()
  end)

IO.inspect(%{
  registrar: registrar,
  creation_date: creation_date,
  nameservers: nameservers
})
```

### IP Network Information

```elixir
{:ok, results} = YellowDog.Whois.lookup_raw("8.8.8.8")
{_server, whois_data} = List.last(results)

# Extract network range
network = Regex.run(~r/NetRange:\s*(.+)/, whois_data, capture: :all_but_first)
  |> case do
    [range] -> range
    _ -> nil
  end

# Extract organization
org_name = Regex.run(~r/OrgName:\s*(.+)/, whois_data, capture: :all_but_first)
  |> case do
    [name] -> name
    _ -> nil
  end

# Extract abuse contact
abuse_email = Regex.run(~r/OrgAbuseEmail:\s*(.+)/, whois_data, capture: :all_but_first)
  |> case do
    [email] -> email
    _ -> nil
  end

IO.inspect(%{
  network: network,
  organization: org_name,
  abuse_email: abuse_email
})
```

### Helper Module for Parsing

```elixir
defmodule MyApp.WhoisParser do
  def parse_domain(whois_data) do
    lines = String.split(whois_data, "\n")

    %{
      registrar: extract_field(lines, ["Registrar:", "registrar:"]),
      creation_date: extract_field(lines, ["Creation Date:", "created:"]),
      expiry_date: extract_field(lines, ["Expiry Date:", "Registry Expiry Date:"]),
      nameservers: extract_nameservers(lines),
      status: extract_field(lines, ["Domain Status:", "status:"])
    }
  end

  defp extract_field(lines, patterns) do
    Enum.find_value(lines, fn line ->
      Enum.find_value(patterns, fn pattern ->
        if String.starts_with?(line, pattern) do
          line |> String.split(":", parts: 2) |> Enum.at(1) |> String.trim()
        end
      end)
    end)
  end

  defp extract_nameservers(lines) do
    lines
    |> Enum.filter(&(String.contains?(&1, "Name Server:") or String.contains?(&1, "nserver:")))
    |> Enum.map(fn line ->
      line |> String.split(":", parts: 2) |> Enum.at(1) |> String.trim() |> String.downcase()
    end)
  end
end

# Usage
{:ok, results} = YellowDog.Whois.lookup_raw("example.com")
{_server, whois_data} = List.last(results)
parsed = MyApp.WhoisParser.parse_domain(whois_data)
```

## Telemetry Events

YellowDog.Whois emits telemetry events for monitoring and debugging:

### Available Events

- `[:yellow_dog, :whois, :lookup, :start]` - Lookup starts
- `[:yellow_dog, :whois, :lookup, :stop]` - Lookup returns (including an error tuple)
- `[:yellow_dog, :whois, :lookup, :exception]` - Lookup raises, throws, or exits

### Event Metadata

Lookup events include `%{query: "example.com", type: :domain}`. The `:stop` event's measurements include `duration` in native time units; `:exception` metadata additionally includes `kind`, `reason`, and `stacktrace`. Cache events include the same query/type fields, with `:hit` or `:miss` in the event name. A normal `{:error, :timeout}` return emits `:stop`, while `:exception` is reserved for exceptions, throws, and exits.

### Setting Up Telemetry Handler

```elixir
defmodule MyApp.TelemetryHandler do
  require Logger

  def handle_event([:yellow_dog, :whois, :lookup, :start], _measurements, metadata, _config) do
    Logger.info("Starting WHOIS lookup for: #{metadata.query}")
  end

  def handle_event([:yellow_dog, :whois, :lookup, :stop], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    Logger.info("WHOIS lookup returned in #{duration_ms}ms: #{metadata.query}")
  end

  def handle_event([:yellow_dog, :whois, :lookup, :exception], measurements, metadata, _config) do
    Logger.error("WHOIS lookup failed for #{metadata.query}: #{inspect(metadata.reason)}")
  end
end

# Attach the handler
:telemetry.attach_many(
  "whois-telemetry-handler",
  [
    [:yellow_dog, :whois, :lookup, :start],
    [:yellow_dog, :whois, :lookup, :stop],
    [:yellow_dog, :whois, :lookup, :exception]
  ],
  &MyApp.TelemetryHandler.handle_event/4,
  nil
)
```

### Integration with GSMLG.Telemetry

If using the GSMLG umbrella project's telemetry system:

```elixir
# Events are automatically logged to configured backends
# (console, file, CloudWatch, etc.)

# View metrics
GSMLG.Telemetry.Metrics.get_summary()

# See WHOIS-specific metrics
GSMLG.Telemetry.Metrics.get_metrics([:yellow_dog, :whois, :lookup, :stop])
```

## Error Handling

### Common Errors

```elixir
case YellowDog.Whois.lookup_raw(query) do
  {:ok, results} ->
    # Success

  {:error, :timeout} ->
    # Network timeout (30 seconds default)

  {:error, :closed} ->
    # Connection closed by server

  {:error, :econnrefused} ->
    # Connection refused (server down or firewalled)

  {:error, :nxdomain} ->
    # DNS resolution failed

  {:error, reason} ->
    # Other error
    Logger.error("WHOIS lookup failed: #{inspect(reason)}")
end
```

### Timeout Configuration

WHOIS uses a finite total deadline, including native DNS resolution, TCP connection, sending the query, every response read, and all referrals. The default is 30,000 milliseconds. New data and referrals do not restart the budget. Expiry returns `{:error, :timeout}` even if a previous server returned a partial record. Other referral connection errors retain the previous raw records. Set a non-negative integer timeout; zero expires immediately, and `:infinity` is rejected. Cancelling a caller task closes its linked lookup worker and the worker-owned sockets.

```elixir
# Configure timeout in config/config.exs
config :yellow_dog_whois,
  timeout: 60_000  # 60 seconds

# Or pass per-request
{:ok, results} = YellowDog.Whois.lookup_raw("example.com", timeout: 10_000)
```

## Production Best Practices

### 1. Always Use Caching

```elixir
# In your application.ex
def start(_type, _args) do
  children = [
    YellowDog.Whois.Cache,  # Start cache first
    # ... other children
  ]

  Supervisor.start_link(children, strategy: :one_for_one)
end
```

### 2. Handle Timeouts Gracefully

```elixir
defmodule MyApp.Whois do
  def lookup_with_fallback(query) do
    case YellowDog.Whois.lookup_raw(query) do
      {:ok, results} ->
        {:ok, results}

      {:error, :timeout} ->
        # Return cached result even if expired, or use alternative source
        case YellowDog.Whois.Cache.get(query) do
          {:ok, stale_result} ->
            Logger.warn("Using stale cache for #{query}")
            {:ok, stale_result}
          _ ->
            {:error, :timeout}
        end

      error ->
        error
    end
  end
end
```

### 3. Implement Rate Limiting

```elixir
defmodule MyApp.RateLimitedWhois do
  use GenServer

  @rate_limit 1  # 1 request per second

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def lookup(query) do
    GenServer.call(__MODULE__, {:lookup, query}, :timer.minutes(2))
  end

  def init(_opts) do
    {:ok, %{last_request: 0}}
  end

  def handle_call({:lookup, query}, _from, state) do
    # Ensure at least 1 second between requests
    now = System.monotonic_time(:millisecond)
    delay = max(0, @rate_limit * 1000 - (now - state.last_request))

    if delay > 0, do: Process.sleep(delay)

    result = YellowDog.Whois.lookup_raw(query)
    {:reply, result, %{state | last_request: System.monotonic_time(:millisecond)}}
  end
end
```

### 4. Monitor with Telemetry

```elixir
# Track slow queries
:telemetry.attach(
  "slow-whois-queries",
  [:yellow_dog, :whois, :lookup, :stop],
  fn _event, measurements, metadata, _config ->
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    if duration_ms > 5_000 and not metadata.cache_hit do
      Logger.warn("Slow WHOIS query: #{metadata.query} took #{duration_ms}ms from #{metadata.server}")
    end
  end,
  nil
)
```

### 5. Batch Lookups with Task.async_stream

```elixir
defmodule MyApp.BatchWhois do
  def lookup_batch(queries) do
    queries
    |> Task.async_stream(
      &YellowDog.Whois.lookup_raw/1,
      max_concurrency: 5,      # Don't overwhelm WHOIS servers
      timeout: :timer.minutes(2),
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, {:ok, result}} -> {:ok, result}
      {:ok, {:error, reason}} -> {:error, reason}
      {:exit, :timeout} -> {:error, :timeout}
    end)
  end
end

# Usage
queries = ["google.com", "cloudflare.com", "github.com"]
results = MyApp.BatchWhois.lookup_batch(queries)
```

## Comparison with Alternatives

### vs. External WHOIS APIs

**YellowDog.Whois:**
- ✅ Free, unlimited lookups
- ✅ No API keys required
- ✅ Direct to authoritative sources
- ✅ Works offline (with cache)
- ❌ Slower (network latency)
- ❌ Unstructured responses

**Commercial APIs (WhoisXML, etc.):**
- ✅ Structured, parsed data
- ✅ Faster response times
- ✅ Historical data
- ❌ Costs money
- ❌ Rate limits
- ❌ API key management

### vs. System `whois` command

**YellowDog.Whois:**
- ✅ Pure Elixir, no system dependencies
- ✅ Programmatic access
- ✅ Built-in caching
- ✅ Telemetry support
- ✅ Cross-platform

**System whois:**
- ✅ Pre-installed on most systems
- ✅ Feature-complete
- ❌ Requires system call
- ❌ Platform-dependent
- ❌ No caching
- ❌ Difficult to parse output

## Common Use Cases

### 1. Domain Availability Checker

```elixir
defmodule DomainChecker do
  def available?(domain) do
    case YellowDog.Whois.lookup_raw(domain) do
      {:ok, results} ->
        {_server, whois_data} = List.last(results)

        # Check for "No match" or similar indicators
        not_registered =
          String.contains?(whois_data, "No match") or
          String.contains?(whois_data, "NOT FOUND") or
          String.contains?(whois_data, "No Data Found")

        not_registered

      {:error, _} ->
        false
    end
  end
end
```

### 2. Bulk Domain Monitoring

```elixir
defmodule DomainMonitor do
  def check_expiry(domains) do
    domains
    |> Enum.map(fn domain ->
      case YellowDog.Whois.lookup_raw(domain) do
        {:ok, results} ->
          {_server, whois_data} = List.last(results)
          expiry = extract_expiry_date(whois_data)

          {domain, expiry, days_until_expiry(expiry)}

        {:error, reason} ->
          {domain, nil, {:error, reason}}
      end
    end)
    |> Enum.filter(fn
      {_domain, _date, days} when is_integer(days) and days < 30 -> true
      _ -> false
    end)
  end

  defp days_until_expiry(nil), do: nil
  defp days_until_expiry(date_string) do
    # Parse date and calculate days
    # Implementation depends on date format
  end
end
```

### 3. IP Abuse Contact Lookup

```elixir
defmodule AbuseContact do
  def find(ip_address) do
    case YellowDog.Whois.lookup_raw(ip_address) do
      {:ok, results} ->
        {_server, whois_data} = List.last(results)

        abuse_email =
          Regex.run(~r/abuse.*?:\s*([^\s@]+@[^\s]+)/i, whois_data, capture: :all_but_first)
          |> case do
            [email] -> email
            _ -> nil
          end

        {:ok, abuse_email}

      error ->
        error
    end
  end
end
```

## Testing

### Unit Tests

```elixir
defmodule MyApp.WhoisTest do
  use ExUnit.Case

  test "lookup returns structured data" do
    {:ok, results} = YellowDog.Whois.lookup_raw("example.com")

    assert is_list(results)
    assert length(results) > 0

    for {server, whois_data} <- results do
      assert is_binary(server)
      assert is_binary(whois_data)
      assert String.length(whois_data) > 0
    end
  end
end
```

### Live Tests (tagged)

```elixir
@tag :live
test "lookup real domain" do
  {:ok, results} = YellowDog.Whois.lookup_raw("google.com")
  {_server, whois_data} = List.last(results)

  assert String.contains?(whois_data, "Google")
end

# Run only live tests:
# mix test --only live
```

### Mocking for Tests

```elixir
# test/support/whois_mock.ex
defmodule MyApp.WhoisMock do
  def lookup_raw("test.com", _opts \\ []) do
    {:ok, [
      {"whois.iana.org", "refer: whois.test.com"},
      {"whois.test.com", """
      Domain Name: TEST.COM
      Registrar: Test Registrar
      Creation Date: 2020-01-01T00:00:00Z
      """}
    ]}
  end

  def lookup_raw(_query, _opts), do: {:error, :not_found}
end
```

## Troubleshooting

### High Memory Usage

**Cause**: Cache growing too large
**Solution**:
```elixir
# Set maximum cache size in config
config :yellow_dog_whois,
  cache_max_size: 10_000  # Limit to 10k entries

# Or periodically clear cache
YellowDog.Whois.Cache.clear()
```

### Slow Lookups

**Cause**: Network latency or WHOIS server overload
**Solution**:
- Ensure caching is enabled
- Increase timeout for slow servers
- Use custom server if faster alternative exists

### Connection Refused

**Cause**: WHOIS server blocking your IP or down
**Solution**:
- Implement rate limiting
- Add retry logic with exponential backoff
- Use alternative WHOIS server

### Inconsistent Results

**Cause**: WHOIS data updated between lookups
**Solution**:
- Use caching for consistency within TTL period
- Store timestamps with lookups
- Compare multiple sources if critical

## Contributing

Contributions welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Add tests
4. Submit a pull request

## License

MIT License

## Resources

- [WHOIS Protocol (RFC 3912)](https://tools.ietf.org/html/rfc3912)
- [IANA WHOIS Service](https://www.iana.org/whois)
- [ICANN WHOIS Policy](https://www.icann.org/resources/pages/whois)

## Changelog

### 0.5.2

### 0.5.1
- Add a finite total WHOIS deadline covering DNS, connect, send, reads, and referrals
- Close sockets on success, errors, deadline expiry, and task cancellation
- Support custom server ports and preserve trailing raw response bytes
- Remove the unpublished umbrella telemetry dependency; emit the documented `:start`, `:stop`, and `:exception` lifecycle events directly through `:telemetry`

### 0.5.0
- Production-ready release
- ETS caching support
- Telemetry integration
- Comprehensive documentation
- Improved error handling
