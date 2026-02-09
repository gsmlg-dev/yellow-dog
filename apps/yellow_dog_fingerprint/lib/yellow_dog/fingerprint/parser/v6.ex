defmodule YellowDog.Fingerprint.Parser.V6 do
  @moduledoc """
  Extracts fingerprint signals from DHCPv6 messages.

  Builds a `Fingerprint` struct from DHCPv6 option data received
  via telemetry events. The primary signal is Option 6 (Option Request)
  combined with Option 16 (Vendor Class).
  """

  alias YellowDog.Fingerprint.Types.Fingerprint

  @doc """
  Extracts a fingerprint from DHCPv6 telemetry metadata.

  Expects metadata with keys:
  - `:option_6` — list of requested option codes (integers)
  - `:option_16` — vendor class data (map with `:enterprise_id` and `:data`, or nil)
  - `:option_39` — client FQDN (or nil)
  - `:duid` — client DUID binary (or nil)

  Returns `{:ok, fingerprint}` or `:skip` if insufficient data.
  """
  @spec extract(map()) :: {:ok, Fingerprint.t()} | :skip
  def extract(metadata) do
    option_request = Map.get(metadata, :option_6, [])

    if option_request == [] do
      :skip
    else
      vendor_class = format_vendor_class(Map.get(metadata, :option_16))
      fqdn = Map.get(metadata, :option_39)
      now = DateTime.utc_now()
      id = Fingerprint.compute_id(:dhcpv6, option_request, vendor_class)

      fingerprint = %Fingerprint{
        id: id,
        protocol: :dhcpv6,
        parameter_list: option_request,
        vendor_class: vendor_class,
        hostname_pattern: normalize_fqdn(fqdn),
        first_seen: now,
        last_seen: now,
        hit_count: 1
      }

      {:ok, fingerprint}
    end
  end

  @doc """
  Extracts Option 6 (Option Request) from raw DHCPv6 options.

  Each option is `%{option_code: integer(), option_data: binary()}`.
  Option 6 contains 2-byte option codes.
  """
  @spec extract_option_6([map()]) :: [non_neg_integer()]
  def extract_option_6(options) do
    case find_option(options, 6) do
      nil -> []
      data -> decode_option_request(data)
    end
  end

  @doc """
  Extracts Option 16 (Vendor Class) from raw DHCPv6 options.

  Returns `%{enterprise_id: integer(), data: binary()}` or nil.
  """
  @spec extract_option_16([map()]) :: map() | nil
  def extract_option_16(options) do
    case find_option(options, 16) do
      <<enterprise_id::32, rest::binary>> ->
        %{enterprise_id: enterprise_id, data: rest}

      _ ->
        nil
    end
  end

  @doc """
  Extracts Option 39 (Client FQDN) from raw DHCPv6 options.
  """
  @spec extract_option_39([map()]) :: String.t() | nil
  def extract_option_39(options) do
    case find_option(options, 39) do
      <<_flags::8, rest::binary>> ->
        rest
        |> String.trim_trailing(<<0>>)
        |> case do
          "" -> nil
          fqdn -> fqdn
        end

      _ ->
        nil
    end
  end

  @doc """
  Analyzes DUID type from raw DUID binary.

  Returns the DUID type integer:
  - 1: DUID-LLT (Link-Layer + Time)
  - 2: DUID-EN (Enterprise Number)
  - 3: DUID-LL (Link-Layer)
  - 4: DUID-UUID
  """
  @spec duid_type(binary() | nil) :: non_neg_integer() | nil
  def duid_type(nil), do: nil
  def duid_type(<<type::16, _rest::binary>>), do: type
  def duid_type(_), do: nil

  @doc """
  Extracts all fingerprint-relevant options from a raw DHCPv6 option list.
  """
  @spec extract_all_options([map()]) :: map()
  def extract_all_options(options) do
    %{
      option_6: extract_option_6(options),
      option_16: extract_option_16(options),
      option_39: extract_option_39(options),
      duid: find_option(options, 1),
      has_ia_na: find_option(options, 3) != nil,
      has_ia_pd: find_option(options, 25) != nil,
      option_8: extract_elapsed_time(options)
    }
  end

  defp extract_elapsed_time(options) do
    case find_option(options, 8) do
      <<elapsed::16>> -> elapsed
      _ -> nil
    end
  end

  defp find_option(options, code) do
    Enum.find_value(options, fn
      %{option_code: ^code, option_data: data} -> data
      _ -> nil
    end)
  end

  defp decode_option_request(data), do: decode_option_request(data, [])
  defp decode_option_request(<<>>, acc), do: Enum.reverse(acc)
  defp decode_option_request(<<code::16, rest::binary>>, acc), do: decode_option_request(rest, [code | acc])
  defp decode_option_request(_, acc), do: Enum.reverse(acc)

  defp format_vendor_class(nil), do: nil
  defp format_vendor_class(%{enterprise_id: eid, data: data}), do: "#{eid}:#{data}"
  defp format_vendor_class(_), do: nil

  defp normalize_fqdn(nil), do: nil

  defp normalize_fqdn(fqdn) do
    fqdn
    |> String.downcase()
    |> String.replace(~r/[0-9]+/, "*")
    |> String.replace(~r/\*+/, "*")
  end
end
