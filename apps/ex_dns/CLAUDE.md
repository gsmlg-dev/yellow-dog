# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is `ex_dns`, a pure Elixir DNS library that provides DNS protocol message parsing, zone management, and resource record handling. The library implements DNS message formats, resource records, and zone operations according to DNS RFC standards.

**Important**: This library is part of the YellowDog umbrella project and is configured as a library application with shared build paths (`build_path: "../../_build"`, `config_path: "../../config/config.exs"`, `deps_path: "../../deps"`, `lockfile: "../../mix.lock"`).

## Architecture

The codebase follows a modular structure with these key components:

- **DNS.Message**: Core DNS message structure with Header, Question, Record sections
- **DNS.Zone**: Zone management for authoritative, stub, forward, and cache zones
- **DNS.ResourceRecordType**: DNS record type definitions (A, AAAA, CNAME, MX, etc.)
- **DNS.Class**: DNS class definitions (IN, CH, HS, etc.)
- **DNS.Parameter**: Protocol serialization/deserialization interface

### Key Module Structure

```
DNS/
├── Message/           # DNS message format implementation
│   ├── Header.ex      # Message header (ID, flags, counts)
│   ├── Question.ex    # Question section
│   ├── Record.ex      # Resource record format
│   ├── Record/Data/   # Specific record types (A, AAAA, CNAME, etc.)
│   └── EDNS0.ex       # Extension mechanisms for DNS
├── Zone/             # DNS zone management
│   ├── Name.ex       # Zone name handling
│   ├── RootHint.ex   # Root server hints
│   └── RRSet.ex      # Resource record sets
└── Class.ex          # DNS class definitions
```

### Core Components

**DNS.Message Protocol System**
- `DNS.Parameter` protocol handles binary serialization/deserialization
- `String.Chars` protocol provides human-readable string representations
- All DNS entities implement both protocols for consistent behavior

**DNS.Message Hierarchy**
- `DNS.Message` - Top-level DNS message with header, questions, and record sections
- `DNS.Message.Header` - Message header (ID, flags, counts)
- `DNS.Message.Question` - Query section with QNAME, QTYPE, QCLASS
- `DNS.Message.Record` - Resource records with name, type, class, TTL, and data
- `DNS.Message.Record.Data/*` - 20+ specific record type implementations (A, AAAA, CNAME, MX, TXT, DNSSEC records, etc.)
- `DNS.Message.Domain` - Domain name parsing with compression support
- `DNS.Message.EDNS0` - Extension mechanisms and options

**DNS.Zone Management**
- `DNS.Zone` - Zone abstraction supporting 4 types: :authoritative, :stub, :forward, :cache
- `DNS.Zone.Manager` - CRUD operations and zone lifecycle management
- `DNS.Zone.Store` - ETS-based persistent zone storage
- `DNS.Zone.Cache` - TTL-based caching with automatic expiration
- `DNS.Zone.Loader` - Zone file loading from various sources
- `DNS.Zone.FileParser` - BIND format zone file parsing
- `DNS.Zone.Validator` - Zone validation and diagnostics
- `DNS.Zone.DNSSEC` - DNSSEC signing and validation (basic implementation)
- `DNS.Zone.Editor` - High-level API for zone record manipulation
- `DNS.Zone.Parser` - Advanced zone file parsing
- `DNS.Zone.Transfer` - Zone transfer (AXFR/IXFR) functionality
- `DNS.Zone.Recursive` - Recursive DNS resolution support

### Key Implementation Patterns

**Protocol-Based Architecture**
All DNS entities implement `DNS.Parameter.to_iodata/1` for binary serialization and `String.Chars.to_string/1` for display. This provides consistent behavior across the entire library.

**Binary Pattern Matching**
Heavy use of Elixir's pattern matching on binaries for efficient DNS protocol parsing, particularly in domain name compression and record data parsing.

**ETS-Based Storage**
Zone management uses ETS tables for in-memory storage with separate tables for zone data and metadata, supporting high-concurrency access patterns.

**Type System Integration**
Comprehensive use of `@type` specifications throughout the codebase with proper union types and structured error returns.

### Critical Implementation Details

**Domain Name Compression**
Located in `DNS.Message.Domain.parse_domain_from_message/2` - handles DNS message compression with pointer dereferencing. This is a performance-critical path and security-sensitive area.

