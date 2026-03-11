defmodule YellowDog.Dhcpv6.OptionParser do
  @moduledoc """
  Efficient single-pass DHCPv6 option extraction.

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
      #      client_id: <<...>>,
      #      server_id: <<...>>,
      #      ia_na: %{iaid: 12345, ia_addr: ...},
      #      ia_ta: nil,
      #      ia_pd: nil
      #    }
  """

  # DHCPv6 option codes
  @option_client_id 1
  @option_server_id 2
  @option_ia_na 3
  @option_ia_ta 4
  @option_ia_addr 5
  @option_rapid_commit 14
  @option_ia_pd 25
  @option_ia_prefix 26

  @type ia_na :: %{
          iaid: non_neg_integer(),
          ia_addr: tuple() | nil,
          type: :ia_na
        }

  @type ia_ta :: %{
          iaid: non_neg_integer(),
          ia_addr: tuple() | nil,
          type: :ia_ta
        }

  @type ia_pd :: %{
          iaid: non_neg_integer(),
          ia_prefix: {tuple(), non_neg_integer()} | nil,
          type: :ia_pd
        }

  @type parsed_options :: %{
          client_id: binary() | nil,
          server_id: binary() | nil,
          ia_na: ia_na() | nil,
          ia_ta: ia_ta() | nil,
          ia_pd: ia_pd() | nil,
          rapid_commit: boolean()
        }

  @doc """
  Extracts all commonly needed DHCPv6 options in a single pass.

  This is more efficient than calling multiple individual extractors
  when you need several option values from the same message.

  ## Parameters
  - `options` - List of DHCPv6 options from message

  ## Returns
  - Map with extracted option values (nil for missing options)
  """
  @spec extract_common([%{option_code: non_neg_integer(), option_data: binary()}]) ::
          parsed_options()
  def extract_common(options) do
    # Initial accumulator with all fields nil
    initial = %{
      client_id: nil,
      server_id: nil,
      ia_na: nil,
      ia_ta: nil,
      ia_pd: nil,
      rapid_commit: false
    }

    # Single pass through options, extracting all relevant values
    Enum.reduce(options, initial, fn option, acc ->
      case option.option_code do
        @option_client_id ->
          %{acc | client_id: option.option_data}

        @option_server_id ->
          %{acc | server_id: option.option_data}

        @option_ia_na ->
          %{acc | ia_na: parse_ia_na(option.option_data)}

        @option_ia_ta ->
          %{acc | ia_ta: parse_ia_ta(option.option_data)}

        @option_rapid_commit ->
          %{acc | rapid_commit: true}

        @option_ia_pd ->
          %{acc | ia_pd: parse_ia_pd(option.option_data)}

        # Skip other options
        _ ->
          acc
      end
    end)
  end

  @doc """
  Extracts only client DUID - use when you only need the client identifier.

  For cases where only the client DUID is needed, this avoids
  the overhead of extracting other fields.
  """
  @spec extract_client_id([%{option_code: non_neg_integer(), option_data: binary()}]) ::
          binary() | nil
  def extract_client_id(options) do
    Enum.find_value(options, fn option ->
      if option.option_code == @option_client_id do
        option.option_data
      end
    end)
  end

  # Private helpers for parsing IA options

  defp parse_ia_na(<<iaid::32, _t1::32, _t2::32, rest::binary>>) do
    ia_addr = extract_ia_addr(rest)
    %{iaid: iaid, ia_addr: ia_addr, type: :ia_na}
  end

  defp parse_ia_na(_), do: nil

  defp parse_ia_ta(<<iaid::32, rest::binary>>) do
    ia_addr = extract_ia_addr(rest)
    %{iaid: iaid, ia_addr: ia_addr, type: :ia_ta}
  end

  defp parse_ia_ta(_), do: nil

  defp parse_ia_pd(<<iaid::32, _t1::32, _t2::32, rest::binary>>) do
    ia_prefix = extract_ia_prefix(rest)
    %{iaid: iaid, ia_prefix: ia_prefix, type: :ia_pd}
  end

  defp parse_ia_pd(_), do: nil

  defp extract_ia_addr(<<@option_ia_addr::16, len::16, data::binary-size(len), _rest::binary>>) do
    case data do
      <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16, _lifetimes::binary>> ->
        {a, b, c, d, e, f, g, h}

      _ ->
        nil
    end
  end

  defp extract_ia_addr(_), do: nil

  defp extract_ia_prefix(
         <<@option_ia_prefix::16, len::16, data::binary-size(len), _rest::binary>>
       ) do
    case data do
      <<_preferred::32, _valid::32, prefix_len::8, a::16, b::16, c::16, d::16, e::16, f::16,
        g::16, h::16>> ->
        {{a, b, c, d, e, f, g, h}, prefix_len}

      _ ->
        nil
    end
  end

  defp extract_ia_prefix(_), do: nil
end
