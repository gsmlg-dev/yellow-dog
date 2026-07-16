defmodule YellowDog.Management.Commands do
  @moduledoc false

  use GenServer

  require Logger

  alias YellowDog.Management.EventStore
  alias YellowDog.Management.EventStore.Config
  alias YellowDog.Management.Storage.AtomicJson
  alias YellowDog.Management.Storage.Path, as: StoragePath
  alias YellowDog.Sync.Bounds
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Operation

  @document_keys Enum.sort([
                   "envelope",
                   "error",
                   "idempotency_fingerprint",
                   "idempotency_key",
                   "inserted_at",
                   "request_id",
                   "resolved_at",
                   "result",
                   "schema_version",
                   "state",
                   "target",
                   "unknown_reason",
                   "updated_at"
                 ])
  @target_keys ["id", "type"]
  @fingerprint_keys [
    "expected_revision",
    "operation",
    "payload_digest",
    "target_id",
    "target_type"
  ]
  @request_id ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @command_file ~r/\A([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.json\z/
  @command_stage ~r/\A\.[0-9a-f-]{36}\.json\..+\.stage\z/
  @unknown_reasons ~w(
    journal_unknown
    malformed_success
    malformed_transport
    management_restart
    runtime_disconnected
    transport_not_connected
    transport_timeout
  )
  @unknown_metadata_keys ~w(outcome reason request_id)

  defmodule Record do
    @moduledoc false
    @enforce_keys [
      :request_id,
      :envelope,
      :state,
      :idempotency_key,
      :fingerprint,
      :inserted_at,
      :updated_at,
      :path
    ]
    defstruct @enforce_keys ++ [result: nil, error: nil, unknown_reason: nil, resolved_at: nil]
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc false
  def replay(%Envelope{} = envelope), do: call({:replay, envelope})

  @doc false
  def reserve(%Envelope{} = envelope), do: call({:reserve, envelope})

  @doc false
  def resolve(request_id, outcome), do: call({:resolve, request_id, outcome})

  @doc false
  def mark_target_unknown(target_type, target_id),
    do: call({:mark_target_unknown, target_type, target_id})

  @doc false
  def reconcile(target_type, target_id, entries),
    do: call({:reconcile, target_type, target_id, entries})

  @doc false
  def unresolved_ids(target_type, target_id),
    do: call({:unresolved_ids, target_type, target_id})

  @doc false
  def unknown_error(%Error{} = error, request_id, reason)
      when is_binary(request_id) and reason in @unknown_reasons do
    error = safe_unknown_base(error)

    details =
      Map.merge(error.details, %{
        "outcome" => "unknown",
        "reason" => reason,
        "request_id" => request_id
      })

    case Error.new(error.code, error.message, details) do
      %Error{} = error ->
        error

      {:error, %Error{}} ->
        Error.new(:internal, "command outcome is unknown", %{
          "outcome" => "unknown",
          "reason" => reason,
          "request_id" => request_id
        })
    end
  end

  @impl true
  def init(:ok) do
    config = EventStore.config()

    with :ok <- cleanup_staging(config),
         {:ok, records, idempotency} <- load_records(config) do
      {:ok, %{records: records, idempotency: idempotency, config: config}}
    else
      {:error, %Error{} = error} ->
        {:stop, {:command_recovery_failed, error.code}}
    end
  end

  @impl true
  def handle_call({request, deadline, requested_config}, _from, state) do
    if requested_config == state.config do
      {reply, state} = handle_request(request, deadline, state)
      {:reply, reply, state}
    else
      {:reply, internal(), state}
    end
  end

  defp handle_request({:replay, envelope}, _deadline, state) do
    {replay(envelope, state), state}
  end

  defp handle_request({:reserve, envelope}, deadline, state) do
    with {:ok, envelope} <- Operation.validate_envelope(envelope, :command),
         :miss <- replay(envelope, state),
         false <- Map.has_key?(state.records, envelope.request_id),
         :ok <- ensure_capacity(state),
         {:ok, path} <- StoragePath.command(state.config.root, envelope.request_id),
         record = new_record(envelope, path),
         :ok <- persist_create(record, deadline, state.config) do
      updated = %{
        state
        | records: Map.put(state.records, record.request_id, record),
          idempotency: Map.put(state.idempotency, record.idempotency_key, record.request_id)
      }

      {{:reserved, record.request_id}, updated}
    else
      {:replay, _result} = replay -> {replay, state}
      true -> {conflict("command request ID already exists", envelope.request_id), state}
      {:error, %Error{}} = error -> {error, state}
    end
  end

  defp handle_request({:resolve, request_id, outcome}, deadline, state) do
    case Map.fetch(state.records, request_id) do
      {:ok, record} -> resolve_record(record, outcome, deadline, state)
      :error -> {not_found("command request was not found"), state}
    end
  end

  defp handle_request({:mark_target_unknown, target_type, target_id}, deadline, state) do
    with :ok <- valid_target(target_type, target_id),
         pending <- pending_records(state.records, target_type, target_id),
         error =
           Error.new(:not_connected, "runtime disconnected before command acknowledgement", %{}) do
      case transition_many(
             pending,
             fn record ->
               {:unknown, unknown_error(error, record.request_id, "runtime_disconnected"),
                "runtime_disconnected"}
             end,
             deadline,
             state
           ) do
        {:ok, committed_state} ->
          {{:ok, unresolved(committed_state.records, target_type, target_id)}, committed_state}

        {:error, %Error{} = error, committed_state} ->
          {{:error, error}, committed_state}
      end
    else
      {:error, %Error{}} = error -> {error, state}
    end
  end

  defp handle_request({:reconcile, target_type, target_id, entries}, deadline, state) do
    with :ok <- valid_target(target_type, target_id),
         {:ok, entries} <- unique_entries(entries),
         {:ok, transitions} <- journal_transitions(entries, target_type, target_id, state) do
      case apply_transitions(transitions, deadline, state) do
        {:ok, committed_state} ->
          {{:ok, unresolved(committed_state.records, target_type, target_id)}, committed_state}

        {:error, %Error{} = error, committed_state} ->
          {{:error, error}, committed_state}
      end
    else
      {:error, %Error{}} = error -> {error, state}
    end
  end

  defp handle_request({:unresolved_ids, target_type, target_id}, _deadline, state) do
    case valid_target(target_type, target_id) do
      :ok -> {{:ok, unresolved(state.records, target_type, target_id)}, state}
      {:error, %Error{}} = error -> {error, state}
    end
  end

  defp replay(envelope, state) do
    with {:ok, envelope} <- Operation.validate_envelope(envelope, :command) do
      fingerprint = fingerprint(envelope)

      case Map.fetch(state.idempotency, envelope.idempotency_key) do
        :error ->
          :miss

        {:ok, request_id} ->
          record = Map.fetch!(state.records, request_id)

          if record.fingerprint == fingerprint do
            {:replay, replay_result(record)}
          else
            conflict("idempotency key conflicts with an existing command", request_id)
          end
      end
    end
  end

  defp replay_result(%Record{state: :completed, result: result}), do: {:ok, result}

  defp replay_result(%Record{state: state, error: error}) when state in [:failed, :unknown],
    do: {:error, error}

  defp replay_result(%Record{state: :pending, request_id: request_id}),
    do: conflict("idempotent command is still pending", request_id)

  defp resolve_record(record, outcome, deadline, state) do
    with {:ok, normalized} <- normalize_outcome(record, outcome),
         {:ok, transition} <- transition(record, normalized, next_updated_at(record)),
         {:ok, state, reply} <- persist_transition(transition, deadline, state) do
      {reply, state}
    else
      {:idempotent, reply} -> {reply, state}
      {:error, %Error{}} = error -> {error, state}
    end
  end

  defp normalize_outcome(record, {:completed, result}) do
    case Operation.validate_result(
           record.envelope.operation,
           record.envelope.target_type,
           :command,
           result
         ) do
      {:ok, result} -> {:ok, {:completed, result}}
      {:error, %Error{}} = error -> error
    end
  end

  defp normalize_outcome(record, {:failed, %Error{} = error}) do
    with {:ok, error} <- validate_error(error),
         :ok <- reject_unknown_markers(error, record.request_id) do
      {:ok, {:failed, error}}
    end
  end

  defp normalize_outcome(record, {:unknown, %Error{} = error, reason})
       when reason in @unknown_reasons do
    with {:ok, error} <- validate_error(error),
         :ok <- validate_unknown_markers(error, record.request_id, reason) do
      {:ok, {:unknown, error, reason}}
    end
  end

  defp normalize_outcome(_record, _outcome), do: invalid("invalid command outcome")

  defp transition(%Record{state: :pending} = record, outcome, now),
    do: {:ok, apply_outcome(record, outcome, now)}

  defp transition(%Record{state: :unknown} = record, {:unknown, _error, _reason}, _now),
    do: {:idempotent, {:error, record.error}}

  defp transition(%Record{state: :unknown} = record, outcome, now),
    do: {:ok, apply_outcome(record, outcome, now)}

  defp transition(%Record{} = record, outcome, _now) do
    if same_outcome?(record, outcome) do
      {:idempotent, terminal_result(record)}
    else
      conflict("command outcome contradicts durable state", record.request_id)
    end
  end

  defp apply_outcome(record, {:completed, result}, now) do
    %{
      record
      | state: :completed,
        result: result,
        error: nil,
        unknown_reason: nil,
        updated_at: now,
        resolved_at: now
    }
  end

  defp apply_outcome(record, {:failed, error}, now) do
    %{
      record
      | state: :failed,
        result: nil,
        error: error,
        unknown_reason: nil,
        updated_at: now,
        resolved_at: now
    }
  end

  defp apply_outcome(record, {:unknown, error, reason}, now) do
    %{
      record
      | state: :unknown,
        result: nil,
        error: error,
        unknown_reason: reason,
        updated_at: now,
        resolved_at: now
    }
  end

  defp same_outcome?(%Record{state: :completed, result: result}, {:completed, result}), do: true
  defp same_outcome?(%Record{state: :failed, error: error}, {:failed, error}), do: true
  defp same_outcome?(_record, _outcome), do: false

  defp persist_transition(%Record{} = record, deadline, state) do
    case persist_replace(record, deadline, state.config) do
      :ok ->
        state = %{state | records: Map.put(state.records, record.request_id, record)}
        {:ok, state, terminal_result(record)}

      {:error, %Error{}} = error ->
        error
    end
  end

  defp terminal_result(%Record{state: :completed, result: result}), do: {:ok, result}

  defp terminal_result(%Record{state: state, error: error}) when state in [:failed, :unknown],
    do: {:error, error}

  defp pending_records(records, target_type, target_id) do
    records
    |> Map.values()
    |> Enum.filter(fn record ->
      record.state == :pending and record.envelope.target_type == target_type and
        record.envelope.target_id == target_id
    end)
    |> Enum.sort_by(& &1.request_id)
  end

  defp transition_many(records, outcome, deadline, state) do
    Enum.reduce_while(records, {:ok, state}, fn record, {:ok, committed_state} ->
      with {:ok, normalized} <- normalize_outcome(record, outcome.(record)),
           {:ok, transitioned} <- transition(record, normalized, next_updated_at(record)),
           {:ok, updated_state, _reply} <-
             persist_transition(transitioned, deadline, committed_state) do
        {:cont, {:ok, updated_state}}
      else
        {:idempotent, _reply} -> {:cont, {:ok, committed_state}}
        {:error, %Error{} = error} -> {:halt, {:error, error, committed_state}}
      end
    end)
  end

  defp unique_entries(entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn entry, {:ok, by_id} ->
      with true <- is_map(entry),
           request_id when is_binary(request_id) <- entry["request_id"],
           true <- Regex.match?(@request_id, request_id) do
        case Map.fetch(by_id, request_id) do
          :error -> {:cont, {:ok, Map.put(by_id, request_id, entry)}}
          {:ok, ^entry} -> {:cont, {:ok, by_id}}
          {:ok, _other} -> {:halt, invalid("journal contains contradictory duplicate entries")}
        end
      else
        _invalid -> {:halt, invalid("invalid command journal")}
      end
    end)
  end

  defp unique_entries(_entries), do: invalid("invalid command journal")

  defp journal_transitions(entries, target_type, target_id, state) do
    entries
    |> Map.values()
    |> Enum.sort_by(& &1["request_id"])
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, transitions} ->
      case Map.fetch(state.records, entry["request_id"]) do
        :error ->
          {:cont, {:ok, transitions}}

        {:ok, record} ->
          with true <- record.envelope.target_type == target_type,
               true <- record.envelope.target_id == target_id,
               true <- record.envelope.operation == entry["operation"],
               {:ok, outcome} <- journal_outcome(record, entry),
               transition <- transition(record, outcome, next_updated_at(record)),
               {:ok, transitioned} <- journal_transition(transition) do
            {:cont, {:ok, [{record, transitioned} | transitions]}}
          else
            _invalid -> {:halt, invalid("journal contradicts a known command")}
          end
      end
    end)
  end

  defp journal_outcome(record, %{"status" => "completed", "result" => result}) do
    normalize_outcome(record, {:completed, result})
  end

  defp journal_outcome(record, %{"status" => "failed", "error" => %Error{} = error}) do
    normalize_outcome(record, {:failed, error})
  end

  defp journal_outcome(record, %{"status" => "unknown"}) do
    error = Error.new(:not_connected, "runtime journal reports an unknown command outcome", %{})

    normalize_outcome(
      record,
      {:unknown, unknown_error(error, record.request_id, "journal_unknown"), "journal_unknown"}
    )
  end

  defp journal_outcome(_record, _entry), do: invalid("invalid journal command outcome")

  defp journal_transition({:ok, record}), do: {:ok, record}
  defp journal_transition({:idempotent, _reply}), do: {:ok, nil}

  defp journal_transition({:error, %Error{}}),
    do: invalid("journal contradicts durable command state")

  defp apply_transitions(transitions, deadline, state) do
    transitions
    |> Enum.reverse()
    |> Enum.reduce_while({:ok, state}, fn
      {_old, nil}, {:ok, committed_state} ->
        {:cont, {:ok, committed_state}}

      {_old, record}, {:ok, committed_state} ->
        case persist_transition(record, deadline, committed_state) do
          {:ok, updated_state, _reply} -> {:cont, {:ok, updated_state}}
          {:error, %Error{} = error} -> {:halt, {:error, error, committed_state}}
        end
    end)
  end

  defp unresolved(records, target_type, target_id) do
    records
    |> Map.values()
    |> Enum.filter(fn record ->
      record.state in [:pending, :unknown] and record.envelope.target_type == target_type and
        record.envelope.target_id == target_id
    end)
    |> Enum.map(& &1.request_id)
    |> Enum.sort()
  end

  defp new_record(envelope, path) do
    now = DateTime.utc_now()

    %Record{
      request_id: envelope.request_id,
      envelope: envelope,
      state: :pending,
      idempotency_key: envelope.idempotency_key,
      fingerprint: fingerprint(envelope),
      inserted_at: now,
      updated_at: now,
      path: path
    }
  end

  defp fingerprint(envelope) do
    %{
      "target_type" => Atom.to_string(envelope.target_type),
      "target_id" => envelope.target_id,
      "operation" => envelope.operation,
      "payload_digest" => envelope.payload_digest,
      "expected_revision" => envelope.expected_revision
    }
  end

  defp persist_create(record, deadline, config) do
    persist_document(:create, record.path, document(record), deadline, config)
  end

  defp persist_replace(record, deadline, config) do
    persist_document(:replace, record.path, document(record), deadline, config)
  end

  defp persist_document(mode, path, document, deadline, config) do
    staging_path = AtomicJson.staging_path(path)

    operation = fn ->
      case mode do
        :create ->
          with {:ok, ^staging_path} <-
                 AtomicJson.stage(path, document, staging_path, config.file_ops),
               {:ok, ^path} <- AtomicJson.promote(staging_path, path, config.file_ops) do
            {:ok, path}
          end

        :replace ->
          AtomicJson.replace(path, document, staging_path, config.file_ops)
      end
    end

    result = AtomicJson.owned(operation, deadline)
    result = reconcile_write(result, path, document, config)

    case result do
      {:ok, ^path} ->
        cleanup_committed_staging_path(staging_path, config)
        :ok

      {:error, %Error{}} = error ->
        case cleanup_staging_path(staging_path, config) do
          :ok -> error
          {:error, %Error{}} = cleanup_error -> cleanup_error
        end

      _invalid ->
        internal("command persistence failed")
    end
  end

  defp reconcile_write({:error, %Error{code: :timeout}} = timeout, path, document, config) do
    case AtomicJson.owned(
           fn -> AtomicJson.read(path, config.file_ops) end,
           recovery_deadline(config)
         ) do
      {:ok, ^document} -> {:ok, path}
      _other -> timeout
    end
  end

  defp reconcile_write(result, _path, _document, _config), do: result

  defp cleanup_staging_path(path, config) do
    case AtomicJson.owned(fn -> config.file_ops.rm(path) end, recovery_deadline(config)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, %Error{}} = error -> error
      {:error, reason} -> internal("command staging cleanup failed: #{inspect(reason)}")
      _invalid -> internal("command staging cleanup failed")
    end
  end

  defp cleanup_committed_staging_path(path, config) do
    case cleanup_staging_path(path, config) do
      :ok ->
        :ok

      {:error, %Error{} = first_error} ->
        case cleanup_staging_path(path, config) do
          :ok ->
            :ok

          {:error, %Error{} = second_error} ->
            Logger.warning(
              "Durable command staging cleanup failed after commit at #{path}: " <>
                "#{first_error.code}/#{second_error.code}"
            )

            :ok
        end
    end
  end

  defp document(record) do
    %{
      "schema_version" => 1,
      "request_id" => record.request_id,
      "envelope" => Envelope.to_wire(record.envelope),
      "target" => %{
        "type" => Atom.to_string(record.envelope.target_type),
        "id" => record.envelope.target_id
      },
      "state" => Atom.to_string(record.state),
      "result" => record.result,
      "error" => encode_error(record.error),
      "unknown_reason" => record.unknown_reason,
      "idempotency_key" => record.idempotency_key,
      "idempotency_fingerprint" => record.fingerprint,
      "inserted_at" => DateTime.to_iso8601(record.inserted_at),
      "updated_at" => DateTime.to_iso8601(record.updated_at),
      "resolved_at" => encode_datetime(record.resolved_at)
    }
  end

  defp load_records(%Config{root: root} = config) when is_binary(root) do
    directory = Path.join(root, "commands")

    with {:ok, filenames} <- list_directory(directory, startup_deadline(config), config),
         :ok <- ensure_recovery_capacity(filenames, config) do
      Enum.reduce_while(Enum.sort(filenames), {:ok, %{}, %{}}, fn filename,
                                                                  {:ok, records, idempotency} ->
        case Regex.run(@command_file, filename) do
          [_, request_id] ->
            load_record(directory, filename, request_id, config, records, idempotency)

          _other ->
            {:cont, {:ok, records, idempotency}}
        end
      end)
    end
  end

  defp load_records(_config), do: {:ok, %{}, %{}}

  defp load_record(directory, filename, request_id, config, records, idempotency) do
    path = Path.join(directory, filename)

    case AtomicJson.owned(
           fn -> AtomicJson.read(path, config.file_ops) end,
           startup_deadline(config)
         ) do
      {:ok, document} ->
        case decode_record(document, request_id, path) do
          {:ok, record} -> recover_loaded(record, config, records, idempotency)
          {:error, %Error{}} -> ignore_malformed(path, records, idempotency)
        end

      {:error, %Error{code: code}} = error when code in [:timeout, :internal] ->
        {:halt, error}

      _invalid ->
        ignore_malformed(path, records, idempotency)
    end
  end

  defp recover_loaded(record, config, records, idempotency) do
    if Map.has_key?(idempotency, record.idempotency_key) do
      {:halt, conflict("duplicate durable idempotency key", record.request_id)}
    else
      with {:ok, record} <- recover_pending(record, config) do
        {:cont,
         {:ok, Map.put(records, record.request_id, record),
          Map.put(idempotency, record.idempotency_key, record.request_id)}}
      else
        {:error, %Error{}} = error -> {:halt, error}
      end
    end
  end

  defp recover_pending(%Record{state: :pending} = record, config) do
    error = Error.new(:not_connected, "command outcome is unknown after management restart", %{})
    error = unknown_error(error, record.request_id, "management_restart")

    recovered =
      apply_outcome(record, {:unknown, error, "management_restart"}, next_updated_at(record))

    with :ok <- persist_replace(recovered, startup_deadline(config), config), do: {:ok, recovered}
  end

  defp recover_pending(record, _config), do: {:ok, record}

  defp decode_record(document, expected_request_id, path) when is_map(document) do
    with true <- Enum.sort(Map.keys(document)) == @document_keys,
         1 <- document["schema_version"],
         ^expected_request_id <- document["request_id"],
         {:ok, envelope} <- Envelope.from_wire(document["envelope"]),
         {:ok, ^envelope} <- Operation.validate_envelope(envelope, :command),
         true <- envelope.request_id == expected_request_id,
         :ok <- decode_target(document["target"], envelope),
         {:ok, state} <- decode_state(document["state"]),
         true <- document["idempotency_key"] == envelope.idempotency_key,
         true <- exact_keys?(document["idempotency_fingerprint"], @fingerprint_keys),
         true <- document["idempotency_fingerprint"] == fingerprint(envelope),
         {:ok, inserted_at} <- decode_datetime(document["inserted_at"]),
         {:ok, updated_at} <- decode_datetime(document["updated_at"]),
         {:ok, resolved_at} <- decode_optional_datetime(document["resolved_at"]),
         true <- DateTime.compare(inserted_at, updated_at) in [:lt, :eq],
         {:ok, result, error, reason} <-
           decode_outcome(
             state,
             envelope,
             document["result"],
             document["error"],
             document["unknown_reason"],
             resolved_at,
             updated_at
           ) do
      {:ok,
       %Record{
         request_id: expected_request_id,
         envelope: envelope,
         state: state,
         result: result,
         error: error,
         unknown_reason: reason,
         idempotency_key: envelope.idempotency_key,
         fingerprint: fingerprint(envelope),
         inserted_at: inserted_at,
         updated_at: updated_at,
         resolved_at: resolved_at,
         path: path
       }}
    else
      _invalid -> invalid("invalid durable command document")
    end
  end

  defp decode_record(_document, _request_id, _path),
    do: invalid("invalid durable command document")

  defp decode_target(target, envelope) do
    if exact_keys?(target, @target_keys) and
         target["type"] == Atom.to_string(envelope.target_type) and
         target["id"] == envelope.target_id do
      :ok
    else
      invalid("invalid durable command target")
    end
  end

  defp decode_outcome(:pending, _envelope, nil, nil, nil, nil, _updated_at),
    do: {:ok, nil, nil, nil}

  defp decode_outcome(:completed, envelope, result, nil, nil, resolved_at, updated_at)
       when not is_nil(resolved_at) do
    with true <- resolved_at == updated_at,
         {:ok, result} <-
           Operation.validate_result(envelope.operation, envelope.target_type, :command, result) do
      {:ok, result, nil, nil}
    end
  end

  defp decode_outcome(:failed, envelope, nil, error, nil, resolved_at, updated_at)
       when not is_nil(resolved_at) do
    with true <- resolved_at == updated_at,
         {:ok, error} <- decode_error(error),
         :ok <- reject_unknown_markers(error, envelope.request_id) do
      {:ok, nil, error, nil}
    end
  end

  defp decode_outcome(:unknown, envelope, nil, error, reason, resolved_at, updated_at)
       when reason in @unknown_reasons and not is_nil(resolved_at) do
    with true <- resolved_at == updated_at,
         {:ok, error} <- decode_error(error),
         :ok <- validate_unknown_markers(error, envelope.request_id, reason) do
      {:ok, nil, error, reason}
    end
  end

  defp decode_outcome(_state, _envelope, _result, _error, _reason, _resolved_at, _updated_at),
    do: invalid("invalid durable command outcome")

  defp decode_state("pending"), do: {:ok, :pending}
  defp decode_state("completed"), do: {:ok, :completed}
  defp decode_state("failed"), do: {:ok, :failed}
  defp decode_state("unknown"), do: {:ok, :unknown}
  defp decode_state(_state), do: invalid("invalid durable command state")

  defp decode_error(error) when is_map(error) do
    with true <- exact_keys?(error, ["code", "details", "message"]),
         {:ok, error} <- Error.from_wire(error),
         {:ok, error} <- validate_error(error) do
      {:ok, error}
    end
  end

  defp decode_error(_error), do: invalid("invalid durable command error")

  defp validate_error(%Error{} = error) do
    wire = Error.to_wire(error)

    with :ok <- Operation.validate_transport(error.details),
         true <- exact_keys?(wire, ["code", "details", "message"]),
         {:ok, decoded} <- Error.from_wire(wire),
         true <- decoded == error do
      {:ok, error}
    else
      _invalid -> invalid("invalid command error")
    end
  end

  defp safe_unknown_base(%Error{} = error) do
    case validate_error(error) do
      {:ok, error} -> error
      {:error, %Error{}} -> Error.new(:invalid, "runtime returned an invalid command error", %{})
    end
  end

  defp encode_error(nil), do: nil
  defp encode_error(%Error{} = error), do: Error.to_wire(error)

  defp encode_datetime(nil), do: nil
  defp encode_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp decode_datetime(value) when is_binary(value) do
    with {:ok, datetime, 0} <- DateTime.from_iso8601(value),
         true <- String.ends_with?(value, "Z") do
      {:ok, datetime}
    else
      _invalid -> invalid("invalid command timestamp")
    end
  end

  defp decode_datetime(_value), do: invalid("invalid command timestamp")
  defp decode_optional_datetime(nil), do: {:ok, nil}
  defp decode_optional_datetime(value), do: decode_datetime(value)

  defp exact_keys?(value, keys) when is_map(value),
    do: Enum.sort(Map.keys(value)) == Enum.sort(keys)

  defp exact_keys?(_value, _keys), do: false

  defp validate_unknown_markers(%Error{details: details}, request_id, reason) do
    if details["outcome"] == "unknown" and details["reason"] == reason and
         details["request_id"] == request_id do
      :ok
    else
      invalid("invalid durable unknown command outcome")
    end
  end

  defp reject_unknown_markers(%Error{details: details}, _request_id) do
    if Enum.any?(@unknown_metadata_keys, &Map.has_key?(details, &1)) do
      invalid("failed command cannot contain unknown outcome markers")
    else
      :ok
    end
  end

  defp list_directory(directory, deadline, config) do
    case AtomicJson.owned(fn -> AtomicJson.ls(directory, config.file_ops) end, deadline) do
      {:ok, filenames} when is_list(filenames) -> {:ok, filenames}
      {:error, :enoent} -> {:ok, []}
      {:error, %Error{}} = error -> error
      {:error, reason} -> internal("command directory read failed: #{inspect(reason)}")
      _invalid -> internal("command directory read failed")
    end
  end

  defp ignore_malformed(path, records, idempotency) do
    Logger.warning("Ignoring malformed durable command: #{path}")
    {:cont, {:ok, records, idempotency}}
  end

  defp cleanup_staging(%Config{root: root} = config) when is_binary(root) do
    directory = Path.join(root, "commands")

    with {:ok, filenames} <- list_directory(directory, startup_deadline(config), config) do
      filenames
      |> Enum.filter(&safe_command_stage?/1)
      |> Enum.sort()
      |> Enum.reduce_while(:ok, fn filename, :ok ->
        case cleanup_staging_path(Path.join(directory, filename), config) do
          :ok -> {:cont, :ok}
          {:error, %Error{}} = error -> {:halt, error}
        end
      end)
    end
  end

  defp cleanup_staging(_config), do: :ok

  defp safe_command_stage?(filename) when is_binary(filename),
    do: Path.basename(filename) == filename and Regex.match?(@command_stage, filename)

  defp safe_command_stage?(_filename), do: false

  defp valid_target(target_type, target_id) when target_type in [:server, :netman] do
    with {:ok, target_id} <- Bounds.id(target_id),
         true <- target_id != "" do
      :ok
    else
      _invalid -> invalid("invalid command target")
    end
  end

  defp valid_target(_target_type, _target_id), do: invalid("invalid command target")

  defp call(request) do
    {deadline, config} = EventStore.operation()

    GenServer.call(
      __MODULE__,
      {request, deadline, config},
      EventStore.call_timeout(deadline, 3, config)
    )
  catch
    :exit, {:timeout, _reason} -> EventStore.timeout_result()
    :exit, _reason -> internal()
  end

  defp recovery_deadline(config) do
    System.monotonic_time(:millisecond) + config.transport_margin_ms
  end

  defp startup_deadline(config) do
    System.monotonic_time(:millisecond) + config.operation_timeout_ms
  end

  defp next_updated_at(record) do
    now = DateTime.utc_now()

    case DateTime.compare(now, record.updated_at || record.inserted_at) do
      :lt -> record.updated_at || record.inserted_at
      _other -> now
    end
  end

  defp ensure_capacity(state) do
    if map_size(state.records) < state.config.max_command_records do
      :ok
    else
      capacity_conflict("commands", state.config.max_command_records)
    end
  end

  defp ensure_recovery_capacity(filenames, config) do
    count = Enum.count(filenames, &safe_command_file?/1)

    if count <= config.max_command_records do
      :ok
    else
      capacity_conflict("commands", config.max_command_records)
    end
  end

  defp safe_command_file?(filename) when is_binary(filename),
    do: Path.basename(filename) == filename and Regex.match?(@command_file, filename)

  defp safe_command_file?(_filename), do: false

  defp conflict(message, request_id) do
    {:error, Error.new(:conflict, message, %{"request_id" => request_id})}
  end

  defp capacity_conflict(resource, limit) do
    {:error,
     Error.new(:conflict, "durable #{resource} capacity reached", %{
       "limit" => limit,
       "resource" => resource
     })}
  end

  defp not_found(message), do: {:error, Error.new(:not_found, message, %{})}
  defp invalid(message), do: {:error, Error.new(:invalid, message, %{})}

  defp internal(message \\ "command persistence failed"),
    do: {:error, Error.new(:internal, message, %{})}
end
