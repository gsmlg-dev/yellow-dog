# Yellow Dog DNS

![Yellow Dog DNS](./priv/yellow_dog.png)

Yellow Dog DNS is a distributed DNS and DHCP server written in Elixir/Erlang.

## Architecture

Yellow Dog DNS is organized as an Elixir umbrella project with the following applications:

- **YellowDog** - Core application providing configuration management and orchestration
- **YellowDog.Dns** - DNS functionality including name resolution, zones, and views
- **YellowDog.Dhcpv4** - DHCPv4 protocol implementation (using dhcp_ex)
- **YellowDog.Dhcpv6** - DHCPv6 protocol implementation (using dhcp_ex)
- **YellowDog.Mdns** - mDNS (multicast DNS) functionality (using ex_dns)

### Key Dependencies

- **ex_dns** - DNS protocol handling (used by YellowDog.Dns and YellowDog.Mdns)
- **dhcp_ex** - DHCP protocol implementation (used by YellowDog.Dhcpv4 and YellowDog.Dhcpv6)
- **abyss** - High-performance UDP server (used across applications)
- **telemetry** - Metrics and observability

## Usage

### Running the Server

```shell
# Start all applications
mix run --no-halt

# Or start specific applications
mix app.start yellow_dog
mix app.start yellow_dog_dns
```

### Configuration

Configuration is managed through the core YellowDog application:

```elixir
# Get configuration
YellowDog.get_config(:key)
YellowDog.get_all_config()

# Start the system
YellowDog.start_link()
```

### DNS Benchmarking

```shell
# Create test queries
echo "www.turku.fi A" > t.txt
echo "www.helsinki.fi A" >> t.txt

# Run DNS performance test
dnsperf -n 100000 -d t.txt -s 127.0.0.1 -p 53
```

## Development

### Project Structure

```
yellow_dog/                 # Umbrella project root
├── apps/                   # Application directory
│   ├── yellow_dog/    # Core application
│   ├── yellow_dog_dns/     # DNS functionality
│   ├── yellow_dog_dhcpv4/  # DHCPv4 protocol
│   ├── yellow_dog_dhcpv6/  # DHCPv6 protocol
│   └── yellow_dog_mdns/    # mDNS functionality
├── config/                 # Configuration files
├── lib/                    # Umbrella-level modules
└── mix.exs                 # Umbrella mix file
```

### Running Tests

```shell
mix test                    # Run all tests
mix test apps/yellow_dog_dns # Run specific app tests
```

### Building

```shell
mix compile                 # Compile all applications
mix format                  # Format code
mix deps.get                # Get dependencies
```
