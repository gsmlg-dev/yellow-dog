defmodule YellowDog.Resolved.QueryLogger do
  @moduledoc """
  In-memory circular buffer for recent DNS query logs.

  Attaches to resolved telemetry events and stores the last N queries
  for inspection via the console or API.
  """

  use GenServer

  @default_buffer_size 200
  @telemetry_id {__MODULE__, :query_events}

  # -- Public API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the most recent `limit` query log entries (newest first)."
  def recent(limit \\ 50) do
    GenServer.call(__MODULE__, {:recent, limit})
  end

  @doc "Clears the query log buffer."
  def clear do
    GenServer.cast(__MODULE__, :clear)
  end

  # -- Callbacks --

  @impl true
  def init(opts) do
    buffer_size = Keyword.get(opts, :buffer_size, @default_buffer_size)

    :telemetry.detach(@telemetry_id)

    :telemetry.attach_many(
      @telemetry_id,
      [
        [:yellow_dog, :resolved, :query, :stop],
        [:yellow_dog, :resolved, :query, :exception]
      ],
      &__MODULE__.handle_event/4,
      %{pid: self()}
    )

    {:ok, %{buffer: :queue.new(), size: 0, max: buffer_size}}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach(@telemetry_id)
    :ok
  end

  @impl true
  def handle_call({:recent, limit}, _from, state) do
    entries =
      state.buffer
      |> :queue.to_list()
      |> Enum.reverse()
      |> Enum.take(limit)

    {:reply, entries, state}
  end

  @impl true
  def handle_cast(:clear, state) do
    {:noreply, %{state | buffer: :queue.new(), size: 0}}
  end

  @impl true
  def handle_cast({:log, entry}, state) do
    {buffer, size} =
      if state.size >= state.max do
        {_, q} = :queue.out(state.buffer)
        {:queue.in(entry, q), state.max}
      else
        {:queue.in(entry, state.buffer), state.size + 1}
      end

    {:noreply, %{state | buffer: buffer, size: size}}
  end

  # -- Telemetry handler (runs in the caller's process) --

  def handle_event([:yellow_dog, :resolved, :query, :stop], measurements, metadata, config) do
    entry = %{
      timestamp: DateTime.utc_now(),
      domain: metadata.domain,
      type: metadata.type,
      source: metadata.source,
      duration_us: System.convert_time_unit(measurements.duration, :native, :microsecond)
    }

    GenServer.cast(config.pid, {:log, entry})
  end

  def handle_event([:yellow_dog, :resolved, :query, :exception], measurements, metadata, config) do
    entry = %{
      timestamp: DateTime.utc_now(),
      domain: metadata.domain,
      type: metadata.type,
      source: :error,
      duration_us: System.convert_time_unit(measurements.duration, :native, :microsecond),
      error: metadata[:reason]
    }

    GenServer.cast(config.pid, {:log, entry})
  end
end
