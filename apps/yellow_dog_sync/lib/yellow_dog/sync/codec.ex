defmodule YellowDog.Sync.Codec do
  @moduledoc false

  alias YellowDog.Sync.Bounds
  alias YellowDog.Sync.Error

  @spec encode(term()) :: {:ok, binary()} | {:error, Error.t()}
  def encode(value) do
    with {:ok, iodata} <- canonical(value) do
      {:ok, IO.iodata_to_binary(iodata)}
    end
  end

  @spec decode(binary()) :: {:ok, term()} | {:error, Error.t()}
  def decode(payload) when is_binary(payload) do
    with {:ok, value} <- Jason.decode(payload),
         {:ok, _iodata} <- canonical(value) do
      {:ok, value}
    else
      _ -> invalid_error()
    end
  end

  def decode(_payload), do: invalid_error()

  defp canonical(value) when is_binary(value) do
    with {:ok, value} <- Bounds.message(value),
         {:ok, encoded} <- Jason.encode(value) do
      {:ok, encoded}
    else
      _ -> invalid_error()
    end
  end

  defp canonical(value) when is_integer(value), do: {:ok, Integer.to_string(value)}
  defp canonical(value) when is_float(value), do: Jason.encode(value)
  defp canonical(true), do: {:ok, "true"}
  defp canonical(false), do: {:ok, "false"}
  defp canonical(nil), do: {:ok, "null"}

  defp canonical(value) when is_map(value) do
    with {:ok, value} <- Bounds.map(value) do
      value
      |> Enum.sort_by(fn {key, _nested_value} -> key end)
      |> canonical_map([])
    end
  end

  defp canonical(value) when is_list(value) do
    with {:ok, value} <- Bounds.list(value) do
      canonical_list(value, [])
    end
  end

  defp canonical(_value), do: invalid_error()

  defp canonical_map([], values), do: {:ok, ["{", Enum.reverse(values), "}"]}

  defp canonical_map([{key, value} | rest], values) do
    with {:ok, key} <- canonical_key(key),
         {:ok, value} <- canonical(value) do
      separator = if values == [], do: [], else: [","]
      canonical_map(rest, [[separator, key, ":", value] | values])
    end
  end

  defp canonical_list([], values), do: {:ok, ["[", Enum.reverse(values), "]"]}

  defp canonical_list([value | rest], values) do
    with {:ok, value} <- canonical(value) do
      separator = if values == [], do: [], else: [","]
      canonical_list(rest, [[separator, value] | values])
    end
  end

  defp canonical_key(key) when is_binary(key), do: canonical(key)
  defp canonical_key(_key), do: invalid_error()

  defp invalid_error, do: {:error, Error.new(:invalid, "invalid value", %{})}
end
