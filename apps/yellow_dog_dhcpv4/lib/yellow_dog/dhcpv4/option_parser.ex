defmodule YellowDog.Dhcpv4.OptionParser do
  @moduledoc """
  Efficient single-pass DHCP option extraction.

  Instead of iterating through the options list multiple times
  (once per option type), this module extracts all common options
  in a single pass for better performance.

  ## Performance Benefit

  Before: O(n * m) where n = option count, m = fields to extract
  After: O(n) - single pass extracts all needed fields

  ## Usage

      options = message.options
      parsed = OptionParser.extract_common(options)
      # => %{
      #      message_type: :discover,
      #      hostname: "client1",
      #      client_id: <<...>>,
      #      server_id: nil,
      #      requested_ip: {192, 168, 1, 50},
      #      vendor_class: nil,
      #      user_class: nil,
      #      client_arch: nil
      #    }
  """

  @type option :: %{type: non_neg_integer(), length: non_neg_integer(), value: binary()}
  @type parsed_options :: %{
          message_type: atom() | nil,
          hostname: String.t() | nil,
          client_id: binary() | nil,
          server_id: binary() | nil,
          requested_ip: tuple() | nil,
          vendor_class: binary() | nil,
          user_class: binary() | nil,
          client_arch: binary() | nil
        }

  # DHCP option codes
  @opt_hostname 12
  @opt_requested_ip 50
  @opt_message_type 53
  @opt_server_id 54
  @opt_client_id 61
  @opt_vendor_class 60
  @opt_user_class 77
  @opt_client_arch 93

  @doc """
  Extracts all commonly needed DHCP options in a single pass.

  This is more efficient than calling multiple individual extractors
  when you need several option values from the same message.

  ## Parameters
  - `options` - List of DHCP options from message

  ## Returns
  - Map with extracted option values (nil for missing options)
  """
  @spec extract_common([option()]) :: parsed_options()
  def extract_common(options) do
    # Initial accumulator with all fields nil
    initial = %{
      message_type: nil,
      hostname: nil,
      client_id: nil,
      server_id: nil,
      requested_ip: nil,
      vendor_class: nil,
      user_class: nil,
      client_arch: nil
    }

    # Single pass through options, extracting all relevant values
    Enum.reduce(options, initial, fn option, acc ->
      case option.type do
        @opt_message_type ->
          %{acc | message_type: decode_message_type(option.value)}

        @opt_hostname ->
          # RFC 2132 §3.14: some clients include a null terminator; strip it.
          %{acc | hostname: String.trim_trailing(option.value, <<0>>)}

        @opt_client_id ->
          %{acc | client_id: option.value}

        @opt_server_id ->
          %{acc | server_id: option.value}

        @opt_requested_ip ->
          %{acc | requested_ip: decode_ip(option.value)}

        @opt_vendor_class ->
          %{acc | vendor_class: option.value}

        @opt_user_class ->
          %{acc | user_class: option.value}

        @opt_client_arch ->
          %{acc | client_arch: option.value}

        # Skip other options
        _ ->
          acc
      end
    end)
  end

  @doc """
  Extracts only message type - use when you only need the type.

  For cases where only the message type is needed, this avoids
  the overhead of extracting other fields.
  """
  @spec extract_message_type([option()]) :: atom() | nil
  def extract_message_type(options) do
    Enum.find_value(options, fn option ->
      if option.type == @opt_message_type do
        decode_message_type(option.value)
      end
    end)
  end

  @doc """
  Builds client info map for ACL evaluation from parsed options.

  ## Parameters
  - `message` - DHCP message struct
  - `parsed` - Pre-parsed options from extract_common/1

  ## Returns
  - Client info map suitable for ACL.evaluate/2
  """
  @spec build_client_info(map(), parsed_options()) :: map()
  def build_client_info(message, parsed) do
    %{
      mac_address: message.chaddr,
      vendor_class: parsed.vendor_class,
      user_class: parsed.user_class,
      client_arch: parsed.client_arch
    }
  end

  # Private helpers

  defp decode_message_type(<<1>>), do: :discover
  defp decode_message_type(<<2>>), do: :offer
  defp decode_message_type(<<3>>), do: :request
  defp decode_message_type(<<4>>), do: :decline
  defp decode_message_type(<<5>>), do: :ack
  defp decode_message_type(<<6>>), do: :nak
  defp decode_message_type(<<7>>), do: :release
  defp decode_message_type(<<8>>), do: :inform
  defp decode_message_type(_), do: nil

  defp decode_ip(<<a, b, c, d>>), do: {a, b, c, d}
  defp decode_ip(_), do: nil
end
