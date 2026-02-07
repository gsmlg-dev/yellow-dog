defmodule YellowDog.RateLimiter do
  @moduledoc """
  Shared token bucket rate limiter implementation.

  Provides a reusable rate limiter that can be embedded into any GenServer
  module via `use YellowDog.RateLimiter`. Each using module gets a complete
  token bucket implementation with per-client and global rate limiting.

  ## Usage

      defmodule MyApp.RateLimiter do
        use YellowDog.RateLimiter,
          ets_table: :my_rate_buckets,
          telemetry_prefix: [:my_app, :rate_limiter],
          otp_app: :my_app,
          default_config: %{
            client_tokens: 10,
            client_refill_rate: 2,
            global_tokens: 1000,
            global_refill_rate: 100,
            bucket_ttl: 300_000,
            cleanup_interval: 60_000
          }
      end

  The generated module provides:
  - `start_link/1` - Start the rate limiter
  - `check_rate/1` - Check if a request should be allowed
  - `stats/0` - Get rate limiter statistics
  - `reset/0` - Reset all buckets
  - `enabled?/0` - Check if rate limiting is enabled
  """

  defmacro __using__(opts) do
    ets_table = Keyword.fetch!(opts, :ets_table)
    telemetry_prefix = Keyword.fetch!(opts, :telemetry_prefix)
    otp_app = Keyword.fetch!(opts, :otp_app)
    default_config = Keyword.fetch!(opts, :default_config)

    quote do
      use GenServer

      require Logger

      @ets_table unquote(ets_table)
      @telemetry_prefix unquote(telemetry_prefix)
      @otp_app unquote(otp_app)
      @default_config unquote(default_config)

      # Client API

      @doc "Starts the RateLimiter GenServer."
      @spec start_link(keyword()) :: GenServer.on_start()
      def start_link(opts \\ []) do
        GenServer.start_link(__MODULE__, opts, name: __MODULE__)
      end

      @doc """
      Checks if a request from the given client should be allowed.

      ## Returns
      - `:ok` - Request allowed
      - `{:error, :rate_limited}` - Request should be rate limited
      """
      @spec check_rate(binary() | tuple()) :: :ok | {:error, :rate_limited}
      def check_rate(client_id) do
        GenServer.call(__MODULE__, {:check_rate, client_id})
      catch
        :exit, {:noproc, _} -> :ok
      end

      @doc "Gets current rate limiter statistics."
      @spec stats() :: map()
      def stats do
        GenServer.call(__MODULE__, :stats)
      catch
        :exit, {:noproc, _} -> %{error: :not_running}
      end

      @doc "Resets all rate limit buckets."
      @spec reset() :: :ok
      def reset do
        GenServer.call(__MODULE__, :reset)
      catch
        :exit, {:noproc, _} -> :ok
      end

      @doc "Checks if rate limiting is enabled."
      @spec enabled?() :: boolean()
      def enabled? do
        GenServer.call(__MODULE__, :enabled?)
      catch
        :exit, {:noproc, _} -> false
      end

      # Server Callbacks

      @impl true
      def init(opts) do
        config = YellowDog.RateLimiter.load_config(@otp_app, __MODULE__, @default_config, opts)
        :ets.new(@ets_table, [:named_table, :public, read_concurrency: true])

        if config.enabled do
          Process.send_after(self(), :cleanup, config.cleanup_interval)
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
          @telemetry_prefix ++ [:started],
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

        {global_allowed, new_global_tokens, new_global_time} =
          YellowDog.RateLimiter.check_global_limit(state, now)

        if not global_allowed do
          :telemetry.execute(
            @telemetry_prefix ++ [:denied],
            %{count: 1},
            %{
              reason: :global_limit,
              client_id: YellowDog.RateLimiter.normalize_client_id(client_id)
            }
          )

          new_state = %{
            state
            | global_tokens: new_global_tokens,
              global_last_update: new_global_time,
              total_denied: state.total_denied + 1
          }

          {:reply, {:error, :rate_limited}, new_state}
        else
          client_key = YellowDog.RateLimiter.normalize_client_id(client_id)

          {client_allowed, _tokens} =
            YellowDog.RateLimiter.check_client_limit(@ets_table, client_key, state.config, now)

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
              @telemetry_prefix ++ [:denied],
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
        bucket_count = :ets.info(@ets_table, :size)

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
        :ets.delete_all_objects(@ets_table)

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
        YellowDog.RateLimiter.cleanup_expired_buckets(
          @ets_table,
          @telemetry_prefix,
          state.config.bucket_ttl
        )

        Process.send_after(self(), :cleanup, state.config.cleanup_interval)
        {:noreply, state}
      end

      @impl true
      def handle_info(_msg, state) do
        {:noreply, state}
      end

      defoverridable init: 1
    end
  end

  # Shared pure functions used by all rate limiter instances

  @doc false
  def load_config(otp_app, module, default_config, opts) do
    app_config = Application.get_env(otp_app, module, [])

    default_config
    |> Map.merge(Enum.into(app_config, %{}))
    |> Map.merge(Enum.into(opts, %{}))
  end

  @doc false
  def check_global_limit(state, now) do
    elapsed_ms = now - state.global_last_update
    refill_tokens = div(elapsed_ms * state.config.global_refill_rate, 1000)
    new_tokens = min(state.global_tokens + refill_tokens, state.config.global_tokens)

    if new_tokens >= 1 do
      {true, new_tokens, now}
    else
      {false, new_tokens, now}
    end
  end

  @doc false
  def check_client_limit(ets_table, client_key, config, now) do
    case :ets.lookup(ets_table, client_key) do
      [] ->
        initial_tokens = config.client_tokens - 1
        :ets.insert(ets_table, {client_key, initial_tokens, now})
        {true, initial_tokens}

      [{^client_key, tokens, last_update}] ->
        elapsed_ms = now - last_update
        refill_tokens = div(elapsed_ms * config.client_refill_rate, 1000)
        current_tokens = min(tokens + refill_tokens, config.client_tokens)

        if current_tokens >= 1 do
          new_tokens = current_tokens - 1
          :ets.insert(ets_table, {client_key, new_tokens, now})
          {true, new_tokens}
        else
          :ets.insert(ets_table, {client_key, current_tokens, now})
          {false, current_tokens}
        end
    end
  end

  @doc false
  def cleanup_expired_buckets(ets_table, telemetry_prefix, ttl) do
    now = System.monotonic_time(:millisecond)
    cutoff = now - ttl

    expired =
      :ets.foldl(
        fn {key, _tokens, last_update}, acc ->
          if last_update < cutoff, do: [key | acc], else: acc
        end,
        [],
        ets_table
      )

    Enum.each(expired, &:ets.delete(ets_table, &1))

    if expired != [] do
      :telemetry.execute(
        telemetry_prefix ++ [:cleanup],
        %{count: length(expired)},
        %{}
      )
    end
  end

  @doc false
  def normalize_client_id(id) when is_binary(id), do: id

  def normalize_client_id({a, b, c, d}) when is_integer(a) and a <= 255 do
    <<a, b, c, d>>
  end

  def normalize_client_id({a, b, c, d, e, f, g, h}) when is_integer(a) do
    <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>
  end

  def normalize_client_id(other), do: inspect(other)
end
