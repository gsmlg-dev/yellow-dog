defmodule YellowDog.Dhcpv4.Supervisor do
  @moduledoc """
  The main supervisor for the YellowDog DHCPv4 application.

  Manages the DHCPv4 server and related components with proper
  supervision strategy and child specifications.
  """

  use Supervisor

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

    :telemetry.execute(
      [:yellow_dog, :dhcpv4, :supervisor, :starting],
      %{count: 1},
      %{}
    )

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
         :telemetry.execute(
           [:yellow_dog, :dhcpv4, :supervisor, :pre_start],
           %{count: 1},
           %{}
         )
       end}
      |> Supervisor.child_spec(id: :pre_start, restart: :temporary),
      # Lease manager - must start before server
      {YellowDog.Dhcpv4.LeaseManager, [pools: pools]}
      |> Supervisor.child_spec(id: :lease_manager),
      # Conflict resolver - handles IP conflicts and quarantine (PRD FR2.4)
      YellowDog.Dhcpv4.ConflictResolver
      |> Supervisor.child_spec(id: :conflict_resolver),
      # DHCPv4 server
      {YellowDog.Dhcpv4.Server, server_options}
      |> Supervisor.child_spec(id: :server),
      # Post-start task
      {Task,
       fn ->
         :telemetry.execute(
           [:yellow_dog, :dhcpv4, :supervisor, :post_start],
           %{count: 1},
           %{}
         )
       end}
      |> Supervisor.child_spec(id: :post_start, restart: :temporary)
    ]
  end
end
