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

  alias YellowDog.Management.Storage.Path, as: StoragePath

  @max_sequence 9_223_372_036_854_775_807
  @max_message_bytes 128
  @max_metadata_entries 20
  @max_metadata_key_bytes 64
  @max_metadata_value_bytes 256
  @commit_token ~r/\A[A-Za-z0-9_-]{43}\z/

  @doc false
  def new(attrs) do
    sequence = System.unique_integer([:positive, :monotonic])
    new(attrs, sequence)
  end

  @doc false
  def new(attrs, sequence) when is_integer(sequence) and sequence in 1..@max_sequence do
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
  def to_map(%__MODULE__{} = event, commit_token) when is_binary(commit_token) do
    %{
      "commit_token" => commit_token,
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
  def from_map(value) do
    with {:ok, event, _commit_token} <- decode_record(value), do: {:ok, event}
  end

  @doc false
  def decode_record(
        %{
          "commit_token" => commit_token,
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
    with true <- map_size(value) == 9,
         true <- valid_commit_token?(commit_token),
         true <- is_integer(sequence) and sequence in 1..@max_sequence,
         true <- id == "evt-#{sequence}",
         {:ok, _path} <- StoragePath.event(id),
         {:ok, source} <- decode_source(source),
         {:ok, source_id} <- decode_source_id(source, source_id),
         {:ok, type} <- decode_type(type),
         true <- coherent_source_type?(source, type),
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
       }, commit_token}
    else
      _invalid -> :error
    end
  end

  def decode_record(_value), do: :error

  @doc false
  def digest(value) when is_map(value) do
    :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
    |> Base.url_encode64(padding: false)
  end

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
    with {:ok, pairs} <- decode_metadata_entries(entries, @max_metadata_entries, []),
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
  def decode_scalar(%{"type" => "atom", "value" => "registered"} = value)
      when map_size(value) == 2,
      do: {:ok, :registered}

  def decode_scalar(%{"type" => "atom", "value" => "online"} = value)
      when map_size(value) == 2,
      do: {:ok, :online}

  def decode_scalar(%{"type" => "atom", "value" => "offline"} = value)
      when map_size(value) == 2,
      do: {:ok, :offline}

  def decode_scalar(%{"type" => "atom", "value" => "status"} = value)
      when map_size(value) == 2,
      do: {:ok, :status}

  def decode_scalar(%{"type" => "atom", "value" => "site"} = value)
      when map_size(value) == 2,
      do: {:ok, :site}

  def decode_scalar(%{"type" => "string", "value" => value} = scalar)
      when map_size(scalar) == 2 and is_binary(value),
      do: {:ok, value}

  def decode_scalar(%{"type" => "boolean", "value" => value} = scalar)
      when map_size(scalar) == 2 and is_boolean(value),
      do: {:ok, value}

  def decode_scalar(%{"type" => "integer", "value" => value} = scalar)
      when map_size(scalar) == 2 and is_integer(value) and
             value in -@max_sequence..@max_sequence,
      do: {:ok, value}

  def decode_scalar(%{"type" => "float", "value" => value} = scalar)
      when map_size(scalar) == 2 and is_float(value),
      do: {:ok, value}

  def decode_scalar(%{"type" => "datetime", "value" => value} = scalar)
      when map_size(scalar) == 2,
      do: decode_datetime(value)

  def decode_scalar(_value), do: :error

  @doc false
  def encode_datetime(nil), do: nil
  def encode_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)

  @doc false
  def decode_optional_datetime(nil), do: {:ok, nil}
  def decode_optional_datetime(value), do: decode_datetime(value)

  defp decode_metadata_entries([], _remaining, pairs), do: {:ok, Enum.reverse(pairs)}
  defp decode_metadata_entries([_entry | _entries], 0, _pairs), do: :error

  defp decode_metadata_entries(
         [%{"key" => key, "value" => value} = entry | entries],
         remaining,
         pairs
       )
       when map_size(entry) == 2 do
    with {:ok, key} <- decode_scalar(key),
         true <- valid_metadata_key?(key),
         {:ok, value} <- decode_scalar(value),
         true <- valid_metadata_value?(value) do
      decode_metadata_entries(entries, remaining - 1, [{key, value} | pairs])
    else
      _invalid -> :error
    end
  end

  defp decode_metadata_entries(_entries, _remaining, _pairs), do: :error

  defp decode_source("server"), do: {:ok, :server}
  defp decode_source("netman"), do: {:ok, :netman}
  defp decode_source(_source), do: :error

  defp decode_type("server_registered"), do: {:ok, :server_registered}
  defp decode_type("server_status_updated"), do: {:ok, :server_status_updated}
  defp decode_type("netman_registered"), do: {:ok, :netman_registered}
  defp decode_type("netman_status_updated"), do: {:ok, :netman_status_updated}
  defp decode_type(_type), do: :error

  defp decode_source_id(:server, value) do
    with {:ok, _path} <- StoragePath.server_manifest(value), do: {:ok, value}
  end

  defp decode_source_id(:netman, value) do
    with {:ok, _path} <- StoragePath.netman_manifest(value), do: {:ok, value}
  end

  defp decode_source_id(_source, _source_id), do: :error

  defp coherent_source_type?(:server, type),
    do: type in [:server_registered, :server_status_updated]

  defp coherent_source_type?(:netman, type),
    do: type in [:netman_registered, :netman_status_updated]

  defp valid_commit_token?(token) when is_binary(token), do: Regex.match?(@commit_token, token)
  defp valid_commit_token?(_token), do: false

  defp decode_message(nil), do: {:ok, nil}

  defp decode_message(value)
       when is_binary(value) and byte_size(value) <= @max_message_bytes,
       do: if(String.valid?(value), do: {:ok, value}, else: :error)

  defp decode_message(_message), do: :error

  defp decode_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, %DateTime{microsecond: {0, 0}} = datetime, 0} ->
        unix = DateTime.to_unix(datetime)
        if unix in 0..@max_sequence, do: {:ok, datetime}, else: :error

      _invalid ->
        :error
    end
  end

  defp decode_datetime(_value), do: :error

  defp valid_metadata_key?(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> valid_metadata_key?()
  end

  defp valid_metadata_key?(value) when is_binary(value) do
    value != "" and byte_size(value) <= @max_metadata_key_bytes and String.valid?(value)
  end

  defp valid_metadata_key?(_value), do: false

  defp valid_metadata_value?(value) when is_binary(value),
    do: byte_size(value) <= @max_metadata_value_bytes and String.valid?(value)

  defp valid_metadata_value?(value)
       when is_atom(value) or is_boolean(value) or is_integer(value) or is_float(value),
       do: true

  defp valid_metadata_value?(%DateTime{} = value),
    do: match?({:ok, _datetime}, decode_datetime(DateTime.to_iso8601(value)))

  defp valid_metadata_value?(_value), do: false
end
