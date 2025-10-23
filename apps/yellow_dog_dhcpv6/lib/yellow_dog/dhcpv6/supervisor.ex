defmodule YellowDog.Dhcpv6.Supervisor do
  @moduledoc """
  The main supervisor for the YellowDog DHCPv6 application.

  Manages the DHCPv6 server and related components with proper
  supervision strategy and child specifications.
  """

  use Supervisor
  require Logger

  @doc """
  Starts the DHCPv6 server supervisor.

  ## Options
  - `name`: Supervisor name (default: YellowDog.Dhcpv6)
  - `server_options`: Options passed to DHCPv6 server

  ## Returns
  - `{:ok, pid}` - Supervisor started successfully
  - `{:error, reason}` - Failed to start supervisor
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    opts = Map.new(opts)
    name = Map.get(opts, :name, YellowDog.Dhcpv6)
    opts = Map.put(opts, :name, name)

    Logger.debug("Starting DHCPv6 supervisor")
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    children = build_children(opts)

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp build_children(opts) do
    server_options = Map.get(opts, :server_options, [])
    pools = Keyword.get(server_options, :pools, [])

    [
      # Pre-start task
      {Task,
       fn ->
         Logger.debug("DHCPv6 pre-start task: Initializing ETS tables")
       end}
      |> Supervisor.child_spec(id: :pre_start, restart: :temporary),
      # Lease manager - must start before server
      {YellowDog.Dhcpv6.LeaseManager, [pools: pools]}
      |> Supervisor.child_spec(id: :lease_manager),
      # DHCPv6 server
      {YellowDog.Dhcpv6.Server, server_options}
      |> Supervisor.child_spec(id: :server),
      # Post-start task
      {Task,
       fn ->
         Logger.debug("DHCPv6 post-start task completed")
       end}
      |> Supervisor.child_spec(id: :post_start, restart: :temporary)
    ]
  end
end
