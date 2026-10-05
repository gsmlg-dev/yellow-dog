defmodule YellowDog.Worker.ServiceController do
  @moduledoc "Serializes a single service's preparation, lifecycle and runtime repair."
  use GenServer
  alias YellowDog.Worker.{DnsAdapter, OwnedShutdown}

  # This is the entire executable service allowlist; no input becomes an atom/module.
  @adapters %{"dns" => DnsAdapter}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def apply(pid, service, resources),
    do: GenServer.call(pid, {:apply, service, resources}, 30_000)

  def status(pid), do: GenServer.call(pid, :status)
  def quiesce(pid), do: GenServer.call(pid, :quiesce, 10_000)

  def validate(service, resources) do
    case Map.fetch(@adapters, service["type"]) do
      {:ok, adapter} -> adapter.validate(service, resources)
      :error -> {:error, :unsupported_service}
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       service: nil,
       resources: [],
       runtime: nil,
       owned: [],
       applied: nil,
       applied_resources: nil,
       owner: hd(Process.get(:"$ancestors")),
       observer: Keyword.get(opts, :observer),
       adapter: nil,
       error: nil,
       starts: 0,
       suspended: false
     }}
  end

  @impl true
  def handle_call({:apply, service, resources}, _from, state) do
    {reply, state} = install(service, resources, state)
    {:reply, reply, state}
  end

  def handle_call(:quiesce, _from, state) do
    {result, state} = stop_runtime(state)
    {:reply, result, %{state | suspended: true}}
  end

  def handle_call(:status, _from, state) do
    observation = observation(state)
    stopped = state.service && state.service["desired_state"] == "stopped"

    {:reply,
     %{
       desired: state.service,
       applied: state.applied,
       applied_resources: state.applied_resources,
       prepared_resources: identities(state.resources),
       process: alive?(state.runtime),
       runtime_pid: state.runtime,
       owned_pids: state.owned,
       ready:
         state.error == nil and state.service == state.applied and
           identities(state.resources) == state.applied_resources and
           if(stopped,
             do: not Enum.any?(state.owned, &alive?/1),
             else:
               observation[:ready] == true and
                 observation[:loaded_resources] == state.applied_resources
           ),
       active: observation,
       starts: state.starts,
       error: state.error
     }, state}
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, %{runtime: pid} = state) do
    Process.send_after(self(), :repair, 200)
    {:noreply, %{state | error: {:runtime_exit, reason}}}
  end

  def handle_info(:repair, %{suspended: true} = state), do: {:noreply, state}

  def handle_info(:repair, %{observer: observer} = state) when is_pid(observer) do
    send(observer, {:repair_service, self()})
    {:noreply, state}
  end

  def handle_info(:repair, state) do
    {_reply, state} = install(state.service, state.resources, state)
    if state.error, do: Process.send_after(self(), :repair, 1000)
    {:noreply, state}
  end

  def handle_info({:EXIT, pid, reason}, %{owner: pid} = state),
    do: {:stop, {:owner_exited, reason}, state}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    case stop_runtime(state) do
      {:ok, _state} -> :ok
      {{:error, reason}, _state} -> exit(reason)
    end
  end

  defp install(nil, _resources, state), do: {:ok, state}

  defp install(service, resources, state) do
    with :ok <- validate(service, resources) do
      adapter = Map.fetch!(@adapters, service["type"])

      next = %{
        state
        | service: service,
          resources: resources,
          adapter: adapter,
          suspended: false
      }

      cond do
        service["desired_state"] == "stopped" ->
          case stop_runtime(next) do
            {:ok, stopped} ->
              {:ok,
               %{stopped | applied: service, applied_resources: identities(resources), error: nil}}

            {error, stopped} ->
              {error, stopped}
          end

        alive?(state.runtime) and state.service == service and state.resources == resources and
          observation(state)[:ready] == true and
            observation(state)[:loaded_resources] == identities(resources) ->
          confirm_runtime(next)

        alive?(state.runtime) and state.service["config"] == service["config"] ->
          case adapter.update(state.runtime, service, resources) do
            :ok -> confirm_runtime(next)
            {:error, reason} -> {{:error, reason}, %{next | error: reason}}
          end

        true ->
          case stop_runtime(next) do
            {:ok, stopped} -> start_runtime(stopped)
            {error, stopped} -> {error, stopped}
          end
      end
    else
      {:error, reason} ->
        {{:error, reason}, %{state | error: reason}}
    end
  catch
    :exit, reason -> {{:error, reason}, %{state | error: reason}}
  end

  defp observation(%{runtime: pid, adapter: adapter}) when is_pid(pid) do
    if Process.alive?(pid), do: adapter.status(pid), else: %{}
  catch
    :exit, reason -> %{ready: false, error: {:runtime_unavailable, reason}}
  end

  defp observation(_), do: %{}
  defp alive?(pid), do: is_pid(pid) and Process.alive?(pid)

  defp start_runtime(state) do
    case state.adapter.start_link(service: state.service, resources: state.resources) do
      {:ok, pid} ->
        started = %{state | runtime: pid, owned: [pid], starts: state.starts + 1}
        notify_ownership(started)

        confirm_runtime(started)

      {:error, reason} ->
        {{:error, reason}, %{state | error: reason}}
    end
  end

  defp confirm_runtime(state) do
    current = observation(state)
    expected = identities(state.resources)
    observed = %{state | owned: Map.get(current, :owned_pids, state.owned)}
    notify_ownership(observed)

    cond do
      current[:ready] != true ->
        reason = {:runtime_not_ready, current}
        {{:error, reason}, %{observed | error: reason}}

      current[:loaded_resources] != expected ->
        reason = {:loaded_resource_mismatch, expected, current[:loaded_resources]}
        {{:error, reason}, %{observed | error: reason}}

      true ->
        {:ok, %{observed | applied: state.service, applied_resources: expected, error: nil}}
    end
  end

  defp stop_runtime(state) do
    case OwnedShutdown.stop(state.runtime, state.owned) do
      :ok ->
        stopped = %{state | runtime: nil, owned: [], error: nil}
        notify_ownership(stopped)
        {:ok, stopped}

      {:error, {:shutdown_failed, _result, remaining} = reason} = error ->
        failed = %{state | error: reason, owned: Enum.uniq(state.owned ++ remaining)}
        notify_ownership(failed)
        {error, failed}
    end
  end

  defp notify_ownership(%{observer: observer, owned: owned}) when is_pid(observer),
    do: send(observer, {:runtime_ownership, self(), owned})

  defp notify_ownership(_state), do: :ok

  defp identities(resources), do: Enum.map(resources, &Map.take(&1, ~w(id version digest)))
end
