defmodule Abyss.DatagramDispatcher do
  @moduledoc """
  Behaviour for an opt-in persistent datagram dispatcher.

  The callback owns protocol state (for example a QUIC endpoint), while
  `Abyss.Dispatcher` owns admission, route generations and the shared socket
  writer. The callback must never close the socket or call back into the
  blocked listener.
  """

  @callback init(context :: map(), opts :: keyword()) :: {:ok, state :: term()} | {:error, term()}

  @callback handle_datagram(
              remote :: {term(), non_neg_integer()},
              bytes :: binary(),
              received_at :: integer(),
              context :: map()
            ) ::
              {:ok, state :: term()}
              | {:drop, reason :: term(), state :: term()}
              | {:new, keys :: [term()], pid(), state :: term()}
              | {:route, keys :: [term()], pid(), state :: term()}

  @callback terminate(reason :: term(), state :: term()) :: term()
  @optional_callbacks terminate: 2
end

defmodule Abyss.Dispatcher do
  @moduledoc """
  Persistent bounded dispatcher used before Abyss's legacy handler path.

  One dispatcher is created per listener. Calls are serialized in this process,
  and connection processes are monitored so all CID routes are removed on
  death. Egress uses a separate bounded writer because the listener may be
  blocked in `recv(:infinity)`.
  """

  use GenServer

  defmodule SendCapability do
    @enforce_keys [:writer, :generation]
    defstruct [:writer, :generation]
  end

  defmodule Writer do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    def enqueue(pid, capability, remote, bytes, timeout \\ 100) do
      try do
        GenServer.call(pid, {:enqueue, capability, remote, bytes}, timeout)
      catch
        :exit, {:timeout, _} -> {:error, :writer_timeout}
        :exit, reason -> {:error, reason}
      end
    end

    def await(pid, capability, ref, timeout \\ 100)
        when is_reference(ref) do
      try do
        GenServer.call(pid, {:await, capability, ref}, timeout)
      catch
        :exit, {:timeout, _} -> {:error, :writer_timeout}
        :exit, reason -> {:error, reason}
      end
    end

    @impl true
    def init(opts) do
      Process.flag(:trap_exit, true)

      {:ok,
       %{
         socket: Keyword.fetch!(opts, :socket),
         transport: Keyword.fetch!(opts, :transport),
         owner: Keyword.fetch!(opts, :owner),
         generation: Keyword.fetch!(opts, :generation),
         max_queue: Keyword.fetch!(opts, :max_queue),
         max_bytes: Keyword.fetch!(opts, :max_bytes),
         queue: :queue.new(),
         queue_bytes: 0,
         sending: false,
         refs: %{},
         waiters: %{},
         results: %{},
         max_results: 256
       }}
    end

    @impl true
    def handle_call(
          {:enqueue, %SendCapability{writer: writer, generation: generation}, remote, bytes},
          _from,
          state
        )
        when writer == self() and generation == state.generation and is_binary(bytes) and
               byte_size(bytes) > 0 do
      if :queue.len(state.queue) + if(state.sending, do: 1, else: 0) >= state.max_queue do
        {:reply, {:error, :queue_limit}, state}
      else
        size = byte_size(bytes)

        if state.queue_bytes + size > state.max_bytes do
          {:reply, {:error, :queue_bytes_limit}, state}
        else
          ref = make_ref()
          item = {ref, remote, bytes}

          next = %{
            state
            | queue: :queue.in(item, state.queue),
              queue_bytes: state.queue_bytes + size
          }

          {:reply, {:ok, ref}, maybe_send(next)}
        end
      end
    end

    def handle_call({:enqueue, %SendCapability{}, _remote, _bytes}, _from, state),
      do: {:reply, {:error, :stale_generation}, state}

    def handle_call({:enqueue, _capability, _remote, _bytes}, _from, state),
      do: {:reply, {:error, :invalid_send}, state}

    def handle_call(
          {:await, %SendCapability{writer: writer, generation: generation}, ref},
          from,
          state
        )
        when writer == self() and generation == state.generation do
      case Map.pop(state.results, ref) do
        {nil, _results} -> {:noreply, %{state | waiters: Map.put(state.waiters, ref, from)}}
        {result, results} -> {:reply, result, %{state | results: results}}
      end
    end

    def handle_call({:await, %SendCapability{}, _ref}, _from, state),
      do: {:reply, {:error, :stale_generation}, state}

    def handle_call({:await, _capability, _ref}, _from, state),
      do: {:reply, {:error, :invalid_send}, state}

    @impl true
    def handle_info({:send_result, ref, result}, state) do
      completed = normalize_result(result)

      send(
        state.owner,
        {:abyss_dispatcher_send, state.generation, ref, completed, monotonic_time()}
      )

      state = %{state | sending: false, refs: Map.delete(state.refs, ref)}

      case Map.pop(state.waiters, ref) do
        {nil, waiters} ->
          results =
            if map_size(state.results) < state.max_results,
              do: Map.put(state.results, ref, completed),
              else: state.results

          {:noreply,
           maybe_send(%{
             state
             | waiters: waiters,
               results: results
           })}

        {from, waiters} ->
          GenServer.reply(from, completed)
          {:noreply, maybe_send(%{state | waiters: waiters})}
      end
    end

    defp maybe_send(%{sending: true} = state), do: state

    defp maybe_send(state) do
      case :queue.out(state.queue) do
        {{:value, {ref, remote, bytes}}, queue} ->
          result =
            try do
              state.transport.send(state.socket, elem(remote, 0), elem(remote, 1), bytes)
            rescue
              error -> {:error, error}
            catch
              kind, reason -> {:error, {kind, reason}}
            end

          send(self(), {:send_result, ref, result})

          %{
            state
            | queue: queue,
              queue_bytes: state.queue_bytes - byte_size(bytes),
              sending: true,
              refs: Map.put(state.refs, ref, {remote, bytes})
          }

        {:empty, _} ->
          state
      end
    end

    defp monotonic_time, do: System.monotonic_time(:microsecond)
    defp normalize_result(:ok), do: {:ok, monotonic_time()}
    defp normalize_result({:ok, at}) when is_integer(at), do: {:ok, at}
    defp normalize_result({:error, _} = error), do: error
    defp normalize_result(other), do: {:error, {:invalid_send_result, other}}
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def dispatch(pid, remote, bytes, received_at, timeout \\ 100) do
    try do
      GenServer.call(pid, {:datagram, remote, bytes, received_at}, timeout)
    catch
      :exit, {:timeout, _} -> {:error, :dispatcher_overloaded}
      :exit, reason -> {:error, reason}
    end
  end

  def send(capability, remote, bytes, timeout \\ 100)
      when is_struct(capability, SendCapability) and is_tuple(remote) and is_binary(bytes) and
             byte_size(bytes) > 0 do
    Writer.enqueue(capability.writer, capability, remote, bytes, timeout)
  end

  def send_receipt(capability, remote, bytes, timeout \\ 100)
      when is_struct(capability, SendCapability) and is_tuple(remote) and is_binary(bytes) and
             byte_size(bytes) > 0 do
    with {:ok, ref} <- send(capability, remote, bytes, timeout) do
      Writer.await(capability.writer, capability, ref, timeout)
    end
  end

  def routes(pid), do: GenServer.call(pid, :routes)

  @impl true
  def init(opts) do
    module = Keyword.fetch!(opts, :module)
    module_opts = Keyword.get(opts, :module_options, [])
    generation = make_ref()

    Process.flag(:trap_exit, true)

    with {:ok, writer} <-
           Writer.start_link(
             socket: Keyword.fetch!(opts, :socket),
             transport: Keyword.fetch!(opts, :transport),
             owner: self(),
             generation: generation,
             max_queue: Keyword.fetch!(opts, :max_queue),
             max_bytes: Keyword.fetch!(opts, :max_bytes)
           ),
         {:ok, callback_state} <-
           module.init(
             %{
               local_info: Keyword.fetch!(opts, :local_info),
               generation: generation,
               send: %SendCapability{writer: writer, generation: generation},
               send_fun: fn remote, bytes ->
                 send_receipt(
                   %SendCapability{writer: writer, generation: generation},
                   remote,
                   bytes
                 )
               end
             },
             module_opts
           ) do
      {:ok,
       %{
         module: module,
         callback_state: callback_state,
         listener: Keyword.get(opts, :listener),
         writer: writer,
         generation: generation,
         send: %SendCapability{writer: writer, generation: generation},
         routes: %{},
         monitors: %{}
       }}
    end
  end

  @impl true
  def handle_call(:routes, _from, state), do: {:reply, state.routes, state}

  def handle_call({:datagram, remote, bytes, received_at}, _from, state)
      when is_tuple(remote) and is_binary(bytes) do
    context = %{
      local: self(),
      generation: state.generation,
      send: state.send,
      send_fun: fn remote, bytes -> send_receipt(state.send, remote, bytes) end,
      routes: state.routes,
      state: state.callback_state
    }

    result =
      try do
        state.module.handle_datagram(remote, bytes, received_at, context)
      rescue
        error -> {:drop, {:callback_error, error}, state.callback_state}
      catch
        kind, reason -> {:drop, {:callback_error, {kind, reason}}, state.callback_state}
      end

    case result do
      {:ok, callback_state} ->
        {:reply, :ok, %{state | callback_state: callback_state}}

      {:drop, reason, callback_state} ->
        {:reply, {:dropped, reason}, %{state | callback_state: callback_state}}

      {:new, keys, pid, callback_state} ->
        {:reply, :ok, register(state, keys, pid, remote, callback_state)}

      {:route, keys, pid, callback_state} ->
        {:reply, :ok, register(state, keys, pid, remote, callback_state)}

      _ ->
        {:reply, {:error, :invalid_dispatch_result}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    {keys, monitors} =
      Enum.reduce(state.routes, {[], state.monitors}, fn {key, route}, {removed, mons} ->
        if route.monitor == monitor,
          do: {[key | removed], Map.delete(mons, monitor)},
          else: {removed, mons}
      end)

    {:noreply, %{state | routes: Map.drop(state.routes, keys), monitors: monitors}}
  end

  def handle_info({:abyss_dispatcher_send, _generation, _ref, _result, _at}, state),
    do: {:noreply, state}

  def handle_info({:EXIT, writer, reason}, %{writer: writer} = state) do
    if is_pid(state.listener), do: send(state.listener, {:abyss_dispatcher_writer_error, reason})

    {:noreply,
     %{
       state
       | writer: nil,
         send: %SendCapability{writer: writer, generation: :stale},
         callback_state: state.callback_state
     }}
  end

  def handle_info({:abyss_dispatcher_writer_error, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    if function_exported?(state.module, :terminate, 2),
      do: state.module.terminate(reason, state.callback_state)

    if is_pid(state.writer), do: GenServer.stop(state.writer, :normal, 1_000)
    :ok
  end

  defp register(state, keys, pid, remote, callback_state) when is_pid(pid) and is_list(keys) do
    monitor =
      keys
      |> Enum.find_value(fn key ->
        case Map.get(state.routes, key) do
          %{pid: ^pid, monitor: existing} -> existing
          _ -> nil
        end
      end) || Process.monitor(pid)

    route = %{pid: pid, remote: remote, generation: state.generation, monitor: monitor}
    routes = Enum.reduce(keys, state.routes, &Map.put(&2, &1, route))

    %{
      state
      | routes: routes,
        monitors: Map.put(state.monitors, monitor, keys),
        callback_state: callback_state
    }
  end

  defp register(state, _keys, _pid, _remote, callback_state),
    do: %{state | callback_state: callback_state}
end
