# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is `ex_dhcp`, a pure Elixir implementation of DHCP (Dynamic Host Configuration Protocol) supporting both DHCPv4 and DHCPv6:

- DHCPv4 implementation based on RFC 2131 and RFC 2132
- DHCPv6 implementation based on RFC 3315 and RFC 3633
- Complete message parsing and serialization for both protocols
- Support for all standard DHCP options
- Type-safe structs for DHCP messages and options
- Binary protocol implementation for network communication

## Architecture

### Core Components

DHCPv4 (RFC 2131/2132):
- **DHCPv4**: Main DHCPv4 module providing the public API
- **DHCPv4.Message**: Core DHCPv4 message struct with full RFC 2131 compliance
- **DHCPv4.Message.Option**: DHCPv4 options handling (splits into specialized modules)
- **DHCPv4.Message.Option.Decoder**: Option parsing logic with functional error handling
- **DHCPv4.Message.Option.Types**: Type-specific option decoding functions
- **DHCPv4.Message.Option.Serializer**: Option serialization using IO.iodata
- **DHCPv4.Message.Option.Formatter**: Option display formatting
- **DHCPv4.Message.Option.Helpers**: Common utility functions
- **DHCPv4.Server**: DHCPv4 server implementation
- **DHCPv4.Client**: DHCPv4 client implementation
- **DHCPv4.Config**: DHCPv4 configuration management

DHCPv6 (RFC 3315/3633):
- **DHCPv6**: Main DHCPv6 module providing the public API
- **DHCPv6.Message**: Core DHCPv6 message struct with full RFC 3315 compliance
- **DHCPv6.Message.Option**: DHCPv6 options handling per RFC 3315
- **DHCPv6.Server**: DHCPv6 server implementation
- **DHCPv6.Client**: DHCPv6 client implementation
- **DHCPv6.Config**: DHCPv6 configuration management

Shared:
- **DHCP.Parameter**: Protocol for binary serialization/deserialization
- **DHCP.SecureRandom**: Cryptographically secure random number generation

### Key Types

DHCPv4:
- `DHCPv4.Message.t`: Complete DHCPv4 message structure with all RFC 2131 fields
- `DHCPv4.Message.Option.t`: DHCPv4 option with type, length, and value
- IPv4 addresses represented as Erlang `:inet.ip4_address()` tuples `{a,b,c,d}`

DHCPv6:
- `DHCPv6.Message.t`: Complete DHCPv6 message structure with all RFC 3315 fields
- `DHCPv6.Message.Option.t`: DHCPv6 option with code, length, and value
- IPv6 addresses represented as Erlang `:inet.ip6_address()` tuples `{a,b,c,d,e,f,g,h}`

### Binary Format

DHCPv4 messages follow the DHCP wire format:
- Fixed 236-byte header (op, htype, hlen, hops, xid, secs, flags, addresses, chaddr, sname, file)
- Variable options section with magic cookie `99.130.83.99`
- Options use TLV (Type-Length-Value) encoding with 1-byte type/length

DHCPv6 messages use a simpler format:
- Fixed 4-byte header (msg-type + 3-byte transaction-id)
- Variable options section
- Options use TLV encoding with 2-byte code/length

## Development Commands

### Setup
```bash
mix deps.get    # Install dependencies
mix compile     # Compile the project
```

### Testing
```bash
mix test                    # Run all tests
mix test test/dhcpv4/       # Run only DHCPv4 tests
mix test test/dhcpv6/       # Run only DHCPv6 tests
mix test test/dhcpv4/message_test.exs  # Run specific test file
mix test --trace            # Run tests with detailed output
mix test.coverage           # Run tests with coverage report
```

### Code Quality
```bash
mix format                  # Format code
mix credo                   # Run static analysis
mix dialyzer                # Run type checking (requires plt build)
mix dialyzer.build          # Build dialyzer PLT files
```

### Documentation
```bash
mix docs                    # Generate documentation
mix hex.publish             # Publish to hex.pm (includes format check)
```

### Common Tasks

