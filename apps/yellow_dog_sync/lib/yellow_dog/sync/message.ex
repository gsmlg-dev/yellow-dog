defmodule YellowDog.Sync.Message do
  @moduledoc false

  alias YellowDog.Sync.Bounds
  alias YellowDog.Sync.Codec
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Identity
  alias YellowDog.Sync.Operation

  @uuid_pattern ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @message_types ~w(hello heartbeat status query command result config_delivery config_state journal event)
  @max_wrapper_bytes byte_size(~s({"payload":,"type":"config_delivery"}))
  @max_message_document_bytes Codec.max_document_bytes() + @max_wrapper_bytes
  @max_message_depth Bounds.max_error_details_depth() + 2
  @envelope_keys [
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

  defmodule Hello do
    @enforce_keys [:identity]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule Heartbeat do
    @enforce_keys [:target_type, :target_id, :observed_at]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule Status do
    @enforce_keys [:target_type, :target_id, :state, :details, :observed_at]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule Query do
    @enforce_keys [:envelope]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule Command do
    @enforce_keys [:envelope]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule Result do
    @enforce_keys [:request_id, :target_type, :operation, :value, :error]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule ConfigDelivery do
    @enforce_keys [:envelope]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule ConfigState do
    @enforce_keys [
      :target_type,
      :target_id,
      :operation,
      :state,
      :version,
      :digest,
      :applied_revision,
      :previous_revision,
      :failure,
      :rollback,
      :observed_at
    ]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule Journal do
    @enforce_keys [:target_type, :target_id, :entries]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule Event do
    @enforce_keys [:target_type, :target_id, :event_id, :name, :payload, :observed_at]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  @type t ::
          Hello.t()
          | Heartbeat.t()
          | Status.t()
          | Query.t()
          | Command.t()
          | Result.t()
          | ConfigDelivery.t()
          | ConfigState.t()
          | Journal.t()
          | Event.t()

  @spec encode(t()) :: {:ok, binary()} | {:error, Error.t()}
  def encode(message) do
    with {:ok, wire} <- to_wire(message),
         {:ok, wire} <- exact_map(wire, ["type", "payload"]),
         true <- wire["type"] in @message_types,
         {:ok, encoded_payload} <- Codec.encode_envelope(wire["payload"]),
         {:ok, encoded_type} <- Codec.encode(wire["type"]),
         encoded <-
           IO.iodata_to_binary([
             "{\"payload\":",
             encoded_payload,
             ",\"type\":",
             encoded_type,
             "}"
           ]),
         {:ok, encoded} <- message_document(encoded) do
      {:ok, encoded}
    else
      _ -> invalid_error()
    end
  end

  @spec max_document_bytes() :: pos_integer()
  def max_document_bytes, do: @max_message_document_bytes

  @spec decode(binary()) :: {:ok, t()} | {:error, Error.t()}
  def decode(payload) do
    with {:ok, payload} <- message_document(payload),
         :ok <- preflight(payload, @max_message_depth),
         {:ok, wire} <- Jason.decode(payload),
         {:ok, wire} <- exact_map(wire, ["type", "payload"]),
         true <- wire["type"] in @message_types,
         {:ok, _encoded_payload} <- Codec.encode_envelope(wire["payload"]) do
      from_wire(wire)
    else
      _ -> invalid_error()
    end
  end

  defp to_wire(%Hello{identity: identity}) do
    with wire when is_map(wire) <- Identity.to_wire(identity),
         {:ok, _identity} <- Identity.from_wire(wire),
         {:ok, _wire} <- identity_wire(wire) do
      tagged("hello", wire)
    else
      _ -> invalid_error()
    end
  end

  defp to_wire(%Heartbeat{} = message) do
    with {:ok, target_type} <- target_type(message.target_type),
         {:ok, target_id} <- valid_id(message.target_id),
         {:ok, observed_at} <- utc_datetime(message.observed_at) do
      tagged("heartbeat", %{
        "target_type" => target_type,
        "target_id" => target_id,
        "observed_at" => DateTime.to_iso8601(observed_at)
      })
    else
      _ -> invalid_error()
    end
  end

  defp to_wire(%Status{} = message) do
    with {:ok, target_type} <- target_type(message.target_type),
         {:ok, target_id} <- valid_id(message.target_id),
         {:ok, state} <- status_state(message.state),
         {:ok, details} <- Bounds.details(message.details),
         :ok <- Operation.validate_transport(details),
         {:ok, observed_at} <- utc_datetime(message.observed_at) do
      tagged("status", %{
        "target_type" => target_type,
        "target_id" => target_id,
        "state" => Atom.to_string(state),
        "details" => details,
        "observed_at" => DateTime.to_iso8601(observed_at)
      })
    else
      _ -> invalid_error()
    end
  end

  defp to_wire(%Query{envelope: envelope}), do: envelope_wire("query", envelope, :query)
  defp to_wire(%Command{envelope: envelope}), do: envelope_wire("command", envelope, :command)

  defp to_wire(%Result{} = message) do
    with {:ok, request_id} <- uuid(message.request_id),
         {:ok, target_type} <- target_type_atom(message.target_type),
         {:ok, operation} <- operation_for_target(message.operation, target_type),
         {:ok, value, error} <- result_value(operation, message.value, message.error) do
      tagged("result", %{
        "request_id" => request_id,
        "target_type" => Atom.to_string(target_type),
        "operation" => message.operation,
        "value" => value,
        "error" => error
      })
    else
      _ -> invalid_error()
    end
  end

  defp to_wire(%ConfigDelivery{envelope: envelope}),
    do: envelope_wire("config_delivery", envelope, :config)

  defp to_wire(%ConfigState{} = message) do
    state = config_state_map(message)

    with {:ok, target_type} <- target_type_atom(message.target_type),
         {:ok, target_id} <- valid_id(message.target_id),
         {:ok, operation} <- operation_for_target(message.operation, target_type),
         {:ok, _state} <- Operation.validate_result(operation, state),
         {:ok, observed_at} <- utc_datetime(message.observed_at) do
      tagged("config_state", %{
        "target_type" => Atom.to_string(target_type),
        "target_id" => target_id,
        "operation" => message.operation,
        "state" => state,
        "observed_at" => DateTime.to_iso8601(observed_at)
      })
    else
      _ -> invalid_error()
    end
  end

  defp to_wire(%Journal{} = message) do
    with {:ok, target_type} <- target_type_atom(message.target_type),
         {:ok, target_id} <- valid_id(message.target_id),
         {:ok, entries} <- journal_entries(message.entries, target_type) do
      tagged("journal", %{
        "target_type" => Atom.to_string(target_type),
        "target_id" => target_id,
        "entries" => entries
      })
    else
      _ -> invalid_error()
    end
  end

  defp to_wire(%Event{} = message) do
    with {:ok, target_type} <- target_type(message.target_type),
         {:ok, target_id} <- valid_id(message.target_id),
         {:ok, event_id} <- uuid(message.event_id),
         {:ok, name} <- nonempty_text(message.name),
         {:ok, payload} <- bounded_map(message.payload),
         {:ok, observed_at} <- utc_datetime(message.observed_at) do
      tagged("event", %{
        "target_type" => target_type,
        "target_id" => target_id,
        "event_id" => event_id,
        "name" => name,
        "payload" => payload,
        "observed_at" => DateTime.to_iso8601(observed_at)
      })
    else
      _ -> invalid_error()
    end
  end

  defp to_wire(_message), do: invalid_error()

  defp from_wire(%{"type" => "hello", "payload" => wire}) do
    with {:ok, wire} <- identity_wire(wire),
         {:ok, identity} <- Identity.from_wire(wire) do
      {:ok, %Hello{identity: identity}}
    else
      _ -> invalid_error()
    end
  end

  defp from_wire(%{"type" => "heartbeat", "payload" => wire}) do
    with {:ok, wire} <- exact_map(wire, ["target_type", "target_id", "observed_at"]),
         {:ok, target_type} <- target_type_atom(wire["target_type"]),
         {:ok, target_id} <- valid_id(wire["target_id"]),
         {:ok, observed_at} <- utc_datetime(wire["observed_at"]) do
      {:ok, %Heartbeat{target_type: target_type, target_id: target_id, observed_at: observed_at}}
    else
      _ -> invalid_error()
    end
  end

  defp from_wire(%{"type" => "status", "payload" => wire}) do
    keys = ["target_type", "target_id", "state", "details", "observed_at"]

    with {:ok, wire} <- exact_map(wire, keys),
         {:ok, target_type} <- target_type_atom(wire["target_type"]),
         {:ok, target_id} <- valid_id(wire["target_id"]),
         {:ok, state} <- status_state(wire["state"]),
         {:ok, details} <- Bounds.details(wire["details"]),
         :ok <- Operation.validate_transport(details),
         {:ok, observed_at} <- utc_datetime(wire["observed_at"]) do
      {:ok,
       %Status{
         target_type: target_type,
         target_id: target_id,
         state: state,
         details: details,
         observed_at: observed_at
       }}
    else
      _ -> invalid_error()
    end
  end

  defp from_wire(%{"type" => "query", "payload" => wire}),
    do: decode_envelope(wire, :query, Query)

  defp from_wire(%{"type" => "command", "payload" => wire}),
    do: decode_envelope(wire, :command, Command)

  defp from_wire(%{"type" => "result", "payload" => wire}) do
    keys = ["request_id", "target_type", "operation", "value", "error"]

    with {:ok, wire} <- exact_map(wire, keys),
         {:ok, request_id} <- uuid(wire["request_id"]),
         {:ok, target_type} <- target_type_atom(wire["target_type"]),
         {:ok, operation} <- operation_for_target(wire["operation"], target_type),
         {:ok, value, error} <- result_from_wire(operation, wire["value"], wire["error"]) do
      {:ok,
       %Result{
         request_id: request_id,
         target_type: target_type,
         operation: wire["operation"],
         value: value,
         error: error
       }}
    else
      _ -> invalid_error()
    end
  end

  defp from_wire(%{"type" => "config_delivery", "payload" => wire}),
    do: decode_envelope(wire, :config, ConfigDelivery)

  defp from_wire(%{"type" => "config_state", "payload" => wire}) do
    keys = ["target_type", "target_id", "operation", "state", "observed_at"]

    with {:ok, wire} <- exact_map(wire, keys),
         {:ok, target_type} <- target_type_atom(wire["target_type"]),
         {:ok, target_id} <- valid_id(wire["target_id"]),
         {:ok, operation} <- operation_for_target(wire["operation"], target_type),
         {:ok, state} <- Operation.validate_result(operation, wire["state"]),
         {:ok, observed_at} <- utc_datetime(wire["observed_at"]),
         {:ok, config_state} <-
           config_state_from_wire(target_type, target_id, wire, state, observed_at) do
      {:ok, config_state}
    else
      _ -> invalid_error()
    end
  end

  defp from_wire(%{"type" => "journal", "payload" => wire}) do
    with {:ok, wire} <- exact_map(wire, ["target_type", "target_id", "entries"]),
         {:ok, target_type} <- target_type_atom(wire["target_type"]),
         {:ok, target_id} <- valid_id(wire["target_id"]),
         {:ok, entries} <- journal_entries_from_wire(wire["entries"], target_type) do
      {:ok, %Journal{target_type: target_type, target_id: target_id, entries: entries}}
    else
      _ -> invalid_error()
    end
  end

  defp from_wire(%{"type" => "event", "payload" => wire}) do
    keys = ["target_type", "target_id", "event_id", "name", "payload", "observed_at"]

    with {:ok, wire} <- exact_map(wire, keys),
         {:ok, target_type} <- target_type_atom(wire["target_type"]),
         {:ok, target_id} <- valid_id(wire["target_id"]),
         {:ok, event_id} <- uuid(wire["event_id"]),
         {:ok, name} <- nonempty_text(wire["name"]),
         {:ok, payload} <- bounded_map(wire["payload"]),
         {:ok, observed_at} <- utc_datetime(wire["observed_at"]) do
      {:ok,
       %Event{
         target_type: target_type,
         target_id: target_id,
         event_id: event_id,
         name: name,
         payload: payload,
         observed_at: observed_at
       }}
    else
      _ -> invalid_error()
    end
  end

  defp from_wire(_wire), do: invalid_error()

  defp tagged(type, payload), do: {:ok, %{"type" => type, "payload" => payload}}

  defp identity_wire(wire) do
    exact_map(wire, [
      "target_type",
      "id",
      "name",
      "version",
      "profile",
      "capabilities",
      "config_revision"
    ])
  end

  defp envelope_wire(type, %Envelope{} = envelope, kind) do
    with {:ok, envelope} <- Operation.validate_envelope(envelope, kind),
         {:ok, encoded} <- Envelope.encode(envelope),
         {:ok, wire} <- Codec.decode_envelope(encoded) do
      tagged(type, wire)
    else
      _ -> invalid_error()
    end
  end

  defp envelope_wire(_type, _envelope, _kind), do: invalid_error()

  defp decode_envelope(wire, kind, module) do
    with {:ok, wire} <- exact_map(wire, @envelope_keys),
         {:ok, envelope} <- Envelope.from_wire(wire),
         {:ok, envelope} <- Operation.validate_envelope(envelope, kind) do
      {:ok, struct!(module, envelope: envelope)}
    else
      _ -> invalid_error()
    end
  end

  defp operation_for_target(name, target_type) do
    with {:ok, %Operation{target_type: ^target_type} = operation} <- Operation.lookup(name) do
      {:ok, operation}
    else
      _ -> invalid_error()
    end
  end

  defp result_value(operation, value, nil) do
    with {:ok, value} <- Operation.validate_result(operation, value) do
      {:ok, value, nil}
    end
  end

  defp result_value(_operation, nil, %Error{} = error) do
    with :ok <- Operation.validate_transport(error.details),
         %Error{} = error <- Error.new(error.code, error.message, error.details),
         wire <- Error.to_wire(error),
         {:ok, _wire} <- error_wire(wire),
         {:ok, _error} <- Error.from_wire(wire) do
      {:ok, nil, wire}
    else
      _ -> invalid_error()
    end
  end

  defp result_value(_operation, _value, _error), do: invalid_error()

  defp result_from_wire(operation, value, nil) do
    with {:ok, value} <- Operation.validate_result(operation, value) do
      {:ok, value, nil}
    end
  end

  defp result_from_wire(_operation, nil, wire) when is_map(wire) do
    with {:ok, wire} <- error_wire(wire),
         {:ok, error} <- Error.from_wire(wire),
         :ok <- Operation.validate_transport(error.details) do
      {:ok, nil, error}
    else
      _ -> invalid_error()
    end
  end

  defp result_from_wire(_operation, _value, _error), do: invalid_error()

  defp error_wire(wire), do: exact_map(wire, ["code", "message", "details"])

  defp config_state_map(message) do
    %{
      "state" => encode_config_state(message.state),
      "version" => message.version,
      "digest" => message.digest,
      "applied_revision" => message.applied_revision,
      "previous_revision" => message.previous_revision,
      "failure" => message.failure,
      "rollback" => message.rollback
    }
  end

  defp config_state_from_wire(target_type, target_id, wire, state, observed_at) do
    with {:ok, state_name} <- decode_config_state(state["state"]) do
      {:ok,
       %ConfigState{
         target_type: target_type,
         target_id: target_id,
         operation: wire["operation"],
         state: state_name,
         version: state["version"],
         digest: state["digest"],
         applied_revision: state["applied_revision"],
         previous_revision: state["previous_revision"],
         failure: state["failure"],
         rollback: state["rollback"],
         observed_at: observed_at
       }}
    end
  end

  defp encode_config_state(state)
       when state in [:desired, :delivered, :applying, :applied, :failed],
       do: Atom.to_string(state)

  defp encode_config_state(_state), do: nil

  defp decode_config_state("desired"), do: {:ok, :desired}
  defp decode_config_state("delivered"), do: {:ok, :delivered}
  defp decode_config_state("applying"), do: {:ok, :applying}
  defp decode_config_state("applied"), do: {:ok, :applied}
  defp decode_config_state("failed"), do: {:ok, :failed}
  defp decode_config_state(_state), do: invalid_error()

  defp journal_entries(entries, target_type) do
    with {:ok, entries} <- Bounds.list(entries) do
      map_entries(entries, &journal_entry(&1, target_type))
    else
      _ -> invalid_error()
    end
  end

  defp journal_entries_from_wire(entries, target_type) do
    with {:ok, entries} <- Bounds.list(entries) do
      map_entries(entries, &journal_entry_from_wire(&1, target_type))
    else
      _ -> invalid_error()
    end
  end

  defp journal_entry(entry, target_type) do
    keys = ["request_id", "operation", "status", "result", "error"]

    with {:ok, entry} <- exact_map(entry, keys),
         {:ok, _request_id} <- uuid(entry["request_id"]),
         {:ok, operation} <- operation_for_target(entry["operation"], target_type),
         {:ok, result, error} <- journal_outcome(operation, entry),
         true <- entry["status"] in ["completed", "failed", "unknown"] do
      {:ok, %{entry | "result" => result, "error" => error}}
    else
      _ -> invalid_error()
    end
  end

  defp journal_entry_from_wire(entry, target_type) do
    keys = ["request_id", "operation", "status", "result", "error"]

    with {:ok, entry} <- exact_map(entry, keys),
         {:ok, _request_id} <- uuid(entry["request_id"]),
         {:ok, operation} <- operation_for_target(entry["operation"], target_type),
         {:ok, result, error} <- journal_outcome_from_wire(operation, entry),
         true <- entry["status"] in ["completed", "failed", "unknown"] do
      {:ok, %{entry | "result" => result, "error" => error}}
    else
      _ -> invalid_error()
    end
  end

  defp journal_outcome(operation, %{"status" => "completed", "result" => result, "error" => nil}),
    do: result_value(operation, result, nil)

  defp journal_outcome(_operation, %{"status" => "failed", "result" => nil, "error" => error}),
    do: result_value(nil, nil, error)

  defp journal_outcome(_operation, %{"status" => "unknown", "result" => nil, "error" => nil}),
    do: {:ok, nil, nil}

  defp journal_outcome(_operation, _entry), do: invalid_error()

  defp journal_outcome_from_wire(
         operation,
         %{"status" => "completed", "result" => result, "error" => nil}
       ),
       do: result_from_wire(operation, result, nil)

  defp journal_outcome_from_wire(
         _operation,
         %{"status" => "failed", "result" => nil, "error" => error}
       ),
       do: result_from_wire(nil, nil, error)

  defp journal_outcome_from_wire(
         _operation,
         %{"status" => "unknown", "result" => nil, "error" => nil}
       ),
       do: {:ok, nil, nil}

  defp journal_outcome_from_wire(_operation, _entry), do: invalid_error()

  defp map_entries(entries, validator) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, values} ->
      case validator.(entry) do
        {:ok, value} -> {:cont, {:ok, [value | values]}}
        _ -> {:halt, invalid_error()}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp exact_map(value, keys) when is_map(value) do
    if Map.keys(value) |> Enum.sort() == Enum.sort(keys), do: {:ok, value}, else: invalid_error()
  end

  defp exact_map(_value, _keys), do: invalid_error()

  defp target_type(value) do
    with {:ok, target_type} <- target_type_atom(value) do
      {:ok, Atom.to_string(target_type)}
    end
  end

  defp target_type_atom(:server), do: {:ok, :server}
  defp target_type_atom(:netman), do: {:ok, :netman}
  defp target_type_atom("server"), do: {:ok, :server}
  defp target_type_atom("netman"), do: {:ok, :netman}
  defp target_type_atom(_value), do: invalid_error()

  defp status_state(:online), do: {:ok, :online}
  defp status_state(:offline), do: {:ok, :offline}
  defp status_state(:degraded), do: {:ok, :degraded}
  defp status_state("online"), do: {:ok, :online}
  defp status_state("offline"), do: {:ok, :offline}
  defp status_state("degraded"), do: {:ok, :degraded}
  defp status_state(_state), do: invalid_error()

  defp uuid(value) do
    with {:ok, value} <- Bounds.id(value),
         true <- String.match?(value, @uuid_pattern) do
      {:ok, value}
    else
      _ -> invalid_error()
    end
  end

  defp valid_id(value) do
    with {:ok, value} <- Bounds.id(value),
         true <- value != "" do
      {:ok, value}
    else
      _ -> invalid_error()
    end
  end

  defp nonempty_text(value) do
    with {:ok, value} <- Bounds.message(value),
         true <- value != "" do
      {:ok, value}
    else
      _ -> invalid_error()
    end
  end

  defp bounded_map(value) when is_map(value) do
    with {:ok, _value} <- Bounds.map(value),
         :ok <- Operation.validate_transport(value),
         {:ok, encoded} <- Codec.encode(value),
         {:ok, _encoded} <- Bounds.payload(encoded) do
      {:ok, value}
    else
      _ -> invalid_error()
    end
  end

  defp bounded_map(_value), do: invalid_error()

  defp utc_datetime(%DateTime{utc_offset: 0, std_offset: 0} = value), do: {:ok, value}
  defp utc_datetime(%DateTime{}), do: invalid_error()

  defp utc_datetime(value) when is_binary(value) do
    with {:ok, datetime, 0} <- DateTime.from_iso8601(value),
         true <- String.ends_with?(value, "Z") do
      {:ok, datetime}
    else
      _ -> invalid_error()
    end
  end

  defp utc_datetime(_value), do: invalid_error()

  defp message_document(payload)
       when is_binary(payload) and byte_size(payload) <= @max_message_document_bytes,
       do: {:ok, payload}

  defp message_document(_payload), do: invalid_error()

  defp preflight(payload, maximum_depth), do: scan(payload, 0, false, maximum_depth)

  defp scan(<<>>, _depth, _in_string, _maximum_depth), do: :ok

  defp scan(<<92, _escaped, rest::binary>>, depth, true, maximum_depth),
    do: scan(rest, depth, true, maximum_depth)

  defp scan(<<92>>, _depth, true, _maximum_depth), do: :ok

  defp scan(<<?\", rest::binary>>, depth, true, maximum_depth),
    do: scan(rest, depth, false, maximum_depth)

  defp scan(<<_byte, rest::binary>>, depth, true, maximum_depth),
    do: scan(rest, depth, true, maximum_depth)

  defp scan(<<?\", rest::binary>>, depth, false, maximum_depth),
    do: scan(rest, depth, true, maximum_depth)

  defp scan(<<byte, rest::binary>>, depth, false, maximum_depth) when byte in [?{, ?[] do
    next_depth = depth + 1

    if next_depth <= maximum_depth do
      scan(rest, next_depth, false, maximum_depth)
    else
      invalid_error()
    end
  end

  defp scan(<<byte, rest::binary>>, depth, false, maximum_depth) when byte in [?}, ?]] do
    scan(rest, max(depth - 1, 0), false, maximum_depth)
  end

  defp scan(<<_byte, rest::binary>>, depth, false, maximum_depth),
    do: scan(rest, depth, false, maximum_depth)

  defp invalid_error, do: {:error, Error.new(:invalid, "invalid value", %{})}
end
