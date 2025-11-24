defmodule DHCP do
  @moduledoc """
  Dynamic Host Configuration Protocol (DHCP) implementation in pure Elixir.

  This module provides the main entry point for DHCP operations and serves
  as a unified interface for both DHCPv4 and DHCPv6 protocol implementations.

  ## Features

  - Complete DHCPv4 implementation based on [RFC 2131](https://datatracker.ietf.org/doc/html/rfc2131)
  - Complete DHCPv6 implementation based on [RFC 3315](https://datatracker.ietf.org/doc/html/rfc3315)
  - Support for all standard DHCP options from RFC 2132
  - Type-safe message parsing and serialization
  - Cryptographically secure random number generation
  - Pure Elixir implementation with no external dependencies

  ## Architecture

  The library is organized into the following main components:

  ### DHCPv4 (IPv4)
  - `DHCPv4.Message` - DHCPv4 message structure and parsing
  - `DHCPv4.Message.Option` - DHCPv4 options handling
  - `DHCPv4.Server` - DHCPv4 server implementation
  - `DHCPv4.Client` - DHCPv4 client utilities for testing

  ### DHCPv6 (IPv6)
  - `DHCPv6.Message` - DHCPv6 message structure and parsing
  - `DHCPv6.Message.Option` - DHCPv6 options handling
  - `DHCPv6.Server` - DHCPv6 server implementation
  - `DHCPv6.Client` - DHCPv6 client utilities for testing

  ### Shared Components
  - `DHCP.Parameter` - Protocol for binary serialization
  - `DHCP.SecureRandom` - Cryptographically secure random number generation

  ## Quick Start

  ### Parsing a DHCPv4 Message

      iex> message_data = <<99, 130, 83, 99, 53, 1, 1, 1, 4, 255, 255, 255, 0, 255>>
      iex> {:ok, message} = DHCPv4.Message.from_iodata(message_data)
      iex> message.msg_type
      1  # DHCPDISCOVER

  ### Creating a DHCPv4 Message

      iex> message = DHCPv4.Message.new()
      iex> binary = DHCP.to_iodata(message)

  ### DHCPv4 Server Usage

      iex> config = %{
      ...>   subnet: {192, 168, 1, 0},
      ...>   netmask: {255, 255, 255, 0},
      ...>   range_start: {192, 168, 1, 100},
      ...>   range_end: {192, 168, 1, 200},
      ...>   gateway: {192, 168, 1, 1},
      ...>   dns_servers: [{8, 8, 8, 8}, {8, 8, 4, 4}],
      ...>   lease_time: 3600,
      ...>   options: []
      ...> }
      iex> server_state = DHCPv4.Server.init(config)

  ## Protocol Information

  DHCP provides configuration parameters to Internet hosts.  DHCP consists of
  two components: a protocol for delivering host-specific configuration
  parameters from a DHCP server to a host and a mechanism for allocation of
  network addresses to hosts.

  DHCP is built on a client-server model, where designated DHCP server
  hosts allocate network addresses and deliver configuration parameters
  to dynamically configured hosts.  Throughout the remainder of this
  document, the term "server" refers to a host providing initialization
  parameters through DHCP, and the term "client" refers to a host
  requesting initialization parameters from a DHCP server.

  """

  @doc """
  Convert any DHCP-compliant struct to binary format.

  This function provides a unified interface for serializing DHCP messages
  and options to their binary wire format using the `DHCP.Parameter` protocol.

  ## Parameters

    * `value` - Any struct that implements the `DHCP.Parameter` protocol

  ## Returns

    Binary representation of the DHCP data suitable for network transmission

  ## Examples

      iex> message = DHCPv4.Message.new()
      iex> binary = DHCP.to_iodata(message)
      iex> is_binary(binary)
      true

      iex> option = DHCPv4.Message.Option.new(53, 1, <<1>>)
      iex> binary = DHCP.to_iodata(option)
      iex> binary
      <<53, 1, 1>>

  """
  @spec to_iodata(DHCP.Parameter.t()) :: binary()
  def to_iodata(value) do
    DHCP.Parameter.to_iodata(value)
  end
end
