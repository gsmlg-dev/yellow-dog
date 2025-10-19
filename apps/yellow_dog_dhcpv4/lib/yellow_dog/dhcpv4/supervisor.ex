defmodule YellowDog.Dhcpv4.Supervisor do
  @moduledoc """
  The main supervisor for the YellowDog DHCPv4 application.

  Manages the DHCPv4 server and related components with proper
  supervision strategy and child specifications.
  """

  use Supervisor
  require Logger

  @doc """
  Starts the DHCPv4 server supervisor.

  ## Options
  - `name`: Supervisor name (default: YellowDog.Dhcpv4)
  - `server_options`: Options passed to DHCPv4 server

  ## Returns
  - `{:ok, pid}` - Supervisor started successfully
  - `{:error, reason}` - Failed to start supervisor
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    opts = Map.new(opts)
    name = Map.get(opts, :name, YellowDog.Dhcpv4)
    opts = Map.put(opts, :name, name)

    Logger.debug("Starting DHCPv4 supervisor")
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    children = build_children(opts)

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp build_children(opts) do
    server_options = Map.get(opts, :server_options, [])

    [
      {Task,
        fn ->
          Logger.debug("DHCPv4 pre-start task completed")
        end}
      |> Supervisor.child_spec(id: :pre_start),
      {YellowDog.Dhcpv4.Server, server_options}
      |> Supervisor.child_spec(id: :server),
      {Task,
        fn ->
          Logger.debug("DHCPv4 post-start task completed")
        end}
      |> Supervisor.child_spec(id: :post_start)
    ]
  end
end
