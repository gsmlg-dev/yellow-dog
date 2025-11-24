# Forward Zone Example
#
# This script demonstrates how to use forward zones in YellowDog DNS.
# Forward zones allow delegating DNS queries to upstream resolvers instead
# of performing authoritative resolution.
#
# Usage:
#   cd apps/yellow_dog_dns
#   mix run examples/forward_zone_example.exs

alias YellowDog.Dns.Zone.Manager
alias YellowDog.Dns.Zone.Storage
alias YellowDog.Dns.Query.Resolver

# Initialize storage
Storage.init()

# Start the Zone Manager
{:ok, _pid} = Manager.start_link()

IO.puts("\n=== Forward Zone Example ===\n")

# Example 1: Load a forward zone with "only" mode (always forward)
IO.puts("1. Loading forward zone 'external.com' with Google DNS (8.8.8.8)...")

forwarders = [{8, 8, 8, 8}, {1, 1, 1, 1}]

case Manager.load_forward_zone("external.com", forwarders, forward_mode: :only, timeout_ms: 5000) do
  {:ok, zone_name} ->
    IO.puts("   ✓ Forward zone '#{zone_name}' loaded successfully")

  {:error, reason} ->
    IO.puts("   ✗ Failed to load forward zone: #{inspect(reason)}")
end

# Example 2: Query through the forward zone
IO.puts("\n2. Querying 'www.external.com' through forward zone...")

case Resolver.resolve("external.com", "www.external.com", :A) do
  {:ok, records, _authority} ->
    IO.puts("   ✓ Resolved #{length(records)} records:")

    Enum.each(records, fn record ->
      IO.puts("      - #{record.owner} #{record.ttl}s #{record.type} #{inspect(record.rdata)}")
    end)

  {:nxdomain, _, _} ->
    IO.puts("   ⚠ NXDOMAIN - name does not exist")

  {:servfail, _, _} ->
    IO.puts("   ✗ SERVFAIL - query failed (network may be unavailable)")

  {:error, reason} ->
    IO.puts("   ✗ Error: #{inspect(reason)}")
end

# Example 3: Load a forward zone with "first" mode (try local first)
IO.puts("\n3. Loading forward zone 'local-then-forward.com' with 'first' mode...")

case Manager.load_forward_zone(
       "local-then-forward.com",
       forwarders,
       forward_mode: :first,
       timeout_ms: 3000,
       max_retries: 1
     ) do
  {:ok, zone_name} ->
    IO.puts("   ✓ Forward zone '#{zone_name}' loaded with mode: first")
    IO.puts("      (Will try local authoritative first, then forward on NXDOMAIN)")

  {:error, reason} ->
    IO.puts("   ✗ Failed to load forward zone: #{inspect(reason)}")
end

# Example 4: List all loaded zones
IO.puts("\n4. Listing all loaded zones...")

case Manager.list_zones() do
  {:ok, zones} ->
    IO.puts("   ✓ Loaded zones (#{length(zones)}):")

    Enum.each(zones, fn zone_name ->
      case Manager.get_zone_metadata(zone_name) do
        {:ok, metadata} ->
          type = Map.get(metadata, :type, :unknown)
          mode = Map.get(metadata, :forward_mode)

          if type == :forward do
            IO.puts("      - #{zone_name} (#{type}, mode: #{mode})")
          else
            IO.puts("      - #{zone_name} (#{type})")
          end

        _ ->
          IO.puts("      - #{zone_name}")
      end
    end)

  {:error, reason} ->
    IO.puts("   ✗ Failed to list zones: #{inspect(reason)}")
end

# Example 5: Configuration via TOML
IO.puts("\n5. Example TOML configuration for forward zones:")

toml_example = """
[[dns.zones]]
name = "external.com"
type = "forward"
forwarders = ["8.8.8.8", "1.1.1.1"]
forward_mode = "only"
timeout_ms = 5000
max_retries = 2

[[dns.zones]]
name = "corp.internal"
type = "forward"
forwarders = ["10.0.0.53", "10.0.1.53"]
forward_mode = "first"
timeout_ms = 3000
"""

IO.puts(toml_example)

IO.puts("\n=== Example Complete ===\n")

# Cleanup
Manager.unload_zone("external.com")
Manager.unload_zone("local-then-forward.com")
