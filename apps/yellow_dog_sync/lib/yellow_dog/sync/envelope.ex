defmodule YellowDog.Sync.Envelope do
  @moduledoc false

  alias YellowDog.Sync.Bounds
  alias YellowDog.Sync.Codec
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Error

  @protocol_version 1
  @max_config_version 9_223_372_036_854_775_807
  @uuid_pattern ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @wire_keys [
    "protocol_version",
    "request_id",
    "target_type",
    "target_id",
    "operation",
    "expected_revision",
    "idempotency_key",
    "payload",
    "payload_digest",
    "sent_at"
  ]

  @enforce_keys [
    :protocol_version,
    :request_id,
    :target_type,
    :target_id,
    :operation,
    :idempotency_key,
    :payload,
    :payload_digest,
    :sent_at
  ]
  defstruct @enforce_keys ++ [expected_revision: nil, config_version: nil]

  @type target_type :: :server | :netman

  @type t :: %__MODULE__{
          protocol_version: 1,
          request_id: String.t(),
          target_type: target_type(),
          target_id: String.t(),
          operation: String.t(),
          idempotency_key: String.t(),
          payload: term(),
          payload_digest: String.t(),
          expected_revision: String.t() | nil,
          config_version: pos_integer() | nil,
          sent_at: DateTime.t()
        }

  @spec encode(t()) :: {:ok, binary()} | {:error, Error.t()}
  def encode(%__MODULE__{} = envelope) do
    with {:ok, envelope} <- validate(envelope) do
      Codec.encode_envelope(to_wire(envelope))
    end
  end

  def encode(_envelope), do: invalid_error()

  @spec decode(binary()) :: {:ok, t()} | {:error, Error.t()}
  def decode(payload), do: decode(payload, nil)

  @spec decode(binary(), target_type() | nil) :: {:ok, t()} | {:error, Error.t()}
  def decode(payload, expected_type) when expected_type in [:server, :netman, nil] do
    with {:ok, wire} <- Codec.decode_envelope(payload),
         {:ok, envelope} <- from_wire(wire),
         :ok <- validate_target_type(envelope.target_type, expected_type) do
      {:ok, envelope}
    else
      _ -> invalid_error()
    end
  end

  def decode(_payload, _expected_type), do: invalid_error()

  @spec from_wire(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_wire(wire) when is_map(wire) do
    with {:ok, wire} <- Bounds.map(wire),
         {:ok, wire} <- exact_wire(wire),
         {:ok, protocol_version} <-
           fetch_and_validate(wire, "protocol_version", &protocol_version/1),
         {:ok, request_id} <- fetch_and_validate(wire, "request_id", &uuid/1),
         {:ok, target_type} <- fetch_and_validate(wire, "target_type", &target_type/1),
         {:ok, target_id} <- fetch_and_validate(wire, "target_id", &target_id/1),
         {:ok, operation} <- fetch_and_validate(wire, "operation", &operation/1),
         {:ok, idempotency_key} <- fetch_and_validate(wire, "idempotency_key", &uuid/1),
         {:ok, payload} <- fetch_and_validate(wire, "payload", &payload/1),
         {:ok, payload_digest} <- fetch_and_validate(wire, "payload_digest", &Digest.validate/1),
         :ok <- Digest.verify(payload, payload_digest),
         {:ok, expected_revision} <-
           fetch_and_validate(wire, "expected_revision", &expected_revision/1),
         {:ok, config_version} <- config_version(Map.get(wire, "config_version")),
         {:ok, sent_at} <- fetch_and_validate(wire, "sent_at", &sent_at/1) do
      {:ok,
       %__MODULE__{
         protocol_version: protocol_version,
         request_id: request_id,
         target_type: target_type,
         target_id: target_id,
         operation: operation,
         idempotency_key: idempotency_key,
         payload: payload,
         payload_digest: payload_digest,
         expected_revision: expected_revision,
         config_version: config_version,
         sent_at: sent_at
       }}
    else
      _ -> invalid_error()
    end
  end

  def from_wire(_wire), do: invalid_error()

  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = envelope) do
    wire = %{
      "protocol_version" => envelope.protocol_version,
      "request_id" => envelope.request_id,
      "target_type" => Atom.to_string(envelope.target_type),
      "target_id" => envelope.target_id,
      "operation" => envelope.operation,
      "expected_revision" => envelope.expected_revision,
      "idempotency_key" => envelope.idempotency_key,
      "payload" => envelope.payload,
      "payload_digest" => envelope.payload_digest,
      "sent_at" => DateTime.to_iso8601(envelope.sent_at)
    }

    if is_nil(envelope.config_version) do
      wire
    else
      Map.put(wire, "config_version", envelope.config_version)
    end
  end

  defp validate(envelope) do
    with {:ok, protocol_version} <- protocol_version(envelope.protocol_version),
         {:ok, request_id} <- uuid(envelope.request_id),
         {:ok, target_type} <- target_type(envelope.target_type),
         {:ok, target_id} <- target_id(envelope.target_id),
         {:ok, operation} <- operation(envelope.operation),
         {:ok, idempotency_key} <- uuid(envelope.idempotency_key),
         {:ok, payload} <- payload(envelope.payload),
         {:ok, payload_digest} <- Digest.validate(envelope.payload_digest),
         :ok <- Digest.verify(payload, payload_digest),
         {:ok, expected_revision} <- expected_revision(envelope.expected_revision),
         {:ok, config_version} <- config_version(envelope.config_version),
         {:ok, sent_at} <- sent_at(envelope.sent_at) do
      {:ok,
       %__MODULE__{
         protocol_version: protocol_version,
         request_id: request_id,
         target_type: target_type,
         target_id: target_id,
         operation: operation,
         idempotency_key: idempotency_key,
         payload: payload,
         payload_digest: payload_digest,
         expected_revision: expected_revision,
         config_version: config_version,
         sent_at: sent_at
       }}
    else
      _ -> invalid_error()
    end
  end

  defp protocol_version(@protocol_version), do: {:ok, @protocol_version}
  defp protocol_version(_value), do: invalid_error()

  defp target_type("server"), do: {:ok, :server}
  defp target_type("netman"), do: {:ok, :netman}
  defp target_type(:server), do: {:ok, :server}
  defp target_type(:netman), do: {:ok, :netman}
  defp target_type(_value), do: invalid_error()

  defp uuid(value) do
    with {:ok, value} <- Bounds.id(value),
         true <- String.match?(value, @uuid_pattern) do
      {:ok, value}
    else
      _ -> invalid_error()
    end
  end

  defp target_id(value) do
    with {:ok, value} <- Bounds.id(value),
         true <- value != "" do
      {:ok, value}
    else
      _ -> invalid_error()
    end
  end

  defp operation(value) do
    with {:ok, value} <- Bounds.operation(value),
         true <- value != "" do
      {:ok, value}
    else
      _ -> invalid_error()
    end
  end

  defp payload(value) do
    with {:ok, encoded} <- Codec.encode(value),
         {:ok, _encoded} <- Bounds.payload(encoded) do
      {:ok, value}
    else
      _ -> invalid_error()
    end
  end

  defp expected_revision(nil), do: {:ok, nil}
  defp expected_revision(value), do: Digest.validate(value)

  defp config_version(nil), do: {:ok, nil}

  defp config_version(value)
       when is_integer(value) and value >= 1 and value <= @max_config_version,
       do: {:ok, value}

  defp config_version(_value), do: invalid_error()

  defp sent_at(%DateTime{utc_offset: 0, std_offset: 0} = value), do: {:ok, value}
  defp sent_at(%DateTime{}), do: invalid_error()

  defp sent_at(wire_value) when is_binary(wire_value) do
    with {:ok, value, 0} <- DateTime.from_iso8601(wire_value),
         true <- String.ends_with?(wire_value, "Z") do
      {:ok, value}
    else
      _ -> invalid_error()
    end
  end

  defp sent_at(_value), do: invalid_error()

  defp fetch_and_validate(wire, key, validator) do
    with {:ok, value} <- Map.fetch(wire, key),
         {:ok, value} <- validator.(value) do
      {:ok, value}
    else
      _ -> invalid_error()
    end
  end

  defp exact_wire(wire) do
    keys = Map.keys(wire) |> Enum.sort()
    base_keys = Enum.sort(@wire_keys)
    versioned_keys = Enum.sort(["config_version" | @wire_keys])

    if keys in [base_keys, versioned_keys], do: {:ok, wire}, else: invalid_error()
  end

  defp validate_target_type(_target_type, nil), do: :ok
  defp validate_target_type(target_type, target_type), do: :ok
  defp validate_target_type(_target_type, _expected_type), do: invalid_error()

  defp invalid_error, do: {:error, Error.new(:invalid, "invalid value", %{})}
end
