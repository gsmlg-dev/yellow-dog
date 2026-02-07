defmodule YellowDog.Dhcpv4.RateLimiter do
  @moduledoc """
  Token bucket rate limiter for DHCPv4 requests.

  Provides protection against:
  - Single client flooding (per-client rate limiting)
  - Pool exhaustion attacks (global rate limiting)
  - DoS attacks from spoofed MACs

  Uses a token bucket algorithm with configurable:
  - Tokens per client (bucket capacity)
  - Token refill rate (tokens per second)
  - Global request limit

  ## Configuration

      config :yellow_dog_dhcpv4, YellowDog.Dhcpv4.RateLimiter,
        enabled: true,
        # Per-client limits
        client_tokens: 10,           # Max burst per client
        client_refill_rate: 2,       # Tokens per second per client
        # Global limits
        global_tokens: 1000,         # Max global burst
        global_refill_rate: 100,     # Global tokens per second
        # Cleanup
        bucket_ttl: 300_000,         # 5 minutes - cleanup inactive buckets
        cleanup_interval: 60_000     # 1 minute - run cleanup

  ## Usage

      # In handler, before processing request:
      case RateLimiter.check_rate(client_identifier) do
        :ok -> process_request(...)
        {:error, :rate_limited} -> drop_request()
      end
  """

  use GenServer

  require Logger

  @default_config %{
    enabled: true,
    client_tokens: 10,
    client_refill_rate: 2,
    global_tokens: 1000,
    global_refill_rate: 100,
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
  Checks if a request from the given client should be allowed.

  ## Parameters
  - `client_id` - Client identifier (typically MAC address or IP)

  ## Returns
  - `:ok` - Request allowed
  - `{:error, :rate_limited}` - Request should be dropped
  - `{:error, :disabled}` - Rate limiting is disabled, always allow
  """
  @spec check_rate(binary() | tuple()) :: :ok | {:error, :rate_limited | :disabled}
  def check_rate(client_id) do
    GenServer.call(__MODULE__, {:check_rate, client_id})
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
    - `active_buckets` - Number of active client buckets
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

    # Create ETS table for client buckets
    :ets.new(:dhcpv4_rate_buckets, [:named_table, :public, read_concurrency: true])

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
      [:yellow_dog, :dhcpv4, :rate_limiter, :started],
      %{count: 1},
      %{enabled: config.enabled}
    )

    {:ok, state}
  end

  @impl true
  def handle_call({:check_rate, _client_id}, _from, %{config: %{enabled: false}} = state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:check_rate, client_id}, _from, state) do
    now = System.monotonic_time(:millisecond)

    # Check global rate limit first
    {global_allowed, new_global_tokens, new_global_time} =
      check_global_limit(state, now)

    if not global_allowed do
      :telemetry.execute(
        [:yellow_dog, :dhcpv4, :rate_limiter, :denied],
        %{count: 1},
        %{reason: :global_limit, client_id: normalize_client_id(client_id)}
      )

      new_state = %{
        state
        | global_tokens: new_global_tokens,
          global_last_update: new_global_time,
          total_denied: state.total_denied + 1
      }

      {:reply, {:error, :rate_limited}, new_state}
    else
      # Check per-client rate limit
      client_key = normalize_client_id(client_id)
      {client_allowed, _tokens} = check_client_limit(client_key, state.config, now)

      if client_allowed do
        new_state = %{
          state
          | global_tokens: new_global_tokens - 1,
            global_last_update: new_global_time,
            total_allowed: state.total_allowed + 1
        }

        {:reply, :ok, new_state}
      else
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :rate_limiter, :denied],
          %{count: 1},
          %{reason: :client_limit, client_id: client_key}
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
    bucket_count = :ets.info(:dhcpv4_rate_buckets, :size)

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
    :ets.delete_all_objects(:dhcpv4_rate_buckets)

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

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private functions

  defp load_config(opts) do
    app_config = Application.get_env(:yellow_dog_dhcpv4, __MODULE__, [])

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

  defp check_client_limit(client_key, config, now) do
    case :ets.lookup(:dhcpv4_rate_buckets, client_key) do
      [] ->
        # New client, create bucket with one token consumed
        initial_tokens = config.client_tokens - 1
        :ets.insert(:dhcpv4_rate_buckets, {client_key, initial_tokens, now})
        {true, initial_tokens}

      [{^client_key, tokens, last_update}] ->
        # Existing client, refill tokens based on time elapsed
        elapsed_ms = now - last_update
        refill_tokens = div(elapsed_ms * config.client_refill_rate, 1000)

        current_tokens = min(tokens + refill_tokens, config.client_tokens)

        if current_tokens >= 1 do
          new_tokens = current_tokens - 1
          :ets.insert(:dhcpv4_rate_buckets, {client_key, new_tokens, now})
          {true, new_tokens}
        else
          # Update last_update for accurate refill calculation
          :ets.insert(:dhcpv4_rate_buckets, {client_key, current_tokens, now})
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
        :dhcpv4_rate_buckets
      )

    Enum.each(expired, &:ets.delete(:dhcpv4_rate_buckets, &1))

    if length(expired) > 0 do
      :telemetry.execute(
        [:yellow_dog, :dhcpv4, :rate_limiter, :cleanup],
        %{count: length(expired)},
        %{}
      )
    end
  end

  defp schedule_cleanup(interval) do
    Process.send_after(self(), :cleanup, interval)
  end

  # Normalize client identifier to a consistent format
  defp normalize_client_id(id) when is_binary(id), do: id

  defp normalize_client_id({a, b, c, d}) when is_integer(a) do
    <<a, b, c, d>>
  end

  defp normalize_client_id(other), do: inspect(other)
end
