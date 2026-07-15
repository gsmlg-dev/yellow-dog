defmodule YellowDog.Management.Event do
  @moduledoc """
  Concrete management event emitted by server and Netman registries.
  """

  @enforce_keys [:id, :source, :source_id, :type, :occurred_at, :sequence]
  defstruct [
    :id,
    :source,
    :source_id,
    :type,
    :message,
    :occurred_at,
    :sequence,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          source: :server | :netman,
          source_id: String.t(),
          type: atom(),
          message: String.t() | nil,
          metadata: map(),
          occurred_at: DateTime.t(),
          sequence: pos_integer()
        }

  @doc false
  def new(attrs) do
    sequence = System.unique_integer([:positive, :monotonic])
    new(attrs, sequence)
  end

  @doc false
  def new(attrs, sequence) when is_integer(sequence) and sequence > 0 do
    %__MODULE__{
      id: "evt-#{sequence}",
      source: Map.fetch!(attrs, :source),
      source_id: Map.fetch!(attrs, :source_id),
      type: Map.fetch!(attrs, :type),
      message: Map.get(attrs, :message),
      metadata: Map.get(attrs, :metadata, %{}),
      occurred_at: DateTime.utc_now(:second),
      sequence: sequence
    }
  end

  @doc false
  def to_map(%__MODULE__{} = event) do
    %{
      "id" => event.id,
      "source" => Atom.to_string(event.source),
      "source_id" => event.source_id,
      "type" => Atom.to_string(event.type),
      "message" => event.message,
      "metadata" => encode_metadata(event.metadata),
      "occurred_at" => DateTime.to_iso8601(event.occurred_at),
      "sequence" => event.sequence
    }
  end

  @doc false
  def from_map(
        %{
          "id" => id,
          "source" => source,
          "source_id" => source_id,
          "type" => type,
          "message" => message,
          "metadata" => metadata,
          "occurred_at" => occurred_at,
          "sequence" => sequence
        } = value
      ) do
    with true <- map_size(value) == 8,
         true <- is_integer(sequence) and sequence > 0,
         true <- id == "evt-#{sequence}",
         {:ok, source} <- decode_source(source),
         {:ok, source_id} <- decode_source_id(source_id),
         {:ok, type} <- decode_type(type),
         {:ok, message} <- decode_message(message),
         {:ok, metadata} <- decode_metadata(metadata),
         {:ok, occurred_at} <- decode_datetime(occurred_at) do
      {:ok,
       %__MODULE__{
         id: id,
         source: source,
         source_id: source_id,
         type: type,
         message: message,
         metadata: metadata,
         occurred_at: occurred_at,
         sequence: sequence
       }}
    else
      _invalid -> :error
    end
  end

  def from_map(_value), do: :error

  @doc false
  def encode_metadata(metadata) do
    metadata
    |> Enum.sort_by(fn {key, _value} -> inspect(key) end)
    |> Enum.map(fn {key, value} ->
      %{"key" => encode_scalar(key), "value" => encode_scalar(value)}
    end)
  end

  @doc false
  def decode_metadata(entries) when is_list(entries) do
    with {:ok, pairs} <- decode_metadata_entries(entries),
         metadata <- Map.new(pairs),
         true <- map_size(metadata) == length(pairs) do
      {:ok, metadata}
    else
      _invalid -> :error
    end
  end

  def decode_metadata(_entries), do: :error

  @doc false
  def encode_scalar(value) when is_atom(value),
    do: %{"type" => "atom", "value" => Atom.to_string(value)}

  def encode_scalar(value) when is_binary(value), do: %{"type" => "string", "value" => value}
  def encode_scalar(value) when is_boolean(value), do: %{"type" => "boolean", "value" => value}
  def encode_scalar(value) when is_integer(value), do: %{"type" => "integer", "value" => value}
  def encode_scalar(value) when is_float(value), do: %{"type" => "float", "value" => value}

  def encode_scalar(%DateTime{} = value),
    do: %{"type" => "datetime", "value" => DateTime.to_iso8601(value)}

  @doc false
  def decode_scalar(%{"type" => "atom", "value" => value}) when is_binary(value) do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError -> :error
  end

  def decode_scalar(%{"type" => "string", "value" => value}) when is_binary(value),
    do: {:ok, value}

  def decode_scalar(%{"type" => "boolean", "value" => value}) when is_boolean(value),
    do: {:ok, value}

  def decode_scalar(%{"type" => "integer", "value" => value}) when is_integer(value),
    do: {:ok, value}

  def decode_scalar(%{"type" => "float", "value" => value}) when is_float(value),
    do: {:ok, value}

  def decode_scalar(%{"type" => "datetime", "value" => value}), do: decode_datetime(value)
  def decode_scalar(_value), do: :error

  @doc false
  def encode_datetime(nil), do: nil
  def encode_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)

  @doc false
  def decode_optional_datetime(nil), do: {:ok, nil}
  def decode_optional_datetime(value), do: decode_datetime(value)

  defp decode_metadata_entries(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn
      %{"key" => key, "value" => value} = entry, {:ok, pairs} when map_size(entry) == 2 ->
        with {:ok, key} <- decode_scalar(key),
             true <- is_atom(key) or is_binary(key),
             {:ok, value} <- decode_scalar(value) do
          {:cont, {:ok, [{key, value} | pairs]}}
        else
          _invalid -> {:halt, :error}
        end

      _entry, _acc ->
        {:halt, :error}
    end)
  end

  defp decode_source("server"), do: {:ok, :server}
  defp decode_source("netman"), do: {:ok, :netman}
  defp decode_source(_source), do: :error

  defp decode_type("server_registered"), do: {:ok, :server_registered}
  defp decode_type("server_status_updated"), do: {:ok, :server_status_updated}
  defp decode_type("netman_registered"), do: {:ok, :netman_registered}
  defp decode_type("netman_status_updated"), do: {:ok, :netman_status_updated}
  defp decode_type(_type), do: :error

  defp decode_source_id(value) when is_binary(value) and value != "" and byte_size(value) <= 128,
    do: {:ok, value}

  defp decode_source_id(_source_id), do: :error

  defp decode_message(nil), do: {:ok, nil}
  defp decode_message(value) when is_binary(value) and byte_size(value) <= 128, do: {:ok, value}
  defp decode_message(_message), do: :error

  defp decode_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _invalid -> :error
    end
  end

  defp decode_datetime(_value), do: :error
end
