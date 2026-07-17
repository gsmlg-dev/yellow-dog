defmodule YellowDog.ServerSettingsControlFake do
  @moduledoc false

  use Agent

  def start_link(_opts) do
    Agent.start_link(
      fn ->
        %{responses: %{}, calls: []}
      end,
      name: __MODULE__
    )
  end

  def configure(operation, response) when is_atom(operation) do
    Agent.update(__MODULE__, &put_in(&1, [:responses, operation], response))
  end

  def take_calls do
    Agent.get_and_update(__MODULE__, fn state ->
      {Enum.reverse(state.calls), %{state | calls: []}}
    end)
  end

  def call(operation, arguments) do
    response =
      Agent.get_and_update(__MODULE__, fn state ->
        response = Map.get(state.responses, operation, {:error, :unsupported})
        {response, %{state | calls: [{operation, arguments} | state.calls]}}
      end)

    run(response)
  end

  defp run({:raise, reason}), do: raise(reason)
  defp run({:throw, reason}), do: throw(reason)
  defp run({:exit, reason}), do: exit(reason)
  defp run(response), do: response
end

defmodule YellowDog.ServerSettingsControlFake.Manager do
  @moduledoc false

  def effective(service), do: YellowDog.ServerSettingsControlFake.call(:effective, [service])
  def source(service), do: YellowDog.ServerSettingsControlFake.call(:source, [service])
  def revision(service), do: YellowDog.ServerSettingsControlFake.call(:revision, [service])
  def validation(service), do: YellowDog.ServerSettingsControlFake.call(:validation, [service])

  def update(service, entries),
    do: YellowDog.ServerSettingsControlFake.call(:update, [service, entries])

  def apply(service), do: YellowDog.ServerSettingsControlFake.call(:apply, [service])
  def reload(service), do: YellowDog.ServerSettingsControlFake.call(:reload, [service])

  def rollback(service, target_revision),
    do: YellowDog.ServerSettingsControlFake.call(:rollback, [service, target_revision])
end
