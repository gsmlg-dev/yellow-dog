defmodule YellowDog.Sync.Bounds do
  @moduledoc """
  Bounded values accepted by the control protocol.

  The first protocol version permits IDs up to 128 bytes, operations up to 256
  bytes, messages and nested error strings up to 1,024 bytes, maps up to 100
  entries, lists up to 1,000 entries, and payloads up to 1,048,576 bytes.
  Error details may nest maps and lists to a maximum depth of 8.
  """

  alias YellowDog.Sync.Error

  @max_id_bytes 128
  @max_operation_bytes 256
  @max_message_bytes 1_024
  @max_map_entries 100
  @max_list_entries 1_000
  @max_payload_bytes 1_048_576
  @max_error_details_depth 8

  @spec max_id_bytes() :: pos_integer()
  def max_id_bytes, do: @max_id_bytes

  @spec max_operation_bytes() :: pos_integer()
  def max_operation_bytes, do: @max_operation_bytes

  @spec max_message_bytes() :: pos_integer()
  def max_message_bytes, do: @max_message_bytes

  @spec max_map_entries() :: pos_integer()
  def max_map_entries, do: @max_map_entries

  @spec max_list_entries() :: pos_integer()
  def max_list_entries, do: @max_list_entries

  @spec max_payload_bytes() :: pos_integer()
  def max_payload_bytes, do: @max_payload_bytes

  @spec max_error_details_depth() :: pos_integer()
  def max_error_details_depth, do: @max_error_details_depth

  @spec id(term()) :: {:ok, String.t()} | {:error, Error.t()}
  def id(value), do: bounded_text(value, @max_id_bytes)

  @spec operation(term()) :: {:ok, String.t()} | {:error, Error.t()}
  def operation(value), do: bounded_text(value, @max_operation_bytes)

  @spec message(term()) :: {:ok, String.t()} | {:error, Error.t()}
  def message(value), do: bounded_text(value, @max_message_bytes)

  @spec map(term()) :: {:ok, map()} | {:error, Error.t()}
  def map(value) when is_map(value) and map_size(value) <= @max_map_entries, do: {:ok, value}
  def map(_value), do: invalid_error()

  @spec list(term()) :: {:ok, list()} | {:error, Error.t()}
  def list(value) do
    if list_within_limit?(value, @max_list_entries), do: {:ok, value}, else: invalid_error()
  end

  @spec details(term()) :: {:ok, map()} | {:error, Error.t()}
  def details(value) when is_map(value), do: validate_detail(value, @max_error_details_depth)
  def details(_value), do: invalid_error()

  @spec payload(term()) :: {:ok, binary()} | {:error, Error.t()}
  def payload(value), do: bounded_binary(value, @max_payload_bytes)

  defp bounded_binary(value, maximum) when is_binary(value) and byte_size(value) <= maximum,
    do: {:ok, value}

  defp bounded_binary(_value, _maximum), do: invalid_error()

  defp bounded_text(value, maximum) when is_binary(value) and byte_size(value) <= maximum do
    if String.valid?(value), do: {:ok, value}, else: invalid_error()
  end

  defp bounded_text(_value, _maximum), do: invalid_error()

  defp validate_detail(value, depth) when is_map(value) and depth > 0 do
    validate_detail_map(value, depth - 1)
  end

  defp validate_detail([], depth) when depth > 0 do
    validate_detail_list([], depth - 1, @max_list_entries, [])
  end

  defp validate_detail([_value | _rest] = value, depth) when depth > 0 do
    validate_detail_list(value, depth - 1, @max_list_entries, [])
  end

  defp validate_detail(value, _depth) when is_binary(value), do: message(value)

  defp validate_detail(value, _depth)
       when is_nil(value) or is_boolean(value) or is_integer(value) or is_float(value),
       do: {:ok, value}

  defp validate_detail(_value, _depth), do: invalid_error()

  defp validate_detail_map(value, depth) when map_size(value) <= @max_map_entries do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, nested_value}, {:ok, details} ->
      with {:ok, key} <- message(key),
           {:ok, nested_value} <- validate_detail(nested_value, depth) do
        {:cont, {:ok, Map.put(details, key, nested_value)}}
      else
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  defp validate_detail_map(_value, _depth), do: invalid_error()

  defp validate_detail_list([], _depth, _remaining, values), do: {:ok, Enum.reverse(values)}
  defp validate_detail_list([_value | _rest], _depth, 0, _values), do: invalid_error()

  defp validate_detail_list([value | rest], depth, remaining, values) do
    with {:ok, value} <- validate_detail(value, depth) do
      validate_detail_list(rest, depth, remaining - 1, [value | values])
    end
  end

  defp validate_detail_list(_value, _depth, _remaining, _values), do: invalid_error()

  defp list_within_limit?([], _remaining), do: true
  defp list_within_limit?([_value | _rest], 0), do: false

  defp list_within_limit?([_value | rest], remaining) do
    list_within_limit?(rest, remaining - 1)
  end

  defp list_within_limit?(_value, _remaining), do: false

  defp invalid_error, do: {:error, Error.new(:invalid, "invalid value", %{})}
end
