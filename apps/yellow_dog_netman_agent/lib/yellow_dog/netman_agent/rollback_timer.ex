defmodule YellowDog.NetmanAgent.RollbackTimer do
  @moduledoc """
  Durable reconnect deadline for provisional Netman configuration changes.

  The deadline uses wall-clock milliseconds so it remains meaningful after a
  process or node restart. Confirmation and rollback are checkpointed before
  invoking `ConfigApplier`, making both recovery paths idempotent.
  """

  use GenServer

  alias YellowDog.NetmanAgent.ConfigApplier
  alias YellowDog.NetmanAgent.Storage
  alias YellowDog.Sync.Bounds
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Message

  @schema_version 1
  @default_rollback_window 60_000
  @maximum_rollback_window 86_400_000
  @default_retry_interval 1_000
  @maximum_timer_ms 4_294_967_295
  @max_version 9_223_372_036_854_775_807
  @max_unix_ms 253_402_300_799_999
  @max_storage_bytes Message.max_document_bytes()
  @document_keys ~w(
    deadline_unix_ms previous_revision schema_version status
    target_id target_type version
  )
  @statuses [:idle, :armed, :confirming, :rolling_back]
  @allowed_options [
    :name,
    :data_dir,
    :netman_id,
    :config_applier,
    :rollback_window,
    :retry_interval,
    :clock,
    :timer,
    :max_bytes,
    :storage_opts
  ]

  @type server :: GenServer.server()
  @type snapshot :: %{
          status: :idle | :armed | :confirming | :rolling_back,
          version: pos_integer() | nil,
          previous_revision: String.t() | nil,
          deadline_unix_ms: non_neg_integer() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    with {:ok, config, name} <- validate_options(opts) do
      case name do
        nil -> GenServer.start_link(__MODULE__, config)
        name -> GenServer.start_link(__MODULE__, config, name: name)
      end
    end
  end

  def start_link(_opts), do: {:error, :invalid_options}

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @spec snapshot(server()) :: {:ok, snapshot()} | {:error, Error.t()}
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @spec arm(pos_integer(), String.t(), server()) ::
          {:ok, snapshot()} | {:error, Error.t()}
  def arm(version, previous_revision, server \\ __MODULE__),
    do: GenServer.call(server, {:arm, version, previous_revision})

  @spec confirm(server()) :: {:ok, :idle | map()} | {:error, Error.t()}
  def confirm(server \\ __MODULE__), do: GenServer.call(server, :confirm, :infinity)

  @spec abort(pos_integer(), server()) :: :ok
  def abort(version, server \\ __MODULE__) do
    GenServer.cast(server, {:abort, version})
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(config) do
    with :ok <- ensure_owned_path(config),
         {:ok, record, persisted?} <- load_record(config) do
      {:ok,
       %{
         config: config,
         record: record,
         persisted?: persisted?,
         timer_ref: nil
       }, {:continue, :recover}}
    else
      _invalid -> {:stop, {:rollback_timer_recovery_failed, :persistence}}
    end
  end

  @impl true
  def handle_continue(:recover, state) do
    {:noreply, recover(state)}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, {:ok, state.record}, state}
  end

  def handle_call({:arm, version, previous_revision}, _from, state) do
    with {:ok, version} <- version(version),
         {:ok, previous_revision} <- Digest.validate(previous_revision),
         {:ok, now} <- now(state.config),
         {:ok, deadline} <- deadline(now, state.config.rollback_window) do
      arm_record(version, previous_revision, deadline, state)
    else
      _invalid -> {:reply, invalid(), state}
    end
  end

  def handle_call(:confirm, _from, %{record: %{status: :idle}} = state) do
    {:reply, {:ok, :idle}, state}
  end

  def handle_call(:confirm, _from, %{record: %{status: :armed}} = state) do
    state = cancel_timer(state)

    case persist(%{state.record | status: :confirming}, state) do
      {:ok, state} -> confirm_provisional(state)
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call(:confirm, _from, %{record: %{status: :confirming}} = state),
    do: confirm_provisional(state)

  def handle_call(:confirm, _from, state), do: {:reply, conflict(), state}

  @impl true
  def handle_cast({:abort, version}, %{record: %{version: version}} = state) do
    state = cancel_timer(state)

    case persist(idle_record(), state) do
      {:ok, state} -> {:noreply, state}
      {:error, %Error{}} -> {:noreply, recover(state)}
    end
  end

  def handle_cast({:abort, _version}, state), do: {:noreply, state}

  @impl true
  def handle_info(
        {:rollback_deadline, version, deadline},
        %{record: %{status: :armed, version: version, deadline_unix_ms: deadline}} = state
      ) do
    state = %{state | timer_ref: nil}

    case persist(%{state.record | status: :rolling_back}, state) do
      {:ok, state} -> {:noreply, rollback_provisional(state)}
      {:error, %Error{}} -> {:noreply, schedule_deadline_retry(state)}
    end
  end

  def handle_info(
        {:rollback_action_retry, status, version},
        %{record: %{status: status, version: version}} = state
      )
      when status in [:confirming, :rolling_back] do
    state = %{state | timer_ref: nil}

    case status do
      :confirming ->
        case confirm_provisional_result(state) do
          {:ok, _result, state} -> {:noreply, state}
          {:error, state} -> {:noreply, schedule_retry(state)}
        end

      :rolling_back ->
        {:noreply, rollback_provisional(state)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _state = cancel_timer(state)
    :ok
  end

  defp arm_record(version, previous_revision, deadline, state) do
    candidate = %{
      status: :armed,
      version: version,
      previous_revision: previous_revision,
      deadline_unix_ms: deadline
    }

    cond do
      state.record.status == :armed and state.record.version == version and
          state.record.previous_revision == previous_revision ->
        {:reply, {:ok, state.record}, schedule_deadline(state)}

      state.record.status == :idle ->
        case persist(candidate, state) do
          {:ok, state} -> {:reply, {:ok, state.record}, schedule_deadline(state)}
          {:error, %Error{} = error} -> {:reply, {:error, error}, state}
        end

      true ->
        {:reply, conflict(), state}
    end
  end

  defp recover(%{record: %{status: :idle}} = state), do: state
  defp recover(%{record: %{status: :armed}} = state), do: schedule_deadline(state)

  defp recover(%{record: %{status: status}} = state)
       when status in [:confirming, :rolling_back],
       do: schedule_retry(state, 0)

  defp confirm_provisional(state) do
    case confirm_provisional_result(state) do
      {:ok, result, state} -> {:reply, {:ok, result}, state}
      {:error, state} -> {:reply, internal(), schedule_retry(state)}
    end
  end

  defp confirm_provisional_result(state) do
    case safe_applier_call(fn ->
           ConfigApplier.confirm_provisional(
             state.record.version,
             state.config.config_applier
           )
         end) do
      {:ok, %{status: status} = result} when status in [:applied, :replay] ->
        case persist(idle_record(), state) do
          {:ok, state} -> {:ok, result, cancel_timer(state)}
          {:error, %Error{}} -> {:error, state}
        end

      _error_or_malformed ->
        {:error, state}
    end
  end

  defp rollback_provisional(state) do
    case safe_applier_call(fn ->
           ConfigApplier.rollback_provisional(
             state.record.version,
             "management reconnect timed out",
             state.config.config_applier
           )
         end) do
      {:ok, %{status: status}} when status in [:failed, :replay] ->
        case persist(idle_record(), state) do
          {:ok, state} -> cancel_timer(state)
          {:error, %Error{}} -> schedule_retry(state)
        end

      _error_or_malformed ->
        schedule_retry(state)
    end
  end

  defp safe_applier_call(callback) do
    callback.()
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp schedule_deadline(state) do
    with {:ok, now} <- now(state.config) do
      delay = max(state.record.deadline_unix_ms - now, 0)

      schedule(
        state,
        {:rollback_deadline, state.record.version, state.record.deadline_unix_ms},
        delay
      )
    else
      _invalid -> schedule_deadline_retry(state)
    end
  end

  defp schedule_deadline_retry(state) do
    schedule(
      state,
      {:rollback_deadline, state.record.version, state.record.deadline_unix_ms},
      state.config.retry_interval
    )
  end

  defp schedule_retry(state, delay \\ nil) do
    delay = delay || state.config.retry_interval
    schedule(state, {:rollback_action_retry, state.record.status, state.record.version}, delay)
  end

  defp schedule(state, message, delay)
       when is_integer(delay) and delay >= 0 and delay <= @maximum_timer_ms do
    state = cancel_timer(state)

    case safe_timer_call(state.config.timer, :send_after, [self(), message, delay]) do
      ref when is_reference(ref) -> %{state | timer_ref: ref}
      _invalid -> state
    end
  end

  defp schedule(state, message, delay) when delay > @maximum_timer_ms,
    do: schedule(state, message, @maximum_timer_ms)

  defp cancel_timer(%{timer_ref: nil} = state), do: state

  defp cancel_timer(state) do
    _result = safe_timer_call(state.config.timer, :cancel, [state.timer_ref])
    %{state | timer_ref: nil}
  end

  defp safe_timer_call(module, function, arguments) do
    apply(module, function, arguments)
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp persist(record, state) do
    path = state_path(state.config)

    with :ok <- ensure_owned_path(state.config),
         {:ok, ^path} <-
           Storage.replace(path, encode_record(record, state.config), state.config.storage_opts),
         {:ok, document} <- Storage.read(path, state.config.storage_opts),
         {:ok, ^record} <- decode_record(document, state.config) do
      {:ok, %{state | record: record, persisted?: true}}
    else
      _invalid -> {:error, internal_error()}
    end
  end

  defp load_record(config) do
    path = state_path(config)

    case File.lstat(path) do
      {:error, :enoent} ->
        {:ok, idle_record(), false}

      {:ok, %File.Stat{type: :regular}} ->
        with {:ok, document} <- Storage.read(path, config.storage_opts),
             {:ok, record} <- decode_record(document, config) do
          {:ok, record, true}
        end

      _unsafe_or_unavailable ->
        {:error, :persistence}
    end
  end

  defp encode_record(record, config) do
    %{
      "schema_version" => @schema_version,
      "target_type" => "netman",
      "target_id" => config.netman_id,
      "status" => Atom.to_string(record.status),
      "version" => record.version,
      "previous_revision" => record.previous_revision,
      "deadline_unix_ms" => record.deadline_unix_ms
    }
  end

  defp decode_record(document, config) when is_map(document) do
    with true <- Enum.sort(Map.keys(document)) == Enum.sort(@document_keys),
         @schema_version <- document["schema_version"],
         "netman" <- document["target_type"],
         true <- document["target_id"] == config.netman_id,
         {:ok, status} <- status(document["status"]),
         {:ok, record} <-
           decoded_record(
             status,
             document["version"],
             document["previous_revision"],
             document["deadline_unix_ms"]
           ) do
      {:ok, record}
    else
      _invalid -> {:error, :corrupt}
    end
  end

  defp decode_record(_document, _config), do: {:error, :corrupt}

  defp decoded_record(:idle, nil, nil, nil), do: {:ok, idle_record()}

  defp decoded_record(status, version, previous_revision, deadline)
       when status in [:armed, :confirming, :rolling_back] do
    with {:ok, version} <- version(version),
         {:ok, previous_revision} <- Digest.validate(previous_revision),
         {:ok, deadline} <- unix_ms(deadline) do
      {:ok,
       %{
         status: status,
         version: version,
         previous_revision: previous_revision,
         deadline_unix_ms: deadline
       }}
    end
  end

  defp decoded_record(_status, _version, _revision, _deadline), do: {:error, :corrupt}

  defp idle_record do
    %{status: :idle, version: nil, previous_revision: nil, deadline_unix_ms: nil}
  end

  defp validate_options(opts) do
    with true <- Keyword.keyword?(opts),
         keys = Keyword.keys(opts),
         true <- length(keys) == length(Enum.uniq(keys)),
         true <- Enum.all?(keys, &(&1 in @allowed_options)),
         {:ok, name} <- process_name(Keyword.get(opts, :name, __MODULE__)),
         {:ok, data_dir} <- absolute_data_dir(Keyword.get(opts, :data_dir)),
         {:ok, netman_id} <- netman_id(Keyword.get(opts, :netman_id)),
         {:ok, config_applier} <- server_ref(Keyword.get(opts, :config_applier)),
         {:ok, rollback_window} <-
           rollback_window(Keyword.get(opts, :rollback_window, @default_rollback_window)),
         {:ok, retry_interval} <-
           retry_interval(Keyword.get(opts, :retry_interval, @default_retry_interval)),
         {:ok, clock} <- callback_module(Keyword.get(opts, :clock, __MODULE__.Clock), now: 0),
         {:ok, timer} <-
           callback_module(Keyword.get(opts, :timer, __MODULE__.Timer), send_after: 3, cancel: 1),
         {:ok, storage_opts} <- storage_options(opts) do
      {:ok,
       %{
         data_dir: data_dir,
         netman_id: netman_id,
         config_applier: config_applier,
         rollback_window: rollback_window,
         retry_interval: retry_interval,
         clock: clock,
         timer: timer,
         storage_opts: storage_opts
       }, name}
    else
      _invalid -> {:error, :invalid_options}
    end
  end

  defp process_name(nil), do: {:ok, nil}
  defp process_name(value) when is_atom(value) and not is_nil(value), do: {:ok, value}
  defp process_name({:global, _term} = value), do: {:ok, value}

  defp process_name({:via, module, _term} = value)
       when is_atom(module) and not is_nil(module),
       do: {:ok, value}

  defp process_name(_value), do: :error

  defp server_ref(value) when is_pid(value), do: {:ok, value}
  defp server_ref(value) when is_atom(value) and not is_nil(value), do: {:ok, value}
  defp server_ref({:global, _term} = value), do: {:ok, value}

  defp server_ref({:via, module, _term} = value)
       when is_atom(module) and not is_nil(module),
       do: {:ok, value}

  defp server_ref(_value), do: :error

  defp callback_module(value, callbacks) when is_atom(value) and not is_nil(value) do
    if Code.ensure_loaded?(value) and
         Enum.all?(callbacks, fn {function, arity} ->
           function_exported?(value, function, arity)
         end),
       do: {:ok, value},
       else: :error
  end

  defp callback_module(_value, _callbacks), do: :error

  defp storage_options(opts) do
    storage_opts = Keyword.get(opts, :storage_opts, [])

    with true <- Keyword.keyword?(storage_opts),
         {:ok, storage_opts} <- maybe_put_max_bytes(storage_opts, Keyword.fetch(opts, :max_bytes)) do
      {:ok, storage_opts}
    else
      _invalid -> :error
    end
  end

  defp maybe_put_max_bytes(storage_opts, :error), do: {:ok, storage_opts}

  defp maybe_put_max_bytes(storage_opts, {:ok, max_bytes})
       when is_integer(max_bytes) and max_bytes > 0 and max_bytes <= @max_storage_bytes,
       do: {:ok, Keyword.put(storage_opts, :max_bytes, max_bytes)}

  defp maybe_put_max_bytes(_storage_opts, _max_bytes), do: :error

  defp absolute_data_dir(value) when is_binary(value) do
    expanded = Path.expand(value)
    if Path.type(value) == :absolute and expanded == value, do: {:ok, value}, else: :error
  end

  defp absolute_data_dir(_value), do: :error

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

  defp rollback_window(value)
       when is_integer(value) and value > 0 and value <= @maximum_rollback_window,
       do: {:ok, value}

  defp rollback_window(_value), do: :error

  defp retry_interval(value)
       when is_integer(value) and value > 0 and value <= @maximum_timer_ms,
       do: {:ok, value}

  defp retry_interval(_value), do: :error

  defp version(value) when is_integer(value) and value > 0 and value <= @max_version,
    do: {:ok, value}

  defp version(_value), do: :error

  defp unix_ms(value) when is_integer(value) and value >= 0 and value <= @max_unix_ms,
    do: {:ok, value}

  defp unix_ms(_value), do: :error

  defp now(config) do
    case safe_timer_call(config.clock, :now, []) do
      value -> unix_ms(value)
    end
  end

  defp deadline(now, window) when now <= @max_unix_ms - window,
    do: {:ok, now + window}

  defp deadline(_now, _window), do: :error

  defp status(value) when is_binary(value) do
    case Enum.find(@statuses, &(Atom.to_string(&1) == value)) do
      nil -> :error
      status -> {:ok, status}
    end
  end

  defp status(_value), do: :error

  defp ensure_owned_path(config) do
    [config.data_dir, Path.join(config.data_dir, "netman")]
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case ensure_directory(path) do
        :ok -> {:cont, :ok}
        _unsafe -> {:halt, {:error, :path}}
      end
    end)
  end

  defp ensure_directory(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        :ok

      {:error, :enoent} ->
        case File.mkdir(path) do
          :ok -> validate_directory(path)
          {:error, :eexist} -> validate_directory(path)
          _error -> {:error, :path}
        end

      _unsafe ->
        {:error, :path}
    end
  rescue
    _exception -> {:error, :path}
  catch
    _kind, _reason -> {:error, :path}
  end

  defp validate_directory(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      _unsafe -> {:error, :path}
    end
  end

  defp state_path(config), do: Path.join([config.data_dir, "netman", "rollback_timer.json"])

  defp invalid, do: {:error, Error.new(:invalid, "invalid rollback timer state", %{})}
  defp conflict, do: {:error, Error.new(:conflict, "rollback timer conflicts", %{})}
  defp internal, do: {:error, internal_error()}
  defp internal_error, do: Error.new(:internal, "rollback timer persistence failed", %{})

  defmodule Clock do
    @moduledoc false
    def now, do: System.system_time(:millisecond)
  end

  defmodule Timer do
    @moduledoc false
    def send_after(destination, message, delay),
      do: Process.send_after(destination, message, delay)

    def cancel(ref), do: Process.cancel_timer(ref)
  end
end
