defmodule YellowDog.Dns.SpanManager do
  @moduledoc """
  Manages active TSI (Telemetry Span Items) for in-flight DNS requests.

  The SpanManager provides:
  - Registration of new requests
  - Completion tracking
  - Timeout handling for stale requests
  - Statistics for monitoring

  All active TSIs are stored in an ETS table for fast lookup.
  """

  use GenServer

  alias YellowDog.Dns.TSI
  alias YellowDog.Telemetry

  @table_name :dns_span_manager
  @cleanup_interval :timer.seconds(30)
  @default_timeout :timer.seconds(30)

  # Client API

  @doc """
  Starts the SpanManager.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Registers a new TSI for tracking.

  Returns the TSI with any additional metadata added.
  """
  @spec register(TSI.t()) :: TSI.t()
  def register(%TSI{} = tsi) do
    register(__MODULE__, tsi)
  end

  @spec register(GenServer.server(), TSI.t()) :: TSI.t()
  def register(server, %TSI{} = tsi) do
    GenServer.call(server, {:register, tsi})
  end

  @doc """
  Marks a TSI as complete.

  Returns the completed TSI.
  """
  @spec complete(TSI.t()) :: TSI.t()
  def complete(%TSI{} = tsi) do
    complete(__MODULE__, tsi)
  end

  @spec complete(GenServer.server(), TSI.t()) :: TSI.t()
  def complete(server, %TSI{} = tsi) do
    GenServer.call(server, {:complete, tsi})
  end

  @doc """
  Gets a TSI by its ID.
  """
  @spec get(binary()) :: TSI.t() | nil
  def get(tsi_id) do
    get(__MODULE__, tsi_id)
  end

  @spec get(GenServer.server(), binary()) :: TSI.t() | nil
  def get(_server, tsi_id) do
    case :ets.lookup(@table_name, tsi_id) do
      [{^tsi_id, tsi}] -> tsi
      [] -> nil
    end
  end

  @doc """
  Returns statistics about active spans.
  """
  @spec stats() :: map()
  def stats do
    stats(__MODULE__)
  end

  @spec stats(GenServer.server()) :: map()
  def stats(server) do
    GenServer.call(server, :stats)
  end

  @doc """
  Returns all active TSIs (for debugging/monitoring).
  """
  @spec list_active() :: [TSI.t()]
  def list_active do
    :ets.tab2list(@table_name)
    |> Enum.map(fn {_id, tsi} -> tsi end)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    # Create ETS table for fast TSI lookup
    table =
      :ets.new(@table_name, [
        :named_table,
        :set,
        :public,
        read_concurrency: true
      ])

    timeout = Keyword.get(opts, :request_timeout, @default_timeout)

    # Schedule periodic cleanup
    schedule_cleanup()

    Telemetry.info("SpanManager started", %{table: table, timeout: timeout})

    {:ok,
     %{
       table: table,
       timeout: timeout,
       registered_count: 0,
       completed_count: 0,
       timeout_count: 0
     }}
  end

  @impl true
  def handle_call({:register, tsi}, _from, state) do
    # Insert TSI into ETS
    :ets.insert(@table_name, {tsi.id, tsi})

    # Emit telemetry
    Telemetry.debug("DNS request registered", TSI.to_telemetry_metadata(tsi))

    new_state = %{state | registered_count: state.registered_count + 1}
    {:reply, tsi, new_state}
  end

  @impl true
  def handle_call({:complete, tsi}, _from, state) do
    # Remove from active tracking
    :ets.delete(@table_name, tsi.id)

    # Emit telemetry with timing
    metadata = TSI.to_telemetry_metadata(tsi)

    Telemetry.span("dns.request", metadata, fn ->
      {:ok, metadata}
    end)

    Telemetry.debug("DNS request completed", metadata)

    new_state = %{state | completed_count: state.completed_count + 1}
    {:reply, tsi, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    active_count = :ets.info(@table_name, :size)

    stats = %{
      active: active_count,
      registered: state.registered_count,
      completed: state.completed_count,
      timed_out: state.timeout_count
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.monotonic_time(:microsecond)
    timeout_us = state.timeout * 1000

    # Find and remove timed out requests
    timed_out =
      :ets.foldl(
        fn {id, tsi}, acc ->
          elapsed = now - tsi.received_at

          if elapsed > timeout_us do
            :ets.delete(@table_name, id)

            Telemetry.warning("DNS request timed out", %{
              tsi_id: id,
              elapsed_ms: elapsed / 1000
            })

            acc + 1
          else
            acc
          end
        end,
        0,
        @table_name
      )

    # Schedule next cleanup
    schedule_cleanup()

    new_state = %{state | timeout_count: state.timeout_count + timed_out}
    {:noreply, new_state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
