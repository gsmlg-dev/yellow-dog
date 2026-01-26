defmodule YellowDog.Mdns.RateLimiter do
  @moduledoc """
  Token bucket rate limiter for mDNS requests.

  Provides protection against:
  - Single source flooding (per-source rate limiting)
  - Network congestion (global rate limiting)
  - mDNS amplification attacks

  Uses a token bucket algorithm with configurable:
  - Tokens per source (bucket capacity)
  - Token refill rate (tokens per second)
  - Global request limit

  mDNS rate limiting is less aggressive than DNS since:
  - It operates only on the local network
  - Multicast nature means responses go to all hosts
  - Legitimate usage can be bursty (service announcements)

  ## Configuration

      config :yellow_dog_mdns, YellowDog.Mdns.RateLimiter,
        enabled: true,
        # Per-source limits
        client_tokens: 100,          # Max burst per source
        client_refill_rate: 50,      # Tokens per second per source
        # Global limits
        global_tokens: 10000,        # Max global burst
        global_refill_rate: 5000,    # Global tokens per second
        # Cleanup
        bucket_ttl: 300_000,         # 5 minutes - cleanup inactive buckets
        cleanup_interval: 60_000     # 1 minute - run cleanup

  ## Usage

      # In handler, before processing request:
      case RateLimiter.check_rate(source_ip) do
        :ok -> process_message(...)
        {:error, :rate_limited} -> drop_message()
      end
  """

  use GenServer

  require Logger

  # mDNS has higher burst requirements - local network only
  @default_config %{
    enabled: true,
    client_tokens: 100,
    client_refill_rate: 50,
    global_tokens: 10000,
    global_refill_rate: 5000,
    bucket_ttl: 300_000,
    cleanup_interval: 60_000
  }

  # Client API

  @doc """
  Starts the RateLimiter GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Checks if a message from the given source should be allowed.

  ## Parameters
  - `source_id` - Source identifier (typically IP address)

  ## Returns
  - `:ok` - Request allowed
  - `{:error, :rate_limited}` - Message should be dropped
  """
  @spec check_rate(binary() | tuple()) :: :ok | {:error, :rate_limited}
  def check_rate(source_id) do
    GenServer.call(__MODULE__, {:check_rate, source_id})
  catch
    :exit, {:noproc, _} ->
      # Rate limiter not running, allow all requests
      :ok
  end

  @doc """
  Gets current rate limiter statistics.

  ## Returns
  - Map with statistics including:
    - `total_allowed` - Total allowed requests
    - `total_denied` - Total denied requests
    - `active_buckets` - Number of active source buckets
    - `global_tokens` - Current global token count
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  catch
    :exit, {:noproc, _} ->
      %{error: :not_running}
  end

  @doc """
  Resets all rate limit buckets.

  Useful for testing or after configuration changes.
  """
  @spec reset() :: :ok
  def reset do
    GenServer.call(__MODULE__, :reset)
  catch
    :exit, {:noproc, _} ->
      :ok
  end

  @doc """
  Checks if rate limiting is enabled.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    GenServer.call(__MODULE__, :enabled?)
  catch
    :exit, {:noproc, _} ->
      false
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    config = load_config(opts)

    # Create ETS table for source buckets
    :ets.new(:mdns_rate_buckets, [:named_table, :public, read_concurrency: true])

    # Schedule periodic cleanup
    if config.enabled do
      schedule_cleanup(config.cleanup_interval)
    end

    now = System.monotonic_time(:millisecond)

    state = %{
      config: config,
      global_tokens: config.global_tokens,
      global_last_update: now,
      total_allowed: 0,
      total_denied: 0
    }

    :telemetry.execute(
      [:yellow_dog, :mdns, :rate_limiter, :started],
      %{count: 1},
      %{enabled: config.enabled}
    )

    {:ok, state}
  end

  @impl true
  def handle_call({:check_rate, _source_id}, _from, %{config: %{enabled: false}} = state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:check_rate, source_id}, _from, state) do
    now = System.monotonic_time(:millisecond)

    # Check global rate limit first
    {global_allowed, new_global_tokens, new_global_time} =
      check_global_limit(state, now)

    if not global_allowed do
      :telemetry.execute(
        [:yellow_dog, :mdns, :rate_limiter, :denied],
        %{count: 1},
        %{reason: :global_limit, source_id: normalize_source_id(source_id)}
      )

      new_state = %{
        state
        | global_tokens: new_global_tokens,
          global_last_update: new_global_time,
          total_denied: state.total_denied + 1
      }

      {:reply, {:error, :rate_limited}, new_state}
    else
      # Check per-source rate limit
      source_key = normalize_source_id(source_id)
      {source_allowed, _tokens} = check_source_limit(source_key, state.config, now)

      if source_allowed do
        new_state = %{
          state
          | global_tokens: new_global_tokens - 1,
            global_last_update: new_global_time,
            total_allowed: state.total_allowed + 1
        }

        {:reply, :ok, new_state}
      else
        :telemetry.execute(
          [:yellow_dog, :mdns, :rate_limiter, :denied],
          %{count: 1},
          %{reason: :source_limit, source_id: source_key}
        )

        new_state = %{
          state
          | global_tokens: new_global_tokens,
            global_last_update: new_global_time,
            total_denied: state.total_denied + 1
        }

        {:reply, {:error, :rate_limited}, new_state}
      end
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    bucket_count = :ets.info(:mdns_rate_buckets, :size)

    stats = %{
      enabled: state.config.enabled,
      total_allowed: state.total_allowed,
      total_denied: state.total_denied,
      active_buckets: bucket_count,
      global_tokens: state.global_tokens,
      config: %{
        client_tokens: state.config.client_tokens,
        client_refill_rate: state.config.client_refill_rate,
        global_tokens: state.config.global_tokens,
        global_refill_rate: state.config.global_refill_rate
      }
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(:mdns_rate_buckets)

    new_state = %{
      state
      | global_tokens: state.config.global_tokens,
        global_last_update: System.monotonic_time(:millisecond),
        total_allowed: 0,
        total_denied: 0
    }

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:enabled?, _from, state) do
    {:reply, state.config.enabled, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired_buckets(state.config.bucket_ttl)
    schedule_cleanup(state.config.cleanup_interval)
    {:noreply, state}
  end

  # Private functions

  defp load_config(opts) do
    app_config = Application.get_env(:yellow_dog_mdns, __MODULE__, [])

    merged =
      @default_config
      |> Map.merge(Enum.into(app_config, %{}))
      |> Map.merge(Enum.into(opts, %{}))

    merged
  end

  defp check_global_limit(state, now) do
    elapsed_ms = now - state.global_last_update
    refill_tokens = div(elapsed_ms * state.config.global_refill_rate, 1000)

    new_tokens =
      min(state.global_tokens + refill_tokens, state.config.global_tokens)

    if new_tokens >= 1 do
      {true, new_tokens, now}
    else
      {false, new_tokens, now}
    end
  end

  defp check_source_limit(source_key, config, now) do
    case :ets.lookup(:mdns_rate_buckets, source_key) do
      [] ->
        # New source, create bucket with one token consumed
        initial_tokens = config.client_tokens - 1
        :ets.insert(:mdns_rate_buckets, {source_key, initial_tokens, now})
        {true, initial_tokens}

      [{^source_key, tokens, last_update}] ->
        # Existing source, refill tokens based on time elapsed
        elapsed_ms = now - last_update
        refill_tokens = div(elapsed_ms * config.client_refill_rate, 1000)

        current_tokens = min(tokens + refill_tokens, config.client_tokens)

        if current_tokens >= 1 do
          new_tokens = current_tokens - 1
          :ets.insert(:mdns_rate_buckets, {source_key, new_tokens, now})
          {true, new_tokens}
        else
          # Update last_update for accurate refill calculation
          :ets.insert(:mdns_rate_buckets, {source_key, current_tokens, now})
          {false, current_tokens}
        end
    end
  end

  defp cleanup_expired_buckets(ttl) do
    now = System.monotonic_time(:millisecond)
    cutoff = now - ttl

    # Find and delete expired buckets
    expired =
      :ets.foldl(
        fn {key, _tokens, last_update}, acc ->
          if last_update < cutoff do
            [key | acc]
          else
            acc
          end
        end,
        [],
        :mdns_rate_buckets
      )

    Enum.each(expired, &:ets.delete(:mdns_rate_buckets, &1))

    if length(expired) > 0 do
      :telemetry.execute(
        [:yellow_dog, :mdns, :rate_limiter, :cleanup],
        %{count: length(expired)},
        %{}
      )
    end
  end

  defp schedule_cleanup(interval) do
    Process.send_after(self(), :cleanup, interval)
  end

  # Normalize source identifier to a consistent format
  defp normalize_source_id(id) when is_binary(id), do: id

  # IPv4 address tuple
  defp normalize_source_id({a, b, c, d}) when is_integer(a) and a <= 255 do
    <<a, b, c, d>>
  end

  # IPv6 address tuple
  defp normalize_source_id({a, b, c, d, e, f, g, h}) when is_integer(a) do
    <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>
  end

  defp normalize_source_id(other), do: inspect(other)
end
