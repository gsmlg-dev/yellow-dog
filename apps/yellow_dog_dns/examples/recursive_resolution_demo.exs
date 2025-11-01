#!/usr/bin/env elixir
#
# Recursive DNS Resolution Demo
#
# This script demonstrates the recursive DNS resolver in action.
# It shows the complete resolution path from root servers to authoritative servers.
#
# Usage:
#   mix run examples/recursive_resolution_demo.exs
#

# Ensure application is loaded
Application.ensure_all_started(:yellow_dog)

# Start the RootZone.Manager
alias YellowDog.Dns.RootZone.Manager
alias YellowDog.Dns.Query.Recursive

{:ok, _pid} = Manager.start_link(strategy: :hints)

IO.puts("\n=== YellowDog DNS Recursive Resolver Demo ===\n")

# Demo 1: Resolve example.com A record
IO.puts("1. Resolving example.com A record recursively from root servers...")
IO.puts("   This will query root → .com → example.com")

case Recursive.resolve("example.com", :A, timeout_ms: 15000) do
  {:ok, records, authority} ->
    IO.puts("\n   ✓ Successfully resolved!")
    IO.puts("   Answer records: #{length(records)}")

    Enum.each(records, fn record ->
      IO.puts("     - #{inspect(record.name.value)} A #{inspect(record.data.data)}")
    end)

    if length(authority) > 0 do
      IO.puts("\n   Authority records: #{length(authority)}")
    end

  {:nxdomain, [], authority} ->
    IO.puts("\n   ✗ Domain does not exist")
    IO.puts("   Authority: #{length(authority)} SOA records")

  {:error, reason} ->
    IO.puts("\n   ✗ Resolution failed: #{inspect(reason)}")
    IO.puts("   (This is normal if network is unavailable)")
end

# Demo 2: Show root servers
IO.puts("\n2. Available root servers:")
root_servers = Manager.get_root_servers()
ipv4_count = Enum.count(root_servers, fn {_, ip} -> tuple_size(ip) == 4 end)
ipv6_count = Enum.count(root_servers, fn {_, ip} -> tuple_size(ip) == 8 end)

IO.puts("   Total: #{length(root_servers)} servers")
IO.puts("   IPv4: #{ipv4_count} servers")
IO.puts("   IPv6: #{ipv6_count} servers")

# Show first 3 root servers
IO.puts("\n   First 3 root servers:")
root_servers
|> Enum.take(3)
|> Enum.each(fn {name, ip} ->
  IO.puts("     - #{name}: #{format_ip(ip)}")
end)

# Demo 3: Resolution statistics
IO.puts("\n3. Root Zone Manager statistics:")
stats = Manager.stats()
IO.inspect(stats, label: "   Stats", pretty: true)

IO.puts("\n=== Demo Complete ===\n")

# Helper function
defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
defp format_ip({a, b, c, d, e, f, g, h}) do
  parts = [a, b, c, d, e, f, g, h]
  hex_parts = Enum.map(parts, &Integer.to_string(&1, 16))
  Enum.join(hex_parts, ":")
end