**Record Data Dispatch and Registry**
`DNS.Message.Record.Data` uses a registry-based dispatch system via `DNS.Message.Record.Data.Registry`. The registry is a GenServer with ETS-based storage that maps DNS record type integers to their implementation modules. When parsing or creating records:
- `DNS.Message.Record.Data.from_iodata/3` looks up the type in the registry
- If found, delegates to the specific module's `from_iodata/2` function
- If not found, stores raw binary data in generic `DNS.Message.Record.Data` struct
- New record types must implement `DNS.Message.Record.Data.Behaviour` and be registered in the registry
- All record type modules (22+ implementations in `lib/dns/message/record/data/`) follow this pattern

**Zone Manager Store Integration**
`DNS.Zone.Manager` coordinates with `DNS.Zone.Store` for persistence and `DNS.Zone.Cache` for temporary storage, with automatic initialization and cleanup.

**Error Handling Patterns**
The codebase uses a mix of throw/1 for parsing errors and {:error, reason} tuples for validation errors. This inconsistency is being addressed in ongoing refactoring.

### Security Considerations

**Domain Compression Depth**
Domain name decompression in `DNS.Message.Domain` is vulnerable to compression loop attacks. Implementation must include depth limits.

**Binary Data Validation**
Record length fields (rdlength) require validation to prevent memory exhaustion attacks. Critical in `DNS.Message.Record.from_iodata/2`.

**DNSSEC Implementation**
Current DNSSEC support uses placeholder cryptographic functions. Production use requires proper cryptographic implementations.

## Development Commands

### Testing
```bash
mix test                                  # Run all tests
mix test test/dns/message_test.exs       # Run specific test file
mix test --include wip                    # Run tests including WIP tagged tests
mix test --trace                         # Run tests with detailed output
```

### Code Quality & Analysis
```bash
mix format                               # Format code with Elixir formatter
mix format --check-formatted            # Check if code is formatted
mix credo                               # Run static code analysis
mix dialyzer                            # Run type checking and static analysis
```

### Build & Dependencies
```bash
mix deps.get                            # Install/update dependencies
mix compile                             # Compile the project
mix clean                               # Clean compiled files
mix compile --warnings-as-errors        # Treat warnings as errors (CI requirement)
```

### Documentation
```bash
mix docs                                # Generate documentation
mix help                                # List available tasks
```

### Publishing & Release
```bash
mix publish                             # Format and publish to hex.pm (custom alias)
mix hex.publish --yes                   # Direct publish to hex.pm
```

### Mix Aliases
```bash
mix lint                                 # Run credo --strict and dialyzer
mix publish                             # Format code and publish to hex.pm
```

## Key Development Patterns

### Protocol Implementation
All DNS entities implement two key protocols:
- **`DNS.Parameter`**: Binary serialization for network transmission via `DNS.Parameter.to_iodata/1`
- **`String.Chars`**: Human-readable output via `to_string/1`

This dual-protocol approach ensures consistent behavior across the library. When adding new record types or DNS entities, both protocols must be implemented.

### Record Type Implementation
To add a new DNS record type:
1. Create module in `lib/dns/message/record/data/` implementing `DNS.Message.Record.Data.Behaviour`
2. Implement `new/1`, `from_iodata/2` functions
3. Implement `DNS.Parameter` protocol for binary serialization
4. Implement `String.Chars` protocol for display
5. Register the type in `DNS.Message.Record.Data.Registry` initialization
6. Add type definition to `DNS.ResourceRecordType` if needed

### Zone Types
Four zone types are supported, each with different behaviors:
- **`:authoritative`** - Primary authoritative zone with full record management
- **`:stub`** - Stub zone containing only NS records for delegation
- **`:forward`** - Forward zone redirecting queries to specified servers
- **`:cache`** - Cache zone for temporary DNS response caching with TTL expiration

### Error Handling
The codebase uses mixed error handling patterns:
- `throw/1` for parsing errors in binary parsing paths (legacy pattern)
- `{:ok, result}` or `{:error, reason}` tuples for validation and high-level operations (preferred pattern)
- Ongoing refactoring to standardize on `{:ok, result}` / `{:error, reason}` pattern

## Working with Umbrella Projects

Since this is an umbrella application:
- Run tests from umbrella root: `cd ../.. && mix test apps/ex_dns`
- Or run from this directory: `mix test` (uses shared build paths)
- Dependencies are managed at umbrella level when possible
- Dialyzer PLT files stored in `priv/plts/` to avoid conflicts

## File Organization

- `lib/dns/` - Core DNS implementation (71 source files)
  - `message/` - DNS protocol message handling
    - `record/data/` - 22+ record type implementations
  - `zone/` - Zone management operations (15 modules)
- `test/dns/` - Comprehensive test suite matching lib structure
- `priv/data/` - DNS root hints and zone data files