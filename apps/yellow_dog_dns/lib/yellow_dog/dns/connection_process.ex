defmodule YellowDog.Dns.ConnectionProcess do
  @moduledoc """
  Per-connection process that orchestrates DNS resolution via async message passing.

  ## Lifecycle

  - Lifetime = network connection lifetime
  - UDP: typically one query, then connection closes
  - TCP: potentially multiple concurrent queries, terminates when TCP closes

  ## Responsibilities

  - Track multiple in-flight queries concurrently
  - Create telemetry span per query (`:telemetry.span`)
  - Drive resolution step-by-step: ViewManager → View → Zone
  - Pass own PID with each request for response routing
  - Handle messages from View/Zone, route to correct query context
  - Timeout detection per query
  - Error detection per query
  - Log each resolution step with telemetry
  - Return responses to Handler (can be out-of-order)

  ## Per-Query State

  Each query is tracked with:
  - Query ID (DNS message ID)
  - Telemetry span reference
  - Current resolution phase
  - Timeout timer reference
  - In-flight status

  ## Concurrency Model

  - Multiple queries in-flight simultaneously
  - Each query tracked independently
  - Responses can arrive and be sent out-of-order
  - State machine per query, not per connection
  """

  use GenServer

  alias YellowDog.Dns.QueryLogger
  alias YellowDog.Telemetry
  alias DNS.Message
  alias DNS.Message.RCode

  # DNS module used for to_iodata/1
  require DNS

  @default_query_timeout 5_000

  # Query phases
  @phase_received :received
  @phase_firewall :firewall_check
  @phase_view_routing :view_routing
  @phase_zone_lookup :zone_lookup
  @phase_resolving :resolving
  @phase_rpz :rpz_evaluation

  defstruct [
    :handler_pid,
    :client_ip,
    :client_port,
    :socket,
    queries: %{},
    query_timeout: @default_query_timeout,
    max_concurrent_queries: 100
  ]

  # Query state struct
  defmodule QueryState do
    @moduledoc false
    defstruct [
      :id,
      :query,
      :span_ref,
      :timer_ref,
      :started_at,
      phase: :received,
      view: nil,
      zone: nil,
      metadata: %{},
      raw: false
    ]
  end

  # Client API

  @doc """
  Starts a connection process.

  ## Options
  - `:handler_pid` - PID of the Handler process (required)
  - `:client_ip` - Client IP address (required)
  - `:client_port` - Client port number (required)
  - `:socket` - Socket for sending responses
  - `:query_timeout` - Per-query timeout in ms (default: 5000)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Submits a DNS query for resolution.

  The query will be resolved asynchronously and the response sent
  to the Handler via `{:dns_response, query_id, response}` message.
  """
  @spec submit_query(pid(), Message.t()) :: :ok | {:error, term()}
  def submit_query(pid, query) do
    GenServer.call(pid, {:submit_query, query})
  end

  @doc """
  Submits raw DNS data for resolution.

  The data will be parsed, resolved, and the raw response binary sent
  back to the Handler via `{:dns_raw_response, response_data}` message.

  This allows the handler to remain purely I/O focused without any
  DNS protocol knowledge.
  """
  @spec submit_raw_data(pid(), binary()) :: :ok | {:error, term()}
  def submit_raw_data(pid, data) do
    GenServer.call(pid, {:submit_raw_data, data})
  end

  @doc """
  Notifies the connection process that the network connection is closing.
  """
  @spec connection_closed(pid()) :: :ok
  def connection_closed(pid) do
    GenServer.cast(pid, :connection_closed)
  end

  @doc """
  Returns statistics for this connection.
  """
  @spec stats(pid()) :: map()
  def stats(pid) do
    GenServer.call(pid, :stats)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    handler_pid = Keyword.fetch!(opts, :handler_pid)
    client_ip = Keyword.fetch!(opts, :client_ip)
    client_port = Keyword.fetch!(opts, :client_port)
    socket = Keyword.get(opts, :socket)
    query_timeout = Keyword.get(opts, :query_timeout, @default_query_timeout)

    # Monitor the handler - if it dies, we should too
    Process.monitor(handler_pid)

    state = %__MODULE__{
      handler_pid: handler_pid,
      client_ip: client_ip,
      client_port: client_port,
      socket: socket,
      query_timeout: query_timeout
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:submit_query, query}, _from, state) do
    case submit_query_internal(state, query) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:submit_raw_data, data}, _from, state) do
    try do
      query = Message.from_iodata(data)

      case submit_query_internal(state, query, raw: true) do
        {:ok, new_state} ->
          {:reply, :ok, new_state}

        {:error, _reason} = error ->
          {:reply, error, state}
      end
    rescue
      error in [ArgumentError, MatchError, FunctionClauseError, RuntimeError] ->
        Telemetry.warning("Failed to parse DNS query", %{
          error: inspect(error),
          data_size: byte_size(data)
        })

        {:reply, {:error, :parse_error}, state}
    catch
      {:format_error, section, _details} ->
        Telemetry.warning("DNS format error", %{section: section})
        {:reply, {:error, {:format_error, section}}, state}

      :throw, reason ->
        Telemetry.warning("DNS parse error", %{reason: inspect(reason)})
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      client_ip: format_ip(state.client_ip),
      client_port: state.client_port,
      active_queries: map_size(state.queries),
      queries:
        Enum.map(state.queries, fn {id, qs} ->
          %{id: id, phase: qs.phase, elapsed_ms: elapsed_ms(qs.started_at)}
        end)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_cast(:connection_closed, state) do
    # Cancel all in-flight queries
    Enum.each(state.queries, fn {_id, qs} ->
      if qs.timer_ref, do: Process.cancel_timer(qs.timer_ref)
      if qs.span_ref, do: end_span_error(qs, :connection_closed)
    end)

    {:stop, :normal, state}
  end

  # Handle async resolution messages from ViewManager/View/Zone
  @impl true
  def handle_info({:view_matched, query_id, view_name}, state) do
    state = update_query_phase(state, query_id, @phase_zone_lookup, %{view: view_name})
    {:noreply, state}
  end

  @impl true
  def handle_info({:zone_lookup, query_id, result}, state) do
    phase =
      case result do
        :hit -> @phase_resolving
        :miss -> @phase_resolving
      end

    state = update_query_phase(state, query_id, phase, %{cache_result: result})
    {:noreply, state}
  end

  @impl true
  def handle_info({:zone_response, query_id, _response}, state) do
    # Zone response received - update phase to RPZ evaluation
    # The actual completion happens when {:resolution_complete, ...} is received
    state = update_query_phase(state, query_id, @phase_rpz)
    {:noreply, state}
  end

  @impl true
  def handle_info({:recursive_step, query_id, step_info}, state) do
    state = update_query_metadata(state, query_id, %{recursive_step: step_info})
    {:noreply, state}
  end

  @impl true
  def handle_info({:rpz_evaluation, query_id, result}, state) do
    case Map.get(state.queries, query_id) do
      nil ->
        {:noreply, state}

      _qs ->
        state = update_query_metadata(state, query_id, %{rpz_result: result})
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:resolution_complete, query_id, response}, state) do
    state = complete_query(state, query_id, response)
    {:noreply, state}
  end

  @impl true
  def handle_info({:resolution_error, query_id, reason}, state) do
    state = complete_query_error(state, query_id, reason)
    {:noreply, state}
  end

  # Query timeout
  @impl true
  def handle_info({:query_timeout, query_id}, state) do
    case Map.get(state.queries, query_id) do
      nil ->
        {:noreply, state}

      qs ->
        Telemetry.warning("Query timeout", %{
          query_id: query_id,
          phase: qs.phase,
          elapsed_ms: elapsed_ms(qs.started_at)
        })

        # Cancel any in-flight resolution
        send_cancel_to_view(qs)

        # Complete with SERVFAIL
        state = complete_query_error(state, query_id, :timeout)
        {:noreply, state}
    end
  end

  # Handler died - we should terminate
  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{handler_pid: pid} = state) do
    {:stop, :normal, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private functions

  defp submit_query_internal(state, query, opts \\ []) do
    if map_size(state.queries) >= state.max_concurrent_queries do
      {:error, :too_many_queries}
    else
      query_id = query.header.id
      raw = Keyword.get(opts, :raw, false)

      # Start telemetry span
      span_ref = start_span(state, query)

      # Set timeout
      timer_ref = Process.send_after(self(), {:query_timeout, query_id}, state.query_timeout)

      # Create query state
      qs = %QueryState{
        id: query_id,
        query: query,
        span_ref: span_ref,
        timer_ref: timer_ref,
        started_at: System.monotonic_time(:millisecond),
        phase: @phase_received,
        raw: raw
      }

      # Update state
      new_state = %{state | queries: Map.put(state.queries, query_id, qs)}

      # Start resolution - firewall check first
      new_state = update_query_phase(new_state, query_id, @phase_firewall)

      # TODO: Implement firewall check
      # For now, pass through to view routing
      new_state = update_query_phase(new_state, query_id, @phase_view_routing)

      # Send to ViewManager for routing
      send_to_view_manager(new_state, query_id, query)

      {:ok, new_state}
    end
  end

  defp send_to_view_manager(state, query_id, query) do
    # Capture the connection process PID before spawning
    connection_pid = self()

    # Send resolution request to ViewManager with connection process PID for response routing
    spawn(fn ->
      result =
        YellowDog.Dns.ViewManager.resolve(
          connection_pid,
          state.client_ip,
          query_id,
          query
        )

      # Send result back to connection process
      case result do
        {:ok, response} ->
          send(connection_pid, {:resolution_complete, query_id, response})

        {:error, reason} ->
          send(connection_pid, {:resolution_error, query_id, reason})
      end
    end)
  end

  defp update_query_phase(state, query_id, phase, metadata \\ %{}) do
    case Map.get(state.queries, query_id) do
      nil ->
        state

      qs ->
        emit_phase_event(qs, phase, metadata)

        updated_qs = %{qs | phase: phase, metadata: Map.merge(qs.metadata, metadata)}

        if Map.has_key?(metadata, :view) do
          updated_qs = %{updated_qs | view: metadata.view}
          %{state | queries: Map.put(state.queries, query_id, updated_qs)}
        else
          %{state | queries: Map.put(state.queries, query_id, updated_qs)}
        end
    end
  end

  defp update_query_metadata(state, query_id, metadata) do
    case Map.get(state.queries, query_id) do
      nil ->
        state

      qs ->
        updated_qs = %{qs | metadata: Map.merge(qs.metadata, metadata)}
        %{state | queries: Map.put(state.queries, query_id, updated_qs)}
    end
  end

  defp complete_query(state, query_id, response) do
    case Map.pop(state.queries, query_id) do
      {nil, _queries} ->
        state

      {qs, queries} ->
        # Cancel timeout timer
        if qs.timer_ref, do: Process.cancel_timer(qs.timer_ref)

        # End telemetry span
        end_span_success(qs, response)

        # Log to QueryLogger
        log_query_entry(state, qs, response)

        # Send response to handler (raw binary or parsed message)
        if qs.raw do
          response_data = DNS.to_iodata(response)
          send(state.handler_pid, {:dns_raw_response, query_id, response_data})
        else
          send(state.handler_pid, {:dns_response, query_id, response})
        end

        %{state | queries: queries}
    end
  end

  defp complete_query_error(state, query_id, reason) do
    case Map.pop(state.queries, query_id) do
      {nil, _queries} ->
        state

      {qs, queries} ->
        # Cancel timeout timer
        if qs.timer_ref, do: Process.cancel_timer(qs.timer_ref)

        # End telemetry span with error
        end_span_error(qs, reason)

        # Create error response
        error_response = create_error_response(qs.query, reason)

        # Log error to QueryLogger
        log_query_error(state, qs, error_response, reason)

        # Send error response to handler (raw binary or parsed message)
        if qs.raw do
          response_data = DNS.to_iodata(error_response)
          send(state.handler_pid, {:dns_raw_response, query_id, response_data})
        else
          send(state.handler_pid, {:dns_response, query_id, error_response})
        end

        %{state | queries: queries}
    end
  end

  defp send_cancel_to_view(qs) do
    if qs.view do
      case YellowDog.Dns.ViewManager.get_view(qs.view) do
        {:ok, view_pid} ->
          send(view_pid, {:cancel_query, qs.id})

        _ ->
          :ok
      end
    end
  end

  defp create_error_response(query, reason) do
    rcode =
      case reason do
        :timeout -> RCode.serv_fail()
        :refused -> RCode.refused()
        :nxdomain -> RCode.nx_domain()
        :format_error -> RCode.form_err()
        _ -> RCode.serv_fail()
      end

    %Message{
      header: %{
        query.header
        | qr: 1,
          aa: 0,
          tc: 0,
          ra: 1,
          rcode: rcode,
          ancount: 0,
          nscount: 0,
          arcount: 0
      },
      qdlist: query.qdlist,
      anlist: [],
      nslist: [],
      arlist: []
    }
  end

  # Telemetry helpers

  defp start_span(state, query) do
    metadata = %{
      client_ip: format_ip(state.client_ip),
      client_port: state.client_port,
      query_id: query.header.id,
      query_name: get_query_name(query),
      query_type: get_query_type(query)
    }

    # Start telemetry span
    :telemetry.execute(
      [:yellow_dog, :dns, :query, :start],
      %{system_time: System.system_time()},
      metadata
    )

    # Return a reference for tracking
    make_ref()
  end

  defp end_span_success(qs, response) do
    duration = elapsed_ms(qs.started_at)

    metadata = %{
      query_id: qs.id,
      phase: qs.phase,
      view: qs.view,
      zone: qs.zone,
      rcode: response.header.rcode,
      answer_count: length(response.anlist)
    }

    :telemetry.execute(
      [:yellow_dog, :dns, :query, :stop],
      %{duration: duration},
      metadata
    )
  end

  defp end_span_error(qs, reason) do
    duration = elapsed_ms(qs.started_at)

    metadata = %{
      query_id: qs.id,
      phase: qs.phase,
      view: qs.view,
      zone: qs.zone,
      error: reason
    }

    :telemetry.execute(
      [:yellow_dog, :dns, :query, :exception],
      %{duration: duration},
      metadata
    )
  end

  defp emit_phase_event(qs, phase, metadata) do
    :telemetry.execute(
      [:yellow_dog, :dns, :query, :phase],
      %{elapsed_ms: elapsed_ms(qs.started_at)},
      Map.merge(%{query_id: qs.id, phase: phase}, metadata)
    )
  end

  # Utility helpers

  defp elapsed_ms(started_at) do
    System.monotonic_time(:millisecond) - started_at
  end

  defp format_ip(ip) when is_tuple(ip), do: :inet.ntoa(ip) |> to_string()
  defp format_ip(ip), do: inspect(ip)

  defp get_query_name(%Message{qdlist: [question | _]}), do: question.name
  defp get_query_name(_), do: nil

  defp get_query_type(%Message{qdlist: [question | _]}), do: question.type
  defp get_query_type(_), do: nil

  # QueryLogger integration

  defp log_query_entry(state, qs, response) do
    QueryLogger.log_query(%{
      client_ip: format_ip(state.client_ip),
      client_port: state.client_port,
      view: qs.view,
      qname: get_query_name(qs.query),
      qtype: get_query_type(qs.query),
      response_code: response.header.rcode,
      response_time_us: elapsed_ms(qs.started_at) * 1000,
      answer_count: length(response.anlist),
      authority_count: length(response.nslist),
      additional_count: length(response.arlist),
      cache_hit: Map.get(qs.metadata, :cache_result) == :hit,
      zone_used: qs.zone,
      fallback_used: Map.get(qs.metadata, :fallback_used, false)
    })
  end

  defp log_query_error(state, qs, error_response, reason) do
    QueryLogger.log_query(%{
      client_ip: format_ip(state.client_ip),
      client_port: state.client_port,
      view: qs.view,
      qname: get_query_name(qs.query),
      qtype: get_query_type(qs.query),
      response_code: error_response.header.rcode,
      response_time_us: elapsed_ms(qs.started_at) * 1000,
      answer_count: 0,
      error: reason
    })
  end
end
