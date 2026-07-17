defmodule YellowDog.ServerControlFake do
  @moduledoc false

  use Agent

  @services [:dns, :dhcpv4, :dhcpv6, :mdns, :netboot, :identity]

  def start_link(_opts) do
    Agent.start_link(
      fn ->
        %{
          responses: %{},
          current: %{},
          adapter_calls: [],
          dependency_calls: [],
          available: Map.new(@services, &{&1, true}),
          enabled: Map.new(@services, &{&1, true})
        }
      end,
      name: __MODULE__
    )
  end

  def configure(route, opts) do
    Agent.update(__MODULE__, fn state ->
      state
      |> maybe_put(:responses, route, opts, :response)
      |> maybe_put(:current, route, opts, :current)
    end)
  end

  def set_available(service, available?) when is_boolean(available?) do
    Agent.update(__MODULE__, &put_in(&1, [:available, service], available?))
  end

  def set_enabled(service, enabled?) when is_boolean(enabled?) do
    Agent.update(__MODULE__, &put_in(&1, [:enabled, service], enabled?))
  end

  def take_calls do
    Agent.get_and_update(__MODULE__, fn state ->
      {Enum.reverse(state.adapter_calls), %{state | adapter_calls: []}}
    end)
  end

  def take_dependency_calls do
    Agent.get_and_update(__MODULE__, fn state ->
      {Enum.reverse(state.dependency_calls), %{state | dependency_calls: []}}
    end)
  end

  def current(route, operation, payload) do
    action =
      Agent.get_and_update(__MODULE__, fn state ->
        action = Map.get(state.current, route, {:ok, :missing})
        call = {route, :current, operation, payload}
        {action, %{state | adapter_calls: [call | state.adapter_calls]}}
      end)

    run(action)
  end

  def dispatch(route, operation, payload) do
    action =
      Agent.get_and_update(__MODULE__, fn state ->
        action = Map.get(state.responses, route, {:ok, %{}})
        call = {route, :dispatch, operation, payload}
        {action, %{state | adapter_calls: [call | state.adapter_calls]}}
      end)

    run_dispatch(route, action)
  end

  def fetch_service(service) do
    Agent.get_and_update(__MODULE__, fn state ->
      call = {:service_registry, :fetch, service}

      result =
        case Map.fetch(state.available, service) do
          {:ok, available?} -> {:ok, %{name: service, available?: available?}}
          :error -> :error
        end

      {result, %{state | dependency_calls: [call | state.dependency_calls]}}
    end)
  end

  def resolve_profile do
    Agent.get_and_update(__MODULE__, fn state ->
      call = {:profile_resolver, :resolve}
      {%{services: state.enabled}, %{state | dependency_calls: [call | state.dependency_calls]}}
    end)
  end

  defp maybe_put(state, state_key, route, opts, option_key) do
    if Keyword.has_key?(opts, option_key) do
      put_in(state, [state_key, route], Keyword.fetch!(opts, option_key))
    else
      state
    end
  end

  defp run_dispatch(route, {:block, owner, next_current, result}) do
    send(owner, {:dispatch_blocked, route, self()})

    receive do
      {:release_dispatch, ^route} ->
        Agent.update(__MODULE__, &put_in(&1, [:current, route], {:ok, next_current}))
        run(result)
    after
      2_000 -> exit(:dispatch_release_timeout)
    end
  end

  defp run_dispatch(_route, action), do: run(action)

  defp run({:raise, reason}), do: raise(reason)
  defp run({:throw, reason}), do: throw(reason)
  defp run({:exit, reason}), do: exit(reason)
  defp run(result), do: result
end

defmodule YellowDog.ServerControlFake.ServiceRegistry do
  @moduledoc false
  def fetch(service), do: YellowDog.ServerControlFake.fetch_service(service)
end

defmodule YellowDog.ServerControlFake.ProfileResolver do
  @moduledoc false
  def resolve, do: YellowDog.ServerControlFake.resolve_profile()
end

defmodule YellowDog.ServerControlFake.Adapter.Runtime do
  @moduledoc false
  def current(operation, payload),
    do: YellowDog.ServerControlFake.current(:runtime, operation, payload)

  def dispatch(operation, payload),
    do: YellowDog.ServerControlFake.dispatch(:runtime, operation, payload)
end

defmodule YellowDog.ServerControlFake.Adapter.Dns do
  @moduledoc false
  def current(operation, payload),
    do: YellowDog.ServerControlFake.current(:dns, operation, payload)

  def dispatch(operation, payload),
    do: YellowDog.ServerControlFake.dispatch(:dns, operation, payload)
end

defmodule YellowDog.ServerControlFake.Adapter.Dhcp do
  @moduledoc false
  def current(operation, payload),
    do: YellowDog.ServerControlFake.current(:dhcp, operation, payload)

  def dispatch(operation, payload),
    do: YellowDog.ServerControlFake.dispatch(:dhcp, operation, payload)
end

defmodule YellowDog.ServerControlFake.Adapter.Dhcpv4 do
  @moduledoc false
  def current(operation, payload),
    do: YellowDog.ServerControlFake.current(:dhcpv4, operation, payload)

  def dispatch(operation, payload),
    do: YellowDog.ServerControlFake.dispatch(:dhcpv4, operation, payload)
end

defmodule YellowDog.ServerControlFake.Adapter.Dhcpv6 do
  @moduledoc false
  def current(operation, payload),
    do: YellowDog.ServerControlFake.current(:dhcpv6, operation, payload)

  def dispatch(operation, payload),
    do: YellowDog.ServerControlFake.dispatch(:dhcpv6, operation, payload)
end

defmodule YellowDog.ServerControlFake.Adapter.Mdns do
  @moduledoc false
  def current(operation, payload),
    do: YellowDog.ServerControlFake.current(:mdns, operation, payload)

  def dispatch(operation, payload),
    do: YellowDog.ServerControlFake.dispatch(:mdns, operation, payload)
end

defmodule YellowDog.ServerControlFake.Adapter.Netboot do
  @moduledoc false
  def current(operation, payload),
    do: YellowDog.ServerControlFake.current(:netboot, operation, payload)

  def dispatch(operation, payload),
    do: YellowDog.ServerControlFake.dispatch(:netboot, operation, payload)
end

defmodule YellowDog.ServerControlFake.Adapter.Identity do
  @moduledoc false
  def current(operation, payload),
    do: YellowDog.ServerControlFake.current(:identity, operation, payload)

  def dispatch(operation, payload),
    do: YellowDog.ServerControlFake.dispatch(:identity, operation, payload)
end

defmodule YellowDog.ServerControlFake.Adapter.Settings do
  @moduledoc false
  def current(operation, payload),
    do: YellowDog.ServerControlFake.current(:settings, operation, payload)

  def dispatch(operation, payload),
    do: YellowDog.ServerControlFake.dispatch(:settings, operation, payload)
end
