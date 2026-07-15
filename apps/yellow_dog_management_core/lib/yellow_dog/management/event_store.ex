defmodule YellowDog.Management.EventStore do
  @moduledoc false

  use GenServer

  require Logger

  alias YellowDog.Management.Event
  alias YellowDog.Management.Storage.AtomicJson
  alias YellowDog.Management.Storage.Path, as: StoragePath
  alias YellowDog.Sync.Error

  @default_max_events 500
  @default_event_write_timeout_ms 5_000
  @transport_margin_divisor 5
  @max_events_bound 1_000
  @max_sequence 9_223_372_036_854_775_807
  @max_collision_attempts 1_000
  @allocation_batch_size 100
  @event_filename ~r/^evt-([1-9][0-9]{0,18})\.json$/

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc false
  def operation_deadline do
    monotonic_ms() + event_write_timeout_ms()
  end

  @doc false
  def call_timeout(deadline, margin_stages)
      when is_integer(deadline) and is_integer(margin_stages) and margin_stages > 0 do
    max(deadline - monotonic_ms(), 0) + transport_margin_ms() * margin_stages
  end

  @doc false
  def append(attrs), do: append(attrs, operation_deadline())

  @doc false
  def append(attrs, deadline) when is_integer(deadline) do
    GenServer.call(__MODULE__, {:append, attrs, deadline}, call_timeout(deadline, 1))
  catch
    :exit, {:timeout, _reason} -> timeout_result()
  end

  @doc false
  def timeout_result, do: {:error, timeout_error()}

  @doc false
  def list, do: GenServer.call(__MODULE__, :list)

  @impl true
  def init(:ok) do
    Process.flag(:trap_exit, true)
    {:ok, next_sequence()}
  end

  @impl true
  def handle_call({:append, attrs, deadline}, _from, sequence) do
    case append_event(attrs, sequence, @max_collision_attempts, deadline) do
      {:ok, event, next_sequence} -> {:reply, {:ok, event}, next_sequence}
      {:error, error, next_sequence} -> {:reply, {:error, error}, next_sequence}
    end
  end

  def handle_call(:list, _from, sequence) do
    {:reply, read_events(max_events()), sequence}
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, sequence), do: {:noreply, sequence}

  def handle_info({:event_write_result, _token, _result}, sequence),
    do: {:noreply, sequence}

  defp append_event(_attrs, sequence, _remaining, _deadline) when sequence > @max_sequence do
    {:error, internal_error(), sequence}
  end

  defp append_event(_attrs, sequence, 0, _deadline) do
    {:error, conflict_error(), sequence}
  end

  defp append_event(attrs, sequence, remaining, deadline) do
    event = Event.new(attrs, sequence)

    with {:ok, path} <- StoragePath.event(event.id) do
      case create_event(path, Event.to_map(event), deadline) do
        {:ok, _path} ->
          {:ok, event, sequence + 1}

        {:error, %Error{code: :conflict}} ->
          append_event(attrs, sequence + 1, remaining - 1, deadline)

        {:error, %Error{} = error} ->
          {:error, error, sequence}
      end
    else
      {:error, %Error{} = error} -> {:error, error, sequence}
    end
  end

  defp create_event(path, value, deadline) do
    if deadline_expired?(deadline) do
      timeout_result()
    else
      existed_before? = File.exists?(path)
      owner = self()
      token = make_ref()

      {worker_pid, monitor_ref} =
        :erlang.spawn_opt(
          fn ->
            result = AtomicJson.create(path, value)
            send(owner, {:event_write_result, token, result})
          end,
          [:link, :monitor]
        )

      await_event_write(
        worker_pid,
        monitor_ref,
        token,
        path,
        existed_before?,
        deadline
      )
    end
  end

  defp await_event_write(worker_pid, monitor_ref, token, path, existed_before?, deadline) do
    receive do
      {:event_write_result, ^token, result} ->
        await_worker_down(worker_pid, monitor_ref, token)
        finish_event_write(result, path, existed_before?, deadline)

      {:DOWN, ^monitor_ref, :process, ^worker_pid, _reason} ->
        flush_worker_messages(worker_pid, token)
        cleanup_then_error(path, existed_before?, internal_error())

      {:EXIT, ^worker_pid, _reason} ->
        await_worker_down(worker_pid, monitor_ref, token)
        cleanup_then_error(path, existed_before?, internal_error())
    after
      max(deadline - monotonic_ms(), 0) ->
        Process.exit(worker_pid, :kill)
        await_worker_down(worker_pid, monitor_ref, token)
        cleanup_then_error(path, existed_before?, timeout_error())
    end
  end

  defp await_worker_down(worker_pid, monitor_ref, token) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^worker_pid, _reason} ->
        flush_worker_messages(worker_pid, token)

      {:event_write_result, ^token, _result} ->
        await_worker_down(worker_pid, monitor_ref, token)

      {:EXIT, ^worker_pid, _reason} ->
        await_worker_down(worker_pid, monitor_ref, token)
    end
  end

  defp flush_worker_messages(worker_pid, token) do
    receive do
      {:EXIT, ^worker_pid, _reason} -> flush_worker_messages(worker_pid, token)
      {:event_write_result, ^token, _result} -> flush_worker_messages(worker_pid, token)
    after
      0 -> :ok
    end
  end

  defp finish_event_write({:ok, _path} = success, path, _existed_before?, deadline) do
    if deadline_expired?(deadline) do
      cleanup_then_error(path, false, timeout_error())
    else
      success
    end
  end

  defp finish_event_write({:error, %Error{}} = error, _path, _existed_before?, deadline) do
    if deadline_expired?(deadline), do: timeout_result(), else: error
  end

  defp cleanup_then_error(_path, true, error), do: {:error, error}

  defp cleanup_then_error(path, false, error) do
    case File.rm(path) do
      :ok ->
        {:error, error}

      {:error, :enoent} ->
        {:error, error}

      {:error, reason} ->
        Logger.error("Failed to remove timed-out management event #{path}: #{inspect(reason)}")
        {:error, internal_error()}
    end
  end

  defp read_events(limit) do
    with {:ok, directory} <- events_directory(),
         {:ok, filenames} <- File.ls(directory) do
      filenames
      |> Enum.reduce(:gb_sets.empty(), fn filename, events ->
        retain_valid_event(events, directory, filename, limit)
      end)
      |> :gb_sets.to_list()
      |> Enum.map(&elem(&1, 1))
    else
      {:error, :enoent} -> []
      _error -> []
    end
  end

  defp retain_valid_event(events, directory, filename, limit) do
    with {:ok, _sequence} <- event_file_sequence(filename),
         {:ok, event} <- read_event(Path.join(directory, filename)) do
      event_key = {event.sequence, event.occurred_at, event.id}
      events = :gb_sets.add({event_key, event}, events)

      if :gb_sets.size(events) > limit do
        {_oldest, events} = :gb_sets.take_smallest(events)
        events
      else
        events
      end
    else
      _invalid -> events
    end
  end

  defp next_sequence do
    with {:ok, directory} <- events_directory() do
      case highest_valid_sequence(directory, @max_sequence + 1) do
        nil -> 1
        @max_sequence -> @max_sequence + 1
        sequence -> sequence + 1
      end
    else
      _error -> 1
    end
  end

  defp highest_valid_sequence(directory, before_sequence) do
    candidates = select_candidates(directory, @allocation_batch_size, before_sequence)

    case Enum.find_value(candidates, fn {sequence, path} ->
           case read_event(path) do
             {:ok, %Event{sequence: ^sequence}} -> sequence
             :error -> nil
           end
         end) do
      nil ->
        case List.last(candidates) do
          nil -> nil
          {oldest_sequence, _path} -> highest_valid_sequence(directory, oldest_sequence)
        end

      sequence ->
        sequence
    end
  end

  defp select_candidates(_directory, limit, _before_sequence) when limit <= 0, do: []

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

  defp read_event(path) do
    with {:ok, value} <- AtomicJson.read(path),
         {:ok, event} <- Event.from_map(value),
         {:ok, expected_path} <- StoragePath.event(event.id),
         true <- expected_path == path do
      {:ok, event}
    else
      _invalid ->
        Logger.warning("Ignoring malformed management event file: #{path}")
        :error
    end
  end

  defp events_directory do
    with {:ok, root} <- StoragePath.root() do
      {:ok, Path.join(root, "events")}
    end
  end

  defp max_events do
    case Application.get_env(:yellow_dog_management_core, :max_events, @default_max_events) do
      limit when is_integer(limit) and limit in 1..@max_events_bound -> limit
      _invalid -> @default_max_events
    end
  end

  defp event_write_timeout_ms do
    case Application.get_env(
           :yellow_dog_management_core,
           :event_write_timeout_ms,
           @default_event_write_timeout_ms
         ) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _invalid -> @default_event_write_timeout_ms
    end
  end

  defp transport_margin_ms,
    do: max(div(event_write_timeout_ms(), @transport_margin_divisor), 1)

  defp deadline_expired?(deadline), do: deadline <= monotonic_ms()
  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp conflict_error,
    do: Error.new(:conflict, "event sequence allocation exhausted", %{})

  defp timeout_error,
    do: Error.new(:timeout, "management event persistence timed out", %{})

  defp internal_error,
    do: Error.new(:internal, "event sequence allocation exhausted", %{})
end
