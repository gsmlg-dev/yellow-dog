defmodule YellowDog.Console.NetmanConnections do
  @moduledoc """
  Serializes bounded typed Netman candidates, active connections, and requests.

  The legacy `NetmanRegistry` remains separate until the legacy client and UI
  transport are removed.
  """

  use GenServer

  alias YellowDog.Console.ServerChannel.SyncCodec
  alias YellowDog.ManagementCore

  @pubsub YellowDog.Console.PubSub
  @max_id_bytes 128
  @default_handshake_timeout_ms 5_000
  @default_max_candidates 256
  @default_max_candidates_per_netman 1
  @default_max_pending_requests_per_netman 128
  @call_margin_ms 1_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec begin_candidate(String.t(), pid()) ::
          :ok | {:error, :candidate_limit | :internal | :invalid}
  def begin_candidate(netman_id, channel_pid) do
    begin_candidate(__MODULE__, netman_id, channel_pid)
  end

  @doc false
  def begin_candidate(registry, netman_id, channel_pid) do
    safe_call(
      registry,
      {:begin_candidate, netman_id, channel_pid},
      {:error, :internal}
    )
  end

  @spec activate(String.t(), pid(), map(), map()) ::
          {:ok, pid() | nil} | {:error, :internal | :invalid | :not_candidate}
  def activate(netman_id, channel_pid, identity, status) do
    activate(__MODULE__, netman_id, channel_pid, identity, status)
  end

  @doc false
  def activate(registry, netman_id, channel_pid, identity, status) do
    safe_call(
      registry,
      {:activate, netman_id, channel_pid, identity, status},
      {:error, :internal}
    )
  end

  @doc false
  def activate_after_journal(netman_id, channel_pid, identity, status, encoded)
      when is_binary(encoded) do
    safe_call(
      __MODULE__,
      {:activate_after_journal, netman_id, channel_pid, identity, status, encoded},
      {:error, :internal}
    )
  end

  def activate_after_journal(_netman_id, _channel_pid, _identity, _status, _encoded),
    do: {:error, :invalid}

  @spec update_status(String.t(), pid(), map()) ::
          :ok | {:error, :internal | :invalid | :not_connected}
  def update_status(netman_id, channel_pid, status) do
    safe_call(
      __MODULE__,
      {:update_status, netman_id, channel_pid, status},
      {:error, :not_connected}
    )
  end

  @spec touch(String.t(), pid()) :: :ok | {:error, :not_connected}
  def touch(netman_id, channel_pid), do: touch(__MODULE__, netman_id, channel_pid)

  @doc false
  def touch(registry, netman_id, channel_pid) do
    safe_call(registry, {:touch, netman_id, channel_pid}, {:error, :not_connected})
  end

  @spec disconnect(String.t(), pid()) :: :ok | {:error, :not_connected}
  def disconnect(netman_id, channel_pid), do: disconnect(__MODULE__, netman_id, channel_pid)

  @doc false
  def disconnect(registry, netman_id, channel_pid) do
    safe_call(registry, {:disconnect, netman_id, channel_pid}, {:error, :not_connected})
  end

  @spec get(String.t()) :: {:ok, map()} | :error
  def get(netman_id), do: get(__MODULE__, netman_id)

  @doc false
  def get(registry, netman_id), do: safe_call(registry, {:get, netman_id}, :error)

  @spec list() :: [map()]
  def list, do: safe_call(__MODULE__, :list, [])

  @spec connected?(String.t()) :: boolean()
  def connected?(netman_id), do: connected?(__MODULE__, netman_id)

  @doc false
  def connected?(registry, netman_id) do
    safe_call(registry, {:connected?, netman_id}, false)
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
  def resolve_result(netman_id, channel_pid, result) do
    safe_call(
      __MODULE__,
      {:resolve_result, netman_id, channel_pid, result},
      {:error, :internal}
    )
  end

  @doc false
  def reconcile_journal(netman_id, channel_pid, encoded) when is_binary(encoded) do
    safe_call(
      __MODULE__,
      {:reconcile_journal, netman_id, channel_pid, encoded},
      {:error, :not_connected}
    )
  end

  def reconcile_journal(_netman_id, _channel_pid, _encoded), do: {:error, :invalid}

  @doc false
  def accept_config_state(netman_id, channel_pid, publication_sequence, encoded)
      when is_integer(publication_sequence) and publication_sequence > 0 and is_binary(encoded) do
    safe_call(
      __MODULE__,
      {:accept_config_state, netman_id, channel_pid, publication_sequence, encoded},
      {:error, :not_connected}
    )
  end

  def accept_config_state(_netman_id, _channel_pid, _publication_sequence, _encoded),
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
  def handle_call({:begin_candidate, netman_id, channel_pid}, _from, state) do
    key = {netman_id, channel_pid}

    cond do
      not valid_candidate?(netman_id, channel_pid) ->
        {:reply, {:error, :invalid}, state}

      Map.has_key?(state.candidates, key) ->
        {:reply, :ok, state}

      candidate_limit?(state, netman_id) ->
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
          netman_id: netman_id,
          channel_pid: channel_pid,
          monitor_ref: monitor_ref,
          timer_ref: timer_ref,
          timeout_tag: timeout_tag
        }

        state =
          state
          |> put_in([:candidates, key], candidate)
          |> put_in([:monitors, monitor_ref], {:candidate, netman_id, channel_pid})

        {:reply, :ok, state}
    end
  end

  def handle_call(
        {:activate, netman_id, channel_pid, identity, status},
        _from,
        state
      ) do
    key = {netman_id, channel_pid}

    with {:ok, candidate} <- Map.fetch(state.candidates, key),
         true <- valid_identity?(identity, netman_id),
         true <- valid_status?(status, netman_id) do
      {state, connection, replaced_pid} =
        activate_candidate(state, key, candidate, identity, status)

      announce_activation(connection, replaced_pid)
      {:reply, {:ok, replaced_pid}, state}
    else
      :error -> {:reply, {:error, :not_candidate}, state}
      false -> {:reply, {:error, :invalid}, state}
    end
  end

  def handle_call(
        {:activate_after_journal, netman_id, channel_pid, identity, status, encoded},
        _from,
        state
      ) do
    key = {netman_id, channel_pid}

    with {:ok, candidate} <- Map.fetch(state.candidates, key),
         true <- valid_identity?(identity, netman_id),
         true <- valid_status?(status, netman_id),
         {:ok, result} <- SyncCodec.reconcile_journal(encoded, :netman, netman_id),
         {:ok, pending_config} <- pending_config_message(result, netman_id, channel_pid) do
      {state, connection, replaced_pid} =
        activate_candidate(state, key, candidate, identity, status)

      announce_activation(connection, replaced_pid)
      deliver_pending_config(pending_config, connection)
      {:reply, {:ok, replaced_pid}, state}
    else
      :error -> {:reply, {:error, :not_candidate}, state}
      false -> {:reply, {:error, :invalid}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:update_status, netman_id, channel_pid, status}, _from, state) do
    case Map.get(state.connections, netman_id) do
      %{channel_pid: ^channel_pid, connected?: true} = connection ->
        with true <- valid_status?(status, netman_id),
             :ok <- persist_status(netman_id, status.state) do
          updated = %{connection | status: status, last_seen_at: DateTime.utc_now(:second)}
          state = put_in(state, [:connections, netman_id], updated)
          broadcast(netman_id, {:netman_connection, :updated, public_connection(updated)})
          {:reply, :ok, state}
        else
          false -> {:reply, {:error, :invalid}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      _not_active ->
        {:reply, {:error, :not_connected}, state}
    end
  end

  def handle_call({:touch, netman_id, channel_pid}, _from, state) do
    case Map.fetch(state.connections, netman_id) do
      {:ok, %{channel_pid: ^channel_pid, connected?: true} = connection} ->
        updated = %{connection | last_seen_at: DateTime.utc_now(:second)}
        state = put_in(state, [:connections, netman_id], updated)
        broadcast(netman_id, {:netman_connection, :updated, public_connection(updated)})
        {:reply, :ok, state}

      _not_active ->
        {:reply, {:error, :not_connected}, state}
    end
  end

  def handle_call({:disconnect, netman_id, channel_pid}, _from, state) do
    {state, disconnected?} = disconnect_pid(state, netman_id, channel_pid, true)
    if disconnected?, do: management_disconnected(netman_id)
    {:reply, :ok, state}
  end

  def handle_call({:get, netman_id}, _from, state) do
    reply =
      case Map.fetch(state.connections, netman_id) do
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
      |> Enum.sort_by(& &1.netman_id)

    {:reply, connections, state}
  end

  def handle_call({:connected?, netman_id}, _from, state) do
    connected? =
      case Map.get(state.connections, netman_id) do
        %{connected?: true, channel_pid: channel_pid} -> Process.alive?(channel_pid)
        _connection -> false
      end

    {:reply, connected?, state}
  end

  def handle_call({:request, summary, encoded, timeout}, from, state) do
    with {:ok, netman_id} <- request_netman(summary),
         {:ok, connection} <- active_connection(state, netman_id),
         :ok <- pending_capacity(connection, state.config),
         false <- Map.has_key?(connection.pending_requests, summary.request_id) do
      timeout_tag = make_ref()

      timer_ref =
        Process.send_after(
          self(),
          {:request_timeout, netman_id, summary.request_id, connection.channel_pid, timeout_tag},
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
      state = put_in(state, [:connections, netman_id], updated)
      send(connection.channel_pid, {:netman_management_push, encoded})
      {:noreply, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      true -> {:reply, {:error, :invalid}, state}
    end
  end

  def handle_call({:deliver, summary, encoded}, _from, state) do
    with {:ok, netman_id} <- request_netman(summary),
         {:ok, connection} <- active_connection(state, netman_id) do
      send(connection.channel_pid, {:netman_management_push, encoded})
      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:resolve_result, netman_id, channel_pid, result}, _from, state) do
    case matching_pending(state, netman_id, channel_pid, result) do
      {:ok, connection, pending} ->
        cancel_timer(pending.timer_ref)
        pending_requests = Map.delete(connection.pending_requests, pending.request_id)
        updated = %{connection | pending_requests: pending_requests}
        state = put_in(state, [:connections, netman_id], updated)
        GenServer.reply(pending.from, result.outcome)
        {:reply, :ok, state}

      :error ->
        {:reply, :ignored, state}
    end
  end

  def handle_call({:reconcile_journal, netman_id, channel_pid, encoded}, _from, state) do
    with {:ok, connection} <- active_connection(state, netman_id, channel_pid),
         {:ok, _result} <- SyncCodec.reconcile_journal(encoded, :netman, netman_id) do
      updated = %{connection | last_seen_at: DateTime.utc_now(:second)}
      state = put_in(state, [:connections, netman_id], updated)
      broadcast(netman_id, {:netman_connection, :updated, public_connection(updated)})
      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:accept_config_state, netman_id, channel_pid, publication_sequence, encoded},
        _from,
        state
      ) do
    with {:ok, _connection} <- active_connection(state, netman_id, channel_pid) do
      reply =
        case ManagementCore.accept_config_state_publication(
               :netman,
               netman_id,
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
    Enum.each(state.candidates, fn {_key, candidate} -> cancel_timer(candidate.timer_ref) end)
    Enum.each(Map.keys(state.monitors), &Process.demonitor(&1, [:flush]))

    Enum.each(state.connections, fn {_netman_id, connection} ->
      fail_pending(connection.pending_requests, :not_connected)
    end)

    {:reply, :ok, initial_state(state.config)}
  end

  @impl true
  def handle_info({:candidate_timeout, key, timeout_tag}, state) do
    case Map.get(state.candidates, key) do
      %{timeout_tag: ^timeout_tag} = candidate ->
        Process.demonitor(candidate.monitor_ref, [:flush])
        send(candidate.channel_pid, :netman_handshake_timeout)

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
        {:request_timeout, netman_id, request_id, channel_pid, timeout_tag},
        state
      ) do
    case Map.get(state.connections, netman_id) do
      %{
        channel_pid: ^channel_pid,
        pending_requests: %{^request_id => %{timeout_tag: ^timeout_tag} = pending}
      } = connection ->
        pending_requests = Map.delete(connection.pending_requests, request_id)
        updated = %{connection | pending_requests: pending_requests}
        state = put_in(state, [:connections, netman_id], updated)
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

      {{:candidate, netman_id, ^channel_pid}, monitors} ->
        key = {netman_id, channel_pid}

        candidates =
          case Map.pop(state.candidates, key) do
            {%{timer_ref: timer_ref}, candidates} ->
              cancel_timer(timer_ref)
              candidates

            {nil, candidates} ->
              candidates
          end

        {:noreply, %{state | candidates: candidates, monitors: monitors}}

      {{:active, netman_id, ^channel_pid}, monitors} ->
        state = %{state | monitors: monitors}
        {state, disconnected?} = disconnect_pid(state, netman_id, channel_pid, false)
        if disconnected?, do: management_disconnected(netman_id)
        {:noreply, state}
    end
  end

  defp validated_config(opts) do
    values = %{
      handshake_timeout_ms:
        option(
          opts,
          :handshake_timeout_ms,
          :netman_handshake_timeout_ms,
          @default_handshake_timeout_ms
        ),
      max_candidates:
        option(opts, :max_candidates, :netman_max_candidates, @default_max_candidates),
      max_candidates_per_netman:
        option(
          opts,
          :max_candidates_per_netman,
          :netman_max_candidates_per_netman,
          @default_max_candidates_per_netman
        ),
      max_pending_requests_per_netman:
        option(
          opts,
          :max_pending_requests_per_netman,
          :netman_max_pending_requests_per_netman,
          @default_max_pending_requests_per_netman
        )
    }

    if Enum.all?(values, fn {_key, value} -> is_integer(value) and value > 0 end) do
      {:ok, values}
    else
      {:stop, {:invalid_netman_connections_config, values}}
    end
  end

  defp option(opts, option_key, config_key, default) do
    Keyword.get(opts, option_key, Application.get_env(:yellow_dog_console, config_key, default))
  end

  defp candidate_limit?(state, netman_id) do
    map_size(state.candidates) >= state.config.max_candidates or
      Enum.count(state.candidates, fn {{candidate_id, _pid}, _candidate} ->
        candidate_id == netman_id
      end) >= state.config.max_candidates_per_netman
  end

  defp replace_active(state, netman_id) do
    case Map.get(state.connections, netman_id) do
      %{connected?: true, channel_pid: old_pid, monitor_ref: monitor_ref} = connection ->
        Process.demonitor(monitor_ref, [:flush])
        fail_pending(connection.pending_requests, :not_connected)
        {%{state | monitors: Map.delete(state.monitors, monitor_ref)}, old_pid}

      _connection ->
        {state, nil}
    end
  end

  defp activate_candidate(state, key, candidate, identity, status) do
    cancel_timer(candidate.timer_ref)
    {state, replaced_pid} = replace_active(state, candidate.netman_id)
    now = DateTime.utc_now(:second)

    connection = %{
      netman_id: candidate.netman_id,
      channel_pid: candidate.channel_pid,
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
      |> put_in([:connections, candidate.netman_id], connection)
      |> put_in(
        [:monitors, candidate.monitor_ref],
        {:active, candidate.netman_id, candidate.channel_pid}
      )

    {state, connection, replaced_pid}
  end

  defp announce_activation(connection, replaced_pid) do
    if replaced_pid,
      do: send(replaced_pid, {:netman_connection_replaced, connection.channel_pid})

    broadcast(
      connection.netman_id,
      {:netman_connection, :online, public_connection(connection)}
    )
  end

  defp pending_config_message(%{pending_config: nil}, _netman_id, _channel_pid),
    do: {:ok, nil}

  defp pending_config_message(%{pending_config: version}, netman_id, channel_pid) do
    with {:ok, encoded, summary} <- SyncCodec.encode_config_version_delivery(version),
         true <- summary.target_type == :netman,
         true <- summary.target_id == netman_id,
         true <- Process.alive?(channel_pid) do
      {:ok, encoded}
    else
      false -> {:error, :not_connected}
      {:error, _reason} -> {:error, :internal}
      _invalid -> {:error, :internal}
    end
  end

  defp pending_config_message(_result, _netman_id, _channel_pid), do: {:error, :internal}

  defp deliver_pending_config(nil, _connection), do: :ok

  defp deliver_pending_config(encoded, connection) when is_binary(encoded) do
    send(connection.channel_pid, {:netman_management_push, encoded})
    :ok
  end

  defp disconnect_pid(state, netman_id, channel_pid, demonitor?) do
    candidate_key = {netman_id, channel_pid}

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
        disconnect_active(state, netman_id, channel_pid, demonitor?)
    end
  end

  defp disconnect_active(state, netman_id, channel_pid, demonitor?) do
    case Map.get(state.connections, netman_id) do
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
          | connections: Map.put(state.connections, netman_id, updated),
            monitors: Map.delete(state.monitors, monitor_ref)
        }

        broadcast(netman_id, {:netman_connection, :offline, public_connection(updated)})
        {state, true}

      _not_active ->
        {state, false}
    end
  end

  defp active_connection(state, netman_id) do
    case Map.get(state.connections, netman_id) do
      %{connected?: true, channel_pid: channel_pid} = connection ->
        if Process.alive?(channel_pid), do: {:ok, connection}, else: {:error, :not_connected}

      _connection ->
        {:error, :not_connected}
    end
  end

  defp active_connection(state, netman_id, channel_pid) do
    case Map.get(state.connections, netman_id) do
      %{connected?: true, channel_pid: ^channel_pid} = connection ->
        if Process.alive?(channel_pid), do: {:ok, connection}, else: {:error, :not_connected}

      _connection ->
        {:error, :not_connected}
    end
  end

  defp pending_capacity(connection, config) do
    if map_size(connection.pending_requests) < config.max_pending_requests_per_netman,
      do: :ok,
      else: {:error, :request_limit}
  end

  defp request_netman(%{
         target_type: :netman,
         target_id: netman_id,
         request_id: request_id,
         operation: operation
       })
       when is_binary(netman_id) and is_binary(request_id) and is_binary(operation),
       do: {:ok, netman_id}

  defp request_netman(_summary), do: {:error, :invalid}

  defp matching_pending(state, netman_id, channel_pid, result) do
    with %{
           connected?: true,
           channel_pid: ^channel_pid,
           pending_requests: pending_requests
         } = connection <- Map.get(state.connections, netman_id),
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

  defp persist_status(netman_id, status) do
    case ManagementCore.update_netman_status(netman_id, status) do
      {:ok, _netman} -> :ok
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

  defp broadcast(netman_id, message) do
    Phoenix.PubSub.broadcast(@pubsub, "management:netman:#{netman_id}", message)
  catch
    :exit, _reason -> :ok
  end

  defp management_disconnected(netman_id) do
    ManagementCore.runtime_disconnected(:netman, netman_id)
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

  defp valid_candidate?(netman_id, channel_pid) do
    valid_id?(netman_id) and is_pid(channel_pid) and Process.alive?(channel_pid)
  end

  defp valid_identity?(
         %{
           target_type: :netman,
           id: netman_id,
           name: name,
           version: version,
           profile: profile,
           capabilities: capabilities,
           config_revision: config_revision
         },
         netman_id
       ) do
    is_binary(name) and is_binary(version) and is_binary(profile) and
      is_list(capabilities) and is_binary(config_revision)
  end

  defp valid_identity?(_identity, _netman_id), do: false

  defp valid_status?(
         %{
           target_type: :netman,
           target_id: netman_id,
           state: state,
           details: details,
           observed_at: %DateTime{}
         },
         netman_id
       ) do
    state in [:online, :offline, :degraded] and is_map(details)
  end

  defp valid_status?(_status, _netman_id), do: false

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
