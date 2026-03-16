defmodule YellowDog.Data.Supervisor do
  @moduledoc """
  Supervisor for the Data layer.

  Starts the `Data.Registry` which tracks all active Store collections.
  Resource stores are initialized lazily on first access via
  `Resource.init_stores/0` rather than eagerly at boot.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      YellowDog.Data.Registry
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
