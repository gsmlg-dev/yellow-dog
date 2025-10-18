defmodule YellowDog.Mdns do
  @moduledoc """
  mDNS supervisor that manages multicast DNS functionality.
  """

  use Supervisor

  def start_link(_opts) do
    Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    children = [
      # mDNS functionality workers will be added here
      # Placeholder for future mDNS components
    ]

    opts = [strategy: :one_for_one]
    Supervisor.init(children, opts)
  end
end
