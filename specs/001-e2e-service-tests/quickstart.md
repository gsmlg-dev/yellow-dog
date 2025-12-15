# Quickstart: E2E Service Tests

**Feature**: 001-e2e-service-tests
**Date**: 2025-12-15

## Running E2E Tests

### Run All E2E Tests

```bash
mix test.e2e
```

### Run Individual Service Tests

```bash
# DNS E2E tests
mix test.e2e.dns

# mDNS E2E tests
mix test.e2e.mdns

# DHCPv4 E2E tests
mix test.e2e.dhcpv4

# DHCPv6 E2E tests
mix test.e2e.dhcpv6
```

## Test File Structure

```
e2e_test/
├── test_helper.exs      # ExUnit configuration
├── dns_e2e_test.exs     # DNS server tests
├── mdns_e2e_test.exs    # mDNS responder tests
├── dhcpv4_e2e_test.exs  # DHCPv4 server tests
├── dhcpv6_e2e_test.exs  # DHCPv6 server tests
└── support/
    ├── dns_client.ex    # DNS query helper
    ├── dhcp_client.ex   # DHCP message helper
    └── service_helper.ex # Service lifecycle
```

## Writing New E2E Tests

### Basic Test Structure

```elixir
defmodule MyServiceE2ETest do
  use ExUnit.Case, async: false

  alias E2ETest.ServiceHelper
  alias E2ETest.DnsClient

  setup do
    # Start service with auto-selected port
    {:ok, ctx} = ServiceHelper.start_dns_server()

    on_exit(fn ->
      ServiceHelper.stop_service(ctx)
    end)

    {:ok, ctx}
  end

  test "service responds to query", %{port: port} do
    {:ok, response} = DnsClient.query({127, 0, 0, 1}, port, "example.com", :A)

    assert response.header.rcode == :NOERROR
    assert length(response.answers) > 0
  end
end
```

### Service Helper Usage

```elixir
# Start DNS server
{:ok, ctx} = E2ETest.ServiceHelper.start_dns_server()
# ctx = %{server_pid: pid, port: 12345, host: {127,0,0,1}, service: :dns}

# Start mDNS server
{:ok, ctx} = E2ETest.ServiceHelper.start_mdns_server()

# Start DHCPv4 server
{:ok, ctx} = E2ETest.ServiceHelper.start_dhcpv4_server()

# Start DHCPv6 server
{:ok, ctx} = E2ETest.ServiceHelper.start_dhcpv6_server()

# Stop any service
:ok = E2ETest.ServiceHelper.stop_service(ctx)
```

### DNS Client Usage

```elixir
alias E2ETest.DnsClient

# Query A record
{:ok, response} = DnsClient.query({127,0,0,1}, port, "www.example.com", :A)

# Query PTR record (for mDNS service discovery)
{:ok, response} = DnsClient.query({127,0,0,1}, port, "_http._tcp.local", :PTR)

# Query SRV record
{:ok, response} = DnsClient.query({127,0,0,1}, port, "myservice._http._tcp.local", :SRV)
```

### DHCP Client Usage

```elixir
alias E2ETest.DhcpClient

# DHCPv4 DISCOVER
mac = <<0x00, 0x11, 0x22, 0x33, 0x44, 0x55>>
{:ok, offer} = DhcpClient.discover({127,0,0,1}, port, mac)

# DHCPv4 REQUEST
{:ok, ack} = DhcpClient.request({127,0,0,1}, port, mac, offer.yiaddr, offer.xid)

# DHCPv6 SOLICIT
duid = <<0x00, 0x01, 0x00, 0x01, ...>>
{:ok, advertise} = DhcpClient.solicit({0,0,0,0,0,0,0,1}, port, duid)

# DHCPv6 REQUEST
{:ok, reply} = DhcpClient.request_v6({0,0,0,0,0,0,0,1}, port, duid, advertise)
```

## CI Integration

E2E tests run automatically in GitHub Actions on every push:

```yaml
# .github/workflows/e2e.yml
jobs:
  e2e:
    strategy:
      matrix:
        service: [dns, mdns, dhcpv4, dhcpv6]
    steps:
      - run: mix test.e2e.${{ matrix.service }}
```

## Troubleshooting

### Port Already in Use

E2E tests use auto-selected ports (port 0). If you see binding errors:
1. Check for orphaned processes: `ps aux | grep beam`
2. Kill orphaned processes
3. Retry tests

### Service Startup Timeout

If tests fail with timeout during service start:
1. Check that all dependencies compile: `mix compile`
2. Verify config module availability: `iex -S mix` then `YellowDog.Config.get(:dns, :port)`

### mDNS Tests Failing in CI

mDNS E2E tests use unicast to loopback. If tests fail:
1. Verify server binds to 127.0.0.1
2. Confirm queries target 127.0.0.1 (not multicast address)

### Cleanup Failures

If tests fail to clean up:
1. Check `on_exit` callback is registered
2. Verify `Process.alive?/1` check before stop
3. Run tests with `--trace` for detailed output
