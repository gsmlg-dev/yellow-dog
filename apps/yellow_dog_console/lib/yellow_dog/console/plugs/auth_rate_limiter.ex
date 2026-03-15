defmodule YellowDog.Console.Plugs.AuthRateLimiter do
  @moduledoc """
  Rate limiter for authentication attempts to prevent brute-force attacks.

  Uses an ETS table to track failed login attempts per IP address with
  configurable thresholds and lockout periods.

  ## Configuration

      config :yellow_dog_console, YellowDog.Console.Plugs.AuthRateLimiter,
        max_attempts: 5,           # Max failed attempts before lockout
        lockout_seconds: 300,      # Lockout duration (5 minutes)
        cleanup_interval_ms: 60000 # Cleanup interval for expired entries

  ## Behavior

  - After `max_attempts` failed authentication attempts from an IP, further
    attempts are blocked for `lockout_seconds`
  - Successful authentication resets the failure counter
  - Expired entries are periodically cleaned up to prevent memory growth
  """

  use GenServer
  require Logger

  @table_name :auth_rate_limiter
  @default_max_attempts 5
  @default_lockout_seconds 300
  @default_cleanup_interval_ms 60_000

  # Client API

  @doc """
  Starts the rate limiter GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Checks if an IP address is currently locked out due to too many failed attempts.

  Returns:
  - `{:ok, attempts_remaining}` - IP is allowed, with number of remaining attempts
  - `{:error, :locked_out, seconds_remaining}` - IP is locked out
  """
  @spec check_rate_limit(String.t()) ::
          {:ok, non_neg_integer()} | {:error, :locked_out, non_neg_integer()}
  def check_rate_limit(ip) when is_binary(ip) do
    case :ets.lookup(@table_name, ip) do
      [] ->
        {:ok, max_attempts()}

      [{^ip, attempts, lockout_until}] ->
        now = System.system_time(:second)

        cond do
          # Lockout has expired
          lockout_until != nil and now >= lockout_until ->
            :ets.delete(@table_name, ip)
            {:ok, max_attempts()}

          # Currently locked out
          lockout_until != nil ->
            {:error, :locked_out, lockout_until - now}

          # Under the limit
          attempts < max_attempts() ->
            {:ok, max_attempts() - attempts}

          # At or over limit (shouldn't happen, but handle gracefully)
          true ->
            {:error, :locked_out, lockout_seconds()}
        end
    end
  rescue
    ArgumentError ->
      # ETS table doesn't exist (rate limiter not started)
      {:ok, max_attempts()}
  end

  @doc """
  Records a failed authentication attempt from an IP address.

  If this pushes the IP over the limit, initiates a lockout.
  """
  @spec record_failure(String.t()) :: :ok
  def record_failure(ip) when is_binary(ip) do
    now = System.system_time(:second)

    case :ets.lookup(@table_name, ip) do
      [] ->
        :ets.insert(@table_name, {ip, 1, nil})

        Logger.debug("[AuthRateLimiter] Failed attempt",
          attempt: 1,
          max_attempts: max_attempts(),
          ip: ip
        )

      [{^ip, _attempts, lockout_until}] when lockout_until != nil and now < lockout_until ->
        # Already locked out, ignore
        :ok

      [{^ip, attempts, _lockout_until}] ->
        new_attempts = attempts + 1

        if new_attempts >= max_attempts() do
          lockout_until = now + lockout_seconds()
          :ets.insert(@table_name, {ip, new_attempts, lockout_until})

          Logger.warning("[AuthRateLimiter] IP locked out",
            ip: ip,
            lockout_seconds: lockout_seconds(),
            failed_attempts: new_attempts
          )
        else
          :ets.insert(@table_name, {ip, new_attempts, nil})

          Logger.debug("[AuthRateLimiter] Failed attempt",
            attempt: new_attempts,
            max_attempts: max_attempts(),
            ip: ip
          )
        end
    end

    :ok
  rescue
    ArgumentError ->
      # ETS table doesn't exist (rate limiter not started)
      :ok
  end

  @doc """
  Clears the failure record for an IP address after successful authentication.
  """
  @spec record_success(String.t()) :: :ok
  def record_success(ip) when is_binary(ip) do
    :ets.delete(@table_name, ip)
    :ok
  rescue
    ArgumentError ->
      # ETS table doesn't exist
      :ok
  end

  @doc """
  Returns current statistics about rate limiting.
  """
  @spec stats() :: map()
  def stats do
    now = System.system_time(:second)

    entries =
      try do
        :ets.tab2list(@table_name)
      rescue
        ArgumentError -> []
      end

    locked_out =
      Enum.count(entries, fn {_ip, _attempts, lockout_until} ->
        lockout_until != nil and now < lockout_until
      end)

    %{
      total_entries: length(entries),
      locked_out_ips: locked_out,
      max_attempts: max_attempts(),
      lockout_seconds: lockout_seconds()
    }
  end

  # Server callbacks

  @impl GenServer
  def init(_opts) do
    # Delete stale table if it exists (e.g. after :kill restart)
    try do: :ets.delete(@table_name), catch: (_, _ -> :ok)
    :ets.new(@table_name, [:named_table, :public, :set, read_concurrency: true])

    # Schedule periodic cleanup
    schedule_cleanup()

    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:cleanup, state) do
    cleanup_expired_entries()
    schedule_cleanup()
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private helpers

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, cleanup_interval_ms())
  end

  defp cleanup_expired_entries do
    now = System.system_time(:second)

    # Find and delete entries where lockout has expired
    expired =
      :ets.foldl(
        fn
          {ip, _attempts, lockout_until}, acc
          when lockout_until != nil and now >= lockout_until ->
            [ip | acc]

          _entry, acc ->
            acc
        end,
        [],
        @table_name
      )

    Enum.each(expired, &:ets.delete(@table_name, &1))

    if expired != [] do
      Logger.debug("[AuthRateLimiter] Cleaned up expired entries", count: length(expired))
    end
  end

  # Configuration helpers

  defp get_config do
    Application.get_env(:yellow_dog_console, __MODULE__, [])
  end

  defp max_attempts do
    Keyword.get(get_config(), :max_attempts, @default_max_attempts)
  end

  defp lockout_seconds do
    Keyword.get(get_config(), :lockout_seconds, @default_lockout_seconds)
  end

  defp cleanup_interval_ms do
    Keyword.get(get_config(), :cleanup_interval_ms, @default_cleanup_interval_ms)
  end
end
