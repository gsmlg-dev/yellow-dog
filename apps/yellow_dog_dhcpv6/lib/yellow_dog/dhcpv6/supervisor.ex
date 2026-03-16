defmodule YellowDog.Dhcpv6.Supervisor do
  @moduledoc """
  The main supervisor for the YellowDog DHCPv6 application.

  Manages the DHCPv6 server and related components with proper
  supervision strategy and child specifications.
  """

  use Supervisor

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

    :telemetry.execute(
      [:yellow_dog, :dhcpv6, :supervisor, :starting],
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
           [:yellow_dog, :dhcpv6, :supervisor, :pre_start],
           %{count: 1},
           %{}
         )
       end}
      |> Supervisor.child_spec(id: :pre_start, restart: :temporary),
      # Rate limiter - must start before server for DoS protection
      YellowDog.Dhcpv6.RateLimiter
      |> Supervisor.child_spec(id: :rate_limiter),
      # Lease manager - must start before server
      {YellowDog.Dhcpv6.LeaseManager, [pools: pools]}
      |> Supervisor.child_spec(id: :lease_manager),
      # DHCPv6 server
      {YellowDog.Dhcpv6.Server, server_options}
      |> Supervisor.child_spec(id: :server),
      # Post-start task
      {Task,
       fn ->
         :telemetry.execute(
           [:yellow_dog, :dhcpv6, :supervisor, :post_start],
           %{count: 1},
           %{}
         )

         start_store_consumers()
       end}
      |> Supervisor.child_spec(id: :post_start, restart: :temporary)
    ]
  end

  defp start_store_consumers do
    if Process.whereis(YellowDog.Store.EventBridge) do
      child_spec =
        {YellowDog.Store.ConfigWatcher,
         service: :dhcpv6,
         handler: &handle_store_config_change/2,
         name: :dhcpv6_store_config_watcher}

      name = Map.get(%{}, :name, YellowDog.Dhcpv6)

      case Supervisor.start_child(name, child_spec) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, _reason} -> :ok
      end
    end
  rescue
    _ -> :ok
  end

  defp handle_store_config_change(key, value) do
    :telemetry.execute(
      [:yellow_dog, :dhcpv6, :config, :store_change],
      %{},
      %{key: key, value: value}
    )
  end
end
