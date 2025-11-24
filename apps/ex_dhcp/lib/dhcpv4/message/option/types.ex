defmodule DHCPv4.Message.Option.Types do
  @moduledoc """
  Type-specific DHCPv4 option handlers.

  This module provides functions to decode specific DHCP option types
  into their appropriate Elixir representations.
  """

  @doc """
  Decode subnet mask option (type 1).
  """
  def decode_subnet_mask(value), do: {"Subnet Mask", :ip, to_ip_address(value)}

  @doc """
  Decode time offset option (type 2).
  """
  def decode_time_offset(value), do: {"Time Offset", :int, to_int(32, value)}

  @doc """
  Decode router option (type 3).
  """
  def decode_router(value, length), do: {"Router", :ip_list, to_ip_address_list(value, length)}

  @doc """
  Decode time server option (type 4).
  """
  def decode_time_server(value, length),
    do: {"Time Server", :ip_list, to_ip_address_list(value, length)}

  @doc """
  Decode name server option (type 5).
  """
  def decode_name_server(value, length),
    do: {"Name Server", :ip_list, to_ip_address_list(value, length)}

  @doc """
  Decode domain name server option (type 6).
  """
  def decode_domain_name_server(value, length),
    do: {"Domain Name Server", :ip_list, to_ip_address_list(value, length)}

  @doc """
  Decode log server option (type 7).
  """
  def decode_log_server(value, length),
    do: {"Log Server", :ip_list, to_ip_address_list(value, length)}

  @doc """
  Decode cookie server option (type 8).
  """
  def decode_cookie_server(value, length),
    do: {"Cookie Server", :ip_list, to_ip_address_list(value, length)}

  @doc """
  Decode LPR server option (type 9).
  """
  def decode_lpr_server(value, length),
    do: {"LPR Server", :ip_list, to_ip_address_list(value, length)}

  @doc """
  Decode impress server option (type 10).
  """
  def decode_impress_server(value, length),
    do: {"Impress Server", :ip_list, to_ip_address_list(value, length)}

  @doc """
  Decode resource location server option (type 11).
  """
  def decode_resource_location_server(value, length),
    do: {"Resource Location Server", :ip_list, to_ip_address_list(value, length)}

  @doc """
  Decode host name option (type 12).
  """
  def decode_host_name(value), do: {"Host Name", :binary, to_binary_string(value)}

  @doc """
  Decode boot file size option (type 13).
  """
  def decode_boot_file_size(value), do: {"Boot File Size", :int, to_int(16, value)}

  @doc """
  Decode merit dump file option (type 14).
  """
  def decode_merit_dump_file(value), do: {"Merit Dump File", :binary, to_binary_string(value)}

  @doc """
  Decode domain name option (type 15).
  """
  def decode_domain_name(value), do: {"Domain Name", :binary, to_binary_string(value)}

  @doc """
  Decode swap server option (type 16).
  """
  def decode_swap_server(value), do: {"Swap Server", :ip, to_ip_address(value)}

  @doc """
  Decode root path option (type 17).
  """
  def decode_root_path(value), do: {"Root Path", :binary, to_binary_string(value)}

  @doc """
  Decode extensions path option (type 18).
  """
  def decode_extensions_path(value), do: {"Extensions Path", :binary, to_binary_string(value)}

  @doc """
  Decode IP forwarding enable/disable option (type 19).
  """
  def decode_ip_forwarding(value), do: {"IP Forwarding Enable/Disable", :bool, to_bool(value)}

  @doc """
  Decode non-local source routing enable/disable option (type 20).
  """
  def decode_non_local_source_routing(value),
    do: {"Non-Local Source Routing Enable/Disable", :bool, to_bool(value)}

  @doc """
  Decode policy filter option (type 21).
  """
  def decode_policy_filter(value, length),
    do: {"Policy Filter", :ip_mask_list, to_ip_mask_list(value, length)}

  @doc """
  Decode maximum datagram reassembly size option (type 22).
  """
  def decode_maximum_datagram_reassembly_size(value),
    do: {"Maximum Datagram Reassembly Size", :int, to_int(16, value)}

  @doc """
  Decode default IP time-to-live option (type 23).
  """
  def decode_default_ip_ttl(value), do: {"Default IP Time-to-Live", :int, to_int(8, value)}

  @doc """
  Decode path MTU aging timeout option (type 24).
  """
  def decode_path_mtu_aging_timeout(value),
    do: {"Path MTU Aging Timeout", :int, to_int(32, value)}

  @doc """
  Decode path MTU plateau table option (type 25).
  """
  def decode_path_mtu_plateau_table(value, length),
    do: {"Path MTU Plateau Table", :int_list, to_int_list(16, value, length)}

  @doc """
  Decode interface MTU option (type 26).
  """
  def decode_interface_mtu(value), do: {"Interface MTU", :int, to_int(16, value)}

  @doc """
  Decode all subnets are local option (type 27).
  """
  def decode_all_subnets_local(value), do: {"All Subnets are Local", :bool, to_bool(value)}

  @doc """
  Decode broadcast address option (type 28).
  """
  def decode_broadcast_address(value), do: {"Broadcast Address", :ip, to_ip_address(value)}

  @doc """
  Decode perform mask discovery option (type 29).
  """
  def decode_perform_mask_discovery(value), do: {"Perform Mask Discovery", :bool, to_bool(value)}

  @doc """
  Decode mask supplier option (type 30).
  """
  def decode_mask_supplier(value), do: {"Mask Supplier", :bool, to_bool(value)}

  @doc """
  Decode perform router discovery option (type 31).
  """
  def decode_perform_router_discovery(value),
    do: {"Perform Router Discovery", :bool, to_bool(value)}

  @doc """
  Decode router solicitation address option (type 32).
  """
  def decode_router_solicitation_address(value),
    do: {"Router Solicitation Address", :ip, to_ip_address(value)}

  @doc """
  Decode static route option (type 33).
  """
  def decode_static_route(value, length),
    do: {"Static Route", :ip_mask_list, to_ip_mask_list(value, length)}

  @doc """
  Decode trailer encapsulation option (type 34).
  """
  def decode_trailer_encapsulation(value), do: {"Trailer Encapsulation", :bool, to_bool(value)}

  @doc """
  Decode ARP cache timeout option (type 35).
  """
  def decode_arp_cache_timeout(value), do: {"ARP Cache Timeout", :int, to_int(32, value)}

  @doc """
  Decode ethernet encapsulation option (type 36).
  """
  def decode_ethernet_encapsulation(value), do: {"Ethernet Encapsulation", :bool, to_bool(value)}

  @doc """
  Decode TCP default TTL option (type 37).
  """
  def decode_tcp_default_ttl(value), do: {"TCP Default TTL", :int, to_int(8, value)}

  @doc """
  Decode TCP keepalive interval option (type 38).
  """
  def decode_tcp_keepalive_interval(value),
    do: {"TCP Keepalive Interval", :int, to_int(32, value)}

  @doc """
  Decode TCP keepalive garbage option (type 39).
  """
  def decode_tcp_keepalive_garbage(value), do: {"TCP Keepalive Garbage", :bool, to_bool(value)}

  @doc """
  Decode network information service domain option (type 40).
  """
  def decode_nis_domain(value),
    do: {"Network Information Service Domain", :binary, to_binary_string(value)}

  @doc """
  Decode network information servers option (type 41).
  """
  def decode_nis_servers(value, length),
    do: {"Network Information Servers", :ip_list, to_ip_address_list(value, length)}

  @doc """
  Decode NTP servers option (type 42).
  """
  def decode_ntp_servers(value, length),
    do: {"NTP Servers", :ip_list, to_ip_address_list(value, length)}

  @doc """
  Decode vendor specific information option (type 43).
  """
  def decode_vendor_specific(value),
    do: {"Vendor Specific Information", :binary, to_binary_string(value)}

  @doc """
  Decode NetBIOS name server option (type 44).
  """
  def decode_netbios_name_server(value, length),
    do: {"NetBIOS over TCP/IP Name Server", :ip_list, to_ip_address_list(value, length)}

  @doc """
  Decode NetBIOS datagram distribution server option (type 45).
  """
  def decode_netbios_datagram_server(value, length),
    do:
      {"NetBIOS over TCP/IP Datagram Distribution Server", :ip_list,
       to_ip_address_list(value, length)}

  @doc """
  Decode NetBIOS node type option (type 46).
  """
  def decode_netbios_node_type(value),
    do: {"NetBIOS over TCP/IP Node Type", :int, to_int(8, value)}

  @doc """
  Decode NetBIOS scope option (type 47).
  """
  def decode_netbios_scope(value),
    do: {"NetBIOS over TCP/IP Scope", :binary, to_binary_string(value)}

  @doc """
  Decode X window system font server option (type 48).
  """
  def decode_x_font_server(value, length),
    do: {"X Window System Font Server", :ip_list, to_ip_address_list(value, length)}

  @doc """
  Decode X window system display manager option (type 49).
  """
  def decode_x_display_manager(value, length),
    do: {"X Window System Display Manager", :ip_list, to_ip_address_list(value, length)}

  @doc """
  Decode requested IP address option (type 50).
  """
  def decode_requested_ip_address(value), do: {"Requested IP Address", :ip, to_ip_address(value)}

  @doc """
  Decode IP address lease time option (type 51).
  """
  def decode_ip_address_lease_time(value), do: {"IP Address Lease Time", :int, to_int(32, value)}

  @doc """
  Decode option overload option (type 52).
  """
  def decode_option_overload(value), do: {"Option Overload", :int, to_int(8, value)}

  @doc """
  Decode DHCP message type option (type 53).
  """
  def decode_dhcp_message_type(value) do
    message_types = [
      {1, "DHCPDISCOVER", "Client broadcast to locate available servers"},
      {2, "DHCPOFFER", "Server offers an IP address to the client"},
      {3, "DHCPREQUEST", "Client requests offered IP or renews lease"},
      {4, "DHCPDECLINE", "Client declines the offered IP"},
      {5, "DHCPACK", "Server acknowledges the IP lease"},
      {6, "DHCPNAK", "Server refuses the IP request"},
      {7, "DHCPRELEASE", "Client releases the leased IP"},
      {8, "DHCPINFORM", "Client requests configuration without an IP"}
    ]

    type_int = to_int(8, value)

    message =
      Enum.find_value(message_types, type_int, fn {id, type_message, desc} ->
        if id == type_int do
          type_message <> " - " <> desc
        else
          false
        end
      end)

    {"DHCP Message Type", :binary, message}
  end

  @doc """
  Decode server identifier option (type 54).
  """
  def decode_server_identifier(value), do: {"Server Identifier", :ip, to_ip_address(value)}

  @doc """
  Decode parameter request list option (type 55).
  """
  def decode_parameter_request_list(value, length),
    do: {"Parameter Request List", :int_list, to_int_list(8, value, length)}

  @doc """
  Decode message option (type 56).
  """
  def decode_message(value), do: {"Message", :binary, to_binary_string(value)}

  @doc """
  Decode maximum DHCP message size option (type 57).
  """
  def decode_maximum_dhcp_message_size(value),
    do: {"Maximum DHCP Message Size", :int, to_int(16, value)}

  @doc """
  Decode renewal time value option (type 58).
  """
  def decode_renewal_time_value(value), do: {"Renewal (T1) Time Value", :int, to_int(32, value)}

  @doc """
  Decode rebinding time value option (type 59).
  """
  def decode_rebinding_time_value(value),
    do: {"Rebinding (T2) Time Value", :int, to_int(32, value)}

  @doc """
  Decode vendor class identifier option (type 60).
  """
  def decode_vendor_class_identifier(value, length),
    do: {"Vendor class identifier", :int_list, to_int_list(8, value, length)}

  @doc """
  Decode client identifier option (type 61).
  """
  def decode_client_identifier(value, length),
    do: {"Client-identifier", :type_identifier, to_type_identifier(value, length)}

  @doc """
  Decode Netware/IP domain name option (type 62).
  """
  def decode_netware_ip_domain(value),
    do: {"Netware/IP Domain Name", :binary, to_binary_string(value)}

  @doc """
  Decode Netware/IP sub options option (type 63).
  """
  def decode_netware_ip_sub_options(value),
    do: {"Netware/IP sub Options", :binary, to_binary_string(value)}

  @doc """
  Decode NIS+ domain option (type 64).
  """
  def decode_nis_plus_domain(value), do: {"NIS+ Domain", :binary, to_binary_string(value)}

  @doc """
  Decode NIS+ servers option (type 65).
  """
  def decode_nis_plus_servers(value, length),
    do: {"NIS+ Servers", :ip_list, to_ip_address_list(value, length)}

  @doc """
  Decode TFTP server name option (type 66).
  """
  def decode_tftp_server_name(value), do: {"TFTP server name", :binary, to_binary_string(value)}

  @doc """
  Decode bootfile name option (type 67).
  """
  def decode_bootfile_name(value), do: {"Bootfile name", :binary, to_binary_string(value)}

  @doc """
  Decode mobile IP home agent option (type 68).
  """
  def decode_mobile_ip_home_agent(value, length),
    do: {"Mobile IP Home Agent", :ip_list, to_ip_address_list(value, length)}

  @doc """
  Decode SMTP server option (type 69).
  """
  def decode_smtp_server(value, length),
    do: {"SMTP Server", :ip_list, to_ip_address_list(value, length)}

  @doc """
  Decode POP3 server option (type 70).
  """
  def decode_pop3_server(value, length),
    do: {"POP3 Server", :ip_list, to_ip_address_list(value, length)}

  @doc """
  Decode NNTP server option (type 71).
  """
  def decode_nntp_server(value, length),
    do: {"NNTP Server", :ip_list, to_ip_address_list(value, length)}

  @doc """
  Decode WWW server option (type 72).
  """
  def decode_www_server(value, length),
    do: {"WWW Server", :ip_list, to_ip_address_list(value, length)}

  @doc """
  Decode finger server option (type 73).
  """
  def decode_finger_server(value, length),
    do: {"Finger Server", :ip_list, to_ip_address_list(value, length)}

  @doc """
  Decode IRC server option (type 74).
  """
  def decode_irc_server(value, length),
    do: {"IRC Server", :ip_list, to_ip_address_list(value, length)}

  @doc """
  Decode StreetTalk server option (type 75).
  """
  def decode_streettalk_server(value, length),
    do: {"StreetTalk Server", :ip_list, to_ip_address_list(value, length)}

  @doc """
  Decode StreetTalk Directory Assistance server option (type 76).
  """
  def decode_stda_server(value, length),
    do: {"StreetTalk Directory Assistance Server", :ip_list, to_ip_address_list(value, length)}

  @doc """
  Decode TZ-POSIX string option (type 100).
  """
  def decode_tz_posix_string(value), do: {"TZ-POSIX String", :binary, to_binary_string(value)}

  @doc """
  Decode TZ-Database string option (type 101).
  """
  def decode_tz_database_string(value),
    do: {"TZ-Database String", :binary, to_binary_string(value)}

  @doc """
  Decode classless static route option (type 121).
  """
  def decode_classless_static_route(value, length),
    do:
      {"Classless Static Route Option", :network_mask_router_list,
       to_mask_network_route_list(value, length)}

  @doc """
  Decode unknown option types.
  """
  def decode_unknown(value), do: {"Unknown", :raw, value}

  # Helper functions moved from the original module

  defp to_ip_address(<<a::8, b::8, c::8, d::8>>), do: {a, b, c, d}

  defp to_int(bits, value) do
    <<int::size(bits)>> = value
    int
  end

  defp to_bool(<<val::8>>), do: val == 1 || false

  defp to_binary_string(value), do: value

  defp to_ip_address_list(<<a::8, b::8, c::8, d::8, rest::binary>>, len) do
    if len - 4 == 0 do
      [{a, b, c, d}]
    else
      [{a, b, c, d} | to_ip_address_list(rest, len - 4)]
    end
  end

  defp to_ip_address_list(_, _), do: []

  defp to_ip_mask_list(<<a::8, b::8, c::8, d::8, e::8, f::8, g::8, h::8, rest::binary>>, len) do
    if len - 8 == 0 do
      [{{a, b, c, d}, {e, f, g, h}}]
    else
      [{{a, b, c, d}, {e, f, g, h}} | to_ip_mask_list(rest, len - 8)]
    end
  end

  defp to_ip_mask_list(_, _), do: []

  defp to_int_list(int, b, len) do
    <<a::size(b), rest::binary>> = int

    if len - b / 8 == 0 do
      [a]
    else
      [a | to_int_list(rest, b, len - b / 8)]
    end
  end

  defp to_type_identifier(<<type::8, identifier::binary>>, _len) do
    case type do
      0 ->
        {"Non-hardware", identifier}

      1 ->
        mac =
          identifier
          |> :binary.part(0, 6)
          |> Base.encode16(case: :lower)
          |> String.replace(~r/(..)/, "\\1:")
          |> String.trim_trailing(":")

        {"Ethernet", mac}

      _ ->
        {type, identifier}
    end
  end

  defp to_mask_network_route_list(_bin, len) when len == 0, do: []

  defp to_mask_network_route_list(bin, len) do
    <<mask::8, rest::binary>> = bin

    {network, router, rest, size} =
      case mask do
        0 ->
          <<router::binary-size(4), rest::binary>> = rest
          {{0, 0, 0, 0}, router, rest, 5}

        n when n >= 1 and n <= 8 ->
          <<a::8, router::binary-size(4), rest::binary>> = rest
          {{a, 0, 0, 0}, router, rest, 6}

        n when n >= 9 and n <= 16 ->
          <<a::8, b::8, router::binary-size(4), rest::binary>> = rest
          {{a, b, 0, 0}, router, rest, 7}

        n when n >= 17 and n <= 24 ->
          <<a::8, b::8, c::8, router::binary-size(4), rest::binary>> = rest
          {{a, b, c, 0}, router, rest, 8}

        n when n >= 25 and n <= 32 ->
          <<a::8, b::8, c::8, d::8, router::binary-size(4), rest::binary>> = rest
          {{a, b, c, d}, router, rest, 9}
      end

    [{network, mask, router} | to_mask_network_route_list(rest, len - size)]
  end
end
