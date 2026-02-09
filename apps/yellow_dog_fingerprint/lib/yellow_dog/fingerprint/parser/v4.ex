defmodule YellowDog.Fingerprint.Parser.V4 do
  @moduledoc """
  Extracts fingerprint signals from DHCPv4 messages.

  Builds a `Fingerprint` struct from DHCPv4 option data received
  via telemetry events. The primary signal is Option 55 (Parameter
  Request List) combined with Option 60 (Vendor Class Identifier).
  """

  alias YellowDog.Fingerprint.Types.Fingerprint

  @doc """
  Extracts a fingerprint from DHCPv4 telemetry metadata.

  Expects metadata with keys:
  - `:option_55` — list of requested option codes (integers)
  - `:option_60` — vendor class identifier string (or nil)
  - `:option_12` — hostname (or nil)

  Returns `{:ok, fingerprint}` or `:skip` if insufficient data.
  """
  @spec extract(map()) :: {:ok, Fingerprint.t()} | :skip
  def extract(metadata) do
    parameter_list = Map.get(metadata, :option_55, [])

    if parameter_list == [] do
      :skip
    else
      vendor_class = Map.get(metadata, :option_60)
      hostname = Map.get(metadata, :option_12)
      now = DateTime.utc_now()
      id = Fingerprint.compute_id(:dhcpv4, parameter_list, vendor_class)

      fingerprint = %Fingerprint{
        id: id,
        protocol: :dhcpv4,
        parameter_list: parameter_list,
        vendor_class: vendor_class,
        hostname_pattern: normalize_hostname(hostname),
        first_seen: now,
        last_seen: now,
        hit_count: 1
      }

      {:ok, fingerprint}
    end
  end

  @doc """
  Extracts Option 55 (Parameter Request List) from raw DHCPv4 options.

  Each option is `%{type: integer(), value: binary()}`.
  Returns a list of integer option codes.
  """
  @spec extract_option_55([map()]) :: [non_neg_integer()]
  def extract_option_55(options) do
    case find_option(options, 55) do
      nil -> []
      value -> :binary.bin_to_list(value)
    end
  end

  @doc """
  Extracts Option 60 (Vendor Class Identifier) from raw DHCPv4 options.
  """
  @spec extract_option_60([map()]) :: String.t() | nil
  def extract_option_60(options) do
    case find_option(options, 60) do
      nil -> nil
      value -> String.trim_trailing(value, <<0>>)
    end
  end

  @doc """
  Extracts Option 12 (Hostname) from raw DHCPv4 options.
  """
  @spec extract_option_12([map()]) :: String.t() | nil
  def extract_option_12(options) do
    case find_option(options, 12) do
      nil -> nil
      value -> String.trim_trailing(value, <<0>>)
    end
  end

  @doc """
  Extracts all fingerprint-relevant options from a raw option list.

  Returns a map suitable for passing to `extract/1`.
  """
  @spec extract_all_options([map()]) :: map()
  def extract_all_options(options) do
    %{
      option_55: extract_option_55(options),
      option_60: extract_option_60(options),
      option_12: extract_option_12(options),
      option_61: find_option(options, 61),
      option_57: extract_option_57(options),
      option_93: extract_option_93(options)
    }
  end

  defp extract_option_57(options) do
    case find_option(options, 57) do
      <<size::16>> -> size
      _ -> nil
    end
  end

  defp extract_option_93(options) do
    case find_option(options, 93) do
      <<arch::16>> -> arch
      _ -> nil
    end
  end

  defp find_option(options, code) do
    Enum.find_value(options, fn
      %{type: ^code, value: value} -> value
      _ -> nil
    end)
  end

  defp normalize_hostname(nil), do: nil

  defp normalize_hostname(hostname) do
    hostname
    |> String.downcase()
    |> String.replace(~r/[0-9]+/, "*")
    |> String.replace(~r/\*+/, "*")
  end
end
