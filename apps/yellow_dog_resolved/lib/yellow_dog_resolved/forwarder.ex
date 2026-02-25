defmodule YellowDog.Resolved.Forwarder do
  @moduledoc """
  Upstream DNS query forwarder with transaction ID correlation.

  Manages sending queries to upstream DNS servers, correlating responses
  by transaction ID, handling timeouts, and upstream failover.

  Tracks per-upstream failure counts and deprioritizes unreliable upstreams
  after N consecutive failures.
  """

  use GenServer

  require Logger

  alias YellowDog.Resolved.Upstream

  @type pending :: %{
          client_txn_id: non_neg_integer(),
          query: DNS.Message.t(),
          from: GenServer.from(),
          sent_at: integer(),
          upstream_index: non_neg_integer()
        }

  # Client API

  @doc "Start the forwarder GenServer with the given config."
  @spec start_link(map()) :: GenServer.on_start()
  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc """
  Forward a DNS query to upstream servers. Blocks until response or all upstreams fail.
  Returns `{:ok, response_binary}` or `{:error, :all_upstreams_failed}`.
  """
  @spec forward(DNS.Message.t()) :: {:ok, binary()} | {:error, :all_upstreams_failed}
  def forward(query) do
    GenServer.call(__MODULE__, {:forward, query}, 15_000)
  end

  # GenServer callbacks

  @impl true
  def init(config) do
    state = %{
      upstreams: config.upstreams,
      timeout_ms: config.upstream_timeout_ms,
      failure_threshold: config.upstream_failure_threshold,
      # %{upstream_ip => consecutive_failure_count}
      failure_counts: Map.new(config.upstreams, &{&1, 0})
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:forward, query}, from, state) do
    # Sort upstreams by failure count (least failures first)
    sorted_upstreams = sort_upstreams(state.upstreams, state.failure_counts)

    # Spawn async task to try upstreams sequentially
    task_state = %{
      query: query,
      upstreams: sorted_upstreams,
      timeout_ms: state.timeout_ms,
      from: from,
      state_pid: self()
    }

    Task.start(fn -> try_upstreams(task_state) end)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:upstream_success, upstream}, state) do
    failure_counts = Map.put(state.failure_counts, upstream, 0)
    {:noreply, %{state | failure_counts: failure_counts}}
  end

  @impl true
  def handle_cast({:upstream_failure, upstream}, state) do
    count = Map.get(state.failure_counts, upstream, 0) + 1
    failure_counts = Map.put(state.failure_counts, upstream, count)

    if count >= state.failure_threshold do
      Logger.warning(
        "Upstream #{Upstream.format(upstream)} deprioritized after #{count} failures"
      )
    end

    {:noreply, %{state | failure_counts: failure_counts}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :ok
  end

  # Private functions

  defp sort_upstreams(upstreams, failure_counts) do
    Enum.sort_by(upstreams, fn upstream ->
      Map.get(failure_counts, upstream, 0)
    end)
  end

  defp try_upstreams(%{upstreams: [], from: from}) do
    GenServer.reply(from, {:error, :all_upstreams_failed})
  end

  defp try_upstreams(%{upstreams: [upstream | rest]} = task_state) do
    query = task_state.query
    timeout = task_state.timeout_ms

    :telemetry.execute(
      [:yellow_dog, :resolved, :forward, :start],
      %{},
      %{
        upstream: upstream,
        domain: get_query_domain(query),
        type: get_query_type(query)
      }
    )

    start_time = System.monotonic_time()

    # Encode the query and send to upstream
    query_binary = DNS.to_iodata(query) |> IO.iodata_to_binary()

    {upstream_ip, upstream_port} = Upstream.normalize(upstream)

    case Abyss.Client.send_recv(upstream_ip, upstream_port, query_binary, timeout) do
      {:ok, response} ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:yellow_dog, :resolved, :forward, :stop],
          %{duration: duration},
          %{
            upstream: upstream,
            domain: get_query_domain(query),
            type: get_query_type(query)
          }
        )

        GenServer.cast(task_state.state_pid, {:upstream_success, upstream})
        GenServer.reply(task_state.from, {:ok, response})

      {:error, reason} ->
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:yellow_dog, :resolved, :forward, :exception],
          %{duration: duration},
          %{upstream: upstream, reason: reason}
        )

        Logger.debug("Upstream #{Upstream.format(upstream)} failed: #{inspect(reason)}")
        GenServer.cast(task_state.state_pid, {:upstream_failure, upstream})

        # Try next upstream
        try_upstreams(%{task_state | upstreams: rest})
    end
  end

  defp get_query_domain(query) do
    case query.qdlist do
      [q | _] -> to_string(q.name)
      _ -> "unknown"
    end
  end

  defp get_query_type(query) do
    case query.qdlist do
      [q | _] -> to_string(q.type)
      _ -> "unknown"
    end
  end
end
