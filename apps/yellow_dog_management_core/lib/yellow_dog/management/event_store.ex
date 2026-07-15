defmodule YellowDog.Management.EventStore do
  @moduledoc false

  use GenServer

  require Logger

  alias YellowDog.Management.Event
  alias YellowDog.Management.Storage.AtomicJson
  alias YellowDog.Management.Storage.Path, as: StoragePath
  alias YellowDog.Sync.Error

  @default_max_events 500
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
  def append(attrs), do: GenServer.call(__MODULE__, {:append, attrs})

  @doc false
  def list, do: GenServer.call(__MODULE__, :list)

  @impl true
  def init(:ok), do: {:ok, next_sequence()}

  @impl true
  def handle_call({:append, attrs}, _from, sequence) do
    case append_event(attrs, sequence, @max_collision_attempts) do
      {:ok, event, next_sequence} -> {:reply, {:ok, event}, next_sequence}
      {:error, error, next_sequence} -> {:reply, {:error, error}, next_sequence}
    end
  end

  def handle_call(:list, _from, sequence) do
    {:reply, read_events(max_events()), sequence}
  end

  defp append_event(_attrs, sequence, _remaining) when sequence > @max_sequence do
    {:error, internal_error(), sequence}
  end

  defp append_event(_attrs, sequence, 0) do
    {:error, conflict_error(), sequence}
  end

  defp append_event(attrs, sequence, remaining) do
    event = Event.new(attrs, sequence)

    with {:ok, path} <- StoragePath.event(event.id) do
      case AtomicJson.create(path, Event.to_map(event)) do
        {:ok, _path} ->
          {:ok, event, sequence + 1}

        {:error, %Error{code: :conflict}} ->
          append_event(attrs, sequence + 1, remaining - 1)

        {:error, %Error{} = error} ->
          {:error, error, sequence}
      end
    else
      {:error, %Error{} = error} -> {:error, error, sequence}
    end
  end

  defp read_events(limit) do
    with {:ok, directory} <- events_directory() do
      directory
      |> collect_valid_events(limit, @max_sequence + 1, [])
      |> Enum.sort_by(&{&1.sequence, &1.occurred_at, &1.id})
    else
      _error -> []
    end
  end

  defp collect_valid_events(_directory, limit, _before_sequence, events)
       when length(events) >= limit,
       do: Enum.take(events, limit)

  defp collect_valid_events(directory, limit, before_sequence, events) do
    remaining = limit - length(events)
    candidates = select_candidates(directory, remaining, before_sequence)

    case candidates do
      [] ->
        events

      _candidates ->
        events =
          Enum.reduce_while(candidates, events, fn {_sequence, path}, acc ->
            if length(acc) >= limit do
              {:halt, acc}
            else
              case read_event(path) do
                {:ok, event} -> {:cont, [event | acc]}
                :error -> {:cont, acc}
              end
            end
          end)

        {oldest_sequence, _path} = List.last(candidates)
        collect_valid_events(directory, limit, oldest_sequence, events)
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

  defp conflict_error,
    do: Error.new(:conflict, "event sequence allocation exhausted", %{})

  defp internal_error,
    do: Error.new(:internal, "event sequence allocation exhausted", %{})
end
