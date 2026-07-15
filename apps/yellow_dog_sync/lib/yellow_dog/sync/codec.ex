defmodule YellowDog.Sync.Codec do
  @moduledoc false

  alias YellowDog.Sync.Bounds
  alias YellowDog.Sync.Error

  # Envelope metadata is capped at 3,865 bytes in canonical JSON: its bounded
  # values need at most 3,708 escaped bytes, with 157 bytes for fixed keys and
  # JSON punctuation. Leave 231 bytes of fixed headroom for the protocol shape.
  @max_envelope_overhead_bytes 4_096

  @spec max_document_bytes() :: pos_integer()
  def max_document_bytes, do: Bounds.max_payload_bytes() + @max_envelope_overhead_bytes

  @spec encode(term()) :: {:ok, binary()} | {:error, Error.t()}
  def encode(value), do: encode(value, Bounds.max_error_details_depth())

  @spec encode_envelope(term()) :: {:ok, binary()} | {:error, Error.t()}
  def encode_envelope(value) do
    with {:ok, encoded} <- encode(value, Bounds.max_error_details_depth() + 1),
         {:ok, _encoded} <- document(encoded) do
      {:ok, encoded}
    end
  end

  @spec decode(binary()) :: {:ok, term()} | {:error, Error.t()}
  def decode(payload), do: decode(payload, Bounds.max_error_details_depth())

  @spec decode_envelope(binary()) :: {:ok, term()} | {:error, Error.t()}
  def decode_envelope(payload), do: decode(payload, Bounds.max_error_details_depth() + 1)

  defp encode(value, max_depth) do
    with {:ok, iodata} <- canonical(value, max_depth) do
      {:ok, IO.iodata_to_binary(iodata)}
    end
  end

  defp decode(payload, max_depth) when is_binary(payload) do
    with {:ok, payload} <- document(payload),
         :ok <- preflight(payload, max_depth),
         {:ok, value} <- Jason.decode(payload),
         {:ok, _iodata} <- canonical(value, max_depth) do
      {:ok, value}
    else
      _ -> invalid_error()
    end
  end

  defp decode(_payload, _max_depth), do: invalid_error()

  defp document(payload) do
    if byte_size(payload) <= max_document_bytes() do
      {:ok, payload}
    else
      invalid_error()
    end
  end

  # This only limits nesting before materialization. Jason remains responsible
  # for validating JSON grammar, including container matching and UTF-8.
  defp preflight(payload, max_depth), do: scan(payload, 0, false, max_depth)

  defp scan(<<>>, _depth, _in_string, _max_depth), do: :ok

  defp scan(<<92, _escaped, rest::binary>>, depth, true, max_depth),
    do: scan(rest, depth, true, max_depth)

  defp scan(<<92>>, _depth, true, _max_depth), do: :ok

  defp scan(<<?\", rest::binary>>, depth, true, max_depth),
    do: scan(rest, depth, false, max_depth)

  defp scan(<<_byte, rest::binary>>, depth, true, max_depth),
    do: scan(rest, depth, true, max_depth)

  defp scan(<<?\", rest::binary>>, depth, false, max_depth),
    do: scan(rest, depth, true, max_depth)

  defp scan(<<byte, rest::binary>>, depth, false, max_depth) when byte in [?{, ?[] do
    next_depth = depth + 1

    if next_depth <= max_depth do
      scan(rest, next_depth, false, max_depth)
    else
      invalid_error()
    end
  end

  defp scan(<<byte, rest::binary>>, depth, false, max_depth) when byte in [?}, ?]] do
    scan(rest, max(depth - 1, 0), false, max_depth)
  end

  defp scan(<<_byte, rest::binary>>, depth, false, max_depth),
    do: scan(rest, depth, false, max_depth)

  defp canonical(value, _depth) when is_binary(value) do
    with {:ok, value} <- Bounds.message(value),
         {:ok, encoded} <- Jason.encode(value) do
      {:ok, encoded}
    else
      _ -> invalid_error()
    end
  end

  defp canonical(value, _depth) when is_integer(value), do: {:ok, Integer.to_string(value)}

  defp canonical(value, _depth) when is_float(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> {:ok, encoded}
      _ -> invalid_error()
    end
  end

  defp canonical(true, _depth), do: {:ok, "true"}
  defp canonical(false, _depth), do: {:ok, "false"}
  defp canonical(nil, _depth), do: {:ok, "null"}

  defp canonical(value, depth) when is_map(value) and depth > 0 do
    with {:ok, value} <- Bounds.map(value) do
      value
      |> Enum.sort_by(fn {key, _nested_value} -> key end)
      |> canonical_map([], depth - 1)
    end
  end

  defp canonical(value, depth) when is_list(value) and depth > 0 do
    with {:ok, value} <- Bounds.list(value) do
      canonical_list(value, [], depth - 1)
    end
  end

  defp canonical(_value, _depth), do: invalid_error()

  defp canonical_map([], values, _depth), do: {:ok, ["{", Enum.reverse(values), "}"]}

  defp canonical_map([{key, value} | rest], values, depth) do
    with {:ok, key} <- canonical_key(key, depth),
         {:ok, value} <- canonical(value, depth) do
      separator = if values == [], do: [], else: [","]
      canonical_map(rest, [[separator, key, ":", value] | values], depth)
    end
  end

  defp canonical_list([], values, _depth), do: {:ok, ["[", Enum.reverse(values), "]"]}

  defp canonical_list([value | rest], values, depth) do
    with {:ok, value} <- canonical(value, depth) do
      separator = if values == [], do: [], else: [","]
      canonical_list(rest, [[separator, value] | values], depth)
    end
  end

  defp canonical_key(key, depth) when is_binary(key), do: canonical(key, depth)
  defp canonical_key(_key, _depth), do: invalid_error()

  defp invalid_error, do: {:error, Error.new(:invalid, "invalid value", %{})}
end
