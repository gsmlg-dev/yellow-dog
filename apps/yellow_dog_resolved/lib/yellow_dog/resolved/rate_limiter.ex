defmodule YellowDog.Resolved.RateLimiter do
  @moduledoc """
  Per-source-IP token bucket rate limiter for DNS queries.
  Uses ETS for lock-free concurrent access from handler processes.
  Periodically sweeps stale entries to bound memory usage.
  """
  use GenServer

  @table :resolved_rate_limiter
  @sweep_interval_ms 30_000
  @stale_threshold_s 120

  # Defaults: 50 queries/sec burst, 20 queries/sec sustained
  @default_burst 50
  @default_rate 20

  # Client API

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc """
  Check if a request from the given IP is allowed.
  Returns :ok if allowed, :rate_limited if the bucket is empty.
  """
  @spec allow?(:inet.ip_address()) :: :ok | :rate_limited
  def allow?(client_ip) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, client_ip) do
      [{^client_ip, tokens, last_refill}] ->
        refill_and_check(client_ip, tokens, last_refill, now)

      [] ->
        # First request from this IP — initialize bucket (consume one token)
        :ets.insert(@table, {client_ip, burst() - 1, now})
        :ok
    end
  end

  @doc """
  Returns the number of tracked IPs in the rate limiter table.
  """
  @spec tracked_ips() :: non_neg_integer()
  def tracked_ips do
    :ets.info(@table, :size)
  end

  # Server callbacks

  @impl true
  def init(config) do
    rate_config = Map.get(config, :rate_limit, %{})

    :ets.new(@table, [:named_table, :set, :public, write_concurrency: true])

    :persistent_term.put({__MODULE__, :burst}, Map.get(rate_config, :burst, @default_burst))
    :persistent_term.put({__MODULE__, :rate}, Map.get(rate_config, :rate, @default_rate))

    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:update_config, config}, state) do
    rate_config = Map.get(config, :rate_limit, %{})
    :persistent_term.put({__MODULE__, :burst}, Map.get(rate_config, :burst, @default_burst))
    :persistent_term.put({__MODULE__, :rate}, Map.get(rate_config, :rate, @default_rate))
    {:noreply, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep_stale()
    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state) do
    :persistent_term.erase({__MODULE__, :burst})
    :persistent_term.erase({__MODULE__, :rate})
    :ok
  end

  # Private

  # Note: the ETS read-then-write here is intentionally non-atomic. Concurrent
  # handler processes may slightly over-allow during bursts (two processes read
  # the same token count, both consume). This is acceptable for a DNS rate limiter
  # where throughput matters more than strict per-token accounting.
  defp refill_and_check(client_ip, tokens, last_refill, now) do
    elapsed_ms = now - last_refill
    refilled = tokens + elapsed_ms * rate() / 1000

    capped = min(refilled, burst() / 1.0)

    if capped >= 1.0 do
      :ets.insert(@table, {client_ip, capped - 1.0, now})
      :ok
    else
      :ets.insert(@table, {client_ip, capped, now})
      :rate_limited
    end
  end

  defp sweep_stale do
    now = System.monotonic_time(:millisecond)
    threshold = now - @stale_threshold_s * 1000

    # Use select_delete instead of foldl+delete — deleting during foldl traversal
    # is undefined behaviour per Erlang docs (foldl iterates via first/next).
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", threshold}], [true]}])
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp burst, do: :persistent_term.get({__MODULE__, :burst})
  defp rate, do: :persistent_term.get({__MODULE__, :rate})
end
