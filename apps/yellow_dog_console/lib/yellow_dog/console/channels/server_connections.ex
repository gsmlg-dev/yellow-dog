defmodule YellowDog.Console.ServerConnections do
  @moduledoc """
  Serializes bounded Server candidates, active connections, and correlated requests.
  """

  use GenServer

  alias YellowDog.Console.ServerChannel.SyncCodec
  alias YellowDog.ManagementCore

  @pubsub YellowDog.Console.PubSub
  @max_id_bytes 128
  @default_handshake_timeout_ms 5_000
  @default_max_candidates 256
  @default_max_candidates_per_server 1
  @default_max_pending_requests_per_server 128
  @call_margin_ms 1_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec begin_candidate(String.t(), pid()) ::
          :ok | {:error, :candidate_limit | :internal | :invalid}
  def begin_candidate(server_id, channel_pid) do
    begin_candidate(__MODULE__, server_id, channel_pid)
  end

  @doc false
  def begin_candidate(registry, server_id, channel_pid) do
    safe_call(
      registry,
      {:begin_candidate, server_id, channel_pid},
      {:error, :internal}
    )
  end

  @spec join_candidate(String.t(), pid()) ::
          :ok | {:error, :candidate_limit | :internal | :invalid}
  def join_candidate(server_id, channel_pid), do: begin_candidate(server_id, channel_pid)

  @spec activate(String.t(), pid(), map(), map()) ::
          {:ok, pid() | nil} | {:error, :internal | :invalid | :not_candidate}
  def activate(server_id, channel_pid, identity, status) do
    activate(__MODULE__, server_id, channel_pid, identity, status)
  end

  @doc false
  def activate(registry, server_id, channel_pid, identity, status) do
    safe_call(
      registry,
      {:activate, server_id, channel_pid, identity, status},
      {:error, :internal}
    )
  end

  @spec update_status(String.t(), pid(), map()) ::
          :ok | {:error, :internal | :invalid | :not_connected}
  def update_status(server_id, channel_pid, status) do
    safe_call(
      __MODULE__,
      {:update_status, server_id, channel_pid, status},
      {:error, :not_connected}
    )
  end

  @spec touch(String.t(), pid()) :: :ok | {:error, :not_connected}
  def touch(server_id, channel_pid), do: touch(__MODULE__, server_id, channel_pid)

  @doc false
  def touch(registry, server_id, channel_pid) do
    safe_call(registry, {:touch, server_id, channel_pid}, {:error, :not_connected})
  end

  @spec disconnect(String.t(), pid()) :: :ok | {:error, :not_connected}
  def disconnect(server_id, channel_pid), do: disconnect(__MODULE__, server_id, channel_pid)

  @doc false
  def disconnect(registry, server_id, channel_pid) do
    safe_call(registry, {:disconnect, server_id, channel_pid}, {:error, :not_connected})
  end

  @spec get(String.t()) :: {:ok, map()} | :error
  def get(server_id), do: get(__MODULE__, server_id)

  @doc false
  def get(registry, server_id), do: safe_call(registry, {:get, server_id}, :error)

  @spec list() :: [map()]
  def list, do: safe_call(__MODULE__, :list, [])

  @spec connected?(String.t()) :: boolean()
  def connected?(server_id), do: connected?(__MODULE__, server_id)

  @doc false
  def connected?(registry, server_id) do
    safe_call(registry, {:connected?, server_id}, false)
  end

  @doc false
  def request(summary, encoded, timeout)
      when is_map(summary) and is_binary(encoded) and is_integer(timeout) and timeout > 0 do
    request_call({:request, summary, encoded, timeout}, timeout + @call_margin_ms)
  end

  def request(_summary, _encoded, _timeout), do: {:error, :invalid}

  @doc false
  def deliver(summary, encoded) when is_map(summary) and is_binary(encoded) do
    safe_call(__MODULE__, {:deliver, summary, encoded}, {:error, :not_connected})
  end

  def deliver(_summary, _encoded), do: {:error, :invalid}

  @doc false
  def resolve_result(server_id, channel_pid, result) do
    safe_call(
      __MODULE__,
      {:resolve_result, server_id, channel_pid, result},
      {:error, :internal}
    )
  end

  @doc false
  def reconcile_journal(server_id, channel_pid, encoded) when is_binary(encoded) do
    safe_call(
      __MODULE__,
      {:reconcile_journal, server_id, channel_pid, encoded},
      {:error, :not_connected}
    )
  end

  def reconcile_journal(_server_id, _channel_pid, _encoded), do: {:error, :invalid}

  @doc false
  def accept_config_state(server_id, channel_pid, publication_sequence, encoded)
      when is_integer(publication_sequence) and publication_sequence > 0 and is_binary(encoded) do
    safe_call(
      __MODULE__,
      {:accept_config_state, server_id, channel_pid, publication_sequence, encoded},
      {:error, :not_connected}
    )
  end

  def accept_config_state(_server_id, _channel_pid, _publication_sequence, _encoded),
    do: {:error, :invalid}

  @doc false
  def reset, do: reset(__MODULE__)

  @doc false
  def reset(registry), do: safe_call(registry, :reset, {:error, :internal})

  @impl true
  def init(opts) do
    with {:ok, config} <- validated_config(opts) do
      {:ok, initial_state(config)}
    end
  end

  @impl true
  def handle_call({:begin_candidate, server_id, channel_pid}, _from, state) do
    key = {server_id, channel_pid}

    cond do
      not valid_candidate?(server_id, channel_pid) ->
        {:reply, {:error, :invalid}, state}

      Map.has_key?(state.candidates, key) ->
        {:reply, :ok, state}

      candidate_limit?(state, server_id) ->
        {:reply, {:error, :candidate_limit}, state}

      true ->
        monitor_ref = Process.monitor(channel_pid)
        timeout_tag = make_ref()

        timer_ref =
          Process.send_after(
            self(),
            {:candidate_timeout, key, timeout_tag},
            state.config.handshake_timeout_ms
          )

        candidate = %{
          server_id: server_id,
          channel_pid: channel_pid,
          monitor_ref: monitor_ref,
          timer_ref: timer_ref,
          timeout_tag: timeout_tag
        }

        state =
          state
          |> put_in([:candidates, key], candidate)
          |> put_in([:monitors, monitor_ref], {:candidate, server_id, channel_pid})

        {:reply, :ok, state}
    end
  end

  def handle_call(
        {:activate, server_id, channel_pid, identity, status},
        _from,
        state
      ) do
    key = {server_id, channel_pid}

    with {:ok, candidate} <- Map.fetch(state.candidates, key),
         true <- valid_identity?(identity, server_id),
         true <- valid_status?(status, server_id) do
      cancel_timer(candidate.timer_ref)
      {state, replaced_pid} = replace_active(state, server_id)
      now = DateTime.utc_now(:second)

      connection = %{
        server_id: server_id,
        channel_pid: channel_pid,
        monitor_ref: candidate.monitor_ref,
        identity: identity,
        status: status,
        pending_requests: %{},
        connected?: true,
        connected_at: now,
        last_seen_at: now
      }

      state =
        state
        |> update_in([:candidates], &Map.delete(&1, key))
        |> put_in([:connections, server_id], connection)
        |> put_in(
          [:monitors, candidate.monitor_ref],
          {:active, server_id, channel_pid}
        )

      if replaced_pid, do: send(replaced_pid, {:server_connection_replaced, channel_pid})
      broadcast(server_id, {:server_connection, :online, public_connection(connection)})

      {:reply, {:ok, replaced_pid}, state}
    else
      :error -> {:reply, {:error, :not_candidate}, state}
      false -> {:reply, {:error, :invalid}, state}
    end
  end

  def handle_call({:update_status, server_id, channel_pid, status}, _from, state) do
    case Map.get(state.connections, server_id) do
      %{channel_pid: ^channel_pid, connected?: true} = connection ->
        with true <- valid_status?(status, server_id),
             :ok <- persist_status(server_id, status.state) do
          updated = %{connection | status: status, last_seen_at: DateTime.utc_now(:second)}
          state = put_in(state, [:connections, server_id], updated)
          broadcast(server_id, {:server_connection, :updated, public_connection(updated)})
          {:reply, :ok, state}
        else
          false -> {:reply, {:error, :invalid}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      _not_active ->
        {:reply, {:error, :not_connected}, state}
    end
  end

  def handle_call({:touch, server_id, channel_pid}, _from, state) do
    case Map.fetch(state.connections, server_id) do
      {:ok, %{channel_pid: ^channel_pid, connected?: true} = connection} ->
        updated = %{connection | last_seen_at: DateTime.utc_now(:second)}
        state = put_in(state, [:connections, server_id], updated)
        broadcast(server_id, {:server_connection, :updated, public_connection(updated)})
        {:reply, :ok, state}

      _not_active ->
        {:reply, {:error, :not_connected}, state}
    end
  end

  def handle_call({:disconnect, server_id, channel_pid}, _from, state) do
    {state, disconnected?} = disconnect_pid(state, server_id, channel_pid, true)
    if disconnected?, do: management_disconnected(server_id)
    {:reply, :ok, state}
  end

  def handle_call({:get, server_id}, _from, state) do
    reply =
      case Map.fetch(state.connections, server_id) do
        {:ok, connection} -> {:ok, public_connection(connection)}
        :error -> :error
      end

    {:reply, reply, state}
  end

  def handle_call(:list, _from, state) do
    connections =
      state.connections
      |> Map.values()
      |> Enum.map(&public_connection/1)
      |> Enum.sort_by(& &1.server_id)

    {:reply, connections, state}
  end

  def handle_call({:connected?, server_id}, _from, state) do
    connected? =
      case Map.get(state.connections, server_id) do
        %{connected?: true, channel_pid: channel_pid} -> Process.alive?(channel_pid)
        _connection -> false
      end

    {:reply, connected?, state}
  end

  def handle_call({:request, summary, encoded, timeout}, from, state) do
    with {:ok, server_id} <- request_server(summary),
         {:ok, connection} <- active_connection(state, server_id),
         :ok <- pending_capacity(connection, state.config),
         false <- Map.has_key?(connection.pending_requests, summary.request_id) do
      timeout_tag = make_ref()

      timer_ref =
        Process.send_after(
          self(),
          {:request_timeout, server_id, summary.request_id, connection.channel_pid, timeout_tag},
          timeout
        )

      pending = %{
        from: from,
        request_id: summary.request_id,
        target_type: summary.target_type,
        operation: summary.operation,
        channel_pid: connection.channel_pid,
        timer_ref: timer_ref,
        timeout_tag: timeout_tag
      }

      updated = put_in(connection, [:pending_requests, summary.request_id], pending)
      state = put_in(state, [:connections, server_id], updated)
      send(connection.channel_pid, {:server_management_push, encoded})
      {:noreply, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      true -> {:reply, {:error, :invalid}, state}
    end
  end

  def handle_call({:deliver, summary, encoded}, _from, state) do
    with {:ok, server_id} <- request_server(summary),
         {:ok, connection} <- active_connection(state, server_id) do
      send(connection.channel_pid, {:server_management_push, encoded})
      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:resolve_result, server_id, channel_pid, result}, _from, state) do
    case matching_pending(state, server_id, channel_pid, result) do
      {:ok, connection, pending} ->
        cancel_timer(pending.timer_ref)
        pending_requests = Map.delete(connection.pending_requests, pending.request_id)
        updated = %{connection | pending_requests: pending_requests}
        state = put_in(state, [:connections, server_id], updated)
        GenServer.reply(pending.from, result.outcome)
        {:reply, :ok, state}

      :error ->
        {:reply, :ignored, state}
    end
  end

  def handle_call({:reconcile_journal, server_id, channel_pid, encoded}, _from, state) do
    with {:ok, connection} <- active_connection(state, server_id, channel_pid),
         {:ok, result} <- SyncCodec.reconcile_journal(encoded, server_id),
         :ok <- deliver_pending_config(result, connection),
         {:ok, updated} <- touch_connection(connection) do
      state = put_in(state, [:connections, server_id], updated)
      broadcast(server_id, {:server_connection, :updated, public_connection(updated)})
      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:accept_config_state, server_id, channel_pid, publication_sequence, encoded},
        _from,
        state
      ) do
    with {:ok, _connection} <- active_connection(state, server_id, channel_pid) do
      reply =
        case ManagementCore.accept_config_state_publication(
               :server,
               server_id,
               publication_sequence,
               encoded
             ) do
          {:ok, receipt} when is_map(receipt) -> {:ok, receipt}
          {:error, reason} -> {:error, management_error_code(reason)}
          _invalid -> {:error, :internal}
        end

      {:reply, reply, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  rescue
    _exception -> {:reply, {:error, :internal}, state}
  catch
    :exit, _reason -> {:reply, {:error, :internal}, state}
  end

  def handle_call(:reset, _from, state) do
    Enum.each(state.candidates, fn {_key, candidate} ->
      cancel_timer(candidate.timer_ref)
    end)

    Enum.each(Map.keys(state.monitors), &Process.demonitor(&1, [:flush]))

    Enum.each(state.connections, fn {_server_id, connection} ->
      fail_pending(connection.pending_requests, :not_connected)
    end)

    {:reply, :ok, initial_state(state.config)}
  end

  @impl true
  def handle_info({:candidate_timeout, key, timeout_tag}, state) do
    case Map.get(state.candidates, key) do
      %{timeout_tag: ^timeout_tag} = candidate ->
        Process.demonitor(candidate.monitor_ref, [:flush])
        send(candidate.channel_pid, :server_handshake_timeout)

        state = %{
          state
          | candidates: Map.delete(state.candidates, key),
            monitors: Map.delete(state.monitors, candidate.monitor_ref)
        }

        {:noreply, state}

      _stale ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:request_timeout, server_id, request_id, channel_pid, timeout_tag},
        state
      ) do
    case Map.get(state.connections, server_id) do
      %{
        channel_pid: ^channel_pid,
        pending_requests: %{^request_id => %{timeout_tag: ^timeout_tag} = pending}
      } = connection ->
        pending_requests = Map.delete(connection.pending_requests, request_id)
        updated = %{connection | pending_requests: pending_requests}
        state = put_in(state, [:connections, server_id], updated)
        GenServer.reply(pending.from, {:error, :timeout})
        {:noreply, state}

      _stale ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor_ref, :process, channel_pid, _reason}, state) do
    case Map.pop(state.monitors, monitor_ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {{:candidate, server_id, ^channel_pid}, monitors} ->
        key = {server_id, channel_pid}

        candidates =
          case Map.pop(state.candidates, key) do
            {%{timer_ref: timer_ref}, candidates} ->
              cancel_timer(timer_ref)
              candidates

            {nil, candidates} ->
              candidates
          end

        {:noreply, %{state | candidates: candidates, monitors: monitors}}

      {{:active, server_id, ^channel_pid}, monitors} ->
        state = %{state | monitors: monitors}
        {state, disconnected?} = disconnect_pid(state, server_id, channel_pid, false)
        if disconnected?, do: management_disconnected(server_id)
        {:noreply, state}
    end
  end

  defp validated_config(opts) do
    values = %{
      handshake_timeout_ms:
        option(
          opts,
          :handshake_timeout_ms,
          :server_handshake_timeout_ms,
          @default_handshake_timeout_ms
        ),
      max_candidates:
        option(opts, :max_candidates, :server_max_candidates, @default_max_candidates),
      max_candidates_per_server:
        option(
          opts,
          :max_candidates_per_server,
          :server_max_candidates_per_server,
          @default_max_candidates_per_server
        ),
      max_pending_requests_per_server:
        option(
          opts,
          :max_pending_requests_per_server,
          :server_max_pending_requests_per_server,
          @default_max_pending_requests_per_server
        )
    }

    if Enum.all?(values, fn {_key, value} -> is_integer(value) and value > 0 end) do
      {:ok, values}
    else
      {:stop, {:invalid_server_connections_config, values}}
    end
  end

  defp option(opts, option_key, config_key, default) do
    Keyword.get(
      opts,
      option_key,
      Application.get_env(:yellow_dog_console, config_key, default)
    )
  end

  defp candidate_limit?(state, server_id) do
    map_size(state.candidates) >= state.config.max_candidates or
      Enum.count(state.candidates, fn {{candidate_id, _pid}, _candidate} ->
        candidate_id == server_id
      end) >= state.config.max_candidates_per_server
  end

  defp replace_active(state, server_id) do
    case Map.get(state.connections, server_id) do
      %{connected?: true, channel_pid: old_pid, monitor_ref: monitor_ref} = connection ->
        Process.demonitor(monitor_ref, [:flush])
        fail_pending(connection.pending_requests, :not_connected)
        {%{state | monitors: Map.delete(state.monitors, monitor_ref)}, old_pid}

      _connection ->
        {state, nil}
    end
  end

  defp disconnect_pid(state, server_id, channel_pid, demonitor?) do
    candidate_key = {server_id, channel_pid}

    case Map.pop(state.candidates, candidate_key) do
      {%{monitor_ref: monitor_ref, timer_ref: timer_ref}, candidates} ->
        cancel_timer(timer_ref)
        if demonitor?, do: Process.demonitor(monitor_ref, [:flush])

        state = %{
          state
          | candidates: candidates,
            monitors: Map.delete(state.monitors, monitor_ref)
        }

        {state, false}

      {nil, _candidates} ->
        disconnect_active(state, server_id, channel_pid, demonitor?)
    end
  end

  defp disconnect_active(state, server_id, channel_pid, demonitor?) do
    case Map.get(state.connections, server_id) do
      %{channel_pid: ^channel_pid, connected?: true, monitor_ref: monitor_ref} = connection ->
        if demonitor?, do: Process.demonitor(monitor_ref, [:flush])
        fail_pending(connection.pending_requests, :not_connected)

        updated = %{
          connection
          | channel_pid: nil,
            monitor_ref: nil,
            pending_requests: %{},
            connected?: false
        }

        state = %{
          state
          | connections: Map.put(state.connections, server_id, updated),
            monitors: Map.delete(state.monitors, monitor_ref)
        }

        broadcast(server_id, {:server_connection, :offline, public_connection(updated)})
        {state, true}

      _not_active ->
        {state, false}
    end
  end

  defp active_connection(state, server_id) do
    case Map.get(state.connections, server_id) do
      %{connected?: true, channel_pid: channel_pid} = connection ->
        if Process.alive?(channel_pid),
          do: {:ok, connection},
          else: {:error, :not_connected}

      _connection ->
        {:error, :not_connected}
    end
  end

  defp active_connection(state, server_id, channel_pid) do
    case Map.get(state.connections, server_id) do
      %{connected?: true, channel_pid: ^channel_pid} = connection ->
        if Process.alive?(channel_pid),
          do: {:ok, connection},
          else: {:error, :not_connected}

      _connection ->
        {:error, :not_connected}
    end
  end

  defp deliver_pending_config(%{pending_config: nil}, _connection), do: :ok

  defp deliver_pending_config(%{pending_config: version}, connection) do
    with {:ok, encoded, summary} <- SyncCodec.encode_config_version_delivery(version),
         true <- summary.target_type == :server,
         true <- summary.target_id == connection.server_id,
         true <- Process.alive?(connection.channel_pid) do
      send(connection.channel_pid, {:server_management_push, encoded})
      :ok
    else
      false -> {:error, :not_connected}
      {:error, _reason} -> {:error, :internal}
      _invalid -> {:error, :internal}
    end
  end

  defp deliver_pending_config(_result, _connection), do: {:error, :internal}

  defp touch_connection(%{connected?: true} = connection) do
    {:ok, %{connection | last_seen_at: DateTime.utc_now(:second)}}
  end

  defp pending_capacity(connection, config) do
    if map_size(connection.pending_requests) < config.max_pending_requests_per_server,
      do: :ok,
      else: {:error, :request_limit}
  end

  defp request_server(%{
         target_type: :server,
         target_id: server_id,
         request_id: request_id,
         operation: operation
       })
       when is_binary(server_id) and is_binary(request_id) and is_binary(operation),
       do: {:ok, server_id}

  defp request_server(_summary), do: {:error, :invalid}

  defp matching_pending(state, server_id, channel_pid, result) do
    with %{
           connected?: true,
           channel_pid: ^channel_pid,
           pending_requests: pending_requests
         } = connection <- Map.get(state.connections, server_id),
         %{channel_pid: ^channel_pid} = pending <-
           Map.get(pending_requests, result.request_id),
         true <- result.target_type == pending.target_type,
         true <- result.operation == pending.operation do
      {:ok, connection, pending}
    else
      _invalid -> :error
    end
  end

  defp fail_pending(pending_requests, reason) do
    Enum.each(pending_requests, fn {_request_id, pending} ->
      cancel_timer(pending.timer_ref)
      GenServer.reply(pending.from, {:error, reason})
    end)
  end

  defp persist_status(server_id, status) do
    case ManagementCore.update_server_status(server_id, status) do
      {:ok, _server} -> :ok
      {:error, :not_found} -> {:error, :not_connected}
      {:error, _reason} -> {:error, :internal}
      _invalid -> {:error, :internal}
    end
  rescue
    _exception -> {:error, :internal}
  catch
    :exit, _reason -> {:error, :internal}
  end

  defp public_connection(connection) do
    connection
    |> Map.drop([:monitor_ref, :pending_requests])
    |> Map.put(:pending_request_count, map_size(connection.pending_requests))
  end

  defp broadcast(server_id, message) do
    Phoenix.PubSub.broadcast(@pubsub, "management:server:#{server_id}", message)
  catch
    :exit, _reason -> :ok
  end

  defp management_disconnected(server_id) do
    ManagementCore.runtime_disconnected(:server, server_id)
    :ok
  rescue
    _exception -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp management_error_code(reason) when is_map(reason) do
    case Map.get(reason, :code) do
      code
      when code in [
             :not_connected,
             :not_found,
             :invalid,
             :conflict,
             :unsupported,
             :timeout,
             :apply_failed,
             :rollback_failed,
             :internal
           ] ->
        code

      _unknown ->
        :internal
    end
  end

  defp management_error_code(_reason), do: :internal

  defp valid_candidate?(server_id, channel_pid) do
    valid_id?(server_id) and is_pid(channel_pid) and Process.alive?(channel_pid)
  end

  defp valid_identity?(
         %{
           id: server_id,
           name: name,
           version: version,
           profile: profile,
           capabilities: capabilities,
           config_revision: config_revision
         },
         server_id
       ) do
    is_binary(name) and is_binary(version) and is_binary(profile) and
      is_list(capabilities) and is_binary(config_revision)
  end

  defp valid_identity?(_identity, _server_id), do: false

  defp valid_status?(
         %{
           target_type: :server,
           target_id: server_id,
           state: state,
           details: details,
           observed_at: %DateTime{}
         },
         server_id
       ) do
    is_atom(state) and is_map(details)
  end

  defp valid_status?(_status, _server_id), do: false

  defp valid_id?(value) do
    is_binary(value) and value != "" and byte_size(value) <= @max_id_bytes and
      String.valid?(value)
  end

  defp cancel_timer(timer_ref) when is_reference(timer_ref) do
    Process.cancel_timer(timer_ref, async: false, info: false)
    :ok
  end

  defp safe_call(registry, message, fallback, timeout \\ 5_000) do
    GenServer.call(registry, message, timeout)
  rescue
    _exception -> fallback
  catch
    :exit, _reason -> fallback
  end

  defp request_call(message, timeout) do
    GenServer.call(__MODULE__, message, timeout)
  rescue
    _exception -> {:error, :not_connected}
  catch
    :exit, {:timeout, _reason} -> {:error, :timeout}
    :exit, _reason -> {:error, :not_connected}
  end

  defp initial_state(config) do
    %{connections: %{}, candidates: %{}, monitors: %{}, config: config}
  end
end
