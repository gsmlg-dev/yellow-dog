defmodule DNS do
  @moduledoc """
  Pure Elixir DNS library for protocol message parsing and resource record handling.

  This library provides comprehensive DNS protocol implementation including message parsing,
  resource record handling, zone management, and DNSSEC support.

  ## Architecture

  All DNS related modules are namespaced under this module. DNS resources implement
  two key protocols for consistent behavior:

  ### Protocols

  * `String.Chars` - Provides human-readable string representations of DNS entities
  * `DNS.Parameter` - Handles binary serialization for DNS protocol data

  ### Core Components

  * `DNS.Message` - DNS message parsing and construction
    * `DNS.Message.Header` - Message header with flags and counts
    * `DNS.Message.Question` - Query section handling
    * `DNS.Message.Record` - Resource record management
    * `DNS.Message.Domain` - Domain name parsing with compression support
    * `DNS.Message.EDNS0` - Extension mechanisms

  * `DNS.Zone` - Zone management operations
    * `DNS.Zone.Manager` - CRUD operations and lifecycle management
    * `DNS.Zone.Store` - ETS-based persistent storage
    * `DNS.Zone.Cache` - TTL-based caching with expiration
    * `DNS.Zone.Loader` - Zone file loading from various sources

  ## Usage Examples

  ### Creating Resource Records

      iex> a_record = DNS.Message.Record.Data.A.new({192, 168, 1, 1})
      iex> to_string(a_record)
      "192.168.1.1"

  ### Zone Management

      iex> zone = DNS.Zone.new("example.com", :authoritative)
      iex> zone.name
      #DNS.Zone.Name<example.com>

  ## Security Features

  The library includes comprehensive security protections:

  * DNS compression loop attack prevention
  * Input validation bounds checking
  * Path traversal protection
  * Centralized error handling
  * ETS table security

  ## Performance

  * Optimized ETS queries for zone operations
  * Efficient binary pattern matching for DNS parsing
  * Concurrent access support with read_concurrency
  * Memory-efficient zone storage

  """

  @doc """
  Convert a DNS entity to binary iodata using the DNS.Parameter protocol.

  This is a convenience function that delegates to `DNS.Parameter.to_iodata/1`.

  ## Parameters

  * `value` - Any DNS entity that implements the DNS.Parameter protocol

  ## Returns

  * `iodata()` - Binary representation suitable for network transmission

  ## Examples

      iex> DNS.to_iodata("example.com")
      <<7, 101, 120, 97, 109, 112, 108, 101, 3, 99, 111, 109, 0>>

      iex> record = DNS.Message.Record.Data.A.new({192, 168, 1, 1})
      iex> DNS.to_iodata(record)
      <<0, 4, 192, 168, 1, 1>>
  """
  @spec to_iodata(term()) :: iodata()
  def to_iodata(value) do
    DNS.Parameter.to_iodata(value)
  end
end
