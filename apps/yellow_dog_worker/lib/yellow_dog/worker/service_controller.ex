defmodule YellowDog.Worker.ServiceController do
  @moduledoc "Serializes a single service's preparation, lifecycle and runtime repair."
  use GenServer
  alias YellowDog.Worker.DnsAdapter

  # This is the entire executable service allowlist; no input becomes an atom/module.
  @adapters %{"dns" => DnsAdapter}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def apply(pid, service, resources),
    do: GenServer.call(pid, {:apply, service, resources}, 30_000)

  def status(pid), do: GenServer.call(pid, :status)
  def quiesce(pid), do: GenServer.call(pid, :quiesce, 10_000)

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       service: nil,
       resources: [],
       runtime: nil,
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
    stop_runtime(state)
    {:reply, :ok, %{state | runtime: nil, suspended: true}}
  end

  def handle_call(:status, _from, state) do
    observation = observation(state)
    stopped = state.service && state.service["desired_state"] == "stopped"

    {:reply,
     %{
       desired: state.service,
       prepared_resources: identities(state.resources),
       process: alive?(state.runtime),
       runtime_pid: state.runtime,
       ready: if(stopped, do: not alive?(state.runtime), else: observation[:ready] == true),
       active: observation,
       starts: state.starts,
       error: state.error
     }, state}
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, %{runtime: pid} = state) do
    Process.send_after(self(), :repair, 200)
    {:noreply, %{state | runtime: nil, error: {:runtime_exit, reason}}}
  end

  def handle_info(:repair, %{suspended: true} = state), do: {:noreply, state}

  def handle_info(:repair, state) do
    {_reply, state} = install(state.service, state.resources, state)
    if state.error, do: Process.send_after(self(), :repair, 1000)
    {:noreply, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: stop_runtime(state)

  defp install(nil, _resources, state), do: {:ok, state}

  defp install(service, resources, state) do
    case Map.fetch(@adapters, service["type"]) do
      {:ok, adapter} ->
        next = %{
          state
          | service: service,
            resources: resources,
            adapter: adapter,
            suspended: false
        }

        cond do
          service["desired_state"] == "stopped" ->
            stop_runtime(state)
            {:ok, %{next | runtime: nil, error: nil}}

          alive?(state.runtime) and state.service == service and state.resources == resources and
            observation(state)[:ready] == true and
              observation(state)[:loaded_resources] == identities(resources) ->
            {:ok, %{next | error: nil}}

          alive?(state.runtime) and state.service["config"] == service["config"] ->
            case adapter.update(state.runtime, service, resources) do
              :ok -> {:ok, %{next | error: nil}}
              {:error, reason} -> {{:error, reason}, %{next | error: reason}}
            end

          true ->
            stop_runtime(state)

            case adapter.start_link(service: service, resources: resources) do
              {:ok, pid} ->
                {:ok, %{next | runtime: pid, error: nil, starts: state.starts + 1}}

              {:error, reason} ->
                {{:error, reason}, %{next | runtime: nil, error: reason}}
            end
        end

      :error ->
        {{:error, :unsupported_service}, %{state | error: :unsupported_service}}
    end
  catch
    :exit, reason -> {{:error, reason}, %{state | error: reason}}
  end

  defp observation(%{runtime: pid, adapter: adapter}) when is_pid(pid) do
    if Process.alive?(pid), do: adapter.status(pid), else: %{}
  catch
    :exit, _ -> %{}
  end

  defp observation(_), do: %{}
  defp alive?(pid), do: is_pid(pid) and Process.alive?(pid)

  defp stop_runtime(%{runtime: pid}) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5000)
  catch
    :exit, _ -> :ok
  end

  defp stop_runtime(_), do: :ok
  defp identities(resources), do: Enum.map(resources, &Map.take(&1, ~w(id version digest)))
end
