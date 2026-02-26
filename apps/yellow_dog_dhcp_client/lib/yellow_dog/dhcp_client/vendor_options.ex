defmodule YellowDog.DhcpClient.VendorOptions do
  @moduledoc """
  Encode/decode Yellow Dog vendor options using PEN-scoped Option 124/125.

  Yellow Dog uses IANA Private Enterprise Number (PEN) based vendor identification
  following RFC 3925 for clean namespacing. Option 124 (Vendor-Identifying Vendor
  Class) announces the client's identity. Option 125 (Vendor-Identifying
  Vendor-Specific Information) carries server-to-client data scoped by PEN.
  """

  @yellowdog_pen 99_999

  # Sub-option codes (v1)
  @sub_control_url 1
  @sub_server_id 2
  @sub_cluster_id 3
  @sub_auth_token 4
  @sub_control_url_fallback 5
  @sub_flags 6

  @doc """
  Returns the Yellow Dog PEN.
  """
  @spec pen() :: non_neg_integer()
  def pen, do: @yellowdog_pen

  @doc """
  Encodes Option 60 (Vendor Class Identifier) value.

  Format: `"YellowDog:{version}:{capability1,capability2,...}"`

  ## Parameters

    * `version` - Protocol version string, e.g. `"1.0"`
    * `capabilities` - List of capability atoms, e.g. `[:dns, :telemetry]`

  ## Examples

      iex> YellowDog.DhcpClient.VendorOptions.encode_client_id("1.0", [:dns, :telemetry])
      "YellowDog:1.0:dns,telemetry"
  """
  @spec encode_client_id(String.t(), [atom()]) :: binary()
  def encode_client_id(version, capabilities) when is_binary(version) do
    caps = capabilities |> Enum.map_join(",", &Atom.to_string/1)
    "YellowDog:#{version}:#{caps}"
  end

  @doc """
  Encodes Option 124 (Vendor-Identifying Vendor Class) value with the Yellow Dog PEN.

  RFC 3925 format:
  ```
  Enterprise Number (4 bytes)
  Data Length (1 byte)
  Vendor Class Data (variable)
  ```
  """
  @spec encode_vendor_class() :: binary()
  def encode_vendor_class do
    class_data = "YellowDog"
    data_len = byte_size(class_data)
    <<@yellowdog_pen::32, data_len::8, class_data::binary>>
  end

  @doc """
  Decodes Option 125 (Vendor-Identifying Vendor-Specific Information) binary.

  Extracts sub-options scoped to the Yellow Dog PEN. Returns `{:error, :pen_mismatch}`
  if the enterprise number does not match.

  RFC 3925 format:
  ```
  Enterprise Number (4 bytes)
  Data Length (1 byte)
  Sub-options (TLV encoded, variable)
  ```

  ## Returns

    * `{:ok, map}` with keys: `:control_url`, `:server_id`, `:cluster_id`,
      `:auth_token`, `:control_url_fallback`, `:flags`, plus any unknown codes
      as `{code, binary}` entries under `:unknown`
    * `{:error, :pen_mismatch}` if the PEN does not match
    * `{:error, :malformed}` if the binary cannot be parsed
  """
  @spec decode_vendor_info(binary()) :: {:ok, map()} | {:error, :pen_mismatch | :malformed}
  def decode_vendor_info(<<pen::32, data_len::8, data::binary-size(data_len), _rest::binary>>)
      when pen == @yellowdog_pen do
    {:ok, decode_sub_options(data)}
  end

  def decode_vendor_info(<<pen::32, _data_len::8, _rest::binary>>)
      when pen == @yellowdog_pen do
    {:error, :malformed}
  end

  def decode_vendor_info(<<_pen::32, _data_len::8, _rest::binary>>) do
    {:error, :pen_mismatch}
  end

  def decode_vendor_info(_) do
    {:error, :malformed}
  end

  @doc """
  Encodes a map of vendor-specific sub-options into TLV binary.

  Produces output suitable for wrapping in an Option 125 envelope via
  `encode_vendor_info/1`. Known keys are encoded with their sub-option codes;
  unknown keys are ignored.

  ## Examples

      iex> VendorOptions.encode_sub_options(%{control_url: "wss://srv:443", server_id: "s1"})
      <<1, 14, "wss://srv:443", 2, 2, "s1">>
  """
  @spec encode_sub_options(map()) :: binary()
  def encode_sub_options(opts) when is_map(opts) do
    parts =
      [
        encode_tlv(@sub_control_url, opts[:control_url]),
        encode_tlv(@sub_server_id, opts[:server_id]),
        encode_tlv(@sub_cluster_id, opts[:cluster_id]),
        encode_tlv(@sub_auth_token, opts[:auth_token]),
        encode_tlv(@sub_control_url_fallback, opts[:control_url_fallback]),
        encode_flags_tlv(opts[:flags])
      ]
      |> Enum.reject(&is_nil/1)

    IO.iodata_to_binary(parts)
  end

  @doc """
  Encodes a sub-option map into a full Option 125 binary with Yellow Dog PEN header.

  RFC 3925 format: `<<PEN::32, data_length::8, sub_options::binary>>`

  Raises `ArgumentError` if the encoded sub-options exceed 255 bytes
  (the maximum for the single-byte data length field per RFC 3925).
  """
  @spec encode_vendor_info(map()) :: binary()
  def encode_vendor_info(opts) when is_map(opts) do
    sub_binary = encode_sub_options(opts)
    size = byte_size(sub_binary)

    if size > 255 do
      raise ArgumentError,
            "vendor sub-options (#{size} bytes) exceed RFC 3925 maximum of 255 bytes"
    end

    <<@yellowdog_pen::32, size::8, sub_binary::binary>>
  end

  defp encode_tlv(_code, nil), do: nil

  defp encode_tlv(code, value) when is_binary(value) do
    <<code::8, byte_size(value)::8, value::binary>>
  end

  defp encode_flags_tlv(nil), do: nil
  defp encode_flags_tlv(flags) when is_integer(flags), do: <<@sub_flags::8, 2::8, flags::16>>

  @doc """
  Parses TLV-encoded sub-options into a named map.

  Known sub-option codes are resolved to descriptive keys. Unknown codes are
  collected under the `:unknown` key as `[{code, value}]` for forward compatibility.
  """
  @spec decode_sub_options(binary()) :: map()
  def decode_sub_options(data) do
    parse_sub_options(data, %{unknown: []})
  end

  defp parse_sub_options(<<>>, acc), do: finalize_sub_options(acc)
  defp parse_sub_options(<<255, _rest::binary>>, acc), do: finalize_sub_options(acc)
  defp parse_sub_options(<<0, rest::binary>>, acc), do: parse_sub_options(rest, acc)

  defp parse_sub_options(<<code::8, len::8, value::binary-size(len), rest::binary>>, acc) do
    acc = apply_sub_option(code, value, acc)
    parse_sub_options(rest, acc)
  end

  defp parse_sub_options(_malformed, acc), do: finalize_sub_options(acc)

  defp apply_sub_option(@sub_control_url, value, acc),
    do: Map.put(acc, :control_url, value)

  defp apply_sub_option(@sub_server_id, value, acc),
    do: Map.put(acc, :server_id, value)

  defp apply_sub_option(@sub_cluster_id, value, acc),
    do: Map.put(acc, :cluster_id, value)

  defp apply_sub_option(@sub_auth_token, value, acc),
    do: Map.put(acc, :auth_token, value)

  defp apply_sub_option(@sub_control_url_fallback, value, acc),
    do: Map.put(acc, :control_url_fallback, value)

  defp apply_sub_option(@sub_flags, <<flags::16>>, acc),
    do: Map.put(acc, :flags, flags)

  defp apply_sub_option(@sub_flags, _invalid, acc), do: acc

  defp apply_sub_option(code, value, acc),
    do: Map.update!(acc, :unknown, &[{code, value} | &1])

  defp finalize_sub_options(acc) do
    Map.update!(acc, :unknown, &Enum.reverse/1)
  end
end
