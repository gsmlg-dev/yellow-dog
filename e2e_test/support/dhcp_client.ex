defmodule E2ETest.DhcpClient do
  @moduledoc """
  DHCP client helper for E2E tests.

  Provides functions to send DHCPv4 and DHCPv6 messages and receive responses,
  supporting the full DHCP handshake flow.
  """

  alias DHCPv4.Message, as: V4Message
  alias DHCPv4.Message.Option, as: V4Option
  alias DHCPv6.Message, as: V6Message
  alias DHCPv6.Message.Option, as: V6Option

  import Bitwise

  @default_timeout 5_000

  # DHCPv4 Message Types (Option 53)
  @dhcp_discover 1
  @dhcp_offer 2
  @dhcp_request 3
  @dhcp_ack 5
  @dhcp_nak 6

  # DHCPv6 Message Types
  @dhcpv6_solicit 1
  @dhcpv6_advertise 2
  @dhcpv6_request 3
  @dhcpv6_reply 7

  # DHCPv4 Magic Cookie
  @magic_cookie <<99, 130, 83, 99>>

  # ============================================================================
  # DHCPv4 Functions
  # ============================================================================

  @doc """
  Send a DHCPv4 DISCOVER message and receive the OFFER response.

  ## Parameters
  - `host` - Server IP address tuple (e.g., {127, 0, 0, 1})
  - `port` - Server port number
  - `mac` - Client MAC address as 6-byte binary
  - `opts` - Options keyword list
    - `:timeout` - Response timeout in ms (default: 5000)
    - `:xid` - Transaction ID (default: random)

  ## Returns
  - `{:ok, %DHCPv4.Message{}}` - OFFER message
  - `{:error, reason}` - Error
  """
  @spec discover(:inet.ip4_address(), :inet.port_number(), binary(), keyword()) ::
          {:ok, V4Message.t()} | {:error, term()}
  def discover(host, port, mac, opts \\ []) when byte_size(mac) == 6 do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    xid = Keyword.get(opts, :xid, generate_xid())

    message = build_discover(mac, xid)
    send_dhcpv4(host, port, message, timeout)
  end

  @doc """
  Send a DHCPv4 REQUEST message after receiving an OFFER.

  ## Parameters
  - `host` - Server IP address tuple
  - `port` - Server port number
  - `mac` - Client MAC address as 6-byte binary
  - `offered_ip` - IP address from OFFER (yiaddr)
  - `server_ip` - Server IP from OFFER
  - `xid` - Transaction ID from OFFER
  - `opts` - Options keyword list

  ## Returns
  - `{:ok, %DHCPv4.Message{}}` - ACK or NAK message
  - `{:error, reason}` - Error
  """
  @spec request(
          :inet.ip4_address(),
          :inet.port_number(),
          binary(),
          :inet.ip4_address(),
          :inet.ip4_address(),
          non_neg_integer(),
          keyword()
        ) ::
          {:ok, V4Message.t()} | {:error, term()}
  def request(host, port, mac, offered_ip, server_ip, xid, opts \\ [])
      when byte_size(mac) == 6 do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    message = build_request(mac, offered_ip, server_ip, xid)
    send_dhcpv4(host, port, message, timeout)
  end

  @doc """
  Perform a full DHCPv4 DISCOVER -> OFFER -> REQUEST -> ACK handshake.

  ## Returns
  - `{:ok, %{offer: offer, ack: ack}}` - Successful handshake
  - `{:error, reason}` - Error at any stage
  """
  @spec full_handshake(:inet.ip4_address(), :inet.port_number(), binary(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def full_handshake(host, port, mac, opts \\ []) when byte_size(mac) == 6 do
    xid = Keyword.get(opts, :xid, generate_xid())

    with {:ok, offer} <- discover(host, port, mac, Keyword.put(opts, :xid, xid)),
         true <- get_message_type(offer) == @dhcp_offer,
         server_ip <- get_server_identifier(offer) || host,
         {:ok, ack} <- request(host, port, mac, offer.yiaddr, server_ip, offer.xid, opts),
         true <- get_message_type(ack) == @dhcp_ack do
      {:ok, %{offer: offer, ack: ack, assigned_ip: ack.yiaddr}}
    else
      false -> {:error, :unexpected_message_type}
      {:error, _} = error -> error
    end
  end

  @doc """
  Get the DHCP message type from options (Option 53).
  """
  @spec get_message_type(V4Message.t()) :: integer() | nil
  def get_message_type(%V4Message{options: options}) do
    case Enum.find(options, fn opt -> opt.type == 53 end) do
      %{value: <<type>>} -> type
      _ -> nil
    end
  end

  @doc """
  Get the server identifier from options (Option 54).
  """
  @spec get_server_identifier(V4Message.t()) :: :inet.ip4_address() | nil
  def get_server_identifier(%V4Message{options: options}) do
    case Enum.find(options, fn opt -> opt.type == 54 end) do
      %{value: <<a, b, c, d>>} -> {a, b, c, d}
      _ -> nil
    end
  end

  @doc """
  Check if the response is an ACK.
  """
  @spec is_ack?(V4Message.t()) :: boolean()
  def is_ack?(message), do: get_message_type(message) == @dhcp_ack

  @doc """
  Check if the response is a NAK.
  """
  @spec is_nak?(V4Message.t()) :: boolean()
  def is_nak?(message), do: get_message_type(message) == @dhcp_nak

  # ============================================================================
  # DHCPv6 Functions
  # ============================================================================

  @doc """
  Send a DHCPv6 SOLICIT message and receive ADVERTISE response.

  ## Parameters
  - `host` - Server IPv6 address tuple
  - `port` - Server port number
  - `duid` - Client DUID (DHCP Unique Identifier) binary
  - `opts` - Options keyword list

  ## Returns
  - `{:ok, %DHCPv6.Message{}}` - ADVERTISE message
  - `{:error, reason}` - Error
  """
  @spec solicit(:inet.ip6_address(), :inet.port_number(), binary(), keyword()) ::
          {:ok, V6Message.t()} | {:error, term()}
  def solicit(host, port, duid, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    transaction_id = Keyword.get(opts, :transaction_id, generate_transaction_id())

    message = build_solicit(duid, transaction_id)
    send_dhcpv6(host, port, message, timeout)
  end

  @doc """
  Send a DHCPv6 REQUEST message after receiving ADVERTISE.

  ## Parameters
  - `host` - Server IPv6 address tuple
  - `port` - Server port number
  - `duid` - Client DUID binary
  - `server_duid` - Server DUID from ADVERTISE
  - `ia_na` - IA_NA option from ADVERTISE
  - `transaction_id` - Transaction ID from ADVERTISE
  - `opts` - Options keyword list

  ## Returns
  - `{:ok, %DHCPv6.Message{}}` - REPLY message
  - `{:error, reason}` - Error
  """
  @spec request_v6(
          :inet.ip6_address(),
          :inet.port_number(),
          binary(),
          binary(),
          binary(),
          binary(),
          keyword()
        ) ::
          {:ok, V6Message.t()} | {:error, term()}
  def request_v6(host, port, duid, server_duid, ia_na, transaction_id, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    message = build_request_v6(duid, server_duid, ia_na, transaction_id)
    send_dhcpv6(host, port, message, timeout)
  end

  @doc """
  Perform a full DHCPv6 SOLICIT -> ADVERTISE -> REQUEST -> REPLY handshake.
  """
  @spec full_handshake_v6(:inet.ip6_address(), :inet.port_number(), binary(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def full_handshake_v6(host, port, duid, opts \\ []) do
    transaction_id = Keyword.get(opts, :transaction_id, generate_transaction_id())

    with {:ok, advertise} <- solicit(host, port, duid, Keyword.put(opts, :transaction_id, transaction_id)),
         true <- advertise.msg_type == @dhcpv6_advertise,
         server_duid <- get_server_duid(advertise),
         ia_na <- get_ia_na_option(advertise),
         {:ok, reply} <- request_v6(host, port, duid, server_duid, ia_na, advertise.transaction_id, opts),
         true <- reply.msg_type == @dhcpv6_reply do
      {:ok, %{advertise: advertise, reply: reply}}
    else
      nil -> {:error, :missing_required_option}
      false -> {:error, :unexpected_message_type}
      {:error, _} = error -> error
    end
  end

  @doc """
  Get the server DUID from DHCPv6 options (Option 2).
  """
  @spec get_server_duid(V6Message.t()) :: binary() | nil
  def get_server_duid(%V6Message{options: options}) do
    case Enum.find(options, fn opt -> opt.option_code == 2 end) do
      %{option_data: duid} -> duid
      _ -> nil
    end
  end

  @doc """
  Get the IA_NA option from DHCPv6 message (Option 3).
  """
  @spec get_ia_na_option(V6Message.t()) :: binary() | nil
  def get_ia_na_option(%V6Message{options: options}) do
    case Enum.find(options, fn opt -> opt.option_code == 3 end) do
      %{option_data: value} -> value
      _ -> nil
    end
  end

  # ============================================================================
  # Private Functions - DHCPv4
  # ============================================================================

  defp build_discover(mac, xid) do
    # Pad MAC to 16 bytes (chaddr field)
    chaddr = mac <> <<0::unit(8)-size(10)>>

    %V4Message{
      op: 1,
      htype: 1,
      hlen: 6,
      hops: 0,
      xid: xid,
      secs: 0,
      flags: 0x8000,
      ciaddr: {0, 0, 0, 0},
      yiaddr: {0, 0, 0, 0},
      siaddr: {0, 0, 0, 0},
      giaddr: {0, 0, 0, 0},
      chaddr: chaddr,
      sname: <<0::unit(8)-size(64)>>,
      file: <<0::unit(8)-size(128)>>,
      options: [
        V4Option.new(53, 1, <<@dhcp_discover>>),
        V4Option.new(55, 4, <<1, 3, 6, 15>>)
      ]
    }
  end

  defp build_request(mac, offered_ip, server_ip, xid) do
    chaddr = mac <> <<0::unit(8)-size(10)>>
    {a, b, c, d} = offered_ip
    {sa, sb, sc, sd} = server_ip

    %V4Message{
      op: 1,
      htype: 1,
      hlen: 6,
      hops: 0,
      xid: xid,
      secs: 0,
      flags: 0x8000,
      ciaddr: {0, 0, 0, 0},
      yiaddr: {0, 0, 0, 0},
      siaddr: {0, 0, 0, 0},
      giaddr: {0, 0, 0, 0},
      chaddr: chaddr,
      sname: <<0::unit(8)-size(64)>>,
      file: <<0::unit(8)-size(128)>>,
      options: [
        V4Option.new(53, 1, <<@dhcp_request>>),
        V4Option.new(50, 4, <<a, b, c, d>>),
        V4Option.new(54, 4, <<sa, sb, sc, sd>>),
        V4Option.new(55, 4, <<1, 3, 6, 15>>)
      ]
    }
  end

  defp send_dhcpv4(host, port, message, timeout) do
    packet = DHCP.Parameter.to_iodata(message) |> IO.iodata_to_binary()

    case :gen_udp.open(0, [:binary, {:active, false}]) do
      {:ok, socket} ->
        result = send_and_receive_v4(socket, host, port, packet, timeout)
        :gen_udp.close(socket)
        result

      {:error, reason} ->
        {:error, {:socket_open_failed, reason}}
    end
  end

  defp send_and_receive_v4(socket, host, port, packet, timeout) do
    case :gen_udp.send(socket, host, port, packet) do
      :ok ->
        case :gen_udp.recv(socket, 0, timeout) do
          {:ok, {_ip, _port, data}} ->
            parse_dhcpv4_response(data)

          {:error, :timeout} ->
            {:error, :timeout}

          {:error, reason} ->
            {:error, {:recv_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:send_failed, reason}}
    end
  end

  defp parse_dhcpv4_response(data) when byte_size(data) >= 240 do
    try do
      message = V4Message.from_iodata(data)
      {:ok, message}
    rescue
      e -> {:error, {:parse_failed, e}}
    end
  end

  defp parse_dhcpv4_response(_data), do: {:error, :invalid_response}

  # ============================================================================
  # Private Functions - DHCPv6
  # ============================================================================

  defp build_solicit(duid, transaction_id) do
    # Build IA_NA option (Option 3)
    iaid = <<0, 0, 0, 1>>
    t1 = <<0, 0, 0, 0>>
    t2 = <<0, 0, 0, 0>>
    ia_na_value = iaid <> t1 <> t2

    %V6Message{
      msg_type: @dhcpv6_solicit,
      transaction_id: transaction_id,
      options: [
        V6Option.new(1, byte_size(duid), duid),
        V6Option.new(3, byte_size(ia_na_value), ia_na_value),
        V6Option.new(6, 4, <<0, 23, 0, 24>>)
      ]
    }
  end

  defp build_request_v6(duid, server_duid, ia_na, transaction_id) do
    %V6Message{
      msg_type: @dhcpv6_request,
      transaction_id: transaction_id,
      options: [
        V6Option.new(1, byte_size(duid), duid),
        V6Option.new(2, byte_size(server_duid), server_duid),
        V6Option.new(3, byte_size(ia_na), ia_na),
        V6Option.new(6, 4, <<0, 23, 0, 24>>)
      ]
    }
  end

  defp send_dhcpv6(host, port, message, timeout) do
    packet = V6Message.to_iodata(message)

    case :gen_udp.open(0, [:binary, {:active, false}, :inet6]) do
      {:ok, socket} ->
        result = send_and_receive_v6(socket, host, port, packet, timeout)
        :gen_udp.close(socket)
        result

      {:error, reason} ->
        {:error, {:socket_open_failed, reason}}
    end
  end

  defp send_and_receive_v6(socket, host, port, packet, timeout) do
    case :gen_udp.send(socket, host, port, packet) do
      :ok ->
        case :gen_udp.recv(socket, 0, timeout) do
          {:ok, {_ip, _port, data}} ->
            V6Message.from_iodata(data)

          {:error, :timeout} ->
            {:error, :timeout}

          {:error, reason} ->
            {:error, {:recv_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:send_failed, reason}}
    end
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  @doc """
  Generate a random DHCPv4 transaction ID (32-bit).
  """
  @spec generate_xid() :: non_neg_integer()
  def generate_xid do
    :rand.uniform(0xFFFFFFFF)
  end

  @doc """
  Generate a random DHCPv6 transaction ID (24-bit / 3 bytes).
  """
  @spec generate_transaction_id() :: binary()
  def generate_transaction_id do
    :crypto.strong_rand_bytes(3)
  end

  @doc """
  Generate a random MAC address for testing.
  """
  @spec generate_mac() :: binary()
  def generate_mac do
    # Use locally administered, unicast MAC (bit 1 of first byte = 1, bit 0 = 0)
    <<first, rest::binary-size(5)>> = :crypto.strong_rand_bytes(6)
    # Set locally administered bit, clear multicast bit
    <<(first ||| 0x02) &&& 0xFE, rest::binary>>
  end

  @doc """
  Generate a DUID-LL (Link-layer address) for DHCPv6 testing.
  """
  @spec generate_duid() :: binary()
  def generate_duid do
    mac = generate_mac()
    # DUID-LL format: type (2 bytes) + hardware type (2 bytes) + link-layer address
    <<0, 3, 0, 1, mac::binary>>
  end
end
