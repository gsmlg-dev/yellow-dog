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

    children = [
      # mDNS server
      %{
        id: YellowDog.Mdns.Server,
        start: {YellowDog.Mdns.Server, :start_link, [server_options]},
        type: :worker,
        restart: :permanent,
        shutdown: 500
      }
    ]

    # Add conditional children based on configuration
    if Application.get_env(:yellow_dog, :include_test_children, false) do
      # Add test children for development/testing
      children ++ [
        {Task,
         fn ->
           Logger.debug("mDNS pre-start task completed")
         end}
        |> Supervisor.child_spec(id: :pre_start),

        {Task,
         fn ->
           Logger.debug("mDNS post-start task completed")
         end}
        |> Supervisor.child_spec(id: :post_start)
      ]
    else
      children
    end
  end
end
