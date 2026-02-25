defmodule YellowDogIdentity.Supervisor do
  @moduledoc """
  Supervisor for the identity service.

  Manages the Registry GenServer and DHCP LeaseCache.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    data_dir = Keyword.get(opts, :data_dir, "data/identity")

    children = [
      {YellowDogIdentity.Registry, [data_dir: data_dir]},
      {YellowDogIdentity.Trust.DHCP.LeaseCache, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
