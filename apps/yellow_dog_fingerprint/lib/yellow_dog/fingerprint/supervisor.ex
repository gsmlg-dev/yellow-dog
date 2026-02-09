defmodule YellowDog.Fingerprint.Supervisor do
  @moduledoc """
  Top-level supervisor for the fingerprint subsystem.

  Starts the database, OUI lookup, device registry, and telemetry observer
  in dependency order.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    data_dir = Application.get_env(:yellow_dog_fingerprint, :data_dir, "data/fingerprint")

    children = [
      {YellowDog.Fingerprint.Database, data_dir: data_dir},
      {YellowDog.Fingerprint.OUI, data_dir: data_dir},
      {YellowDog.Fingerprint.DeviceRegistry, data_dir: data_dir},
      {YellowDog.Fingerprint.Observer, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
