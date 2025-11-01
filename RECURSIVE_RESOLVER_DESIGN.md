# YellowDog DNS Recursive Resolver - Comprehensive Design Document

**Version**: 1.0
**Date**: 2025-10-29
**Author**: Design Document
**Status**: Design Phase

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Module Structure](#2-module-structure)
3. [Root Zone Management](#3-root-zone-management)
4. [Recursive Resolution Algorithm](#4-recursive-resolution-algorithm)
5. [Data Structures](#5-data-structures)
6. [Configuration](#6-configuration)
7. [Query Resolution Flow](#7-query-resolution-flow)
8. [Glue Record Handling](#8-glue-record-handling)
9. [Integration with Existing Modules](#9-integration-with-existing-modules)
10. [Error Handling](#10-error-handling)
11. [Performance Optimizations](#11-performance-optimizations)
12. [Security Considerations](#12-security-considerations)
13. [Test Strategy](#13-test-strategy)
14. [Implementation Phases](#14-implementation-phases)
15. [Potential Issues and Mitigations](#15-potential-issues-and-mitigations)

---

## 1. Executive Summary

This document outlines the complete architecture for implementing a **Recursive Resolver** in YellowDog DNS. The recursive resolver will enable the DNS server to perform full recursive resolution starting from root servers, following referrals through the DNS hierarchy until obtaining a final answer.

### Key Features

- **Three Root Zone Management Strategies**: Hints (default), IANA fetch, Authoritative
- **Iterative Resolution**: Full RFC-compliant recursive resolution from root servers
- **Glue Record Support**: Proper handling of glue records to prevent resolution deadlocks
- **Cache Integration**: Intermediate result caching to minimize recursive queries
- **Loop Detection**: Comprehensive referral loop detection and prevention
- **Telemetry**: Full telemetry coverage for monitoring and debugging
- **View Integration**: Per-view recursion control

### Current Capabilities

- ✅ Authoritative zone resolution (complete with wildcard support)
- ✅ Forward zone resolution (just implemented)
- ✅ Query.Resolver with CNAME chain following
- ✅ Basic recursive stub in ex_dns (DNS.Zone.Recursive)
- ✅ Root hints data available in ex_dns (DNS.Zone.RootHint)

### What This Design Adds

- Full recursive resolution with proper referral following
- Root zone management with multiple strategies
- Glue record handling
- Per-view recursion configuration
- Comprehensive caching strategy
- Production-ready error handling and security

---

## 2. Module Structure

### 2.1 File Organization

```
apps/yellow_dog_dns/lib/yellow_dog/dns/
├── query/
│   ├── resolver.ex                 # Existing authoritative/forward resolver
│   ├── forwarder.ex               # Existing forward zone handler
│   ├── recursive.ex               # NEW: Main recursive resolver
│   └── iterator.ex                # NEW: Iterative query logic
├── root_zone/
│   ├── manager.ex                 # NEW: Root zone lifecycle manager (GenServer)
│   ├── hints.ex                   # NEW: Embedded root servers
│   ├── fetcher.ex                 # NEW: IANA zone fetcher (GenServer)
│   └── strategy.ex                # NEW: Behavior for root strategies
├── cache/
│   ├── resolver_cache.ex          # NEW: Recursive resolver cache (GenServer)
│   └── entry.ex                   # NEW: Cache entry structure
└── view.ex                        # EXISTING: Add recursion_enabled field

apps/ex_dns/lib/dns/zone/
├── root_hint.ex                   # EXISTING: Root hints data
└── recursive.ex                   # EXISTING: Basic recursive stub
```

### 2.2 Module Descriptions

#### **YellowDog.Dns.Query.Recursive** (NEW)
Main recursive resolver module implementing full recursive resolution.

**Responsibilities:**
- Public API for recursive resolution
- Orchestrates iterative queries via Iterator
- Manages resolution state and history
- Integrates with cache
- Handles CNAME chain following in recursive context
- Enforces timeout and depth limits

**Key Functions:**
```elixir
@spec resolve(String.t(), atom(), keyword()) :: resolve_result()
def resolve(query_name, query_type, opts \\ [])

@spec resolve_with_state(String.t(), atom(), map()) :: {resolve_result(), map()}
defp resolve_with_state(query_name, query_type, state)

@spec follow_cname_chain([Zone.Record.t()], atom(), map()) :: {resolve_result(), map()}
defp follow_cname_chain(answers, query_type, state)
```

#### **YellowDog.Dns.Query.Iterator** (NEW)
Handles single iteration of recursive resolution.

**Responsibilities:**
- Query a set of nameservers
- Parse referrals (NS records + glue)
- Extract answers vs referrals
- Handle timeouts and retries
- Parallel queries with first-wins strategy

**Key Functions:**
```elixir
@spec query_nameservers([nameserver()], String.t(), atom(), keyword()) :: iteration_result()
def query_nameservers(nameservers, query_name, query_type, opts \\ [])

@spec parse_response(DNS.Message.t(), String.t()) :: iteration_result()
defp parse_response(response, query_name)

@spec extract_glue_records([DNS.Message.Record.t()], [DNS.Message.Record.t()]) :: [glue_record()]
defp extract_glue_records(ns_records, ar_records)
```

#### **YellowDog.Dns.RootZone.Manager** (NEW)
GenServer managing root zone data lifecycle.

**Responsibilities:**
- Initialize root zone on startup
- Switch between root zone strategies
- Coordinate with Fetcher for periodic updates
- Provide root nameserver list to recursive resolver
- Handle strategy-specific loading

**Key Functions:**
```elixir
@spec start_link(keyword()) :: GenServer.on_start()
def start_link(opts \\ [])

@spec get_root_nameservers() :: {:ok, [nameserver()]} | {:error, term()}
def get_root_nameservers()

@spec reload_root_zone() :: :ok | {:error, term()}
def reload_root_zone()

@spec get_strategy() :: :hints | :fetch | :auth
def get_strategy()
```

#### **YellowDog.Dns.RootZone.Hints** (NEW)
Static root hints module (no state).

**Responsibilities:**
- Return embedded list of 13 root servers
- Provide both IPv4 and IPv6 addresses
- No external dependencies
- Fast, reliable fallback

**Key Functions:**
```elixir
@spec get_root_servers() :: [nameserver()]
def get_root_servers()

@spec get_root_servers_ipv4() :: [nameserver()]
def get_root_servers_ipv4()

@spec get_root_servers_ipv6() :: [nameserver()]
def get_root_servers_ipv6()
```

#### **YellowDog.Dns.RootZone.Fetcher** (NEW)
GenServer for periodic IANA zone file downloads.

**Responsibilities:**
- Fetch root zone from https://www.internic.net/domain/root.zone
- Parse zone file using Zone.Parser
- Store in Zone.Storage as authoritative zone
- Schedule periodic updates (configurable interval)
- Fallback to hints on failure
- HTTP client with timeout and retry logic

**Key Functions:**
```elixir
@spec start_link(keyword()) :: GenServer.on_start()
def start_link(opts \\ [])

@spec fetch_now() :: :ok | {:error, term()}
def fetch_now()

@spec get_status() :: map()
def get_status()
```

#### **YellowDog.Dns.RootZone.Strategy** (NEW)
Behavior defining root zone strategy interface.

**Responsibilities:**
- Define common interface for all strategies
- Strategy modules implement this behavior
- Enable strategy switching at runtime

**Callbacks:**
```elixir
@callback init(keyword()) :: {:ok, state :: term()} | {:error, term()}
@callback get_nameservers(state :: term()) :: {:ok, [nameserver()]} | {:error, term()}
@callback reload(state :: term()) :: {:ok, new_state :: term()} | {:error, term()}
```

#### **YellowDog.Dns.Cache.ResolverCache** (NEW)
GenServer for recursive resolver cache.

**Responsibilities:**
- Cache intermediate NS records and glue
- Cache final answers with TTL
- Automatic expiration based on TTL
- Periodic cleanup of expired entries
- Statistics tracking
- Separate from authoritative cache

**Key Functions:**
```elixir
@spec start_link(keyword()) :: GenServer.on_start()
def start_link(opts \\ [])

@spec lookup(String.t(), atom()) :: {:hit, [record()]} | :miss
def lookup(query_name, query_type)

@spec insert(String.t(), atom(), [record()], non_neg_integer()) :: :ok
def insert(query_name, query_type, records, ttl)

@spec stats() :: map()
def stats()
```

---

## 3. Root Zone Management

### 3.1 Strategy 1: Root Hints (Default)

**Overview:**
Embedded list of 13 root servers with hardcoded IPv4 and IPv6 addresses.

**Advantages:**
- Zero external dependencies
- Instant startup
- Maximum reliability
- No network failures
- Perfect for most deployments

**Disadvantages:**
- Root server IPs may change (rare)
- No custom TLDs possible
- Static data

**Implementation:**
```elixir
defmodule YellowDog.Dns.RootZone.Hints do
  @moduledoc """
  Embedded root hints providing the 13 root servers.

  Data source: IANA root hints (https://www.internic.net/domain/named.root)
  Last updated: 2024-10-29
  """

  @root_servers [
    %{name: "a.root-servers.net", ipv4: [{198, 41, 0, 4}], ipv6: [{0x2001, 0x503, 0xba3e, 0, 0, 0, 0x2, 0x30}]},
    %{name: "b.root-servers.net", ipv4: [{170, 247, 170, 2}], ipv6: [{0x2801, 0x1b8, 0x10, 0, 0, 0, 0, 0xb}]},
    %{name: "c.root-servers.net", ipv4: [{192, 33, 4, 12}], ipv6: [{0x2001, 0x500, 0x2, 0, 0, 0, 0, 0xc}]},
    %{name: "d.root-servers.net", ipv4: [{199, 7, 91, 13}], ipv6: [{0x2001, 0x500, 0x2d, 0, 0, 0, 0, 0xd}]},
    %{name: "e.root-servers.net", ipv4: [{192, 203, 230, 10}], ipv6: [{0x2001, 0x500, 0xa8, 0, 0, 0, 0, 0xe}]},
    %{name: "f.root-servers.net", ipv4: [{192, 5, 5, 241}], ipv6: [{0x2001, 0x500, 0x2f, 0, 0, 0, 0, 0xf}]},
    %{name: "g.root-servers.net", ipv4: [{192, 112, 36, 4}], ipv6: [{0x2001, 0x500, 0x12, 0, 0, 0, 0, 0xd0d}]},
    %{name: "h.root-servers.net", ipv4: [{198, 97, 190, 53}], ipv6: [{0x2001, 0x500, 0x1, 0, 0, 0, 0, 0x53}]},
    %{name: "i.root-servers.net", ipv4: [{192, 36, 148, 17}], ipv6: [{0x2001, 0x7fe, 0, 0, 0, 0, 0, 0x53}]},
    %{name: "j.root-servers.net", ipv4: [{192, 58, 128, 30}], ipv6: [{0x2001, 0x503, 0xc27, 0, 0, 0, 0x2, 0x30}]},
    %{name: "k.root-servers.net", ipv4: [{193, 0, 14, 129}], ipv6: [{0x2001, 0x7fd, 0, 0, 0, 0, 0, 0x1}]},
    %{name: "l.root-servers.net", ipv4: [{199, 7, 83, 42}], ipv6: [{0x2001, 0x500, 0x9f, 0, 0, 0, 0, 0x42}]},
    %{name: "m.root-servers.net", ipv4: [{202, 12, 27, 33}], ipv6: [{0x2001, 0xdc3, 0, 0, 0, 0, 0, 0x35}]}
  ]

  @spec get_root_servers() :: [nameserver()]
  def get_root_servers do
    Enum.map(@root_servers, fn server ->
      %{
        name: server.name,
        addresses: server.ipv4 ++ server.ipv6
      }
    end)
  end

  @spec get_root_servers_ipv4() :: [nameserver()]
  def get_root_servers_ipv4 do
    Enum.map(@root_servers, fn server ->
      %{name: server.name, addresses: server.ipv4}
    end)
  end
end
```

### 3.2 Strategy 2: Fetch from IANA

**Overview:**
Periodically downloads root zone file from IANA and parses as authoritative zone.

**Advantages:**
- Always up-to-date with official root zone
- Can serve root zone authoritatively
- Supports custom TLDs if manually added
- Automatic updates

**Disadvantages:**
- Network dependency on startup
- Requires HTTP client
- Parsing overhead
- Storage overhead (zone file ~2MB)

**Implementation:**
```elixir
defmodule YellowDog.Dns.RootZone.Fetcher do
  use GenServer
  require Logger

  @fetch_url "https://www.internic.net/domain/root.zone"
  @default_interval_hours 24
  @zone_name "."

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interval_hours = Keyword.get(opts, :fetch_interval_hours, @default_interval_hours)
    fallback_to_hints = Keyword.get(opts, :fallback_to_hints, true)

    state = %{
      interval_ms: interval_hours * 60 * 60 * 1000,
      fallback_to_hints: fallback_to_hints,
      last_fetch: nil,
      last_fetch_status: :not_started,
      fetch_count: 0
    }

    # Fetch immediately on startup
    send(self(), :fetch)

    {:ok, state}
  end

  @impl true
  def handle_info(:fetch, state) do
    case do_fetch() do
      :ok ->
        # Schedule next fetch
        Process.send_after(self(), :fetch, state.interval_ms)

        new_state = %{
          state
          | last_fetch: System.system_time(:second),
            last_fetch_status: :success,
            fetch_count: state.fetch_count + 1
        }

        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("Root zone fetch failed: #{inspect(reason)}")

        # Try hints fallback if enabled
        if state.fallback_to_hints and state.fetch_count == 0 do
          Logger.info("Falling back to root hints")
          # Manager will use hints automatically
        end

        # Schedule retry (shorter interval on failure)
        Process.send_after(self(), :fetch, 60_000)

        new_state = %{
          state
          | last_fetch_status: {:error, reason},
            fetch_count: state.fetch_count + 1
        }

        {:noreply, new_state}
    end
  end

  defp do_fetch do
    with {:ok, response} <- http_get(@fetch_url, timeout: 30_000),
         {:ok, zone_data} <- parse_zone_file(response.body),
         :ok <- store_zone(zone_data) do
      Logger.info("Root zone fetched and loaded successfully")
      :ok
    else
      {:error, reason} = error ->
        Logger.error("Failed to fetch root zone", reason: inspect(reason))
        error
    end
  end

  defp http_get(url, opts) do
    # Use Req or HTTPoison for HTTP client
    case Req.get(url, Keyword.merge([timeout: 30_000], opts)) do
      {:ok, %{status: 200} = response} -> {:ok, response}
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_zone_file(zone_text) do
    # Parse using YellowDog.Dns.Zone.Parser
    YellowDog.Dns.Zone.Parser.parse(zone_text, origin: ".")
  end

  defp store_zone(zone_data) do
    # Store in Zone.Storage as authoritative zone
    metadata = %{
      type: :master,
      source: :fetched_root,
      loaded_at: System.system_time(:second)
    }

    YellowDog.Dns.Zone.Storage.put_zone_metadata(@zone_name, metadata)

    # Insert all records
    Enum.each(zone_data.records, fn record ->
      YellowDog.Dns.Zone.Storage.insert_record(
        @zone_name,
        record.owner,
        record.type,
        record.rdata,
        record.ttl,
        record.class
      )
    end)

    :ok
  end
end
```

### 3.3 Strategy 3: Authoritative Root Zone

**Overview:**
Load root zone from a local zone file, treating it as a regular authoritative zone.

**Advantages:**
- Full control over root zone
- Custom TLDs possible (private root)
- Air-gapped environments
- Testing environments
- No network dependencies

**Disadvantages:**
- Manual zone file management
- Manual updates required
- Large zone file (~2MB)
- Not synced with official root

**Implementation:**
```elixir
# Root zone loaded via regular zone loading mechanism
# Configuration in TOML:

# config.toml
[dns.root_zone]
strategy = "auth"
zone_file = "/etc/yellowdog/zones/root.zone"

# Zone.Manager loads this like any other zone
# The zone_file must be in BIND format
```

### 3.4 Root Zone Manager

**Overview:**
GenServer coordinating root zone strategies and providing unified interface.

**Implementation:**
```elixir
defmodule YellowDog.Dns.RootZone.Manager do
  use GenServer
  require Logger

  @strategies %{
    hints: YellowDog.Dns.RootZone.Hints,
    fetch: YellowDog.Dns.RootZone.Fetcher,
    auth: YellowDog.Dns.RootZone.Auth
  }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    strategy = get_configured_strategy()

    state = %{
      strategy: strategy,
      strategy_state: nil
    }

    case initialize_strategy(strategy, opts) do
      {:ok, strategy_state} ->
        {:ok, %{state | strategy_state: strategy_state}}

      {:error, reason} ->
        Logger.error("Failed to initialize root zone strategy: #{inspect(reason)}")
        # Fallback to hints
        {:ok, hints_state} = initialize_strategy(:hints, opts)
        {:ok, %{state | strategy: :hints, strategy_state: hints_state}}
    end
  end

  # Public API

  @spec get_root_nameservers() :: {:ok, [nameserver()]} | {:error, term()}
  def get_root_nameservers do
    GenServer.call(__MODULE__, :get_root_nameservers)
  end

  @spec reload_root_zone() :: :ok | {:error, term()}
  def reload_root_zone do
    GenServer.call(__MODULE__, :reload)
  end

  @spec get_strategy() :: atom()
  def get_strategy do
    GenServer.call(__MODULE__, :get_strategy)
  end

  # GenServer callbacks

  @impl true
  def handle_call(:get_root_nameservers, _from, state) do
    strategy_module = Map.get(@strategies, state.strategy)
    result = strategy_module.get_nameservers(state.strategy_state)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:get_strategy, _from, state) do
    {:reply, state.strategy, state}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    strategy_module = Map.get(@strategies, state.strategy)

    case strategy_module.reload(state.strategy_state) do
      {:ok, new_strategy_state} ->
        {:reply, :ok, %{state | strategy_state: new_strategy_state}}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  defp get_configured_strategy do
    case YellowDog.Config.get(:dns, :root_zone, %{}) do
      %{strategy: strategy} when strategy in [:hints, :fetch, :auth] ->
        strategy

      _ ->
        :hints  # Default
    end
  end

  defp initialize_strategy(:hints, _opts) do
    # Hints strategy has no state
    {:ok, nil}
  end

  defp initialize_strategy(:fetch, opts) do
    # Start Fetcher GenServer
    case YellowDog.Dns.RootZone.Fetcher.start_link(opts) do
      {:ok, _pid} -> {:ok, nil}
      error -> error
    end
  end

  defp initialize_strategy(:auth, _opts) do
    # Load zone file from configuration
    zone_file = YellowDog.Config.get(:dns, [:root_zone, :zone_file])

    if zone_file && File.exists?(zone_file) do
      case YellowDog.Dns.Zone.Manager.load_zone(".", zone_file, type: :master) do
        {:ok, _} -> {:ok, nil}
        error -> error
      end
    else
      {:error, :zone_file_not_found}
    end
  end
end
```

---

## 4. Recursive Resolution Algorithm

### 4.1 High-Level Algorithm

```
1. START with query (e.g., www.example.com A)

2. CHECK cache
   - If HIT: return cached answer
   - If MISS: continue

3. CHECK authoritative zones
   - If authoritative for zone: return authoritative answer
   - If not: continue

4. CHECK forward zones
   - If forward zone configured: forward query
   - If not: continue

5. BEGIN RECURSIVE RESOLUTION

   5.1 Initialize state:
       - query_name: www.example.com
       - query_type: A
       - current_servers: root servers
       - referral_chain: []
       - depth: 0
       - max_depth: 16

   5.2 ITERATION LOOP (while depth < max_depth):

       a. Query current_servers for (query_name, query_type)
          - Use parallel queries (first successful wins)
          - Timeout per server: 2-5 seconds

       b. Parse response:

          IF answer section non-empty:
              - Extract answers
              - Check for CNAME
              - If CNAME and query_type != CNAME:
                  * Follow CNAME chain (recursive call)
              - Cache answer with TTL
              - RETURN answer

          IF authority section has NS records:
              - Extract NS records (referral)
              - Extract glue records from additional section
              - Validate referral (closer to target than previous)
              - Check for referral loops
              - Update current_servers = glue addresses
              - Add to referral_chain
              - depth++
              - CONTINUE LOOP

          IF no answer and no referral:
              - RETURN NXDOMAIN or SERVFAIL

       c. Check loop detection:
          - If referral_chain contains duplicate: RETURN SERVFAIL

       d. Increment depth

   5.3 If depth >= max_depth:
       - RETURN SERVFAIL (too many referrals)

6. END
```

### 4.2 Detailed Pseudocode

```elixir
defmodule YellowDog.Dns.Query.Recursive do

  @max_depth 16
  @query_timeout_ms 5000

  @spec resolve(String.t(), atom(), keyword()) :: resolve_result()
  def resolve(query_name, query_type, opts \\ []) do
    # Initialize state
    state = %{
      query_name: query_name,
      query_type: query_type,
      referral_chain: [],
      depth: 0,
      max_depth: Keyword.get(opts, :max_depth, @max_depth),
      timeout_ms: Keyword.get(opts, :timeout_ms, @query_timeout_ms),
      start_time: System.monotonic_time(:millisecond)
    }

    # Get root servers from RootZone.Manager
    {:ok, root_servers} = YellowDog.Dns.RootZone.Manager.get_root_nameservers()

    # Start iterative resolution
    resolve_iterative(root_servers, state)
  end

  defp resolve_iterative(current_servers, state) do
    # Check depth limit
    if state.depth >= state.max_depth do
      {:error, :max_depth_exceeded}
    else
      # Check timeout
      elapsed = System.monotonic_time(:millisecond) - state.start_time
      if elapsed > state.timeout_ms do
        {:error, :timeout}
      else
        # Query current nameservers
        case YellowDog.Dns.Query.Iterator.query_nameservers(
          current_servers,
          state.query_name,
          state.query_type,
          timeout_ms: state.timeout_ms - elapsed
        ) do
          {:answer, records} ->
            # Got final answer
            {:ok, records}

          {:referral, ns_records, glue_records} ->
            # Got referral, continue iteration

            # Check for referral loop
            ns_names = Enum.map(ns_records, & &1.rdata)
            if ns_names in state.referral_chain do
              {:error, :referral_loop}
            else
              # Extract nameserver addresses from glue
              next_servers = extract_nameserver_addresses(ns_records, glue_records)

              if Enum.empty?(next_servers) do
                # No glue records, need to resolve NS names (sidequery)
                resolve_nameserver_addresses(ns_records, state)
              else
                # Continue with glue addresses
                new_state = %{
                  state
                  | referral_chain: [ns_names | state.referral_chain],
                    depth: state.depth + 1
                }

                resolve_iterative(next_servers, new_state)
              end
            end

          {:nxdomain} ->
            {:nxdomain, []}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  defp extract_nameserver_addresses(ns_records, glue_records) do
    # For each NS record, find corresponding glue A/AAAA records
    Enum.flat_map(ns_records, fn ns_record ->
      ns_name = ns_record.rdata

      glue_records
      |> Enum.filter(fn glue ->
        glue.name == ns_name && glue.type in [:A, :AAAA]
      end)
      |> Enum.map(fn glue ->
        %{name: ns_name, address: glue.rdata}
      end)
    end)
  end

  defp resolve_nameserver_addresses(ns_records, parent_state) do
    # This is a "sidequery" - we need to resolve NS names themselves
    # Create separate recursive queries for each NS name

    ns_names = Enum.map(ns_records, & &1.rdata)

    # Query for A records of NS names
    results = Enum.map(ns_names, fn ns_name ->
      # Recursive call with new state to avoid infinite loop
      resolve(ns_name, :A, max_depth: parent_state.max_depth - parent_state.depth - 1)
    end)

    # Collect successful resolutions
    addresses = Enum.flat_map(results, fn
      {:ok, records} -> Enum.map(records, & &1.rdata)
      _ -> []
    end)

    if Enum.empty?(addresses) do
      {:error, :no_glue_and_cannot_resolve_ns}
    else
      next_servers = Enum.map(addresses, fn addr ->
        %{name: nil, address: addr}
      end)

      # Continue iteration with resolved addresses
      resolve_iterative(next_servers, %{parent_state | depth: parent_state.depth + 1})
    end
  end
end
```

### 4.3 Iterator Implementation

```elixir
defmodule YellowDog.Dns.Query.Iterator do

  @spec query_nameservers([nameserver()], String.t(), atom(), keyword()) :: iteration_result()
  def query_nameservers(nameservers, query_name, query_type, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 5000)

    # Create DNS query message
    query_message = create_query_message(query_name, query_type)
    query_data = DNS.Parameter.to_iodata(query_message)

    # Query all nameservers in parallel, take first successful response
    case query_parallel(nameservers, query_data, timeout_ms) do
      {:ok, response_message} ->
        parse_response(response_message, query_name)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp query_parallel(nameservers, query_data, timeout_ms) do
    # Use Task.async_stream for parallel queries
    nameservers
    |> Task.async_stream(
      fn ns ->
        query_single_nameserver(ns.address, 53, query_data, timeout_ms)
      end,
      timeout: timeout_ms,
      on_timeout: :kill_task,
      max_concurrency: length(nameservers)
    )
    |> Enum.find_value(fn
      {:ok, {:ok, response}} -> {:ok, response}
      _ -> nil
    end)
    |> case do
      nil -> {:error, :all_nameservers_failed}
      result -> result
    end
  end

  defp query_single_nameserver(ip, port, query_data, timeout_ms) do
    case :gen_udp.open(0, [:binary, active: false]) do
      {:ok, socket} ->
        :gen_udp.send(socket, ip, port, query_data)

        result = case :gen_udp.recv(socket, 0, timeout_ms) do
          {:ok, {_ip, _port, response_data}} ->
            response = DNS.Message.from_iodata(response_data)
            {:ok, response}

          {:error, reason} ->
            {:error, reason}
        end

        :gen_udp.close(socket)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec parse_response(DNS.Message.t(), String.t()) :: iteration_result()
  defp parse_response(response, query_name) do
    cond do
      # Check RCODE
      response.header.rcode.value != <<0>> ->
        rcode = DNS.Message.RCode.to_string(response.header.rcode)

        case rcode do
          "NXDOMAIN" -> {:nxdomain}
          _ -> {:error, {:rcode, rcode}}
        end

      # Check for answers
      response.header.ancount > 0 ->
        {:answer, response.anlist}

      # Check for referral (NS records in authority section)
      response.header.nscount > 0 ->
        ns_records = Enum.filter(response.nslist, & &1.type == :NS)
        glue_records = response.arlist

        if Enum.empty?(ns_records) do
          {:error, :no_ns_in_authority}
        else
          {:referral, ns_records, glue_records}
        end

      # No answer, no referral
      true ->
        {:error, :no_answer_or_referral}
    end
  end

  defp create_query_message(query_name, query_type) do
    %DNS.Message{
      header: %DNS.Message.Header{
        id: :rand.uniform(65535),
        qr: 0,  # Query
        opcode: 0,  # Standard query
        aa: 0,
        tc: 0,
        rd: 0,  # Recursion NOT desired (we're iterating ourselves)
        ra: 0,
        rcode: 0,
        qdcount: 1,
        ancount: 0,
        nscount: 0,
        arcount: 0
      },
      qdlist: [
        DNS.Message.Question.new(query_name, query_type, :in)
      ],
      anlist: [],
      nslist: [],
      arlist: []
    }
  end
end
```

---

## 5. Data Structures

### 5.1 Nameserver Structure

```elixir
@type nameserver :: %{
  name: String.t() | nil,
  address: :inet.ip_address()
}

# Example:
%{
  name: "a.gtld-servers.net",
  address: {192, 5, 6, 30}
}
```

### 5.2 Referral Structure

```elixir
@type referral :: %{
  zone: String.t(),
  ns_records: [DNS.Message.Record.t()],
  glue_records: [DNS.Message.Record.t()]
}

# Example:
%{
  zone: "com.",
  ns_records: [
    %DNS.Message.Record{type: :NS, name: "com.", rdata: "a.gtld-servers.net."},
    %DNS.Message.Record{type: :NS, name: "com.", rdata: "b.gtld-servers.net."}
  ],
  glue_records: [
    %DNS.Message.Record{type: :A, name: "a.gtld-servers.net.", rdata: {192, 5, 6, 30}},
    %DNS.Message.Record{type: :A, name: "b.gtld-servers.net.", rdata: {192, 33, 14, 30}}
  ]
}
```

### 5.3 Resolution State

```elixir
@type resolution_state :: %{
  query_name: String.t(),
  query_type: atom(),
  referral_chain: [[String.t()]],
  depth: non_neg_integer(),
  max_depth: non_neg_integer(),
  timeout_ms: non_neg_integer(),
  start_time: integer(),
  visited_zones: MapSet.t(String.t())
}

# Example:
%{
  query_name: "www.example.com",
  query_type: :A,
  referral_chain: [
    ["a.root-servers.net", "b.root-servers.net"],
    ["a.gtld-servers.net", "b.gtld-servers.net"]
  ],
  depth: 2,
  max_depth: 16,
  timeout_ms: 10000,
  start_time: 1730209843821,
  visited_zones: MapSet.new([".", "com."])
}
```

### 5.4 Cache Entry

```elixir
defmodule YellowDog.Dns.Cache.Entry do
  @moduledoc """
  Cache entry for recursive resolver.

  Stores DNS records with TTL and expiration tracking.
  """

  defstruct [
    :query_name,
    :query_type,
    :records,
    :ttl,
    :cached_at,
    :expires_at
  ]

  @type t :: %__MODULE__{
    query_name: String.t(),
    query_type: atom(),
    records: [DNS.Message.Record.t()],
    ttl: non_neg_integer(),
    cached_at: integer(),
    expires_at: integer()
  }

  @spec new(String.t(), atom(), [DNS.Message.Record.t()], non_neg_integer()) :: t()
  def new(query_name, query_type, records, ttl) do
    now = System.system_time(:second)

    %__MODULE__{
      query_name: query_name,
      query_type: query_type,
      records: records,
      ttl: ttl,
      cached_at: now,
      expires_at: now + ttl
    }
  end

  @spec expired?(t()) :: boolean()
  def expired?(entry) do
    System.system_time(:second) >= entry.expires_at
  end

  @spec remaining_ttl(t()) :: non_neg_integer()
  def remaining_ttl(entry) do
    max(0, entry.expires_at - System.system_time(:second))
  end
end
```

### 5.5 Iteration Result

```elixir
@type iteration_result ::
  {:answer, [DNS.Message.Record.t()]}
  | {:referral, ns_records :: [DNS.Message.Record.t()], glue_records :: [DNS.Message.Record.t()]}
  | {:nxdomain}
  | {:error, term()}
```

---

## 6. Configuration

### 6.1 TOML Configuration

```toml
[dns]
# Enable recursion
recursion_enabled = true

# Recursion settings
recursion_timeout_ms = 10000
max_recursion_depth = 16

# Number of retries per nameserver
query_retries = 2

# Timeout per nameserver query
query_timeout_ms = 5000

# Enable parallel queries
parallel_queries = true

# Maximum concurrent queries
max_concurrent_queries = 10

[dns.root_zone]
# Strategy: "hints", "fetch", or "auth"
strategy = "hints"

# For "fetch" strategy:
fetch_url = "https://www.internic.net/domain/root.zone"
fetch_interval_hours = 24
fallback_to_hints = true

# For "auth" strategy:
zone_file = "/etc/yellowdog/zones/root.zone"

[dns.cache]
# Enable recursive cache
recursive_cache_enabled = true

# Maximum cache size (number of entries)
max_cache_size = 10000

# Minimum TTL for caching (prevent cache pollution)
min_cache_ttl = 60

# Maximum TTL for caching (prevent stale data)
max_cache_ttl = 86400

# Cache cleanup interval (seconds)
cleanup_interval_seconds = 300

[dns.views.default]
# Enable recursion for default view
recursion_enabled = true

[dns.views.internal]
# Disable recursion for internal view
recursion_enabled = false
```

### 6.2 Configuration Module Integration

```elixir
defmodule YellowDog.Config do
  # Add recursive resolver config helpers

  @spec recursion_enabled?() :: boolean()
  def recursion_enabled? do
    get(:dns, :recursion_enabled, true)
  end

  @spec get_recursion_config() :: map()
  def get_recursion_config do
    %{
      enabled: get(:dns, :recursion_enabled, true),
      timeout_ms: get(:dns, :recursion_timeout_ms, 10000),
      max_depth: get(:dns, :max_recursion_depth, 16),
      query_retries: get(:dns, :query_retries, 2),
      query_timeout_ms: get(:dns, :query_timeout_ms, 5000),
      parallel_queries: get(:dns, :parallel_queries, true),
      max_concurrent_queries: get(:dns, :max_concurrent_queries, 10)
    }
  end

  @spec get_root_zone_config() :: map()
  def get_root_zone_config do
    %{
      strategy: get(:dns, [:root_zone, :strategy], :hints),
      fetch_url: get(:dns, [:root_zone, :fetch_url], "https://www.internic.net/domain/root.zone"),
      fetch_interval_hours: get(:dns, [:root_zone, :fetch_interval_hours], 24),
      fallback_to_hints: get(:dns, [:root_zone, :fallback_to_hints], true),
      zone_file: get(:dns, [:root_zone, :zone_file])
    }
  end

  @spec get_cache_config() :: map()
  def get_cache_config do
    %{
      enabled: get(:dns, [:cache, :recursive_cache_enabled], true),
      max_size: get(:dns, [:cache, :max_cache_size], 10000),
      min_ttl: get(:dns, [:cache, :min_cache_ttl], 60),
      max_ttl: get(:dns, [:cache, :max_cache_ttl], 86400),
      cleanup_interval: get(:dns, [:cache, :cleanup_interval_seconds], 300)
    }
  end
end
```

---

## 7. Query Resolution Flow

### 7.1 Complete Resolution Flow Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                     DNS Query Arrives                           │
│                  (via Handler.UDP)                              │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│                     Check View                                  │
│              (View.match_view by client IP)                     │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│                 Check Recursive Cache                           │
│         (Cache.ResolverCache.lookup if enabled)                 │
└───────────┬─────────────────────────────────┬───────────────────┘
            │ CACHE HIT                       │ CACHE MISS
            ▼                                 ▼
    ┌───────────────┐              ┌──────────────────────────────┐
    │ Return Cached │              │ Continue Resolution          │
    │   Response    │              └──────────┬───────────────────┘
    └───────────────┘                         │
                                              ▼
                            ┌─────────────────────────────────────┐
                            │ Check Authoritative Zones           │
                            │  (Query.Resolver.resolve)           │
                            └─────┬─────────────────┬─────────────┘
                                  │ FOUND           │ NOT FOUND
                                  ▼                 ▼
                          ┌────────────────┐   ┌──────────────────┐
                          │ Authoritative  │   │ Check Forward    │
                          │    Answer      │   │     Zones        │
                          └────────────────┘   └────┬──────┬──────┘
                                                    │FOUND │NOT FOUND
                                                    ▼      ▼
                                            ┌──────────┐  ┌─────────────┐
                                            │ Forward  │  │  Recursion  │
                                            │  Answer  │  │   Enabled?  │
                                            └──────────┘  └──────┬──────┘
                                                                 │YES
                                                                 ▼
┌──────────────────────────────────────────────────────────────────────────┐
│                        START RECURSIVE RESOLUTION                        │
│                  (Query.Recursive.resolve)                               │
└───────────────────────────────────┬──────────────────────────────────────┘
                                    │
                                    ▼
                    ┌───────────────────────────────┐
                    │ Get Root Nameservers          │
                    │ (RootZone.Manager)            │
                    └───────────┬───────────────────┘
                                │
                                ▼
                    ┌───────────────────────────────┐
                    │ Initialize Resolution State   │
                    │ - depth = 0                   │
                    │ - referral_chain = []         │
                    │ - current_servers = roots     │
                    └───────────┬───────────────────┘
                                │
                ┌───────────────┴─────────────────────────┐
                │       ITERATION LOOP                    │
                │  (Query.Iterator.query_nameservers)     │
                └───────────────┬─────────────────────────┘
                                │
        ┌───────────────────────┼──────────────────────────┐
        │                       │                          │
        ▼                       ▼                          ▼
┌──────────────┐      ┌───────────────────┐      ┌────────────────┐
│  ANSWER      │      │    REFERRAL       │      │  NXDOMAIN /    │
│  SECTION     │      │    (NS records)   │      │   SERVFAIL     │
│  NON-EMPTY   │      │                   │      └────────────────┘
└──────┬───────┘      └─────────┬─────────┘
       │                        │
       ▼                        ▼
┌──────────────┐      ┌────────────────────────┐
│  Check for   │      │  Extract Glue Records  │
│    CNAME     │      │  from Additional Sec.  │
└──────┬───────┘      └─────────┬──────────────┘
       │YES                     │
       ▼                        ▼
┌──────────────┐      ┌────────────────────────┐
│ Follow CNAME │      │  Check Referral Loop   │
│ Chain (recur)│      │  (visited zones)       │
└──────────────┘      └─────────┬──────────────┘
                                │NO LOOP
                                ▼
                      ┌────────────────────────┐
                      │  Update State:         │
                      │  - depth++             │
                      │  - current_servers     │
                      │  - referral_chain      │
                      └─────────┬──────────────┘
                                │
                                ▼
                      ┌────────────────────────┐
                      │  Check Depth Limit     │
                      │  (depth < max_depth)   │
                      └─────────┬──────────────┘
                                │OK
                                ▼
                      ┌────────────────────────┐
                      │  CONTINUE ITERATION    │
                      │  (loop back)           │
                      └────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                    FINAL ANSWER                                 │
│            - Cache result (if successful)                       │
│            - Emit telemetry events                              │
│            - Return to Handler.UDP                              │
└─────────────────────────────────────────────────────────────────┘
```

### 7.2 Handler.UDP Integration

Update Handler.UDP to integrate recursive resolution:

```elixir
defmodule YellowDog.Dns.Handler.UDP do
  # In handle_not_found/4:

  defp handle_not_found(query, question, state, start_time) do
    # Check if recursion is enabled for this view
    case get_view_recursion_enabled(state) do
      true ->
        perform_recursive_resolution(query, question, state, start_time)

      false ->
        # Recursion not allowed, return REFUSED
        response = create_response(query, question, [], :refused)
        {response, state}
    end
  end

  defp perform_recursive_resolution(query, question, state, start_time) do
    Telemetry.span(
      "dns.recursive.resolve",
      %{name: question.name.value, type: to_string(question.type)},
      fn ->
        case YellowDog.Dns.Query.Recursive.resolve(
          question.name.value,
          question.type,
          timeout_ms: get_recursion_timeout(state)
        ) do
          {:ok, records} ->
            # Convert records to DNS.Message.Record format
            dns_records = convert_recursive_records(records)
            response = create_response(query, question, dns_records, :no_error)
            state = cache_response(response, question, state)

            :telemetry.execute(
              [:yellow_dog, :dns, :recursive_response],
              %{duration: System.monotonic_time(:microsecond) - start_time},
              %{name: question.name.value, type: to_string(question.type)}
            )

            {response, state}

          {:nxdomain, _} ->
            response = create_response(query, question, [], :nxdomain)
            {response, state}

          {:error, reason} ->
            Logger.warning("Recursive resolution failed", reason: inspect(reason))
            response = create_response(query, question, [], :servfail)
            {response, state}
        end
      end
    )
  end
end
```

---

## 8. Glue Record Handling

### 8.1 What Are Glue Records?

**Definition:**
Glue records are A or AAAA records in the additional section of a DNS response that provide IP addresses for nameservers listed in the authority section.

**Why Needed:**
When a nameserver for a zone is within that zone itself, a circular dependency exists. For example:

```
example.com NS ns1.example.com
example.com NS ns2.example.com
```

To resolve `www.example.com`, you need to query `ns1.example.com`, but to resolve `ns1.example.com`, you need to query the nameservers for `example.com` (which include `ns1.example.com` itself). This creates a circular dependency.

**Solution:**
The parent zone (`.com` in this case) provides glue records:

```
# Authority Section:
example.com.    IN NS  ns1.example.com.
example.com.    IN NS  ns2.example.com.

# Additional Section (Glue):
ns1.example.com. IN A   192.0.2.1
ns2.example.com. IN A   192.0.2.2
```

### 8.2 Glue Record Extraction

```elixir
defmodule YellowDog.Dns.Query.Iterator do

  @spec extract_glue_records([DNS.Message.Record.t()], [DNS.Message.Record.t()]) :: [glue_record()]
  defp extract_glue_records(ns_records, ar_records) do
    # For each NS record, find corresponding A/AAAA records in additional section

    ns_names = Enum.map(ns_records, & &1.rdata)

    ar_records
    |> Enum.filter(fn ar ->
      # Glue record must be A or AAAA type
      ar.type in [:A, :AAAA] &&
      # Glue record name must match one of the NS names
      ar.name.value in ns_names
    end)
    |> Enum.map(fn glue ->
      %{
        name: glue.name.value,
        type: glue.type,
        address: glue.rdata,
        ttl: glue.ttl
      }
    end)
  end

  @spec nameservers_from_glue([DNS.Message.Record.t()], [glue_record()]) :: [nameserver()]
  defp nameservers_from_glue(ns_records, glue_records) do
    Enum.flat_map(ns_records, fn ns ->
      ns_name = ns.rdata

      # Find glue for this NS
      glue_for_ns = Enum.filter(glue_records, & &1.name == ns_name)

      if Enum.empty?(glue_for_ns) do
        # No glue for this NS
        []
      else
        # Create nameserver entry for each glue address
        Enum.map(glue_for_ns, fn glue ->
          %{name: ns_name, address: glue.address}
        end)
      end
    end)
  end
end
```

### 8.3 Handling Missing Glue

When a referral has NS records but no glue records, we must perform "sidequery" resolution:

```elixir
defmodule YellowDog.Dns.Query.Recursive do

  defp resolve_nameserver_addresses(ns_records, parent_state) do
    # Create separate recursive queries for NS names

    ns_names = Enum.map(ns_records, & &1.rdata) |> Enum.uniq()

    Logger.debug("No glue records, resolving NS addresses: #{inspect(ns_names)}")

    # Prevent infinite recursion by limiting depth
    remaining_depth = parent_state.max_depth - parent_state.depth

    if remaining_depth <= 1 do
      {:error, :insufficient_depth_for_ns_resolution}
    else
      # Resolve each NS name
      results = Enum.map(ns_names, fn ns_name ->
        # Try A record first
        case resolve(ns_name, :A, max_depth: remaining_depth - 1) do
          {:ok, records} ->
            {:ok, Enum.map(records, fn r -> %{name: ns_name, address: r.rdata} end)}

          _ ->
            # Try AAAA if A fails
            case resolve(ns_name, :AAAA, max_depth: remaining_depth - 1) do
              {:ok, records} ->
                {:ok, Enum.map(records, fn r -> %{name: ns_name, address: r.rdata} end)}

              error -> error
            end
        end
      end)

      # Collect successful resolutions
      nameservers = Enum.flat_map(results, fn
        {:ok, ns_list} -> ns_list
        _ -> []
      end)

      if Enum.empty?(nameservers) do
        {:error, :no_glue_and_cannot_resolve_ns}
      else
        # Continue iteration with resolved NS addresses
        new_state = %{parent_state | depth: parent_state.depth + 1}
        resolve_iterative(nameservers, new_state)
      end
    end
  end
end
```

### 8.4 Glue Record Validation

```elixir
defmodule YellowDog.Dns.Query.Iterator do

  @spec validate_glue([glue_record()], String.t()) :: :ok | {:error, term()}
  defp validate_glue(glue_records, referral_zone) do
    # Validate that glue records are for nameservers within the referral zone

    Enum.reduce_while(glue_records, :ok, fn glue, _acc ->
      # Check if glue name is within referral zone
      if is_subdomain?(glue.name, referral_zone) do
        {:cont, :ok}
      else
        # Out-of-bailiwick glue (potentially malicious)
        Logger.warning("Out-of-bailiwick glue record detected",
          glue: glue.name, zone: referral_zone)

        # Continue but log warning (don't fail)
        {:cont, :ok}
      end
    end)
  end

  defp is_subdomain?(name, zone) do
    normalized_name = String.downcase(name) |> String.trim_trailing(".")
    normalized_zone = String.downcase(zone) |> String.trim_trailing(".")

    normalized_name == normalized_zone ||
      String.ends_with?(normalized_name, "." <> normalized_zone)
  end
end
```

---

## 9. Integration with Existing Modules

### 9.1 Query.Resolver Integration

Update `Query.Resolver` to call recursive resolver when appropriate:

```elixir
defmodule YellowDog.Dns.Query.Resolver do

  defp do_resolve(zone_name, owner, qtype) do
    unless Storage.zone_exists?(zone_name) do
      # Zone not found locally
      # Check if recursion is enabled
      if YellowDog.Config.recursion_enabled?() do
        # Use recursive resolution
        case YellowDog.Dns.Query.Recursive.resolve(owner, qtype) do
          {:ok, records} ->
            # Convert to resolver format
            {:ok, records, []}

          {:nxdomain, _} ->
            {:nxdomain, [], []}

          {:error, _} ->
            {:servfail, [], []}
        end
      else
        # Recursion disabled, return SERVFAIL
        {:servfail, [], []}
      end
    else
      # Zone exists, use existing authoritative/forward logic
      case Storage.get_zone_metadata(zone_name) do
        {:ok, %{type: :forward} = metadata} ->
          resolve_forward(zone_name, owner, qtype, metadata)

        {:ok, _metadata} ->
          resolve_authoritative(zone_name, owner, qtype)

        {:error, _} ->
          {:servfail, [], []}
      end
    end
  end
end
```

### 9.2 View Integration

Update `View` struct to include `recursion_enabled` field:

```elixir
defmodule YellowDog.Dns.View do
  defstruct [:name, :match_clients, :zones, :recursion_enabled, :recursion_config]

  @type t :: %__MODULE__{
    name: String.t(),
    match_clients: :all | list(),
    zones: list(),
    recursion_enabled: boolean(),
    recursion_config: map() | nil
  }

  @spec default() :: t()
  def default do
    %__MODULE__{
      name: "default",
      match_clients: :all,
      zones: [],
      recursion_enabled: true,
      recursion_config: YellowDog.Config.get_recursion_config()
    }
  end

  @spec recursion_allowed?(t()) :: boolean()
  def recursion_allowed?(view) do
    view.recursion_enabled
  end
end
```

### 9.3 Supervisor Integration

Add recursive resolver components to DNS supervisor:

```elixir
defmodule YellowDog.Dns.Supervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      # Existing children
      {YellowDog.Dns.Zone.Manager, []},
      {YellowDog.Dns.Server, []},

      # New recursive resolver components
      {YellowDog.Dns.RootZone.Manager, []},
      {YellowDog.Dns.Cache.ResolverCache, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

### 9.4 Zone.Storage Integration

Ensure Zone.Storage can handle root zone (zone name "."):

```elixir
defmodule YellowDog.Dns.Zone.Storage do

  # Root zone special handling
  defp normalize_zone("."), do: "."
  defp normalize_zone(zone_name) when is_binary(zone_name) do
    zone_name
    |> String.downcase()
    |> String.trim_trailing(".")
  end

  # Allow querying root zone
  def zone_exists?("."), do: root_zone_loaded?()
  def zone_exists?(zone_name), do: # ... existing code

  defp root_zone_loaded? do
    :ets.member(@zone_metadata_table, ".")
  end
end
```

---

## 10. Error Handling

### 10.1 Error Types

```elixir
@type recursive_error ::
  {:error, :max_depth_exceeded}
  | {:error, :timeout}
  | {:error, :referral_loop}
  | {:error, :all_nameservers_failed}
  | {:error, :no_root_servers}
  | {:error, :no_glue_and_cannot_resolve_ns}
  | {:error, :invalid_referral}
  | {:error, {:rcode, String.t()}}
  | {:error, term()}
```

### 10.2 Error Handling Strategy

```elixir
defmodule YellowDog.Dns.Query.Recursive do

  defp handle_resolution_error(error, state) do
    case error do
      {:error, :max_depth_exceeded} ->
        Logger.warning("Recursive resolution exceeded max depth",
          depth: state.depth,
          max_depth: state.max_depth,
          query: state.query_name
        )

        :telemetry.execute(
          [:yellow_dog, :dns, :recursive_error],
          %{count: 1},
          %{error: :max_depth_exceeded, query: state.query_name}
        )

        {:servfail, []}

      {:error, :timeout} ->
        Logger.warning("Recursive resolution timeout",
          query: state.query_name,
          elapsed: System.monotonic_time(:millisecond) - state.start_time
        )

        :telemetry.execute(
          [:yellow_dog, :dns, :recursive_error],
          %{count: 1},
          %{error: :timeout, query: state.query_name}
        )

        {:servfail, []}

      {:error, :referral_loop} ->
        Logger.error("Referral loop detected",
          query: state.query_name,
          referral_chain: state.referral_chain
        )

        :telemetry.execute(
          [:yellow_dog, :dns, :recursive_error],
          %{count: 1},
          %{error: :referral_loop, query: state.query_name}
        )

        {:servfail, []}

      {:error, :all_nameservers_failed} ->
        Logger.warning("All nameservers failed for query",
          query: state.query_name,
          depth: state.depth
        )

        {:servfail, []}

      {:error, :no_glue_and_cannot_resolve_ns} ->
        Logger.error("Cannot resolve nameserver addresses (no glue)",
          query: state.query_name
        )

        {:servfail, []}

      {:error, {:rcode, rcode}} when rcode == "NXDOMAIN" ->
        {:nxdomain, []}

      {:error, {:rcode, rcode}} ->
        Logger.warning("Received error RCODE from nameserver",
          rcode: rcode,
          query: state.query_name
        )

        {:servfail, []}

      {:error, reason} ->
        Logger.error("Recursive resolution error",
          reason: inspect(reason),
          query: state.query_name
        )

        {:servfail, []}
    end
  end
end
```

### 10.3 Telemetry Events

```elixir
# Success events
:telemetry.execute(
  [:yellow_dog, :dns, :recursive_start],
  %{timestamp: System.monotonic_time()},
  %{query_name: query_name, query_type: query_type}
)

:telemetry.execute(
  [:yellow_dog, :dns, :recursive_iteration],
  %{depth: depth},
  %{query_name: query_name, referral_zone: zone}
)

:telemetry.execute(
  [:yellow_dog, :dns, :recursive_complete],
  %{duration: duration, iterations: depth},
  %{query_name: query_name, result: :ok}
)

# Error events
:telemetry.execute(
  [:yellow_dog, :dns, :recursive_error],
  %{count: 1},
  %{error: error_type, query_name: query_name}
)

# Cache events
:telemetry.execute(
  [:yellow_dog, :dns, :recursive_cache_hit],
  %{ttl: remaining_ttl},
  %{query_name: query_name, query_type: query_type}
)

:telemetry.execute(
  [:yellow_dog, :dns, :recursive_cache_miss],
  %{count: 1},
  %{query_name: query_name, query_type: query_type}
)

# Nameserver query events
:telemetry.execute(
  [:yellow_dog, :dns, :nameserver_query],
  %{duration: duration},
  %{nameserver: ns_ip, result: :success}
)

:telemetry.execute(
  [:yellow_dog, :dns, :nameserver_query_failed],
  %{count: 1},
  %{nameserver: ns_ip, reason: reason}
)
```

---

## 11. Performance Optimizations

### 11.1 Caching Strategy

**Multi-Level Caching:**

1. **Answer Cache**: Cache final answers with TTL
2. **NS Cache**: Cache NS records and glue to avoid repeated queries
3. **Negative Cache**: Cache NXDOMAIN responses (with shorter TTL)

**Implementation:**

```elixir
defmodule YellowDog.Dns.Cache.ResolverCache do
  use GenServer

  @table_name :dns_recursive_cache

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    config = YellowDog.Config.get_cache_config()

    # Create ETS table
    :ets.new(@table_name, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    # Schedule periodic cleanup
    schedule_cleanup(config.cleanup_interval * 1000)

    state = %{
      config: config,
      stats: %{
        hits: 0,
        misses: 0,
        inserts: 0,
        evictions: 0
      }
    }

    {:ok, state}
  end

  # Public API

  @spec lookup(String.t(), atom()) :: {:hit, [record()], non_neg_integer()} | :miss
  def lookup(query_name, query_type) do
    key = cache_key(query_name, query_type)

    case :ets.lookup(@table_name, key) do
      [{^key, entry}] ->
        if Cache.Entry.expired?(entry) do
          # Expired, delete and return miss
          :ets.delete(@table_name, key)
          :miss
        else
          # Valid entry
          remaining_ttl = Cache.Entry.remaining_ttl(entry)
          {:hit, entry.records, remaining_ttl}
        end

      [] ->
        :miss
    end
  end

  @spec insert(String.t(), atom(), [record()], non_neg_integer()) :: :ok
  def insert(query_name, query_type, records, ttl) do
    config = YellowDog.Config.get_cache_config()

    # Clamp TTL to configured min/max
    clamped_ttl = clamp_ttl(ttl, config.min_ttl, config.max_ttl)

    entry = Cache.Entry.new(query_name, query_type, records, clamped_ttl)
    key = cache_key(query_name, query_type)

    :ets.insert(@table_name, {key, entry})
    :ok
  end

  defp cache_key(query_name, query_type) do
    normalized_name = String.downcase(query_name) |> String.trim_trailing(".")
    {normalized_name, query_type}
  end

  defp clamp_ttl(ttl, min_ttl, max_ttl) do
    ttl
    |> max(min_ttl)
    |> min(max_ttl)
  end

  # Cleanup process

  @impl true
  def handle_info(:cleanup, state) do
    # Delete expired entries
    now = System.system_time(:second)

    expired_count = :ets.select_delete(@table_name, [
      {
        {:_, %{expires_at: :"$1"}},
        [{:<, :"$1", now}],
        [true]
      }
    ])

    if expired_count > 0 do
      Logger.debug("Cleaned up #{expired_count} expired cache entries")
    end

    # Schedule next cleanup
    schedule_cleanup(state.config.cleanup_interval * 1000)

    {:noreply, state}
  end

  defp schedule_cleanup(interval_ms) do
    Process.send_after(self(), :cleanup, interval_ms)
  end
end
```

### 11.2 Parallel Queries

**Strategy:**
Query multiple nameservers in parallel using `Task.async_stream`, take first successful response.

**Benefits:**
- Reduced latency (fastest server wins)
- Fault tolerance (continue if some servers fail)
- Better resource utilization

**Implementation:**
```elixir
defp query_parallel(nameservers, query_data, timeout_ms) do
  nameservers
  |> Task.async_stream(
    fn ns ->
      query_single_nameserver(ns.address, 53, query_data, timeout_ms)
    end,
    timeout: timeout_ms,
    on_timeout: :kill_task,
    max_concurrency: min(length(nameservers), 10),
    ordered: false  # Don't care about order, just want first success
  )
  |> Enum.find_value(fn
    {:ok, {:ok, response}} -> {:ok, response}
    _ -> nil
  end)
  |> case do
    nil -> {:error, :all_nameservers_failed}
    result -> result
  end
end
```

### 11.3 Connection Pooling

**Strategy:**
Reuse UDP sockets for multiple queries to reduce socket creation overhead.

**Implementation:**
```elixir
defmodule YellowDog.Dns.Query.SocketPool do
  use GenServer

  @pool_size 10

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Create pool of UDP sockets
    sockets = Enum.map(1..@pool_size, fn _ ->
      {:ok, socket} = :gen_udp.open(0, [:binary, active: false])
      socket
    end)

    state = %{
      sockets: :queue.from_list(sockets),
      checked_out: MapSet.new()
    }

    {:ok, state}
  end

  def checkout do
    GenServer.call(__MODULE__, :checkout)
  end

  def checkin(socket) do
    GenServer.cast(__MODULE__, {:checkin, socket})
  end

  @impl true
  def handle_call(:checkout, _from, state) do
    case :queue.out(state.sockets) do
      {{:value, socket}, new_queue} ->
        new_state = %{
          state
          | sockets: new_queue,
            checked_out: MapSet.put(state.checked_out, socket)
        }

        {:reply, {:ok, socket}, new_state}

      {:empty, _} ->
        # Pool exhausted, create temporary socket
        {:ok, socket} = :gen_udp.open(0, [:binary, active: false])
        {:reply, {:ok, socket}, state}
    end
  end

  @impl true
  def handle_cast({:checkin, socket}, state) do
    if MapSet.member?(state.checked_out, socket) do
      # Return to pool
      new_state = %{
        state
        | sockets: :queue.in(socket, state.sockets),
          checked_out: MapSet.delete(state.checked_out, socket)
      }

      {:noreply, new_state}
    else
      # Not from pool, close it
      :gen_udp.close(socket)
      {:noreply, state}
    end
  end
end
```

### 11.4 Query Pipelining

**Strategy:**
Pipeline multiple queries in the same iteration (e.g., query A and AAAA simultaneously).

### 11.5 Prefetching

**Strategy:**
Proactively refresh cache entries before they expire based on access patterns.

---

## 12. Security Considerations

### 12.1 Query ID Randomization

**Issue:**
Predictable query IDs enable cache poisoning attacks.

**Solution:**
```elixir
defp create_query_message(query_name, query_type) do
  %DNS.Message{
    header: %DNS.Message.Header{
      id: :crypto.strong_rand_bytes(2) |> :binary.decode_unsigned(),
      # ... rest of header
    },
    # ... rest of message
  }
end
```

### 12.2 Source Port Randomization

**Issue:**
Predictable source ports enable cache poisoning.

**Solution:**
Use ephemeral ports (automatically assigned by `:gen_udp.open(0, ...)`)

### 12.3 Response Validation

**Issue:**
Malicious responses can poison cache.

**Solution:**
```elixir
defp validate_response(response, query_message) do
  # Check query ID matches
  unless response.header.id == query_message.header.id do
    {:error, :query_id_mismatch}
  else
    # Check question section matches
    if response.header.qdcount > 0 and length(response.qdlist) > 0 do
      response_question = List.first(response.qdlist)
      query_question = List.first(query_message.qdlist)

      if response_question.name != query_question.name ||
         response_question.type != query_question.type do
        {:error, :question_mismatch}
      else
        :ok
      end
    else
      :ok
    end
  end
end
```

### 12.4 Rate Limiting

**Issue:**
Recursive queries can be used for amplification attacks.

**Solution:**
```elixir
defmodule YellowDog.Dns.Query.RateLimiter do
  use GenServer

  @max_queries_per_second 100

  def check_rate_limit(client_ip) do
    GenServer.call(__MODULE__, {:check, client_ip})
  end

  @impl true
  def handle_call({:check, client_ip}, _from, state) do
    now = System.system_time(:second)

    # Get current count for this client
    key = {client_ip, now}
    count = Map.get(state.counts, key, 0)

    if count >= @max_queries_per_second do
      {:reply, {:error, :rate_limited}, state}
    else
      # Increment count
      new_counts = Map.put(state.counts, key, count + 1)
      {:reply, :ok, %{state | counts: new_counts}}
    end
  end
end
```

### 12.5 Referral Validation

**Issue:**
Malicious referrals can lead to out-of-bailiwick attacks.

**Solution:**
```elixir
defp validate_referral(ns_records, current_zone, query_name) do
  # Check that referral is "closer" to query name
  # Referral zone should be a parent of query name

  Enum.reduce_while(ns_records, :ok, fn ns, _acc ->
    # Extract zone from NS record name
    ns_zone = ns.name.value

    # Check if ns_zone is between current_zone and query_name
    if is_valid_referral_progression?(current_zone, ns_zone, query_name) do
      {:cont, :ok}
    else
      Logger.warning("Invalid referral progression",
        current: current_zone,
        referral: ns_zone,
        query: query_name
      )

      {:halt, {:error, :invalid_referral}}
    end
  end)
end

defp is_valid_referral_progression?(current_zone, referral_zone, query_name) do
  # Normalize names
  current = normalize_name(current_zone)
  referral = normalize_name(referral_zone)
  query = normalize_name(query_name)

  # Referral should be:
  # 1. More specific than current zone (longer or equal)
  # 2. Less specific than or equal to query name

  is_subdomain_or_equal?(referral, current) &&
    is_subdomain_or_equal?(query, referral)
end
```

### 12.6 DNSSEC Validation (Future)

**Plan:**
Implement DNSSEC validation in Phase 2 to ensure authenticity of DNS responses.

---

## 13. Test Strategy

### 13.1 Unit Tests

```elixir
defmodule YellowDog.Dns.Query.RecursiveTest do
  use ExUnit.Case, async: false

  describe "resolve/3" do
    test "resolves A record from root" do
      # Mock root zone manager
      {:ok, records} = Recursive.resolve("example.com", :A)

      assert length(records) > 0
      assert Enum.all?(records, & &1.type == :A)
    end

    test "follows CNAME chain" do
      # Test CNAME following in recursive context
    end

    test "handles NXDOMAIN" do
      assert {:nxdomain, []} = Recursive.resolve("nonexistent.example.com", :A)
    end

    test "respects max depth" do
      assert {:error, :max_depth_exceeded} =
        Recursive.resolve("deeply.nested.example.com", :A, max_depth: 2)
    end

    test "detects referral loops" do
      # Test with mocked circular referral
    end

    test "handles timeout" do
      assert {:error, :timeout} =
        Recursive.resolve("slow.example.com", :A, timeout_ms: 100)
    end
  end
end

defmodule YellowDog.Dns.Query.IteratorTest do
  use ExUnit.Case

  describe "query_nameservers/4" do
    test "returns answer from nameserver" do
      # Mock nameserver response
    end

    test "returns referral with glue" do
      # Mock referral response
    end

    test "handles parallel queries" do
      # Test that fastest server wins
    end

    test "handles all nameservers failing" do
      assert {:error, :all_nameservers_failed} =
        Iterator.query_nameservers([], "example.com", :A)
    end
  end

  describe "extract_glue_records/2" do
    test "extracts A glue records" do
      # Test glue extraction
    end

    test "extracts AAAA glue records" do
      # Test IPv6 glue
    end

    test "handles missing glue" do
      # Test when no glue present
    end
  end
end

defmodule YellowDog.Dns.RootZone.ManagerTest do
  use ExUnit.Case, async: false

  describe "get_root_nameservers/0" do
    test "returns root servers with hints strategy" do
      {:ok, servers} = RootZone.Manager.get_root_nameservers()

      assert length(servers) == 13
      assert Enum.all?(servers, & Map.has_key?(&1, :name))
      assert Enum.all?(servers, & Map.has_key?(&1, :addresses))
    end
  end

  describe "strategy switching" do
    test "switches from hints to fetch" do
      # Test strategy change
    end

    test "falls back to hints on fetch failure" do
      # Test fallback mechanism
    end
  end
end

defmodule YellowDog.Dns.Cache.ResolverCacheTest do
  use ExUnit.Case, async: false

  describe "lookup/2" do
    test "returns cached entry" do
      ResolverCache.insert("example.com", :A, [mock_record()], 300)

      assert {:hit, records, ttl} = ResolverCache.lookup("example.com", :A)
      assert length(records) > 0
      assert ttl <= 300
    end

    test "returns miss for uncached query" do
      assert :miss = ResolverCache.lookup("uncached.example.com", :A)
    end

    test "returns miss for expired entry" do
      # Insert with very short TTL
      ResolverCache.insert("example.com", :A, [mock_record()], 1)

      # Wait for expiration
      Process.sleep(1100)

      assert :miss = ResolverCache.lookup("example.com", :A)
    end
  end

  describe "cleanup" do
    test "removes expired entries periodically" do
      # Test periodic cleanup
    end
  end
end
```

### 13.2 Integration Tests

```elixir
defmodule YellowDog.Dns.RecursiveIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  setup do
    # Start all required services
    {:ok, _} = YellowDog.Dns.Supervisor.start_link([])
    :ok
  end

  test "end-to-end recursive resolution" do
    # Real query to public DNS
    {:ok, records} = Recursive.resolve("example.com", :A)

    assert length(records) > 0
    assert Enum.all?(records, & &1.type == :A)
  end

  test "recursive resolution through Handler.UDP" do
    # Create mock UDP query
    query = create_dns_query("example.com", :A)

    # Send to handler
    {response, _state} = Handler.UDP.handle_data(
      {{127, 0, 0, 1}, 12345, query},
      initial_state()
    )

    assert response.header.ancount > 0
  end
end
```

### 13.3 Load Tests

```elixir
defmodule YellowDog.Dns.RecursiveLoadTest do
  use ExUnit.Case

  @moduletag :load
  @moduletag timeout: 60_000

  test "handles 1000 concurrent queries" do
    queries = Enum.map(1..1000, fn i ->
      Task.async(fn ->
        Recursive.resolve("test#{i}.example.com", :A)
      end)
    end)

    results = Task.await_many(queries, 30_000)

    success_count = Enum.count(results, fn
      {:ok, _} -> true
      _ -> false
    end)

    # At least 95% success rate
    assert success_count >= 950
  end
end
```

### 13.4 Mock Nameserver

```elixir
defmodule YellowDog.Dns.Test.MockNameserver do
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, 15353)
    responses = Keyword.get(opts, :responses, %{})

    {:ok, socket} = :gen_udp.open(port, [:binary, active: true])

    {:ok, %{socket: socket, responses: responses}}
  end

  @impl true
  def handle_info({:udp, socket, client_ip, client_port, data}, state) do
    query = DNS.Message.from_iodata(data)

    # Look up canned response
    key = {List.first(query.qdlist).name.value, List.first(query.qdlist).type}

    response = case Map.get(state.responses, key) do
      nil -> create_nxdomain_response(query)
      records -> create_response(query, records)
    end

    response_data = DNS.Parameter.to_iodata(response)
    :gen_udp.send(socket, client_ip, client_port, response_data)

    {:noreply, state}
  end
end
```

---

## 14. Implementation Phases

### Phase 1: Foundation (Week 1-2)

**Goal:** Establish core recursive infrastructure

**Tasks:**
1. Implement `YellowDog.Dns.RootZone.Hints` with embedded root servers
2. Implement `YellowDog.Dns.RootZone.Manager` with hints strategy only
3. Implement `YellowDog.Dns.Cache.Entry` data structure
4. Implement `YellowDog.Dns.Cache.ResolverCache` basic functionality
5. Add supervisor integration
6. Unit tests for all modules

**Deliverables:**
- Root zone hints working
- Cache module functional
- All unit tests passing

**Success Criteria:**
- Can retrieve root servers from RootZone.Manager
- Can cache and retrieve DNS records
- Test coverage > 80%

### Phase 2: Iterator (Week 3-4)

**Goal:** Implement single-iteration query logic

**Tasks:**
1. Implement `YellowDog.Dns.Query.Iterator` module
2. Implement parallel nameserver queries
3. Implement response parsing (answer vs referral)
4. Implement glue record extraction
5. Unit tests for iterator
6. Integration tests with mock nameservers

**Deliverables:**
- Iterator module complete
- Can query nameservers in parallel
- Can parse referrals with glue

**Success Criteria:**
- Iterator tests passing
- Successfully queries mock nameservers
- Correctly identifies answers vs referrals

### Phase 3: Recursive Resolver (Week 5-6)

**Goal:** Implement full recursive resolution

**Tasks:**
1. Implement `YellowDog.Dns.Query.Recursive` module
2. Implement iterative resolution loop
3. Implement referral chain tracking
4. Implement loop detection
5. Implement depth limiting
6. Implement timeout handling
7. Implement sidequery for missing glue
8. Unit tests for recursive resolver
9. End-to-end integration tests

**Deliverables:**
- Recursive resolver complete
- Full iterative resolution working
- All error cases handled

**Success Criteria:**
- Can resolve real domain names from root
- Handles CNAME chains
- Detects and prevents loops
- Respects timeouts and depth limits
- Integration tests passing

### Phase 4: Advanced Features (Week 7-8)

**Goal:** Add fetch/auth strategies and optimizations

**Tasks:**
1. Implement `YellowDog.Dns.RootZone.Fetcher` for IANA fetch strategy
2. Implement auth strategy for local root zone
3. Implement advanced caching (NS cache, negative cache)
4. Implement connection pooling
5. Implement rate limiting
6. Performance testing and optimization
7. Load testing

**Deliverables:**
- All three root zone strategies working
- Performance optimizations applied
- Load tests passing

**Success Criteria:**
- Can switch between root zone strategies
- Handles 1000+ concurrent queries
- Cache hit rate > 50% in typical usage
- Latency < 100ms for cached queries

### Phase 5: Handler Integration (Week 9)

**Goal:** Integrate with Handler.UDP and enable recursion

**Tasks:**
1. Update `Handler.UDP` to call recursive resolver
2. Update `Query.Resolver` integration
3. Update `View` struct for per-view recursion control
4. Add configuration loading
5. Update telemetry events
6. End-to-end system tests

**Deliverables:**
- Full system integration
- Configuration working
- Telemetry events emitting

**Success Criteria:**
- Handler.UDP uses recursive resolver when appropriate
- Per-view recursion control working
- All telemetry events present
- System tests passing

### Phase 6: Security & Polish (Week 10)

**Goal:** Security hardening and production readiness

**Tasks:**
1. Implement query ID randomization
2. Implement response validation
3. Implement referral validation
4. Implement rate limiting
5. Security audit
6. Documentation
7. Performance benchmarks

**Deliverables:**
- Security features implemented
- Documentation complete
- Benchmarks published

**Success Criteria:**
- No known security vulnerabilities
- Documentation covers all features
- Performance benchmarks meet targets

---

## 15. Potential Issues and Mitigations

### Issue 1: Root Server Availability

**Problem:**
All root servers unreachable due to network issues.

**Mitigation:**
- Implement exponential backoff
- Cache last successful root server list
- Fallback to hints if fetch fails
- Log and alert on root server failures

### Issue 2: DNS Amplification Attacks

**Problem:**
Recursive resolver used for DDoS amplification.

**Mitigation:**
- Implement per-client rate limiting
- Restrict recursion to trusted clients (ACLs)
- Implement response rate limiting (RRL)
- Monitor for unusual query patterns

### Issue 3: Cache Poisoning

**Problem:**
Malicious responses poison cache.

**Mitigation:**
- Query ID randomization (strong random)
- Source port randomization
- Response validation (ID, question match)
- Referral validation (bailiwick checking)
- DNSSEC validation (future)

### Issue 4: Referral Loops

**Problem:**
Circular referrals cause infinite loops.

**Mitigation:**
- Track visited zones in referral chain
- Implement max depth limit
- Detect duplicate referrals
- Timeout per query

### Issue 5: Missing Glue Records

**Problem:**
Cannot resolve NS names due to missing glue.

**Mitigation:**
- Implement sidequery resolution
- Reserve depth budget for sidequeries
- Cache NS resolutions
- Fallback to public resolvers if configured

### Issue 6: Memory Exhaustion

**Problem:**
Large cache consumes excessive memory.

**Mitigation:**
- Implement max cache size
- Periodic cache cleanup
- LRU eviction policy
- TTL-based expiration
- Monitor cache statistics

### Issue 7: Slow Nameservers

**Problem:**
Slow/unresponsive nameservers delay resolution.

**Mitigation:**
- Parallel queries with first-wins strategy
- Per-server timeout (2-5s)
- Overall query timeout (10s)
- Retry with different nameservers
- Cache successful servers

### Issue 8: IPv6 Glue Handling

**Problem:**
AAAA glue records increase complexity.

**Mitigation:**
- Support both A and AAAA glue
- Try IPv4 first, fallback to IPv6
- Make IPv6 support configurable
- Test dual-stack scenarios

### Issue 9: CNAME Chains in Recursive Context

**Problem:**
CNAME chains across zones complicate resolution.

**Mitigation:**
- Follow CNAMEs recursively
- Implement max CNAME depth (10)
- Cache intermediate CNAMEs
- Handle CNAME loops

### Issue 10: Test Environment Setup

**Problem:**
Testing recursive resolver requires complex mocking.

**Mitigation:**
- Implement mock nameserver framework
- Use recorded real-world responses
- Create synthetic test scenarios
- Document test setup procedures
- CI/CD integration with test helpers

---

## Appendix A: Example Resolution Trace

### Query: www.example.com A

```
Step 1: Query Root Servers
├─ Send: www.example.com A to 198.41.0.4 (a.root-servers.net)
├─ Receive: Referral to .com nameservers
│  ├─ NS: a.gtld-servers.net
│  ├─ NS: b.gtld-servers.net
│  ├─ Glue: a.gtld-servers.net A 192.5.6.30
│  └─ Glue: b.gtld-servers.net A 192.33.14.30
└─ Cache: .com NS records (TTL: 172800)

Step 2: Query .com Nameservers
├─ Send: www.example.com A to 192.5.6.30 (a.gtld-servers.net)
├─ Receive: Referral to example.com nameservers
│  ├─ NS: ns1.example.com
│  ├─ NS: ns2.example.com
│  ├─ Glue: ns1.example.com A 192.0.2.1
│  └─ Glue: ns2.example.com A 192.0.2.2
└─ Cache: example.com NS records (TTL: 86400)

Step 3: Query example.com Nameservers
├─ Send: www.example.com A to 192.0.2.1 (ns1.example.com)
├─ Receive: Answer
│  └─ A: www.example.com A 192.0.2.100 (TTL: 300)
└─ Cache: www.example.com A (TTL: 300)

Result: 192.0.2.100
Iterations: 3
Duration: 156ms
```

---

## Appendix B: Configuration Examples

### Example 1: Standard Public Recursive Resolver

```toml
[dns]
recursion_enabled = true
recursion_timeout_ms = 10000
max_recursion_depth = 16

[dns.root_zone]
strategy = "hints"

[dns.cache]
recursive_cache_enabled = true
max_cache_size = 10000
min_cache_ttl = 60
max_cache_ttl = 86400
```

### Example 2: Enterprise with Periodic Root Zone Fetch

```toml
[dns]
recursion_enabled = true

[dns.root_zone]
strategy = "fetch"
fetch_interval_hours = 24
fallback_to_hints = true

[dns.cache]
recursive_cache_enabled = true
max_cache_size = 50000
```

### Example 3: Air-Gapped Environment with Local Root

```toml
[dns]
recursion_enabled = true

[dns.root_zone]
strategy = "auth"
zone_file = "/var/lib/yellowdog/zones/root.zone"
```

### Example 4: Split-Horizon DNS with Per-View Recursion

```toml
[dns.views.internal]
recursion_enabled = false  # Internal clients: authoritative only

[dns.views.external]
recursion_enabled = true   # External clients: full recursion

[dns.views.dmz]
recursion_enabled = false  # DMZ: no recursion
```

---

## Appendix C: References

### RFCs
- **RFC 1034** - Domain Names - Concepts and Facilities
- **RFC 1035** - Domain Names - Implementation and Specification
- **RFC 2181** - Clarifications to the DNS Specification
- **RFC 4592** - The Role of Wildcards in the DNS
- **RFC 5452** - Measures for Making DNS More Resilient against Forged Answers
- **RFC 7873** - Domain Name System (DNS) Cookies
- **RFC 8198** - Aggressive Use of DNSSEC-Validated Cache

### Implementation References
- BIND9 recursive resolver implementation
- Unbound recursive resolver
- PowerDNS Recursor
- Elixir ex_dns library recursive stub

### Tools
- `dnsperf` - DNS performance testing
- `dig` - DNS query tool
- `drill` - DNS query tool (DNSSEC-aware)
- `named-checkzone` - Zone file validation

---

## Document Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2025-10-29 | Design Doc | Initial comprehensive design |

---

**END OF DOCUMENT**
