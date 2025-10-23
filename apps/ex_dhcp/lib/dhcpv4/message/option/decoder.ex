defmodule DHCPv4.Message.Option.Decoder do
  @moduledoc """
  DHCPv4 option parsing and decoding logic.

  This module provides functions to parse DHCP option data and delegate
  to type-specific decoders for proper value extraction.
  """

  alias DHCPv4.Message.Option.{Types, Helpers}

  @magic_cookie <<99, 130, 83, 99>>
  @end_option 0xFF

  @doc """
  Parse DHCP options from binary data.

  Returns {:ok, options} on success or {:error, reason} on failure.
  """
  def parse(data) do
    try do
      {:ok, parse_dhcp_options(data)}
    catch
      {:parse_dhcp_options_failed, reason} -> {:error, reason}
    end
  end

  @doc """
  Decode an option value based on its type and length.

  Delegates to the appropriate type-specific decoder.
  """
  def decode_option_value(type, length, value) do
    case type do
      1 -> Types.decode_subnet_mask(value)
      2 -> Types.decode_time_offset(value)
      3 -> Types.decode_router(value, length)
      4 -> Types.decode_time_server(value, length)
      5 -> Types.decode_name_server(value, length)
      6 -> Types.decode_domain_name_server(value, length)
      7 -> Types.decode_log_server(value, length)
      8 -> Types.decode_cookie_server(value, length)
      9 -> Types.decode_lpr_server(value, length)
      10 -> Types.decode_impress_server(value, length)
      11 -> Types.decode_resource_location_server(value, length)
      12 -> Types.decode_host_name(value)
      13 -> Types.decode_boot_file_size(value)
      14 -> Types.decode_merit_dump_file(value)
      15 -> Types.decode_domain_name(value)
      16 -> Types.decode_swap_server(value)
      17 -> Types.decode_root_path(value)
      18 -> Types.decode_extensions_path(value)
      19 -> Types.decode_ip_forwarding(value)
      20 -> Types.decode_non_local_source_routing(value)
      21 -> Types.decode_policy_filter(value, length)
      22 -> Types.decode_maximum_datagram_reassembly_size(value)
      23 -> Types.decode_default_ip_ttl(value)
      24 -> Types.decode_path_mtu_aging_timeout(value)
      25 -> Types.decode_path_mtu_plateau_table(value, length)
      26 -> Types.decode_interface_mtu(value)
      27 -> Types.decode_all_subnets_local(value)
      28 -> Types.decode_broadcast_address(value)
      29 -> Types.decode_perform_mask_discovery(value)
      30 -> Types.decode_mask_supplier(value)
      31 -> Types.decode_perform_router_discovery(value)
      32 -> Types.decode_router_solicitation_address(value)
      33 -> Types.decode_static_route(value, length)
      34 -> Types.decode_trailer_encapsulation(value)
      35 -> Types.decode_arp_cache_timeout(value)
      36 -> Types.decode_ethernet_encapsulation(value)
      37 -> Types.decode_tcp_default_ttl(value)
      38 -> Types.decode_tcp_keepalive_interval(value)
      39 -> Types.decode_tcp_keepalive_garbage(value)
      40 -> Types.decode_nis_domain(value)
      41 -> Types.decode_nis_servers(value, length)
      42 -> Types.decode_ntp_servers(value, length)
      43 -> Types.decode_vendor_specific(value)
      44 -> Types.decode_netbios_name_server(value, length)
      45 -> Types.decode_netbios_datagram_server(value, length)
      46 -> Types.decode_netbios_node_type(value)
      47 -> Types.decode_netbios_scope(value)
      48 -> Types.decode_x_font_server(value, length)
      49 -> Types.decode_x_display_manager(value, length)
      50 -> Types.decode_requested_ip_address(value)
      51 -> Types.decode_ip_address_lease_time(value)
      52 -> Types.decode_option_overload(value)
      53 -> Types.decode_dhcp_message_type(value)
      54 -> Types.decode_server_identifier(value)
      55 -> Types.decode_parameter_request_list(value, length)
      56 -> Types.decode_message(value)
      57 -> Types.decode_maximum_dhcp_message_size(value)
      58 -> Types.decode_renewal_time_value(value)
      59 -> Types.decode_rebinding_time_value(value)
      60 -> Types.decode_vendor_class_identifier(value, length)
      61 -> Types.decode_client_identifier(value, length)
      62 -> Types.decode_netware_ip_domain(value)
      63 -> Types.decode_netware_ip_sub_options(value)
      64 -> Types.decode_nis_plus_domain(value)
      65 -> Types.decode_nis_plus_servers(value, length)
      66 -> Types.decode_tftp_server_name(value)
      67 -> Types.decode_bootfile_name(value)
      68 -> Types.decode_mobile_ip_home_agent(value, length)
      69 -> Types.decode_smtp_server(value, length)
      70 -> Types.decode_pop3_server(value, length)
      71 -> Types.decode_nntp_server(value, length)
      72 -> Types.decode_www_server(value, length)
      73 -> Types.decode_finger_server(value, length)
      74 -> Types.decode_irc_server(value, length)
      75 -> Types.decode_streettalk_server(value, length)
      76 -> Types.decode_stda_server(value, length)
      100 -> Types.decode_tz_posix_string(value)
      101 -> Types.decode_tz_database_string(value)
      121 -> Types.decode_classless_static_route(value, length)
      _ -> Types.decode_unknown(value)
    end
  end

  # Private parsing functions

  defp parse_dhcp_options(<<>>), do: []
  defp parse_dhcp_options(<<@magic_cookie::binary, rest::binary>>), do: parse_options(rest)

  defp parse_dhcp_options(_),
    do:
      throw(
        {:parse_dhcp_options_failed,
         "dhcp options must start with magic cookie #{@magic_cookie |> inspect}"}
      )

  defp parse_options(<<@end_option, _rest::binary>>), do: []

  defp parse_options(<<code, length, value::binary-size(length), rest::binary>>) do
    [Helpers.new(code, length, value) | parse_options(rest)]
  end
end
