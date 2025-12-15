# Research: E2E Service Tests

**Feature**: 001-e2e-service-tests
**Date**: 2025-12-15

## Research Questions

### 1. How to start services with auto-selected ports?

**Decision**: Pass `port: 0` in server options, then retrieve assigned port from Abyss.

**Rationale**: All four service servers (DNS, mDNS, DHCPv4, DHCPv6) accept a `port` option. When `port: 0` is passed, the underlying `:gen_udp` socket will auto-select an available port. The assigned port can be retrieved using `:inet.port/1` on the socket.

**Implementation Pattern**:
```elixir
# Start service with auto-selected port
{:ok, pid} = YellowDog.Dns.Server.start_link(port: 0, listen: {127, 0, 0, 1})

# Wait for service ready, then get the assigned port
# The service stores abyss_pid in state, which has socket info
```

**Alternatives Considered**:
- Fixed high port numbers (e.g., 15353) - Rejected: Still risks conflicts in parallel CI runs
- Random port selection before start - Rejected: Race condition between selection and binding

### 2. How to detect service ready state?

**Decision**: Successful `start_link/1` return indicates service is ready.

**Rationale**: The server GenServer `init/1` callback blocks until Abyss is successfully started. When `start_link/1` returns `{:ok, pid}`, the UDP socket is bound and listening.

**Implementation Pattern**:
```elixir
defmodule E2ETest.ServiceHelper do
  def start_service(module, opts) do
    case module.start_link(opts) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, {:start_failed, reason}}
    end
  end
end
```

**Alternatives Considered**:
- Polling with health check - Rejected: Unnecessary complexity, GenServer already blocks
- Separate ready signal - Rejected: Would require modifying production code

### 3. How to send DNS queries in tests?

**Decision**: Use ex_dns library directly to build and parse DNS messages, send via `:gen_udp`.

**Rationale**: The ex_dns library is already in the umbrella. Using `DNS.Message` for encoding/decoding ensures compatibility with the server's message handling.

**Implementation Pattern**:
```elixir
defmodule E2ETest.DnsClient do
  def query(host, port, name, type) do
    message = %DNS.Message{
      header: %DNS.Header{id: random_id(), qr: false, rd: true},
      questions: [%DNS.Question{name: name, type: type, class: :IN}]
    }

    packet = DNS.to_iodata(message) |> IO.iodata_to_binary()
    {:ok, socket} = :gen_udp.open(0, [:binary, {:active, false}])
    :gen_udp.send(socket, host, port, packet)

    case :gen_udp.recv(socket, 0, 5000) do
      {:ok, {_ip, _port, response}} ->
        :gen_udp.close(socket)
        DNS.decode(response)
      {:error, reason} ->
        :gen_udp.close(socket)
        {:error, reason}
    end
  end
end
```

**Alternatives Considered**:
- External tools (dig, nslookup) - Rejected: Adds external dependencies, harder to parse results
- Custom DNS packet building - Rejected: Reinventing wheel when ex_dns exists

### 4. How to send DHCP messages in tests?

**Decision**: Use ex_dhcp library directly to build and parse DHCP messages, send via `:gen_udp`.

**Rationale**: The ex_dhcp library provides `DHCPv4.Message` and `DHCPv6.Message` modules for encoding/decoding. This ensures test messages match production format.

**Implementation Pattern**:
```elixir
defmodule E2ETest.DhcpClient do
  def discover(host, port, mac_address) do
    message = %DHCPv4.Message{
      op: :BOOTREQUEST,
      htype: 1,
      hlen: 6,
      xid: random_xid(),
      chaddr: mac_address,
      options: [
        {53, <<1>>},  # DHCP Message Type: DISCOVER
        {55, <<1, 3, 6, 15>>}  # Parameter Request List
      ]
    }

    packet = DHCPv4.encode(message)
    {:ok, socket} = :gen_udp.open(0, [:binary, {:active, false}])
    :gen_udp.send(socket, host, port, packet)

    case :gen_udp.recv(socket, 0, 5000) do
      {:ok, {_ip, _port, response}} ->
        :gen_udp.close(socket)
        DHCPv4.decode(response)
      {:error, reason} ->
        :gen_udp.close(socket)
        {:error, reason}
    end
  end
end
```

**Alternatives Considered**:
- External DHCP client tools - Rejected: Adds complexity, harder to control timing
- Raw binary packet building - Rejected: Error-prone, ex_dhcp already handles this

