defmodule YellowDog.Sync.Bounds do
  alias YellowDog.Sync.Error

  @max_id_bytes 128
  @max_operation_bytes 256
  @max_message_bytes 1_024
  @max_map_entries 100
  @max_list_entries 1_000
  @max_payload_bytes 1_048_576

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
  def list(value) when is_list(value) and length(value) <= @max_list_entries, do: {:ok, value}
  def list(_value), do: invalid_error()

  @spec payload(term()) :: {:ok, binary()} | {:error, Error.t()}
  def payload(value), do: bounded_binary(value, @max_payload_bytes)

  defp bounded_binary(value, maximum) when is_binary(value) and byte_size(value) <= maximum,
    do: {:ok, value}

  defp bounded_binary(_value, _maximum), do: invalid_error()

  defp bounded_text(value, maximum) when is_binary(value) and byte_size(value) <= maximum do
    if String.valid?(value), do: {:ok, value}, else: invalid_error()
  end

  defp bounded_text(_value, _maximum), do: invalid_error()

  defp invalid_error, do: {:error, Error.new(:invalid, "invalid value", %{})}
end
