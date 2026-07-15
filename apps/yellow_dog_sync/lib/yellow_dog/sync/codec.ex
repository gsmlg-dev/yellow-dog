defmodule YellowDog.Sync.Codec do
  @moduledoc false

  alias YellowDog.Sync.Bounds
  alias YellowDog.Sync.Error

  @spec encode(term()) :: {:ok, binary()} | {:error, Error.t()}
  def encode(value) do
    with {:ok, iodata} <- canonical(value, Bounds.max_error_details_depth() - 1) do
      {:ok, IO.iodata_to_binary(iodata)}
    end
  end

  @spec decode(binary()) :: {:ok, term()} | {:error, Error.t()}
  def decode(payload) when is_binary(payload) do
    with {:ok, payload} <- Bounds.payload(payload),
         {:ok, value} <- Jason.decode(payload),
         {:ok, _iodata} <- canonical(value, Bounds.max_error_details_depth() - 1) do
      {:ok, value}
    else
      _ -> invalid_error()
    end
  end

  def decode(_payload), do: invalid_error()

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
