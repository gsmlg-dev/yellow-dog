defmodule YellowDog.Dhcpv4.Supervisor do
  @moduledoc """
  The main supervisor for the Phoenix Socket Client.
  """

  use Supervisor

  @doc """
  Starts the Dhcpv4 server supervisor.

  ## Options

  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    opts = Map.new(opts)
    name = Map.get(opts, :name, YellowDog.Dhcpv4)
    opts = Map.put(opts, :name, name)

    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    children = [
      {Task,
       fn ->
         nil
       end}
      |> Supervisor.child_spec(id: :pre_start),

      {Task,
       fn ->
         nil
       end}
      |> Supervisor.child_spec(id: :post_start)
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
