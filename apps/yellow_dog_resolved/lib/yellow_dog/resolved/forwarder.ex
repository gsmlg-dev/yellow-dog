defmodule YellowDog.Resolved.Forwarder do
  @moduledoc """
  Upstream DNS query forwarder with transaction ID correlation and failover.
  """
  use GenServer

  require Logger

  @type pending :: %{
          txn_id: 0..65_535,
          client_addr: :inet.ip_address(),
          client_port: :inet.port_number(),
          query: DNS.Message.t(),
          original_txn_id: non_neg_integer(),
          sent_at: integer(),
          upstream: :inet.ip_address(),
          upstream_index: non_neg_integer(),
          timer_ref: reference(),
          from: GenServer.from()
        }

  # EMA smoothing factor: 0.3 weights recent latency at 30%, history at 70%
  @ema_alpha 0.3

  # Client API

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc """
  Forward a DNS query to upstream servers.
  Returns the response or :timeout.
  """
  @spec forward(DNS.Message.t(), timeout()) :: {:ok, DNS.Message.t()} | {:error, :timeout}
  def forward(query, timeout \\ 3000) do
    GenServer.call(__MODULE__, {:forward, query}, timeout + 1000)
  end

  @doc """
  Returns per-upstream latency averages in microseconds.
  """
  @spec upstream_latencies() :: %{:inet.ip_address() => float()}
  def upstream_latencies do
    GenServer.call(__MODULE__, :upstream_latencies)
  end

  # Server callbacks

  @impl true
  def init(config) do
    state = %{
      upstreams: Map.get(config, :upstreams, [{1, 1, 1, 1}]),
      timeout_ms: Map.get(config, :upstream_timeout_ms, 3000),
      failure_threshold: Map.get(config, :upstream_failure_threshold, 3),
      failure_counts: %{},
      latencies: %{},
      pending: %{},
      next_txn_id: :rand.uniform(65_535)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:forward, query}, from, state) do
    {txn_id, state} = allocate_txn_id(state)
    upstreams = prioritized_upstreams(state)

    case upstreams do
      [] ->
        {:reply, {:error, :timeout}, state}

      [upstream | _] ->
        state = send_to_upstream(query, upstream, 0, txn_id, from, state)
        {:noreply, state}
    end
  end

  def handle_call(:upstream_latencies, _from, state) do
    {:reply, state.latencies, state}
  end

  @impl true
  def handle_cast({:update_config, config}, state) do
    Logger.info("[Resolved] Forwarder config updated")

    {:noreply,
     %{
       state
       | upstreams: Map.get(config, :upstreams, state.upstreams),
         timeout_ms: Map.get(config, :upstream_timeout_ms, state.timeout_ms),
         failure_threshold: Map.get(config, :upstream_failure_threshold, state.failure_threshold),
         failure_counts: %{},
         latencies: %{}
     }}
  end

  @impl true
  def handle_info({:forward_response, txn_id, response_data, upstream}, state) do
    try do
      case DNS.Message.from_iodata(response_data) do
        %DNS.Message{} = response ->
          handle_response(txn_id, response, upstream, state)

        _ ->
          Logger.debug(
            "[Resolved] Received malformed response from upstream #{:inet.ntoa(upstream)}"
          )

          {:noreply, state}
      end
    rescue
      _ ->
        Logger.debug("[Resolved] Failed to parse upstream response from #{:inet.ntoa(upstream)}")
        {:noreply, state}
    catch
      :throw, _ ->
        Logger.debug("[Resolved] Failed to parse upstream response from #{:inet.ntoa(upstream)}")
        {:noreply, state}
    end
  end

  def handle_info({:timeout, txn_id}, state) do
    case Map.get(state.pending, txn_id) do
      nil ->
        {:noreply, state}

      pending ->
        # Increment failure count for this upstream
        state = increment_failure(state, pending.upstream)

        # Try next upstream
        next_index = pending.upstream_index + 1
        upstreams = prioritized_upstreams(state)

        if next_index < length(upstreams) do
          upstream = Enum.at(upstreams, next_index)
          state = %{state | pending: Map.delete(state.pending, txn_id)}

          state =
            send_to_upstream(pending.query, upstream, next_index, txn_id, pending.from, state)

          {:noreply, state}
        else
          # All upstreams failed
          GenServer.reply(pending.from, {:error, :timeout})
          state = %{state | pending: Map.delete(state.pending, txn_id)}

          :telemetry.execute(
            [:yellow_dog, :resolved, :forward, :exception],
            %{duration: System.monotonic_time(:microsecond) - pending.sent_at},
            %{upstream: pending.upstream, reason: :timeout}
          )

          {:noreply, state}
        end
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Private

  defp allocate_txn_id(state) do
    txn_id = rem(state.next_txn_id, 65_536)
    {txn_id, %{state | next_txn_id: txn_id + 1}}
  end

  defp send_to_upstream(query, upstream, upstream_index, txn_id, from, state) do
    # Rewrite txn_id in the query
    rewritten_query = %{query | header: %{query.header | id: txn_id}}
    packet = DNS.to_iodata(rewritten_query) |> IO.iodata_to_binary()

    :telemetry.execute(
      [:yellow_dog, :resolved, :forward, :start],
      %{},
      %{upstream: upstream, domain: query_domain(query), type: query_type(query)}
    )

    # Send via Abyss.Client, capturing Forwarder PID for message delivery
    forwarder = self()

    Task.start(fn ->
      case Abyss.Client.send_recv(upstream, 53, packet, state.timeout_ms) do
        {:ok, response_data} ->
          send(forwarder, {:forward_response, txn_id, response_data, upstream})

        {:error, _reason} ->
          send(forwarder, {:timeout, txn_id})
      end
    end)

    timer_ref = Process.send_after(self(), {:timeout, txn_id}, state.timeout_ms + 500)

    pending = %{
      txn_id: txn_id,
      query: query,
      original_txn_id: query.header.id,
      sent_at: System.monotonic_time(:microsecond),
      upstream: upstream,
      upstream_index: upstream_index,
      timer_ref: timer_ref,
      from: from
    }

    %{state | pending: Map.put(state.pending, txn_id, pending)}
  end

  defp handle_response(txn_id, response, from_ip, state) do
    case Map.get(state.pending, txn_id) do
      nil ->
        {:noreply, state}

      pending ->
        Process.cancel_timer(pending.timer_ref)
        duration = System.monotonic_time(:microsecond) - pending.sent_at

        # Rewrite txn_id back to client's original
        response = %{response | header: %{response.header | id: pending.original_txn_id}}

        # Reset failure count and update latency EMA for this upstream
        state = reset_failure(state, from_ip)
        state = update_latency(state, from_ip, duration)

        :telemetry.execute(
          [:yellow_dog, :resolved, :forward, :stop],
          %{duration: duration},
          %{
            upstream: from_ip,
            domain: query_domain(pending.query),
            type: query_type(pending.query),
            latency_ema: Map.get(state.latencies, from_ip, duration / 1.0)
          }
        )

        GenServer.reply(pending.from, {:ok, response})
        {:noreply, %{state | pending: Map.delete(state.pending, txn_id)}}
    end
  end

  defp prioritized_upstreams(state) do
    threshold = state.failure_threshold

    {healthy, degraded} =
      Enum.split_with(state.upstreams, fn upstream ->
        Map.get(state.failure_counts, upstream, 0) < threshold
      end)

    # Sort healthy upstreams by latency EMA (fastest first).
    # Upstreams without latency data keep their configured order (infinity).
    sorted_healthy =
      Enum.sort_by(healthy, fn upstream ->
        Map.get(state.latencies, upstream, :infinity)
      end)

    sorted_healthy ++ degraded
  end

  defp increment_failure(state, upstream) do
    count = Map.get(state.failure_counts, upstream, 0) + 1
    %{state | failure_counts: Map.put(state.failure_counts, upstream, count)}
  end

  defp reset_failure(state, upstream) do
    %{state | failure_counts: Map.delete(state.failure_counts, upstream)}
  end

  defp update_latency(state, upstream, duration_us) do
    new_ema =
      case Map.get(state.latencies, upstream) do
        nil ->
          duration_us / 1.0

        prev_ema ->
          @ema_alpha * duration_us + (1 - @ema_alpha) * prev_ema
      end

    %{state | latencies: Map.put(state.latencies, upstream, new_ema)}
  end

  defp query_domain(query) do
    case query.qdlist do
      [q | _] -> to_string(q.name)
      _ -> "unknown"
    end
  end

  defp query_type(query) do
    case query.qdlist do
      [q | _] -> q.type
      _ -> :unknown
    end
  end
end
