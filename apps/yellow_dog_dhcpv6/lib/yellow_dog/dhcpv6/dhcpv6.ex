defmodule YellowDog.Dhcpv6 do
  @moduledoc """
  DHCPv6 supervisor that manages DHCPv6 protocol implementation.
  """

  use Supervisor

  def start_link(_opts) do
    Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    children = [
      # DHCPv6 functionality workers will be added here
      # Placeholder for future DHCPv6 components
    ]

    opts = [strategy: :one_for_one]
    Supervisor.init(children, opts)
  end
end
