defmodule YellowDog.NetmanAgent.CommandJournal do
  @moduledoc """
  Durable local command reservation and terminal replay for one Netman.
  """

  use GenServer

  alias YellowDog.NetmanAgent.Storage
  alias YellowDog.Sync.Bounds
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Message
  alias YellowDog.Sync.Message.Journal
  alias YellowDog.Sync.Operation

  @schema_version 1
  @default_max_records 1_000
  @inconsistent_persistence :command_journal_inconsistent_persistence
  @request_id ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @journal_file ~r/\A([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.json\z/
  @document_keys ~w(
    envelope error idempotency_fingerprint inserted_at request_id resolved_at
    result schema_version state updated_at
  )
  @fingerprint_keys ~w(
    config_version expected_revision idempotency_key operation payload_digest
    target_id target_type
  )
  @terminal_states [:succeeded, :failed, :unknown]

  defmodule Record do
    @moduledoc false

    @enforce_keys [
      :request_id,
      :envelope,
      :state,
      :fingerprint,
      :inserted_at,
      :updated_at,
      :path
    ]
    defstruct @enforce_keys ++ [result: nil, error: nil, resolved_at: nil]
  end

  @type server :: GenServer.server()
  @type replay ::
          :miss
          | {:replay, {:ok, map()} | {:error, Error.t()} | {:unknown, String.t()}}
          | {:error, Error.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    with {:ok, config} <- build_config(opts) do
      case Keyword.get(opts, :name, __MODULE__) do
        nil -> GenServer.start_link(__MODULE__, config)
        name -> GenServer.start_link(__MODULE__, config, name: name)
      end
    end
  end

  def start_link(_opts), do: {:error, :invalid_configuration}

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @spec reserve(Envelope.t(), server()) ::
          {:reserved, String.t()} | {:replay, term()} | {:error, Error.t()}
  def reserve(envelope, server \\ __MODULE__),
    do: GenServer.call(server, {:reserve, envelope})

  @spec replay(Envelope.t(), server()) :: replay()
  def replay(envelope, server \\ __MODULE__),
    do: GenServer.call(server, {:replay, envelope})

  @spec mark_running(String.t(), server()) :: :ok | {:error, Error.t()}
  def mark_running(request_id, server \\ __MODULE__),
    do: GenServer.call(server, {:mark_running, request_id})

  @spec complete_success(String.t(), term(), server()) ::
          {:ok, term()} | {:error, Error.t()}
  def complete_success(request_id, result, server \\ __MODULE__),
    do: GenServer.call(server, {:complete_success, request_id, result})

  @spec complete_failure(String.t(), Error.t(), server()) :: {:error, Error.t()}
  def complete_failure(request_id, error, server \\ __MODULE__),
    do: GenServer.call(server, {:complete_failure, request_id, error})

  @spec wire_projection(server()) :: {:ok, Journal.t()} | {:error, Error.t()}
  def wire_projection(server \\ __MODULE__),
    do: GenServer.call(server, :wire_projection)

  @impl true
  def init(config) do
    with :ok <- ensure_owned_path(config),
         {:ok, entries} <- scan(config),
         :ok <- validate_entries(entries, config.max_records),
         {:ok, records, idempotency} <- load_records(entries, config),
         {:ok, records} <- recover_pending(records, config) do
      {:ok, %{config: config, records: records, idempotency: idempotency}}
    else
      {:error, reason} -> {:stop, {:journal_recovery_failed, reason}}
    end
  end

  @impl true
  def handle_call({:reserve, envelope}, _from, state) do
    case validate_envelope(envelope, state.config) do
      {:ok, envelope} -> reserve_valid(envelope, state)
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:replay, envelope}, _from, state) do
    reply =
      with {:ok, envelope} <- validate_envelope(envelope, state.config) do
        replay_valid(envelope, state)
      end

    {:reply, reply, state}
  end

  def handle_call({:mark_running, request_id}, _from, state) do
    with {:ok, record} <- fetch_record(request_id, state),
         :ok <- ensure_transition_record_path(record, state.config),
         {:ok, transitioned} <- transition_running(record, state.config),
         {:ok, state} <- persist_transition(transitioned, state) do
      {:reply, :ok, state}
    else
      {:idempotent, :ok} ->
        {:reply, :ok, state}

      {:error, %Error{} = error} ->
        {:reply, {:error, error}, state}

      {:stop, %Error{} = error} ->
        {:stop, @inconsistent_persistence, {:error, error}, state}
    end
  end

  def handle_call({:complete_success, request_id, result}, _from, state) do
    with {:ok, record} <- fetch_record(request_id, state),
         :ok <- ensure_transition_record_path(record, state.config),
         {:ok, result} <-
           Operation.validate_result(record.envelope.operation, :netman, :command, result),
         {:ok, transitioned} <- transition_success(record, result, state.config),
         {:ok, state} <- persist_transition(transitioned, state) do
      {:reply, {:ok, result}, state}
    else
      {:idempotent, {:ok, result}} ->
        {:reply, {:ok, result}, state}

      {:error, %Error{} = error} ->
        {:reply, {:error, error}, state}

      {:stop, %Error{} = error} ->
        {:stop, @inconsistent_persistence, {:error, error}, state}
    end
  end

  def handle_call({:complete_failure, request_id, error}, _from, state) do
    with {:ok, record} <- fetch_record(request_id, state),
         :ok <- ensure_transition_record_path(record, state.config),
         {:ok, error} <- validate_error(error),
         {:ok, transitioned} <- transition_failure(record, error, state.config),
         {:ok, state} <- persist_transition(transitioned, state) do
      {:reply, {:error, error}, state}
    else
      {:idempotent, {:error, error}} ->
        {:reply, {:error, error}, state}

      {:error, %Error{} = error} ->
        {:reply, {:error, error}, state}

      {:stop, %Error{} = error} ->
        {:stop, @inconsistent_persistence, {:error, error}, state}
    end
  end

  def handle_call(:wire_projection, _from, state) do
    message = %Journal{
      target_type: :netman,
      target_id: state.config.netman_id,
      entries: wire_entries(state.records)
    }

    reply =
      with {:ok, encoded} <- Message.encode(message),
           {:ok, ^message} <- Message.decode(encoded) do
        {:ok, message}
      else
        _invalid -> invalid("invalid command journal projection")
      end

    {:reply, reply, state}
  end

  defp reserve_valid(envelope, state) do
    case replay_valid(envelope, state) do
      :miss -> reserve_new(envelope, state)
      replay_or_error -> {:reply, replay_or_error, state}
    end
  end

  defp reserve_new(envelope, state) do
    with :ok <- ensure_owned_path(state.config),
         :ok <- ensure_capacity(state),
         path = journal_path(state.config.directory, envelope.request_id),
         :ok <- ensure_new_record_path(path),
         {:ok, now} <- now(state.config),
         record = %Record{
           request_id: envelope.request_id,
           envelope: envelope,
           state: :received,
           fingerprint: fingerprint(envelope),
           inserted_at: now,
           updated_at: now,
           path: path
         },
         {:ok, ^path} <- Storage.create(path, document(record), state.config.storage_opts),
         :ok <- ensure_record_path(path, state.config) do
      updated = %{
        state
        | records: Map.put(state.records, record.request_id, record),
          idempotency: Map.put(state.idempotency, envelope.idempotency_key, envelope.request_id)
      }

      {:reply, {:reserved, envelope.request_id}, updated}
    else
      {:error, %Error{} = error} ->
        {:reply, {:error, error}, state}

      {:error, :corrupt} ->
        {:reply, internal("command journal path is unsafe"), state}
    end
  end

  defp replay_valid(envelope, state) do
    fingerprint = fingerprint(envelope)

    case Map.fetch(state.records, envelope.request_id) do
      {:ok, %Record{fingerprint: ^fingerprint} = record} ->
        replay_record(record)

      {:ok, _different_record} ->
        conflict("command request fingerprint conflicts")

      :error ->
        case Map.fetch(state.idempotency, envelope.idempotency_key) do
          :error -> :miss
          {:ok, _other_request_id} -> conflict("command idempotency key conflicts")
        end
    end
  end

  defp replay_record(%Record{state: :succeeded, result: result}), do: {:replay, {:ok, result}}
  defp replay_record(%Record{state: :failed, error: error}), do: {:replay, {:error, error}}

  defp replay_record(%Record{state: :unknown, request_id: request_id}),
    do: {:replay, {:unknown, request_id}}

  defp replay_record(%Record{state: state}) when state in [:received, :running],
    do: conflict("command request is pending")

  defp transition_running(%Record{state: :received} = record, config) do
    with {:ok, now} <- transition_time(record, config) do
      {:ok, %{record | state: :running, updated_at: now}}
    end
  end

  defp transition_running(%Record{state: :running}, _config), do: {:idempotent, :ok}
  defp transition_running(_record, _config), do: conflict("command state cannot become running")

  defp transition_success(%Record{state: :running} = record, result, config) do
    with {:ok, now} <- transition_time(record, config) do
      {:ok,
       %{
         record
         | state: :succeeded,
           result: result,
           error: nil,
           updated_at: now,
           resolved_at: now
       }}
    end
  end

  defp transition_success(%Record{state: :succeeded, result: result}, result, _config),
    do: {:idempotent, {:ok, result}}

  defp transition_success(_record, _result, _config),
    do: conflict("command result conflicts with durable state")

  defp transition_failure(%Record{state: :running} = record, error, config) do
    with {:ok, now} <- transition_time(record, config) do
      {:ok,
       %{
         record
         | state: :failed,
           result: nil,
           error: error,
           updated_at: now,
           resolved_at: now
       }}
    end
  end

  defp transition_failure(%Record{state: :failed, error: error}, error, _config),
    do: {:idempotent, {:error, error}}

  defp transition_failure(_record, _error, _config),
    do: conflict("command error conflicts with durable state")

  defp persist_transition(record, state) do
    prior = Map.fetch!(state.records, record.request_id)

    case replace_record(prior, record, state.config) do
      {:ok, ^record} ->
        {:ok, %{state | records: Map.put(state.records, record.request_id, record)}}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, :inconsistent} ->
        {:error, error} = internal("command journal persistence is inconsistent")
        {:stop, error}
    end
  end

  defp validate_envelope(envelope, config) do
    with {:ok, %Envelope{} = envelope} <- Operation.validate_envelope(envelope, :command),
         true <- envelope.target_type == :netman,
         true <- envelope.target_id == config.netman_id,
         {:ok, %Operation{target_type: :netman, kind: :command} = operation} <-
           Operation.lookup(envelope.operation),
         true <- MapSet.member?(config.capabilities, operation.capability) do
      {:ok, envelope}
    else
      _invalid -> invalid("invalid Netman command envelope")
    end
  end

  defp fetch_record(request_id, state) when is_binary(request_id) do
    if Regex.match?(@request_id, request_id) do
      case Map.fetch(state.records, request_id) do
        {:ok, record} -> {:ok, record}
        :error -> not_found("command request was not found")
      end
    else
      invalid("invalid command request ID")
    end
  end

  defp fetch_record(_request_id, _state), do: invalid("invalid command request ID")

  defp ensure_capacity(state) do
    if map_size(state.records) < state.config.max_records do
      :ok
    else
      conflict("command journal capacity reached")
    end
  end

  defp build_config(opts) do
    if Keyword.keyword?(opts) do
      with {:ok, data_dir} <- absolute_data_dir(Keyword.get(opts, :data_dir)),
           {:ok, netman_id} <- netman_id(Keyword.get(opts, :netman_id)),
           {:ok, capabilities} <- capabilities(Keyword.get(opts, :capabilities)),
           {:ok, max_records} <-
             max_records(Keyword.get(opts, :max_records, @default_max_records)),
           {:ok, clock} <- clock(Keyword.get(opts, :clock, &DateTime.utc_now/0)),
           {:ok, scanner} <-
             directory_scanner(Keyword.get(opts, :directory_scanner, __MODULE__.DirectoryScanner)),
           {:ok, storage_opts} <- storage_opts(Keyword.get(opts, :storage_opts, [])) do
        {:ok,
         %{
           data_dir: data_dir,
           directory: Path.join([data_dir, "netman", "journals"]),
           netman_id: netman_id,
           capabilities: MapSet.new(capabilities),
           max_records: max_records,
           clock: clock,
           directory_scanner: scanner,
           storage_opts: storage_opts
         }}
      else
        _invalid -> {:error, :invalid_configuration}
      end
    else
      {:error, :invalid_configuration}
    end
  end

  defp absolute_data_dir(data_dir) when is_binary(data_dir) and data_dir != "" do
    if Path.type(data_dir) == :absolute and Path.expand(data_dir) == data_dir do
      {:ok, data_dir}
    else
      :error
    end
  end

  defp absolute_data_dir(_data_dir), do: :error

  defp netman_id(value) do
    with {:ok, value} <- Bounds.id(value),
         true <- value != "",
         true <- value not in [".", ".."],
         false <- String.contains?(value, ["/", "\\"]),
         false <- Regex.match?(~r/\A[A-Za-z]:/, value),
         normalized when is_binary(normalized) <- :unicode.characters_to_nfkc_binary(value),
         true <- normalized == value,
         false <- Regex.match?(~r/\p{C}/u, value) do
      {:ok, value}
    else
      _invalid -> :error
    end
  rescue
    _exception -> :error
  end

  defp capabilities(values) do
    with {:ok, values} <- Bounds.list(values),
         true <- Enum.all?(values, &valid_capability?/1),
         true <- length(values) == length(Enum.uniq(values)) do
      {:ok, values}
    else
      _invalid -> :error
    end
  end

  defp valid_capability?(value) do
    match?({:ok, capability} when capability != "", Bounds.message(value))
  end

  defp max_records(value) when is_integer(value) and value > 0 do
    if value <= Bounds.max_list_entries(), do: {:ok, value}, else: :error
  end

  defp max_records(_value), do: :error

  defp clock(value) when is_function(value, 0), do: {:ok, value}
  defp clock(_value), do: :error

  defp directory_scanner(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :scan, 1) do
      {:ok, module}
    else
      :error
    end
  end

  defp directory_scanner(_module), do: :error

  defp storage_opts(opts) do
    if is_list(opts) and Keyword.keyword?(opts), do: {:ok, opts}, else: :error
  end

  defp scan(config) do
    case config.directory_scanner.scan(config.directory) do
      {:ok, entries} when is_list(entries) -> {:ok, entries}
      {:error, :unsafe} -> {:error, :corrupt}
      _error -> {:error, :scan}
    end
  rescue
    _exception -> {:error, :scan}
  catch
    _kind, _reason -> {:error, :scan}
  end

  defp validate_entries(entries, max_records) do
    with true <- length(entries) <= max_records,
         true <- Enum.all?(entries, &valid_entry?/1) do
      :ok
    else
      false when length(entries) > max_records -> {:error, :capacity}
      _invalid -> {:error, :corrupt}
    end
  end

  defp valid_entry?(%{name: name, type: :regular}) when is_binary(name) do
    Path.basename(name) == name and Regex.match?(@journal_file, name)
  end

  defp valid_entry?(_entry), do: false

  defp load_records(entries, config) do
    entries
    |> Enum.sort_by(& &1.name)
    |> Enum.reduce_while({:ok, %{}, %{}}, fn entry, {:ok, records, idempotency} ->
      [_, request_id] = Regex.run(@journal_file, entry.name)
      path = Path.join(config.directory, entry.name)

      with {:ok, document} <- read_record_document(path, config),
           {:ok, record} <- decode_record(document, request_id, path, config.netman_id),
           false <- Map.has_key?(idempotency, record.envelope.idempotency_key) do
        {:cont,
         {:ok, Map.put(records, request_id, record),
          Map.put(idempotency, record.envelope.idempotency_key, request_id)}}
      else
        _invalid -> {:halt, {:error, :corrupt}}
      end
    end)
  end

  defp recover_pending(records, config) do
    records
    |> Map.values()
    |> Enum.sort_by(& &1.request_id)
    |> Enum.reduce_while({:ok, records}, fn
      %Record{state: state} = record, {:ok, recovered_records}
      when state in [:received, :running] ->
        with {:ok, now} <- transition_time(record, config),
             recovered = %{
               record
               | state: :unknown,
                 result: nil,
                 error: nil,
                 updated_at: now,
                 resolved_at: now
             },
             {:ok, ^recovered} <- replace_record(record, recovered, config) do
          {:cont, {:ok, Map.put(recovered_records, recovered.request_id, recovered)}}
        else
          {:error, :inconsistent} -> {:halt, {:error, :inconsistent_persistence}}
          _error -> {:halt, {:error, :persistence}}
        end

      _terminal, {:ok, recovered_records} ->
        {:cont, {:ok, recovered_records}}
    end)
  end

  defp replace_record(prior, intended, config) do
    with :ok <- ensure_record_path(intended.path, config) do
      case Storage.replace(intended.path, document(intended), config.storage_opts) do
        {:ok, path} when path == intended.path ->
          case ensure_record_path(intended.path, config) do
            :ok -> {:ok, intended}
            _unsafe -> {:error, :inconsistent}
          end

        {:error, %Error{} = storage_error} ->
          reconcile_replace_error(prior, intended, storage_error, config)

        _invalid ->
          {:error, :inconsistent}
      end
    else
      {:error, :corrupt} -> {:error, :inconsistent}
    end
  end

  defp reconcile_replace_error(prior, intended, storage_error, config) do
    with {:ok, durable_document} <- read_record_document(intended.path, config),
         {:ok, _durable_record} <-
           decode_record(
             durable_document,
             intended.request_id,
             intended.path,
             config.netman_id
           ) do
      cond do
        durable_document == document(intended) -> {:ok, intended}
        durable_document == document(prior) -> {:error, storage_error}
        true -> {:error, :inconsistent}
      end
    else
      _error -> {:error, :inconsistent}
    end
  end

  defp read_record_document(path, config) do
    with :ok <- ensure_owned_path(config),
         {:ok, identity} <- regular_record_identity(path),
         {:ok, document} <- Storage.read(path, config.storage_opts),
         {:ok, ^identity} <- regular_record_identity(path) do
      {:ok, document}
    else
      _unsafe_or_changed -> {:error, :corrupt}
    end
  end

  defp ensure_transition_record_path(record, config) do
    case ensure_record_path(record.path, config) do
      :ok ->
        :ok

      _unsafe ->
        {:error, error} = internal("command journal persistence is inconsistent")
        {:stop, error}
    end
  end

  defp ensure_new_record_path(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, _existing} -> conflict("command journal file conflicts")
      {:error, _reason} -> internal("command journal path is unsafe")
    end
  rescue
    _exception -> internal("command journal path is unsafe")
  catch
    _kind, _reason -> internal("command journal path is unsafe")
  end

  defp ensure_record_path(path, config) do
    with :ok <- ensure_owned_path(config),
         :ok <- ensure_regular_record_path(path) do
      :ok
    end
  end

  defp ensure_regular_record_path(path) do
    case regular_record_identity(path) do
      {:ok, _identity} -> :ok
      {:error, :corrupt} = error -> error
    end
  end

  defp regular_record_identity(path) do
    case File.lstat(path) do
      {:ok,
       %File.Stat{
         type: :regular,
         major_device: major_device,
         minor_device: minor_device,
         inode: inode
       }} ->
        {:ok, {:regular, major_device, minor_device, inode}}

      _other ->
        {:error, :corrupt}
    end
  rescue
    _exception -> {:error, :corrupt}
  catch
    _kind, _reason -> {:error, :corrupt}
  end

  defp ensure_owned_path(config) do
    [config.data_dir, Path.join(config.data_dir, "netman"), config.directory]
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case ensure_owned_directory(path) do
        :ok -> {:cont, :ok}
        {:error, :corrupt} = error -> {:halt, error}
      end
    end)
  end

  defp ensure_owned_directory(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        :ok

      {:ok, _other} ->
        {:error, :corrupt}

      {:error, :enoent} ->
        create_owned_directory(path)

      {:error, _reason} ->
        {:error, :corrupt}
    end
  rescue
    _exception -> {:error, :corrupt}
  catch
    _kind, _reason -> {:error, :corrupt}
  end

  defp create_owned_directory(path) do
    case File.mkdir(path) do
      :ok -> validate_created_directory(path)
      {:error, :eexist} -> validate_created_directory(path)
      {:error, _reason} -> {:error, :corrupt}
    end
  end

  defp validate_created_directory(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      _other -> {:error, :corrupt}
    end
  end

  defp decode_record(document, expected_request_id, path, netman_id) when is_map(document) do
    with true <- exact_keys?(document, @document_keys),
         @schema_version <- document["schema_version"],
         ^expected_request_id <- document["request_id"],
         {:ok, envelope} <- Envelope.from_wire(document["envelope"]),
         true <- Envelope.to_wire(envelope) == document["envelope"],
         {:ok, ^envelope} <- Operation.validate_envelope(envelope, :command),
         true <- envelope.target_type == :netman,
         true <- envelope.target_id == netman_id,
         true <- envelope.request_id == expected_request_id,
         {:ok, %Operation{target_type: :netman, kind: :command}} <-
           Operation.lookup(envelope.operation),
         true <- exact_keys?(document["idempotency_fingerprint"], @fingerprint_keys),
         true <- document["idempotency_fingerprint"] == fingerprint(envelope),
         {:ok, state} <- decode_state(document["state"]),
         {:ok, inserted_at} <- decode_datetime(document["inserted_at"]),
         {:ok, updated_at} <- decode_datetime(document["updated_at"]),
         {:ok, resolved_at} <- decode_optional_datetime(document["resolved_at"]),
         true <- DateTime.compare(inserted_at, updated_at) in [:lt, :eq],
         {:ok, result, error} <-
           decode_outcome(
             state,
             envelope,
             document["result"],
             document["error"],
             resolved_at,
             updated_at
           ) do
      {:ok,
       %Record{
         request_id: expected_request_id,
         envelope: envelope,
         state: state,
         fingerprint: fingerprint(envelope),
         result: result,
         error: error,
         inserted_at: inserted_at,
         updated_at: updated_at,
         resolved_at: resolved_at,
         path: path
       }}
    else
      _invalid -> {:error, :corrupt}
    end
  end

  defp decode_record(_document, _expected_request_id, _path, _netman_id),
    do: {:error, :corrupt}

  defp decode_state("received"), do: {:ok, :received}
  defp decode_state("running"), do: {:ok, :running}
  defp decode_state("succeeded"), do: {:ok, :succeeded}
  defp decode_state("failed"), do: {:ok, :failed}
  defp decode_state("unknown"), do: {:ok, :unknown}
  defp decode_state(_state), do: {:error, :corrupt}

  defp decode_outcome(state, _envelope, nil, nil, nil, _updated_at)
       when state in [:received, :running],
       do: {:ok, nil, nil}

  defp decode_outcome(:succeeded, envelope, result, nil, resolved_at, updated_at)
       when not is_nil(resolved_at) do
    with true <- resolved_at == updated_at,
         {:ok, result} <-
           Operation.validate_result(envelope.operation, :netman, :command, result) do
      {:ok, result, nil}
    end
  end

  defp decode_outcome(:failed, _envelope, nil, error, resolved_at, updated_at)
       when not is_nil(resolved_at) do
    with true <- resolved_at == updated_at,
         {:ok, error} <- decode_error(error) do
      {:ok, nil, error}
    end
  end

  defp decode_outcome(:unknown, _envelope, nil, nil, resolved_at, updated_at)
       when not is_nil(resolved_at) do
    if resolved_at == updated_at, do: {:ok, nil, nil}, else: {:error, :corrupt}
  end

  defp decode_outcome(_state, _envelope, _result, _error, _resolved_at, _updated_at),
    do: {:error, :corrupt}

  defp decode_error(error) when is_map(error) do
    with true <- exact_keys?(error, ["code", "details", "message"]),
         {:ok, decoded} <- Error.from_wire(error),
         {:ok, decoded} <- validate_error(decoded),
         true <- Error.to_wire(decoded) == error do
      {:ok, decoded}
    else
      _invalid -> {:error, :corrupt}
    end
  end

  defp decode_error(_error), do: {:error, :corrupt}

  defp validate_error(%Error{} = error) do
    with :ok <- Operation.validate_transport(error.details),
         %Error{} = validated <- Error.new(error.code, error.message, error.details),
         true <- validated == error,
         wire when is_map(wire) <- Error.to_wire(validated),
         true <- exact_keys?(wire, ["code", "details", "message"]),
         {:ok, ^validated} <- Error.from_wire(wire) do
      {:ok, validated}
    else
      _invalid -> invalid("invalid command error")
    end
  end

  defp validate_error(_error), do: invalid("invalid command error")

  defp document(record) do
    %{
      "schema_version" => @schema_version,
      "request_id" => record.request_id,
      "envelope" => Envelope.to_wire(record.envelope),
      "state" => Atom.to_string(record.state),
      "result" => record.result,
      "error" => encode_error(record.error),
      "idempotency_fingerprint" => record.fingerprint,
      "inserted_at" => DateTime.to_iso8601(record.inserted_at),
      "updated_at" => DateTime.to_iso8601(record.updated_at),
      "resolved_at" => encode_datetime(record.resolved_at)
    }
  end

  defp fingerprint(envelope) do
    %{
      "target_type" => Atom.to_string(envelope.target_type),
      "target_id" => envelope.target_id,
      "operation" => envelope.operation,
      "idempotency_key" => envelope.idempotency_key,
      "expected_revision" => envelope.expected_revision,
      "payload_digest" => envelope.payload_digest,
      "config_version" => envelope.config_version
    }
  end

  defp wire_entries(records) do
    records
    |> Map.values()
    |> Enum.filter(&(&1.state in @terminal_states))
    |> Enum.sort_by(& &1.request_id)
    |> Enum.map(&wire_entry/1)
  end

  defp wire_entry(%Record{state: :succeeded} = record) do
    wire_entry(record, "completed", record.result, nil)
  end

  defp wire_entry(%Record{state: :failed} = record) do
    wire_entry(record, "failed", nil, record.error)
  end

  defp wire_entry(%Record{state: :unknown} = record) do
    wire_entry(record, "unknown", nil, nil)
  end

  defp wire_entry(record, status, result, error) do
    %{
      "request_id" => record.request_id,
      "operation" => record.envelope.operation,
      "status" => status,
      "result" => result,
      "error" => error
    }
  end

  defp now(config) do
    case config.clock.() do
      %DateTime{utc_offset: 0, std_offset: 0} = value -> {:ok, value}
      _invalid -> internal("command journal clock failed")
    end
  rescue
    _exception -> internal("command journal clock failed")
  catch
    _kind, _reason -> internal("command journal clock failed")
  end

  defp transition_time(record, config) do
    with {:ok, now} <- now(config),
         true <- DateTime.compare(record.updated_at, now) in [:lt, :eq] do
      {:ok, now}
    else
      _invalid -> internal("command journal clock moved backwards")
    end
  end

  defp decode_datetime(value) when is_binary(value) do
    with {:ok, datetime, 0} <- DateTime.from_iso8601(value),
         true <- String.ends_with?(value, "Z"),
         true <- DateTime.to_iso8601(datetime) == value do
      {:ok, datetime}
    else
      _invalid -> {:error, :corrupt}
    end
  end

  defp decode_datetime(_value), do: {:error, :corrupt}
  defp decode_optional_datetime(nil), do: {:ok, nil}
  defp decode_optional_datetime(value), do: decode_datetime(value)

  defp encode_error(nil), do: nil
  defp encode_error(%Error{} = error), do: Error.to_wire(error)
  defp encode_datetime(nil), do: nil
  defp encode_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp journal_path(directory, request_id), do: Path.join(directory, "#{request_id}.json")

  defp exact_keys?(value, keys) when is_map(value),
    do: Enum.sort(Map.keys(value)) == Enum.sort(keys)

  defp exact_keys?(_value, _keys), do: false

  defp invalid(message), do: {:error, Error.new(:invalid, message, %{})}
  defp conflict(message), do: {:error, Error.new(:conflict, message, %{})}
  defp not_found(message), do: {:error, Error.new(:not_found, message, %{})}
  defp internal(message), do: {:error, Error.new(:internal, message, %{})}
end

defmodule YellowDog.NetmanAgent.CommandJournal.DirectoryScanner do
  @moduledoc false

  @spec scan(Path.t()) ::
          {:ok, [%{name: String.t(), type: atom()}]} | {:error, :unsafe | term()}
  def scan(directory) do
    case File.lstat(directory) do
      {:ok, %File.Stat{type: :directory}} -> scan_entries(directory)
      {:ok, _other} -> {:error, :unsafe}
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  defp scan_entries(directory) do
    with {:ok, names} <- File.ls(directory) do
      Enum.reduce_while(names, {:ok, []}, fn name, {:ok, entries} ->
        case File.lstat(Path.join(directory, name)) do
          {:ok, %File.Stat{type: type}} ->
            {:cont, {:ok, [%{name: name, type: type} | entries]}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, entries} -> {:ok, Enum.reverse(entries)}
        error -> error
      end
    end
  end
end
