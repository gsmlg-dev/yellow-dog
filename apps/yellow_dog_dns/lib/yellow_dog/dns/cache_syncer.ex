defmodule YellowDog.Dns.CacheSyncer do
  @moduledoc """
  Periodic process that synchronizes the DNS cache between local ETS and Concord.

  Responsibilities:
  - **Startup:** Warms local ETS cache from Concord via `Store.Cache.warm_from_store/0`.
  - **Periodic flush:** Writes recent ETS entries to Concord via `Store.Cache.flush_to_store/0`.
    Batch size adapts to Raft latency automatically (handled by Cache module).
  - **Not on the query path.** Must never block DNS resolution.
  """

  use GenServer

  require Logger

  @default_flush_interval_ms 30_000
  @default_warm_on_start true

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    flush_interval = Keyword.get(opts, :flush_interval_ms, @default_flush_interval_ms)
    warm_on_start = Keyword.get(opts, :warm_on_start, @default_warm_on_start)

    if warm_on_start do
      warm_cache()
    end

    schedule_flush(flush_interval)

    {:ok, %{flush_interval: flush_interval}}
  end

  @impl true
  def handle_info(:flush, state) do
    flush_cache()
    schedule_flush(state.flush_interval)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp warm_cache do
    try do
      YellowDog.Store.Cache.warm_from_store()
    rescue
      e ->
        Logger.warning("CacheSyncer: warm_from_store failed: #{inspect(e)}")
    end
  end

  defp flush_cache do
    try do
      YellowDog.Store.Cache.flush_to_store()
    rescue
      e ->
        Logger.warning("CacheSyncer: flush_to_store failed: #{inspect(e)}")
    end
  end

  defp schedule_flush(interval) do
    Process.send_after(self(), :flush, interval)
  end
end