DHCPv4:
- **Parse DHCPv4 message**: `DHCPv4.Message.from_iodata(binary)`
- **Create DHCPv4 message**: `DHCPv4.Message.new()`
- **Serialize DHCPv4 message**: `DHCP.Parameter.to_iodata(message)`
- **Parse DHCPv4 options**: `DHCPv4.Message.Option.parse(binary)` (returns `{:ok, options}`)
- **Parse DHCPv4 options (legacy)**: `DHCPv4.Message.Option.parse!(binary)` (raises on error)
- **Create DHCPv4 option**: `DHCPv4.Message.Option.new(type, length, value)`

DHCPv6:
- **Parse DHCPv6 message**: `DHCPv6.Message.from_iodata(binary)`
- **Create DHCPv6 message**: `DHCPv6.Message.new()`
- **Serialize DHCPv6 message**: `DHCP.Parameter.to_iodata(message)`
- **Parse DHCPv6 options**: `DHCPv6.Message.Option.parse_option(binary)`
- **Create DHCPv6 option**: `DHCPv6.Message.Option.new(code, length, value)`

Secure Random Numbers:
- **Generate DHCPv4 transaction ID**: `DHCP.SecureRandom.generate_dhcpv4_xid()`
- **Generate DHCPv6 transaction ID**: `DHCP.SecureRandom.generate_dhcpv6_transaction_id()`
- **Generate IA ID**: `DHCP.SecureRandom.generate_ia_id()`

## Dependencies

- **machete**: Testing utilities (dev/test only)
- **dialyxir**: Type checking (dev/test only)
- **credo**: Code quality (dev/test only)
- **ex_doc**: Documentation generation (dev only)

## File Structure

```
lib/
├── dhcp.ex                    # Legacy main API module
├── dhcp/
│   ├── parameter.ex           # Binary serialization protocol
│   └── secure_random.ex       # Cryptographically secure random numbers
├── dhcpv4/                    # DHCPv4 implementation
│   ├── message.ex             # DHCPv4 message struct and parsing
│   ├── message/
│   │   ├── option.ex          # DHCPv4 options public interface
│   │   ├── option/
│   │   │   ├── decoder.ex     # Option parsing logic
│   │   │   ├── types.ex       # Type-specific decoding
│   │   │   ├── serializer.ex  # Option serialization
│   │   │   ├── formatter.ex   # Option display formatting
│   │   │   └── helpers.ex     # Common utilities
│   ├── server.ex              # DHCPv4 server implementation
│   ├── client.ex              # DHCPv4 client implementation
│   └── config.ex              # DHCPv4 configuration management
└── dhcpv6/                    # DHCPv6 implementation
    ├── message.ex             # DHCPv6 message struct and parsing
    ├── message/
    │   └── option.ex          # DHCPv6 options handling
    ├── server.ex              # DHCPv6 server implementation
    ├── client.ex              # DHCPv6 client implementation
    └── config.ex              # DHCPv6 configuration management

test/
├── dhcpv4/                    # DHCPv4 tests
│   ├── message_test.exs
│   ├── message/
│   │   └── option_test.exs
│   ├── server_test.exs
│   └── config_test.exs
└── dhcpv6/                    # DHCPv6 tests
    ├── message_test.exs
    ├── message/
    │   └── option_test.exs
    ├── server_test.exs
    └── config_test.exs
```

## Error Handling Patterns

This codebase uses functional error handling patterns:

- `DHCPv4.Message.Option.parse/1` returns `{:ok, options} | {:error, reason}`
- Legacy `DHCPv4.Message.Option.parse!/1` raises on error (for backward compatibility)
- Most parsing functions follow the `{:ok, result} | {:error, reason}` pattern
- Error tuples provide descriptive error messages for debugging

## RFC Compliance

DHCPv4:
- **RFC 2131**: DHCP protocol specification
- **RFC 2132**: DHCP options and BOOTP vendor extensions
- Supports all standard DHCPv4 message types (DISCOVER, OFFER, REQUEST, etc.)
- Implements magic cookie and proper option formatting

DHCPv6:
- **RFC 3315**: Dynamic Host Configuration Protocol for IPv6
- **RFC 3633**: IPv6 Prefix Options for DHCPv6
- Supports all standard DHCPv6 message types (SOLICIT, ADVERTISE, REQUEST, etc.)
- Implements DUID-based identification and multicast support