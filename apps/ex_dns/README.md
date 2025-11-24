# DNS

[![release](https://github.com/gsmlg-dev/ex_dns/actions/workflows/release.yml/badge.svg)](https://github.com/gsmlg-dev/ex_dns/actions/workflows/release.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/ex_dns.svg)](https://hex.pm/packages/ex_dns)
[![Documentation](https://img.shields.io/badge/documentation-gray)](https://hexdocs.pm/ex_dns)

A pure Elixir DNS library that provides comprehensive DNS protocol message parsing, zone management, and resource record handling according to DNS RFC standards.

## Features

- **Complete DNS Protocol Implementation**: Full DNS message parsing and serialization
- **20+ Resource Record Types**: Support for A, AAAA, CNAME, MX, TXT, DNSSEC records, and more
- **Zone Management**: Authoritative, stub, forward, and cache zone support
- **DNSSEC Support**: Basic DNSSEC signing and validation capabilities
- **Binary Protocol Handling**: Efficient binary parsing with domain name compression
- **Type Safety**: Comprehensive type specifications throughout the codebase
- **Protocol-Based Architecture**: Consistent behavior via `DNS.Parameter` and `String.Chars` protocols

## Installation

Add `ex_dns` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ex_dns, "~> 0.4.0"}
  ]
end
```

## Quick Start

### DNS Message Parsing

```elixir
# Parse a DNS message from binary data
message = DNS.Message.from_iodata(binary_data)

# Create a new DNS query
message = DNS.Message.new()
|> DNS.Message.add_question(%DNS.Message.Question{
  name: DNS.Message.Domain.new("example.com"),
  type: DNS.ResourceRecordType.new(:a),
  class: DNS.Class.new(:in)
})

# Convert to binary for network transmission
binary_data = DNS.Parameter.to_iodata(message)

# Display as human-readable string
IO.puts(to_string(message))
```

### Zone Management

```elixir
# Create a new authoritative zone
zone = DNS.Zone.new("example.com", :authoritative)

# Add records interactively
{:ok, zone} = DNS.Zone.Editor.create_zone_interactive("example.com",
  type: :authoritative,
  soa: [
    mname: "ns1.example.com",
    rname: "admin.example.com",
    serial: 2024010101,
    refresh: 3600,
    retry: 1800,
    expire: 604800,
    minimum: 300
  ],
  ns: ["ns1.example.com", "ns2.example.com"],
  a: [{"@", "192.168.1.10"}, {"www", "192.168.1.10"}]
)

# Export zone to BIND format
{:ok, zone_file} = DNS.Zone.Editor.export_zone("example.com", format: :bind)
```

## Architecture

### Core Components

#### DNS.Message Protocol System
The library uses a protocol-based architecture where all DNS entities implement:

- **`DNS.Parameter`**: Binary serialization/deserialization for network transmission
- **`String.Chars`**: Human-readable string representations

#### DNS.Message Hierarchy
```
DNS.Message
├── DNS.Message.Header        # Message header (ID, flags, counts)
├── DNS.Message.Question      # Query section (QNAME, QTYPE, QCLASS)
├── DNS.Message.Record        # Resource records (name, type, class, TTL, data)
└── DNS.Message.Record.Data/* # 20+ specific record type implementations
    ├── A, AAAA, CNAME, MX, TXT
    ├── DNSSEC records (DNSKEY, RRSIG, DS, NSEC, NSEC3)
    └── Modern records (HTTPS, SVCB, TLSA, CAA)
```

#### DNS.Zone Management
```
DNS.Zone
├── DNS.Zone.Manager         # CRUD operations and lifecycle management
├── DNS.Zone.Store           # ETS-based persistent storage
├── DNS.Zone.Cache           # TTL-based caching with expiration
├── DNS.Zone.Loader          # Zone file loading from various sources
├── DNS.Zone.FileParser      # BIND format zone file parsing
├── DNS.Zone.Validator       # Zone validation and diagnostics
└── DNS.Zone.DNSSEC          # DNSSEC signing and validation
```

### Supported Record Types

The library supports over 20 DNS record types including:

- **Basic Records**: A, AAAA, CNAME, MX, NS, PTR, TXT, SOA
- **Service Records**: SRV, SSHFP, TLSA
- **DNSSEC Records**: DNSKEY, RRSIG, DS, NSEC, NSEC3, NSEC3PARAM
- **Modern Records**: HTTPS, SVCB, CAA
- **Experimental/Deprecated**: Various historical and experimental types

## Usage Examples

### Working with DNS Messages

```elixir
# Create a DNS query for an A record
query = DNS.Message.new()
|> DNS.Message.add_question(%DNS.Message.Question{
  name: DNS.Message.Domain.new("example.com"),
  type: DNS.ResourceRecordType.new(:a),
  class: DNS.Class.new(:in)
})

# Parse response
response = DNS.Message.from_iodata(response_binary)

# Extract answer records
answers = response.anlist
# => [%DNS.Message.Record{name: "example.com", type: :a, data: %{ip: {93, 184, 216, 34}}}]
```

### Zone File Operations

```elixir
# Load zone from BIND format file
{:ok, zone} = DNS.Zone.Loader.load_zone_from_file("example.com", "example.com.zone")

# Parse zone from string
zone_content = """
$TTL 3600
$ORIGIN example.com.
@ IN SOA ns1.example.com. admin.example.com. (
    2024010101 ; serial
    3600       ; refresh
    1800       ; retry
    604800     ; expire
    300        ; minimum
)
@ IN NS ns1.example.com.
www IN A 192.168.1.100
"""

{:ok, zone} = DNS.Zone.Loader.load_zone_from_string(zone_content)
```

### Record Management

```elixir
# Add various record types
{:ok, zone} = DNS.Zone.Editor.add_record("example.com", :a,
  name: "www.example.com",
  ip: {192, 168, 1, 100},
  ttl: 300
)

{:ok, zone} = DNS.Zone.Editor.add_record("example.com", :mx,
  name: "example.com",
  preference: 10,
  exchange: "mail.example.com"
)

{:ok, zone} = DNS.Zone.Editor.add_record("example.com", :txt,
  name: "example.com",
  text: "v=spf1 mx ~all"
)

# Search records
{:ok, a_records} = DNS.Zone.Editor.search_records("example.com", type: :a)
{:ok, www_records} = DNS.Zone.Editor.search_records("example.com", name: "www.example.com")
```

### DNSSEC Operations

```elixir
# Enable DNSSEC for a zone
case DNS.Zone.Editor.enable_dnssec("example.com") do
  {:ok, signed_zone} ->
    IO.puts("DNSSEC enabled successfully")
  {:error, reason} ->
    IO.puts("DNSSEC setup failed: #{reason}")
end

# Manual zone signing
case DNS.Zone.DNSSEC.sign_zone(zone,
  algorithm: :rsasha256,
  key_size: 2048,
  nsec3_enabled: true
) do
  {:ok, signed_zone} ->
    IO.puts("Zone signed successfully")
  {:error, reason} ->
    IO.puts("Signing failed: #{reason}")
end
```

### Zone Validation

```elixir
# Validate zone configuration
case DNS.Zone.Validator.validate_zone(zone) do
  {:ok, result} ->
    IO.puts("Zone is valid: #{result.zone_name}")
  {:error, result} ->
    IO.puts("Zone has errors: #{inspect(result.errors)}")
end

# Generate comprehensive diagnostics
diagnostics = DNS.Zone.Validator.generate_diagnostics(zone)
IO.inspect(diagnostics.statistics)
IO.inspect(diagnostics.security_assessment)
IO.inspect(diagnostics.recommendations)
```

## Development

### Testing

```bash
# Run all tests
mix test

# Run specific test file
mix test test/dns/message_test.exs

# Run tests including WIP tagged tests
mix test --include wip

# Run tests with detailed output
mix test --trace
```

### Code Quality

```bash
# Format code
mix format

# Check if code is formatted
mix format --check-formatted

# Run static code analysis
mix credo

# Run type checking
mix dialyzer
```

### Manual Testing Scripts

```bash
# Test all String.Chars implementations
elixir test_all_string_chars.exs

# Test zone system functionality
elixir test_zone_system.exs
```

## Performance Considerations

### Domain Name Compression
Domain name compression is implemented in `DNS.Message.Domain.parse_domain_from_message/2` with security measures to prevent compression loop attacks.

### Binary Pattern Matching
The library heavily utilizes Elixir's pattern matching on binaries for efficient DNS protocol parsing, particularly in performance-critical paths.

### ETS-Based Storage
Zone management uses ETS tables for high-concurrency in-memory storage with separate tables for zone data and metadata.

## Security Notes

### Current Limitations
- DNSSEC implementation uses placeholder cryptographic functions (production use requires proper crypto implementations)
- Domain compression depth limits should be enforced in production
- Record length fields (rdlength) require validation to prevent memory exhaustion attacks

### Recommendations
- Validate all binary input data before processing
- Implement rate limiting for DNS message processing
- Use proper cryptographic libraries for DNSSEC operations
- Monitor for compression loop attacks in domain name parsing

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a Pull Request

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## References

- [IANA DNS Parameters](https://www.iana.org/assignments/dns-parameters/)
- [RFC 1035 - Domain Names - Implementation and Specification](https://tools.ietf.org/html/rfc1035)
- [RFC 6891 - Extension Mechanisms for DNS (EDNS0)](https://tools.ietf.org/html/rfc6891)
- [RFC 4034 - Resource Records for the DNS Security Extensions](https://tools.ietf.org/html/rfc4034)
- [RFC 9460 - Service Binding and Parameter Specification via the DNS (SVCB and HTTPS)](https://tools.ietf.org/html/rfc9460)