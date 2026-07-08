defmodule YellowDog.ServerAgent.Application do
  @moduledoc false

  @behaviour Application

  @impl Application
  def start(_type, args), do: YellowDog.ServerAgent.Supervisor.start_link(args)

  @impl Application
  def stop(_state), do: :ok
end
