defmodule YellowDog.Mdns.Supervisor do
  @moduledoc """
  The main supervisor for the YellowDog mDNS service.

  Manages the mDNS server and related components with proper supervision
  and lifecycle management.
  """

  use Supervisor
  require Logger

  @doc """
  Starts the mDNS server supervisor.

  ## Options
  - `:name` - Name for the supervisor (default: YellowDog.Mdns)
  - `:server_options` - Options to pass to the mDNS server

  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    opts = Map.new(opts)
    name = Map.get(opts, :name, YellowDog.Mdns)
    opts = Map.put(opts, :name, name)

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
          Logger.debug("mDNS pre-start task completed")
        end}
      |> Supervisor.child_spec(id: :pre_start),
      {YellowDog.Mdns.Server, server_options}
      |> Supervisor.child_spec(id: :server),
      {Task,
        fn ->
          Logger.debug("mDNS post-start task completed")
        end}
      |> Supervisor.child_spec(id: :post_start)
    ]
  end
end
