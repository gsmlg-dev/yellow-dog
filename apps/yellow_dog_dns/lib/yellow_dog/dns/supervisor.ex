defmodule YellowDog.Dns.Supervisor do
  @moduledoc """
  The main supervisor for the Phoenix Socket Client.
  """

  use Supervisor

  @doc """
  Starts the dns server supervisor.

  ## Options

  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    opts = Map.new(opts)
    name = Map.get(opts, :name, YellowDog.Dns)
    opts = Map.put(opts, :name, name)

    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    sup_pid = self()
    opts = opts |> Map.put(:sup_pid, sup_pid)

    name = Map.get(opts, :name)

    default_registry_name =
      name
      |> to_string()
      |> String.replace_leading("Elixir.", "")
      |> String.split(["_", "."])
      |> Enum.map(&String.capitalize/1)
      |> Enum.join()
      |> (&(&1 <> "ChannelRegistry")).()
      |> String.to_atom()

    registry_name = Map.get(opts, :registry_name, default_registry_name)

    opts = opts |> Map.put(:registry_name, registry_name)

    children = [
      {Task,
       fn ->
         nil
       end}
      |> Supervisor.child_spec(id: :pre_start),
      # DNS View Manager
      {YellowDog.Dns.ViewManager, []},
      # DNS Name Resolver
      {YellowDog.Dns.NameResolver, []},
      {Task,
       fn ->
         nil
       end}
      |> Supervisor.child_spec(id: :post_start)
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
