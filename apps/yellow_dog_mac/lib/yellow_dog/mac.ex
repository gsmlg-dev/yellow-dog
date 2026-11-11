defmodule YellowDog.MAC do
  @moduledoc """
  YellowDog.MAC provides comprehensive MAC address utilities.

  This module provides MAC address validation, normalization, formatting,
  vendor lookup, and random MAC generation.
  """

  alias YellowDog.MAC.Parser

  @doc """
  Lookup manufacturer/vendor of a MAC address.

  Returns `{:ok, short_name, full_name}` if found, `:error` otherwise.

  ## Examples

      iex> YellowDog.MAC.lookup_vendor("00:00:0A:BB:28:FC")
      {:ok, "OmronTat", "Omron Tateisi Electronics Co."}

      iex> YellowDog.MAC.lookup_vendor("00-50-56-C0-00-08")
      {:ok, "VMware", "VMware, Inc."}

      iex> YellowDog.MAC.lookup_vendor("FF:FF:FF:FF:FF:FF")
      :error

  """
  @spec lookup_vendor(String.t()) :: {:ok, String.t(), String.t()} | :error
  def lookup_vendor(mac) when is_binary(mac) do
    result = YellowDog.MAC.Vendor.lookup(mac)
    emit_telemetry_lookup(mac, result)
    result
  end

  @doc """
  Validates if a string is a valid MAC address format.

  Returns `true` for valid MAC addresses, `false` otherwise.

  Accepts formats: XX:XX:XX:XX:XX:XX, XX-XX-XX-XX-XX-XX, XXXX.XXXX.XXXX, XXXXXXXXXXXX

  ## Examples

      iex> YellowDog.MAC.validate("00:1A:2B:3C:4D:5E")
      true

      iex> YellowDog.MAC.validate("00-1A-2B-3C-4D-5E")
      true

      iex> YellowDog.MAC.validate("001A.2B3C.4D5E")
      true

      iex> YellowDog.MAC.validate("001A2B3C4D5E")
      true

      iex> YellowDog.MAC.validate("invalid")
      false

      iex> YellowDog.MAC.validate("00:1A:2B:3C:4D")
      false

  """
  @spec validate(String.t()) :: boolean()
  def validate(mac) when is_binary(mac) do
    result =
      case Parser.to_bitstring(mac) do
        <<_::bits-size(48)>> -> true
        _ -> false
      end

    emit_telemetry_operation(:validate, mac, if(result, do: :ok, else: :error))
    result
  end

  def validate(_), do: false

  @doc """
  Normalizes a MAC address to standard uppercase colon-separated format.

  Returns `{:ok, normalized_mac}` or `{:error, :invalid_mac}`.

  ## Examples

      iex> YellowDog.MAC.normalize("00-1a-2b-3c-4d-5e")
      {:ok, "00:1A:2B:3C:4D:5E"}

      iex> YellowDog.MAC.normalize("001a.2b3c.4d5e")
      {:ok, "00:1A:2B:3C:4D:5E"}

      iex> YellowDog.MAC.normalize("001a2b3c4d5e")
      {:ok, "00:1A:2B:3C:4D:5E"}

      iex> YellowDog.MAC.normalize("invalid")
      {:error, :invalid_mac}

  """
  @spec normalize(String.t()) :: {:ok, String.t()} | {:error, :invalid_mac}
  def normalize(mac) when is_binary(mac) do
    result =
      case Parser.to_bitstring(mac) do
        <<a::8, b::8, c::8, d::8, e::8, f::8>> ->
          normalized =
            [a, b, c, d, e, f]
            |> Enum.map(&to_hex_byte/1)
            |> Enum.join(":")

          {:ok, normalized}

        _ ->
          {:error, :invalid_mac}
      end

    emit_telemetry_operation(:normalize, mac, elem(result, 0))
    result
  end

  def normalize(_), do: {:error, :invalid_mac}

  @doc """
  Formats a MAC address with specified separator style.

  Format options:
  - `:colons` - 00:1A:2B:3C:4D:5E (default)
  - `:hyphens` - 00-1A-2B-3C-4D-5E
  - `:dots` or `:cisco` - 001A.2B3C.4D5E
  - `:none` - 001A2B3C4D5E

  Returns `{:ok, formatted_mac}` or `{:error, reason}`.

  ## Examples

      iex> YellowDog.MAC.format("001a2b3c4d5e", :colons)
      {:ok, "00:1A:2B:3C:4D:5E"}

      iex> YellowDog.MAC.format("00:1A:2B:3C:4D:5E", :hyphens)
      {:ok, "00-1A-2B-3C-4D-5E"}

      iex> YellowDog.MAC.format("001A2B3C4D5E", :dots)
      {:ok, "001A.2B3C.4D5E"}

      iex> YellowDog.MAC.format("00:1A:2B:3C:4D:5E", :none)
      {:ok, "001A2B3C4D5E"}

  """
  @spec format(String.t(), atom()) ::
          {:ok, String.t()} | {:error, :invalid_mac | :invalid_format}
  def format(mac, format_type \\ :colons) when is_binary(mac) and is_atom(format_type) do
    result =
      with <<a::8, b::8, c::8, d::8, e::8, f::8>> <- Parser.to_bitstring(mac) do
        bytes = [a, b, c, d, e, f] |> Enum.map(&to_hex_byte/1)

        formatted =
          case format_type do
            :colons -> Enum.join(bytes, ":")
            :hyphens -> Enum.join(bytes, "-")
            :dots -> format_cisco(bytes)
            :cisco -> format_cisco(bytes)
            :none -> Enum.join(bytes, "")
            _ -> :invalid_format
          end

        case formatted do
          :invalid_format -> {:error, :invalid_format}
          result -> {:ok, result}
        end
      else
        _ -> {:error, :invalid_mac}
      end

    emit_telemetry_operation(:format, mac, elem(result, 0))
    result
  end

  @doc """
  Extracts the OUI (Organizationally Unique Identifier) from a MAC address.

  The OUI is the first 24 bits (3 bytes) that identify the vendor.

  Returns `{:ok, oui}` or `{:error, :invalid_mac}`.

  ## Examples

      iex> YellowDog.MAC.parse_oui("00:1A:2B:3C:4D:5E")
      {:ok, "00:1A:2B"}

      iex> YellowDog.MAC.parse_oui("00-1A-2B-3C-4D-5E")
      {:ok, "00:1A:2B"}

      iex> YellowDog.MAC.parse_oui("invalid")
      {:error, :invalid_mac}

  """
  @spec parse_oui(String.t()) :: {:ok, String.t()} | {:error, :invalid_mac}
  def parse_oui(mac) when is_binary(mac) do
    result =
      case Parser.to_bitstring(mac) do
        <<a::8, b::8, c::8, _::bits>> ->
          oui = [a, b, c] |> Enum.map(&to_hex_byte/1) |> Enum.join(":")
          {:ok, oui}

        _ ->
          {:error, :invalid_mac}
      end

    emit_telemetry_operation(:parse_oui, mac, elem(result, 0))
    result
  end

  def parse_oui(_), do: {:error, :invalid_mac}

  @doc """
  Generates a random MAC address.

  With no arguments, generates a fully random MAC.
  With an OUI argument, generates a random MAC with that OUI.

  Returns a MAC string in colon-separated format, or `{:error, :invalid_oui}`.

  ## Examples

      iex> mac = YellowDog.MAC.random()
      iex> YellowDog.MAC.validate(mac)
      true

      iex> mac = YellowDog.MAC.random("00:1A:2B")
      iex> String.starts_with?(mac, "00:1A:2B")
      true

      iex> YellowDog.MAC.random("invalid")
      {:error, :invalid_oui}

  """
  @spec random() :: String.t()
  @spec random(String.t()) :: String.t() | {:error, :invalid_oui}
  def random do
    bytes = for _ <- 1..6, do: :rand.uniform(256) - 1
    result = bytes |> Enum.map(&to_hex_byte/1) |> Enum.join(":")
    emit_telemetry_operation(:random, "random", :ok)
    result
  end

  def random(oui) when is_binary(oui) do
    result =
      case Parser.to_bitstring(oui) do
        <<a::8, b::8, c::8>> ->
          random_bytes = for _ <- 1..3, do: :rand.uniform(256) - 1
          all_bytes = [a, b, c | random_bytes]
          all_bytes |> Enum.map(&to_hex_byte/1) |> Enum.join(":")

        _ ->
          {:error, :invalid_oui}
      end

    emit_telemetry_operation(:random, oui, if(is_binary(result), do: :ok, else: :error))
    result
  end

  # Private Helpers
  # ---------------

  defp to_hex_byte(byte) do
    byte
    |> Integer.to_string(16)
    |> String.pad_leading(2, "0")
    |> String.upcase()
  end

  defp format_cisco(bytes) do
    bytes
    |> Enum.chunk_every(2)
    |> Enum.map(&Enum.join/1)
    |> Enum.join(".")
  end

  defp emit_telemetry_lookup(mac, result) do
    {found, metadata} =
      case result do
        {:ok, short, full} ->
          {true, %{vendor_short: short, vendor_full: full}}

        :error ->
          {false, %{}}
      end

    oui =
      case parse_oui(mac) do
        {:ok, oui} -> oui
        _ -> nil
      end

    :telemetry.execute(
      [:yellow_dog, :mac, :lookup],
      %{},
      Map.merge(metadata, %{mac: mac, oui: oui, found: found})
    )
  rescue
    _ -> :ok
  end

  defp emit_telemetry_operation(operation, mac, result) do
    :telemetry.execute(
      [:yellow_dog, :mac, :operation],
      %{},
      %{operation: operation, mac: mac, result: result}
    )
  rescue
    _ -> :ok
  end
end