### 5. How to handle mDNS without multicast in CI?

**Decision**: Use unicast queries to loopback (127.0.0.1) for E2E tests.

**Rationale**: CI environments often don't support multicast. The mDNS server accepts unicast queries on the same port. Tests send unicast to 127.0.0.1:port instead of multicast to 224.0.0.251.

**Implementation Pattern**:
```elixir
# Start mDNS server without multicast options for testing
opts = [
  port: 0,
  listen_address: {127, 0, 0, 1},
  # Skip multicast membership for CI
  transport_options: [ip: {127, 0, 0, 1}]
]
{:ok, pid} = YellowDog.Mdns.Server.start_link(opts)

# Query via unicast to loopback
E2ETest.DnsClient.query({127, 0, 0, 1}, port, "_http._tcp.local", :PTR)
```

**Alternatives Considered**:
- Full multicast testing - Rejected: Doesn't work reliably in CI
- Skip mDNS E2E tests in CI - Rejected: Loses test coverage
- Mock mDNS at network layer - Rejected: Too complex, tests become less realistic

### 6. How to structure mix aliases for E2E tests?

**Decision**: Add aliases in umbrella `mix.exs` that run ExUnit with `e2e_test/` path.

**Rationale**: Mix aliases provide clean CLI interface. ExUnit can target specific directories.

**Implementation Pattern**:
```elixir
# In umbrella mix.exs
defp aliases do
  [
    # ... existing aliases
    "test.e2e": ["test e2e_test/"],
    "test.e2e.dns": ["test e2e_test/dns_e2e_test.exs"],
    "test.e2e.mdns": ["test e2e_test/mdns_e2e_test.exs"],
    "test.e2e.dhcpv4": ["test e2e_test/dhcpv4_e2e_test.exs"],
    "test.e2e.dhcpv6": ["test e2e_test/dhcpv6_e2e_test.exs"]
  ]
end
```

**Alternatives Considered**:
- Custom mix tasks - Rejected: More code, aliases are simpler
- Makefile targets - Rejected: Mix ecosystem is standard for Elixir
- ExUnit tags instead of separate directory - Rejected: User wants separate `e2e_test/` directory

### 7. GitHub Actions workflow structure?

**Decision**: Create `.github/workflows/e2e.yml` with matrix jobs for each service.

**Rationale**: Matrix jobs allow parallel execution. Each service test is independent.

**Implementation Pattern**:
```yaml
name: E2E Tests
on: [push, pull_request]
jobs:
  e2e:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        service: [dns, mdns, dhcpv4, dhcpv6]
    steps:
      - uses: actions/checkout@v4
      - uses: erlef/setup-beam@v1
        with:
          elixir-version: '1.18'
          otp-version: '28'
      - run: mix deps.get
      - run: mix test.e2e.${{ matrix.service }}
```

**Alternatives Considered**:
- Single sequential job - Rejected: Slower, doesn't leverage parallelism
- Separate workflow files per service - Rejected: Duplicates configuration
- Reusable workflows - Rejected: Overkill for 4 similar jobs

### 8. How to clean up services after tests?

**Decision**: Use ExUnit `setup` and `on_exit` callbacks for lifecycle management.

**Rationale**: ExUnit provides standard hooks for test setup/teardown. The `on_exit/1` callback guarantees cleanup even on test failure.

**Implementation Pattern**:
```elixir
defmodule DnsE2ETest do
  use ExUnit.Case

  setup do
    {:ok, pid} = YellowDog.Dns.Server.start_link(port: 0, listen: {127, 0, 0, 1})
    port = get_assigned_port(pid)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    {:ok, server_pid: pid, port: port}
  end
end
```

**Alternatives Considered**:
- Manual cleanup in each test - Rejected: Error-prone, risks resource leaks
- Process.flag(:trap_exit, true) - Rejected: ExUnit handles this better
- Global test setup - Rejected: Tests should be isolated

## Summary

All technical questions have been resolved:

| Question | Decision |
|----------|----------|
| Port selection | Use port 0, OS auto-assigns |
| Service ready | start_link return indicates ready |
| DNS queries | ex_dns + :gen_udp |
| DHCP messages | ex_dhcp + :gen_udp |
| mDNS multicast | Unicast to loopback |
| Mix aliases | Aliases targeting e2e_test/ |
| CI workflow | Matrix jobs per service |
| Cleanup | ExUnit on_exit callbacks |

No NEEDS CLARIFICATION items remain. Ready for Phase 1.
