defmodule YellowDog.DhcpClient.Packet do
  @moduledoc """
  DHCP packet construction and parsing with Yellow Dog vendor option support.

  Builds outbound packets with Option 60 (vendor class with version and
  capabilities) and Option 124 (PEN) injected. Parses inbound replies and
  extracts Option 125 (PEN-scoped vendor info) into the Lease struct.
  """

  alias DHCPv4.Message
  alias DHCPv4.Message.Option
  alias YellowDog.DhcpClient.{Lease, VendorOptions}

  @zero_ip {0, 0, 0, 0}

  # DHCP message types
  @discover 1
  @request 3
  @decline 4
  @release 7

  # DHCP option codes
  @opt_subnet_mask 1
  @opt_router 3
  @opt_dns 6
  @opt_hostname 12
  @opt_domain_name 15
  @opt_mtu 26
  @opt_ntp 42
  @opt_requested_ip 50
  @opt_lease_time 51
  @opt_message_type 53
  @opt_server_id 54
  @opt_param_request 55
  @opt_t1 58
  @opt_t2 59
  @opt_vendor_class 60
  @opt_client_id 61
  @opt_vendor_class_id 124
  @opt_vendor_specific 125

  @doc """
  Builds a DHCPDISCOVER packet.

  ## Options

    * `:hostname` - Hostname for Option 12
    * `:vendor_class` - Override vendor class string
    * `:capabilities` - List of capability atoms (default: `[]`)
    * `:version` - Protocol version (default: `"1.0"`)
  """
  @spec build_discover(binary(), non_neg_integer(), keyword()) :: binary()
  def build_discover(mac, xid, opts \\ []) do
    hostname = Keyword.get(opts, :hostname)
    version = Keyword.get(opts, :version, "1.0")
    capabilities = Keyword.get(opts, :capabilities, [])

    options =
      [
        msg_type_option(@discover),
        vendor_class_option(version, capabilities),
        vendor_class_id_option(),
        param_request_option(),
        client_id_option(mac)
      ]
      |> maybe_add_hostname(hostname)

    build_message(mac, xid, @zero_ip, options)
  end

  @doc """
  Builds a DHCPREQUEST packet.

  ## Options

    * `:hostname` - Hostname for Option 12
    * `:version` - Protocol version (default: `"1.0"`)
    * `:capabilities` - List of capability atoms (default: `[]`)
  """
  @spec build_request(
          binary(),
          non_neg_integer(),
          :inet.ip4_address(),
          :inet.ip4_address(),
          keyword()
        ) ::
          binary()
  def build_request(mac, xid, server_ip, offered_ip, opts \\ []) do
    hostname = Keyword.get(opts, :hostname)
    version = Keyword.get(opts, :version, "1.0")
    capabilities = Keyword.get(opts, :capabilities, [])

    options =
      [
        msg_type_option(@request),
        requested_ip_option(offered_ip),
        server_id_option(server_ip),
        vendor_class_option(version, capabilities),
        vendor_class_id_option(),
        client_id_option(mac)
      ]
      |> maybe_add_hostname(hostname)

    build_message(mac, xid, @zero_ip, options)
  end

  @doc """
  Builds a DHCPDECLINE packet for duplicate address detection failure.
  """
  @spec build_decline(binary(), non_neg_integer(), :inet.ip4_address(), :inet.ip4_address()) ::
          binary()
  def build_decline(mac, xid, server_ip, declined_ip) do
    options = [
      msg_type_option(@decline),
      requested_ip_option(declined_ip),
      server_id_option(server_ip),
      client_id_option(mac)
    ]

    build_message(mac, xid, @zero_ip, options)
  end

  @doc """
  Builds a DHCPRELEASE packet.
  """
  @spec build_release(binary(), non_neg_integer(), :inet.ip4_address(), :inet.ip4_address()) ::
          binary()
  def build_release(mac, xid, server_ip, client_ip) do
    options = [
      msg_type_option(@release),
      server_id_option(server_ip),
      client_id_option(mac)
    ]

    msg = %Message{
      op: 1,
      htype: 1,
      hlen: 6,
      hops: 0,
      xid: xid,
      secs: 0,
      flags: 0,
      ciaddr: client_ip,
      yiaddr: @zero_ip,
      siaddr: @zero_ip,
      giaddr: @zero_ip,
      chaddr: pad_mac(mac),
      sname: <<0::8*64>>,
      file: <<0::8*128>>,
      options: options
    }

    IO.iodata_to_binary(DHCP.Parameter.to_iodata(msg))
  end

  @doc """
  Parses a DHCP reply packet and returns a typed result.

  Checks Option 53 for message type and extracts lease fields including
  Yellow Dog vendor options from Option 125 when the PEN matches.

  ## Returns

    * `{:offer, lease}` for DHCPOFFER (type 2)
    * `{:ack, lease}` for DHCPACK (type 5)
    * `{:nak, reason}` for DHCPNAK (type 6)
    * `{:error, term}` for parse failures or unknown types
  """
  @spec parse_reply(binary()) ::
          {:offer, Lease.t()} | {:ack, Lease.t()} | {:nak, String.t()} | {:error, term()}
  def parse_reply(data) when is_binary(data) do
    try do
      msg = Message.from_iodata(data)
      opts_map = index_options(msg.options)

      case Map.get(opts_map, @opt_message_type) do
        %Option{value: <<2>>} -> {:offer, build_lease(msg, opts_map)}
        %Option{value: <<5>>} -> {:ack, build_lease(msg, opts_map)}
        %Option{value: <<6>>} -> {:nak, extract_nak_reason(opts_map)}
        nil -> {:error, :missing_message_type}
        _ -> {:error, :unknown_message_type}
      end
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  # -- private helpers --

  defp build_message(mac, xid, ciaddr, options) do
    msg = %Message{
      op: 1,
      htype: 1,
      hlen: 6,
      hops: 0,
      xid: xid,
      secs: 0,
      flags: 0x8000,
      ciaddr: ciaddr,
      yiaddr: @zero_ip,
      siaddr: @zero_ip,
      giaddr: @zero_ip,
      chaddr: pad_mac(mac),
      sname: <<0::8*64>>,
      file: <<0::8*128>>,
      options: options
    }

    DHCP.Parameter.to_iodata(msg)
  end

  defp pad_mac(mac) when byte_size(mac) == 6, do: mac <> <<0::8*10>>
  defp pad_mac(mac) when byte_size(mac) == 16, do: mac

  defp pad_mac(mac) when byte_size(mac) < 16,
    do: :binary.copy(<<0>>, 16 - byte_size(mac)) |> then(&(mac <> &1))

  defp pad_mac(mac), do: binary_part(mac, 0, 16)

  defp msg_type_option(type), do: %Option{type: @opt_message_type, length: 1, value: <<type>>}

  defp requested_ip_option({a, b, c, d}),
    do: %Option{type: @opt_requested_ip, length: 4, value: <<a, b, c, d>>}

  defp server_id_option({a, b, c, d}),
    do: %Option{type: @opt_server_id, length: 4, value: <<a, b, c, d>>}

  defp vendor_class_option(version, capabilities) do
    value = VendorOptions.encode_client_id(version, capabilities)
    %Option{type: @opt_vendor_class, length: byte_size(value), value: value}
  end

  defp vendor_class_id_option do
    value = VendorOptions.encode_vendor_class()
    %Option{type: @opt_vendor_class_id, length: byte_size(value), value: value}
  end

  defp param_request_option do
    codes = <<
      @opt_subnet_mask,
      @opt_router,
      @opt_dns,
      @opt_domain_name,
      @opt_mtu,
      @opt_ntp,
      @opt_lease_time,
      @opt_t1,
      @opt_t2,
      @opt_vendor_specific
    >>

    %Option{type: @opt_param_request, length: byte_size(codes), value: codes}
  end

  defp client_id_option(mac) do
    value = <<1>> <> mac
    %Option{type: @opt_client_id, length: byte_size(value), value: value}
  end

  defp hostname_option(hostname) do
    %Option{type: @opt_hostname, length: byte_size(hostname), value: hostname}
  end

  defp maybe_add_hostname(options, nil), do: options
  defp maybe_add_hostname(options, hostname), do: options ++ [hostname_option(hostname)]

  defp index_options(options) do
    Map.new(options, fn %Option{type: type} = opt -> {type, opt} end)
  end

  defp build_lease(msg, opts_map) do
    lease_time = extract_u32(opts_map, @opt_lease_time, 3600)
    t1 = extract_u32(opts_map, @opt_t1, div(lease_time, 2))
    t2 = extract_u32(opts_map, @opt_t2, div(lease_time * 7, 8))

    {yellowdog_server, vendor} = extract_vendor_options(opts_map)

    %Lease{
      ip: msg.yiaddr,
      subnet_mask: extract_ip(opts_map, @opt_subnet_mask) || {255, 255, 255, 0},
      router: extract_ip(opts_map, @opt_router),
      dns_servers: extract_ip_list(opts_map, @opt_dns),
      server_ip: extract_ip(opts_map, @opt_server_id) || msg.siaddr,
      server_mac: nil,
      lease_time: lease_time,
      t1: t1,
      t2: t2,
      domain_name: extract_string(opts_map, @opt_domain_name),
      ntp_servers: extract_ip_list(opts_map, @opt_ntp),
      mtu: extract_u16(opts_map, @opt_mtu),
      vendor_options: vendor,
      control_url: vendor[:control_url],
      control_url_fallback: vendor[:control_url_fallback],
      auth_token: vendor[:auth_token],
      server_id: vendor[:server_id],
      cluster_id: vendor[:cluster_id],
      yellowdog_server: yellowdog_server,
      obtained_at: DateTime.utc_now(),
      xid: msg.xid,
      raw_options: opts_map
    }
  end

  # Returns {yellowdog_pen_matched :: boolean(), vendor_info :: map()}
  defp extract_vendor_options(opts_map) do
    case Map.get(opts_map, @opt_vendor_specific) do
      %Option{value: data} ->
        case VendorOptions.decode_vendor_info(data) do
          {:ok, info} -> {true, info}
          {:error, _} -> {false, %{unknown: []}}
        end

      nil ->
        {false, %{unknown: []}}
    end
  end

  defp extract_ip(opts_map, code) do
    case Map.get(opts_map, code) do
      %Option{value: <<a, b, c, d, _rest::binary>>} -> {a, b, c, d}
      _ -> nil
    end
  end

  defp extract_ip_list(opts_map, code) do
    case Map.get(opts_map, code) do
      %Option{value: data} when byte_size(data) >= 4 -> parse_ip_list(data, [])
      _ -> []
    end
  end

  defp parse_ip_list(<<a, b, c, d, rest::binary>>, acc),
    do: parse_ip_list(rest, [{a, b, c, d} | acc])

  defp parse_ip_list(_, acc), do: Enum.reverse(acc)

  defp extract_u32(opts_map, code, default) do
    case Map.get(opts_map, code) do
      %Option{value: <<val::32>>} -> val
      _ -> default
    end
  end

  defp extract_u16(opts_map, code) do
    case Map.get(opts_map, code) do
      %Option{value: <<val::16>>} -> val
      _ -> nil
    end
  end

  defp extract_string(opts_map, code) do
    case Map.get(opts_map, code) do
      %Option{value: data} when is_binary(data) and data != "" -> data
      _ -> nil
    end
  end

  defp extract_nak_reason(opts_map) do
    case extract_string(opts_map, 56) do
      nil -> "DHCPNAK received"
      reason -> reason
    end
  end
end
