defmodule YellowDog.Management.EventStore do
  @moduledoc false

  use GenServer

  require Logger

  alias YellowDog.Management.Event
  alias YellowDog.Management.ManifestStore
  alias YellowDog.Management.Storage.AtomicJson
  alias YellowDog.Management.Storage.Path, as: StoragePath
  alias YellowDog.Sync.Error

  @default_max_events 500
  @default_max_command_records 1_000
  @default_max_snapshot_records 1_000
  @default_event_write_timeout_ms 5_000
  @max_event_write_timeout_ms 60_000
  @transport_margin_divisor 5
  @max_events_bound 1_000
  @max_command_records_bound 10_000
  @max_snapshot_records_bound 10_000
  @max_sequence 9_223_372_036_854_775_807
  @max_collision_attempts 1_000
  @allocation_batch_size 100
  @event_filename ~r/^evt-([1-9][0-9]{0,18})\.json$/
  @event_staging_filename ~r/^\.evt-[1-9][0-9]{0,18}\.json\..+\.stage$/
  @config_table YellowDog.Management.EventStore.ConfigSnapshot

  defmodule Config do
    @moduledoc false
    @enforce_keys [
      :root,
      :file_ops,
      :max_events,
      :max_command_records,
      :max_snapshot_records,
      :operation_timeout_ms,
      :transport_margin_ms,
      :test_hook
    ]
    defstruct @enforce_keys
  end

  defmodule Reservation do
    @moduledoc false
    @enforce_keys [
      :event,
      :event_map,
      :event_digest,
      :commit_token,
      :final_path,
      :staging_path,
      :config
    ]
    defstruct @enforce_keys
  end

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{publish_config?: name == __MODULE__}, name: name)
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc false
  def operation do
    config = config()
    {monotonic_ms() + config.operation_timeout_ms, config}
  end

  @doc false
  def operation_deadline, do: elem(operation(), 0)

  @doc false
  def operation_timeout_ms, do: config().operation_timeout_ms

  @doc false
  def call_timeout(deadline, margin_stages),
    do: call_timeout(deadline, margin_stages, config())

  @doc false
  def call_timeout(deadline, margin_stages, %Config{} = config)
      when is_integer(deadline) and is_integer(margin_stages) and margin_stages > 0 do
    max(deadline - monotonic_ms(), 0) + config.transport_margin_ms * margin_stages
  end

  @doc false
  def read_call_timeout, do: read_call_timeout(config())

  @doc false
  def read_call_timeout(%Config{} = config) do
    config.operation_timeout_ms + config.transport_margin_ms * 3
  end

  @doc false
  def config do
    case :ets.whereis(@config_table) do
      :undefined -> fallback_config()
      _table -> lookup_config()
    end
  rescue
    ArgumentError -> fallback_config()
  end

  @doc false
  def append(attrs) do
    {deadline, config} = operation()
    append(attrs, deadline, config)
  end

  @doc false
  def append(attrs, deadline) when is_integer(deadline) do
    append(attrs, deadline, config())
  end

  @doc false
  def append(attrs, deadline, %Config{} = config) when is_integer(deadline) do
    with {:ok, reservation} <- reserve(attrs, deadline, config) do
      ManifestStore.persist_event(reservation, deadline)
    end
  end

  @doc false
  def reserve(attrs, deadline) when is_integer(deadline) do
    reserve(attrs, deadline, config())
  end

  @doc false
  def reserve(attrs, deadline, %Config{} = config) when is_integer(deadline) do
    bounded_call({:reserve, attrs, deadline, config}, deadline, config)
  end

  @doc false
  def persist(%Reservation{} = reservation, deadline) when is_integer(deadline) do
    ManifestStore.persist_event(reservation, deadline)
  end

  @doc false
  def timeout_result, do: {:error, timeout_error()}

  @doc false
  def list do
    GenServer.call(__MODULE__, :list, read_call_timeout())
  catch
    :exit, _reason -> []
  end

  @impl true
  def init(%{publish_config?: publish_config?}) do
    config = snapshot_config()
    publish_config(publish_config?, config)
    cleanup_stale_staging_files(config)
    {:ok, %{sequence: next_sequence(config), config: config}}
  end

  @impl true
  def handle_call({:reserve, attrs, deadline, requested_config}, _from, state) do
    result =
      cond do
        deadline_expired?(deadline) ->
          {:error, timeout_error(), state.sequence}

        requested_config != state.config ->
          {:error, internal_error(), state.sequence}

        true ->
          reserve_event(attrs, state.sequence, @max_collision_attempts, deadline, state.config)
      end

    case result do
      {:ok, reservation, next_sequence} ->
        {:reply, {:ok, reservation}, %{state | sequence: next_sequence}}

      {:error, error, next_sequence} ->
        {:reply, {:error, error}, %{state | sequence: next_sequence}}
    end
  end

  def handle_call(:list, _from, state) do
    {:reply, read_events(state.config), state}
  end

  defp reserve_event(_attrs, sequence, _remaining, _deadline, _config)
       when sequence > @max_sequence do
    {:error, internal_error(), sequence}
  end

  defp reserve_event(_attrs, sequence, 0, _deadline, _config) do
    {:error, conflict_error(), sequence}
  end

  defp reserve_event(attrs, sequence, remaining, deadline, config) do
    if deadline_expired?(deadline) do
      {:error, timeout_error(), sequence}
    else
      event = Event.new(attrs, sequence)
      final_path = event_path(config, event.id)

      if File.exists?(final_path) do
        reserve_event(attrs, sequence + 1, remaining - 1, deadline, config)
      else
        commit_token = random_commit_token()
        event_map = Event.to_map(event, commit_token)

        reservation = %Reservation{
          event: event,
          event_map: event_map,
          event_digest: Event.digest(event_map),
          commit_token: commit_token,
          final_path: final_path,
          staging_path: AtomicJson.staging_path(final_path),
          config: config
        }

        {:ok, reservation, sequence + 1}
      end
    end
  end

  defp read_events(%Config{root: nil}), do: []

  defp read_events(config) do
    directory = Path.join(config.root, "events")

    case File.ls(directory) do
      {:ok, filenames} ->
        filenames
        |> Enum.reduce(:gb_sets.empty(), fn filename, events ->
          retain_valid_event(events, directory, filename, config)
        end)
        |> :gb_sets.to_list()
        |> Enum.map(&elem(&1, 1))

      _missing_or_unreadable ->
        []
    end
  end

  defp retain_valid_event(events, directory, filename, config) do
    with {:ok, _sequence} <- event_file_sequence(filename),
         {:ok, event} <- read_event(Path.join(directory, filename), config) do
      event_key = {event.sequence, event.occurred_at, event.id}
      events = :gb_sets.add({event_key, event}, events)

      if :gb_sets.size(events) > config.max_events do
        {_oldest, events} = :gb_sets.take_smallest(events)
        events
      else
        events
      end
    else
      _invalid -> events
    end
  end

  defp next_sequence(%Config{root: nil}), do: 1

  defp next_sequence(config) do
    directory = Path.join(config.root, "events")

    case highest_valid_sequence(directory, @max_sequence + 1, config) do
      nil -> 1
      @max_sequence -> @max_sequence + 1
      sequence -> sequence + 1
    end
  end

  defp highest_valid_sequence(directory, before_sequence, config) do
    candidates = select_candidates(directory, @allocation_batch_size, before_sequence)

    case Enum.find_value(candidates, fn {sequence, path} ->
           case read_event(path, config) do
             {:ok, %Event{sequence: ^sequence}} -> sequence
             :error -> nil
           end
         end) do
      nil ->
        case List.last(candidates) do
          nil -> nil
          {oldest_sequence, _path} -> highest_valid_sequence(directory, oldest_sequence, config)
        end

      sequence ->
        sequence
    end
  end

  defp select_candidates(directory, limit, before_sequence) do
    case File.ls(directory) do
      {:ok, filenames} ->
        filenames
        |> Enum.reduce(:gb_sets.empty(), fn filename, candidates ->
          case event_file_sequence(filename) do
            {:ok, sequence} when sequence < before_sequence ->
              retain_candidate(candidates, {sequence, Path.join(directory, filename)}, limit)

            _invalid ->
              candidates
          end
        end)
        |> :gb_sets.to_list()
        |> Enum.sort_by(&elem(&1, 0), :desc)

      {:error, :enoent} ->
        []

      {:error, reason} ->
        Logger.warning("Unable to list management events: #{inspect(reason)}")
        []
    end
  end

  defp retain_candidate(candidates, candidate, limit) do
    candidates = :gb_sets.add(candidate, candidates)

    if :gb_sets.size(candidates) > limit do
      {_smallest, candidates} = :gb_sets.take_smallest(candidates)
      candidates
    else
      candidates
    end
  end

  defp event_file_sequence(filename) do
    case Regex.run(@event_filename, filename) do
      [_, sequence] ->
        sequence = String.to_integer(sequence)
        if sequence <= @max_sequence, do: {:ok, sequence}, else: :error

      _invalid ->
        :error
    end
  end

  defp read_event(path, config) do
    with {:ok, value} <- AtomicJson.read(path, config.file_ops),
         {:ok, event} <- Event.from_map(value),
         true <- event_path(config, event.id) == path do
      {:ok, event}
    else
      _invalid ->
        Logger.warning("Ignoring malformed management event file: #{path}")
        :error
    end
  end

  defp snapshot_config do
    timeout = configured_event_write_timeout_ms()

    %Config{
      root: configured_root(),
      file_ops: configured_file_ops(),
      max_events: configured_max_events(),
      max_command_records: configured_max_command_records(),
      max_snapshot_records: configured_max_snapshot_records(),
      operation_timeout_ms: timeout,
      transport_margin_ms: max(div(timeout, @transport_margin_divisor), 1),
      test_hook: configured_test_hook()
    }
  end

  defp fallback_config do
    %Config{
      root: configured_root(),
      file_ops: AtomicJson.FileOps,
      max_events: @default_max_events,
      max_command_records: @default_max_command_records,
      max_snapshot_records: @default_max_snapshot_records,
      operation_timeout_ms: @default_event_write_timeout_ms,
      transport_margin_ms: div(@default_event_write_timeout_ms, @transport_margin_divisor),
      test_hook: nil
    }
  end

  defp configured_root do
    case StoragePath.root() do
      {:ok, root} -> root
      _error -> nil
    end
  end

  defp configured_file_ops do
    Application.get_env(
      :yellow_dog_management_core,
      :atomic_json_file_ops,
      AtomicJson.FileOps
    )
  end

  defp configured_max_events do
    case Application.get_env(:yellow_dog_management_core, :max_events, @default_max_events) do
      limit when is_integer(limit) and limit in 1..@max_events_bound -> limit
      _invalid -> @default_max_events
    end
  end

  defp configured_max_command_records do
    configured_record_limit(
      :max_command_records,
      @default_max_command_records,
      @max_command_records_bound
    )
  end

  defp configured_max_snapshot_records do
    configured_record_limit(
      :max_snapshot_records,
      @default_max_snapshot_records,
      @max_snapshot_records_bound
    )
  end

  defp configured_record_limit(key, default, bound) do
    case Application.get_env(:yellow_dog_management_core, key, default) do
      limit when is_integer(limit) and limit >= 1 and limit <= bound -> limit
      _invalid -> default
    end
  end

  defp configured_event_write_timeout_ms do
    case Application.get_env(
           :yellow_dog_management_core,
           :event_write_timeout_ms,
           @default_event_write_timeout_ms
         ) do
      timeout when is_integer(timeout) and timeout in 1..@max_event_write_timeout_ms -> timeout
      _invalid -> @default_event_write_timeout_ms
    end
  end

  if Mix.env() == :test do
    defp configured_test_hook do
      case Application.get_env(:yellow_dog_management_core, :event_store_test_hook) do
        hook when is_function(hook, 2) -> hook
        _other -> nil
      end
    end
  else
    defp configured_test_hook, do: nil
  end

  defp publish_config(false, _config), do: :ok

  defp publish_config(true, config) do
    :ets.new(@config_table, [:named_table, :set, :protected, read_concurrency: true])
    true = :ets.insert(@config_table, {:config, config})
    :ok
  end

  defp lookup_config do
    case :ets.lookup(@config_table, :config) do
      [{:config, config}] -> config
      [] -> fallback_config()
    end
  end

  defp cleanup_stale_staging_files(%Config{root: nil}), do: :ok

  defp cleanup_stale_staging_files(config) do
    directory = Path.join(config.root, "events")

    case File.ls(directory) do
      {:ok, filenames} ->
        Enum.each(filenames, fn filename ->
          if Regex.match?(@event_staging_filename, filename) do
            best_effort_remove(config.file_ops, Path.join(directory, filename))
          end
        end)

      _missing_or_unreadable ->
        :ok
    end
  end

  defp best_effort_remove(file_ops, path) do
    file_ops.rm(path)
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp bounded_call(request, deadline, config) do
    GenServer.call(__MODULE__, request, call_timeout(deadline, 1, config))
  catch
    :exit, {:timeout, _reason} -> timeout_result()
    :exit, _reason -> {:error, internal_error()}
  end

  defp event_path(%Config{root: root}, event_id) when is_binary(root) do
    Path.join([root, "events", "#{event_id}.json"])
  end

  defp random_commit_token do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
  end

  defp deadline_expired?(deadline), do: deadline <= monotonic_ms()
  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp conflict_error,
    do: Error.new(:conflict, "event sequence allocation exhausted", %{})

  defp timeout_error,
    do: Error.new(:timeout, "management event persistence timed out", %{})

  defp internal_error,
    do: Error.new(:internal, "management event persistence failed", %{})
end
