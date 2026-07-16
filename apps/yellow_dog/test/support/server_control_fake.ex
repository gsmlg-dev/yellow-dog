defmodule YellowDog.ServerControlFake do
  @moduledoc false

  use Agent

  def start_link(_opts) do
    Agent.start_link(
      fn -> %{responses: %{}, current: %{}, calls: []} end,
      name: __MODULE__
    )
  end

  def configure(domain, opts) do
    Agent.update(__MODULE__, fn state ->
      state
      |> put_in([:responses, domain], Keyword.get(opts, :response, {:ok, %{}}))
      |> put_in([:current, domain], Keyword.get(opts, :current, {:ok, :missing}))
    end)
  end

  def take_calls do
    Agent.get_and_update(__MODULE__, fn state ->
      {Enum.reverse(state.calls), %{state | calls: []}}
    end)
  end

  def current(domain, operation, payload) do
    action =
      Agent.get_and_update(__MODULE__, fn state ->
        action = Map.get(state.current, domain, {:ok, :missing})
        {action, %{state | calls: [{domain, :current, operation, payload} | state.calls]}}
      end)

    run(action)
  end

  def dispatch(domain, operation, payload) do
    action =
      Agent.get_and_update(__MODULE__, fn state ->
        action = Map.get(state.responses, domain, {:ok, %{}})
        {action, %{state | calls: [{domain, :dispatch, operation, payload} | state.calls]}}
      end)

    run(action)
  end

  defp run({:raise, reason}), do: raise(reason)
  defp run({:throw, reason}), do: throw(reason)
  defp run({:exit, reason}), do: exit(reason)
  defp run(result), do: result
end

defmodule YellowDog.Server.Control.Runtime do
  @moduledoc false
  def current(operation, payload),
    do: YellowDog.ServerControlFake.current(:runtime, operation, payload)

  def dispatch(operation, payload),
    do: YellowDog.ServerControlFake.dispatch(:runtime, operation, payload)
end

defmodule YellowDog.Server.Control.Dns do
  @moduledoc false
  def current(operation, payload),
    do: YellowDog.ServerControlFake.current(:dns, operation, payload)

  def dispatch(operation, payload),
    do: YellowDog.ServerControlFake.dispatch(:dns, operation, payload)
end

defmodule YellowDog.Server.Control.Dhcpv4 do
  @moduledoc false
  def current(operation, payload),
    do: YellowDog.ServerControlFake.current(:dhcpv4, operation, payload)

  def dispatch(operation, payload),
    do: YellowDog.ServerControlFake.dispatch(:dhcpv4, operation, payload)
end

defmodule YellowDog.Server.Control.Dhcpv6 do
  @moduledoc false
  def current(operation, payload),
    do: YellowDog.ServerControlFake.current(:dhcpv6, operation, payload)

  def dispatch(operation, payload),
    do: YellowDog.ServerControlFake.dispatch(:dhcpv6, operation, payload)
end

defmodule YellowDog.Server.Control.Mdns do
  @moduledoc false
  def current(operation, payload),
    do: YellowDog.ServerControlFake.current(:mdns, operation, payload)

  def dispatch(operation, payload),
    do: YellowDog.ServerControlFake.dispatch(:mdns, operation, payload)
end

defmodule YellowDog.Server.Control.Netboot do
  @moduledoc false
  def current(operation, payload),
    do: YellowDog.ServerControlFake.current(:netboot, operation, payload)

  def dispatch(operation, payload),
    do: YellowDog.ServerControlFake.dispatch(:netboot, operation, payload)
end

defmodule YellowDog.Server.Control.Identity do
  @moduledoc false
  def current(operation, payload),
    do: YellowDog.ServerControlFake.current(:identity, operation, payload)

  def dispatch(operation, payload),
    do: YellowDog.ServerControlFake.dispatch(:identity, operation, payload)
end
