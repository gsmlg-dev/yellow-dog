defmodule YellowDog.Dhcpv4 do
  @moduledoc """
  DHCPv4 supervisor that manages DHCPv4 protocol implementation.
  """

  use Supervisor

  def start_link(_opts) do
    Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    children = [
      # DHCPv4 functionality workers will be added here
      # Placeholder for future DHCPv4 components
    ]

    opts = [strategy: :one_for_one]
    Supervisor.init(children, opts)
  end
end
