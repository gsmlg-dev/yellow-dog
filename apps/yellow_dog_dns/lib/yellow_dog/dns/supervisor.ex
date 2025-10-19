defmodule YellowDog.Dns.Supervisor do
  @moduledoc """
  The main supervisor for the YellowDog DNS application.

  Manages the DNS server and related components with proper
  supervision strategy and child specifications.
  """

  use Supervisor
  require Logger

  @doc """
  Starts the DNS server supervisor.

  ## Options
  - `name`: Supervisor name (default: YellowDog.Dns)
  - `server_options`: Options passed to DNS server

  ## Returns
  - `{:ok, pid}` - Supervisor started successfully
  - `{:error, reason}` - Failed to start supervisor
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    opts = Map.new(opts)
    name = Map.get(opts, :name, YellowDog.Dns)
    opts = Map.put(opts, :name, name)

    Logger.debug("Starting DNS supervisor")
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
          Logger.debug("DNS pre-start task completed")
        end}
      |> Supervisor.child_spec(id: :pre_start),
      {YellowDog.Dns.Server, server_options}
      |> Supervisor.child_spec(id: :server),
      # DNS View Manager
      {YellowDog.Dns.ViewManager, []},
      # DNS Name Resolver
      {YellowDog.Dns.NameResolver, []},
      {Task,
        fn ->
          Logger.debug("DNS post-start task completed")
        end}
      |> Supervisor.child_spec(id: :post_start)
    ]
  end
end
