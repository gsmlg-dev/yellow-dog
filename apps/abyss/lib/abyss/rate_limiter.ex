defmodule Abyss.RateLimiter do
  @moduledoc """
  Rate limiting functionality for DoS protection

  Implements a token bucket algorithm for rate limiting incoming packets
  based on source IP addresses.
  """

  use GenServer

  @typedoc """
  Token bucket state for rate limiting a single IP address.
  """
  @type bucket :: %{
          tokens: non_neg_integer(),
          last_refill: integer(),
          max_tokens: pos_integer(),
          refill_rate: pos_integer()
        }

  @typedoc """
  Internal state of the rate limiter GenServer.
  """
  @type state :: %{
          buckets: %{:inet.ip_address() => bucket()},
          max_packets: pos_integer(),
          window_ms: pos_integer(),
          enabled: boolean()
        }

  defstruct buckets: %{},
            max_packets: 1000,
            window_ms: 1000,
            enabled: false

  @doc """
  Start the rate limiter with the given options.

  Each Abyss server instance should have its own rate limiter.
  The rate limiter is NOT registered with a global name to allow
  multiple server instances to run concurrently.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Check if a packet from the given IP should be allowed based on rate limits.

  ## Parameters
  - `rate_limiter` - PID of the rate limiter process
  - `ip` - Source IP address tuple

  ## Returns
  - `true` if the packet should be allowed
  - `false` if rate limit exceeded
  """
  @spec allow_packet?(pid(), :inet.ip_address()) :: boolean()
  def allow_packet?(rate_limiter, ip) when is_pid(rate_limiter) and is_tuple(ip) do
    GenServer.call(rate_limiter, {:allow_packet?, ip})
  end

  @doc """
  Update rate limiting configuration.
  """
  @spec update_config(pid(), keyword()) :: :ok
  def update_config(rate_limiter, _opts) when is_pid(rate_limiter) do
    GenServer.call(rate_limiter, :update_config, :infinity)
  end

  @doc """
  Get current statistics.
  """
  @spec get_stats(pid()) :: map()
  def get_stats(rate_limiter) when is_pid(rate_limiter) do
    GenServer.call(rate_limiter, :get_stats)
  end

  @impl GenServer
  def init(opts) do
    enabled = Keyword.get(opts, :enabled, false)
    max_packets = Keyword.get(opts, :max_packets, 1000)
    window_ms = Keyword.get(opts, :window_ms, 1000)

    # Schedule periodic cleanup of old buckets
    Process.send_after(self(), :cleanup_buckets, :timer.minutes(5))

    state = %__MODULE__{
      enabled: enabled,
      max_packets: max_packets,
      window_ms: window_ms
    }

    :telemetry.execute(
      [:abyss, :rate_limiter, :start],
      %{count: 1},
      %{source: __MODULE__, enabled: enabled, max_packets: max_packets, window_ms: window_ms}
    )

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:allow_packet?, ip}, _from, state) do
    if not state.enabled do
      {:reply, true, state}
    else
      {allowed, new_state} = check_rate_limit(ip, state)
      {:reply, allowed, new_state}
    end
  end

  def handle_call(:update_config, _from, state) do
    {:reply, :ok, state}
  end

  def handle_call(:get_stats, _from, state) do
    stats = %{
      enabled: state.enabled,
      max_packets: state.max_packets,
      window_ms: state.window_ms,
      active_buckets: map_size(state.buckets),
      total_buckets: Enum.count(state.buckets)
    }

    {:reply, stats, state}
  end

  @impl GenServer
  def handle_info(:cleanup_buckets, state) do
    now = System.monotonic_time(:millisecond)
    cleanup_threshold = state.window_ms * 10

    cleaned_buckets =
      state.buckets
      |> Enum.filter(fn {_ip, bucket} ->
        now - bucket.last_refill < cleanup_threshold
      end)
      |> Map.new()

    cleaned_count = map_size(state.buckets) - map_size(cleaned_buckets)

    if cleaned_count > 0 do
      :telemetry.execute(
        [:abyss, :rate_limiter, :cleanup],
        %{count: cleaned_count},
        %{source: __MODULE__}
      )
    end

    # Schedule next cleanup
    Process.send_after(self(), :cleanup_buckets, :timer.minutes(5))

    {:noreply, %{state | buckets: cleaned_buckets}}
  end

  # Private helper functions

  defp check_rate_limit(ip, state) do
    now = System.monotonic_time(:millisecond)

    case Map.get(state.buckets, ip) do
      nil ->
        # First packet from this IP, create new bucket
        bucket = %{
          tokens: state.max_packets - 1,
          last_refill: now,
          max_tokens: state.max_packets,
          refill_rate: div(state.max_packets * 1000, state.window_ms)
        }

        new_state = %{state | buckets: Map.put(state.buckets, ip, bucket)}
        {true, new_state}

      bucket ->
        # Existing bucket, check and refill tokens
        new_bucket = refill_bucket(bucket, now, state.max_packets, state.window_ms)

        if new_bucket.tokens > 0 do
          # Packet allowed, consume one token
          updated_bucket = %{new_bucket | tokens: new_bucket.tokens - 1}
          updated_state = %{state | buckets: Map.put(state.buckets, ip, updated_bucket)}
          {true, updated_state}
        else
          # Rate limit exceeded
          updated_state = %{state | buckets: Map.put(state.buckets, ip, new_bucket)}
          {false, updated_state}
        end
    end
  end

  defp refill_bucket(bucket, now, max_packets, window_ms) do
    time_passed = now - bucket.last_refill

    if time_passed >= window_ms do
      # Full refill
      %{
        bucket
        | # Assume this packet will consume one
          tokens: max_packets - 1,
          last_refill: now
      }
    else
      if time_passed > 0 do
        # Partial refill based on time passed
        refill_rate = div(max_packets * 1000, window_ms)
        tokens_to_add = div(time_passed * refill_rate, 1000)
        new_tokens = min(bucket.tokens + tokens_to_add, max_packets)

        %{bucket | tokens: new_tokens, last_refill: now}
      else
        # No time passed, use existing bucket
        bucket
      end
    end
  end
end
