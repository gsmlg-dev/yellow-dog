defmodule YellowDog.Netman.Supervisor do
  @moduledoc """
  Top-level supervisor for the Network Manager.

  Uses `rest_for_one` strategy — if a foundational subsystem crashes,
  all dependent subsystems above it restart in order.

  Start order:
  1. Kernel.Supervisor (netlink, link/address/route monitors)
  2. EventBus (Registry-based PubSub)
  3. ProfileStore (TOML profile management)
  4. Connection.Supervisor (DynamicSupervisor for per-interface FSMs)
  5. ReconciliationEngine (desired-state reconciliation loop)
  6. API.Supervisor (Unix socket CLI interface)
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    apply_mode = Keyword.get(opts, :apply_mode, :managed)

    children =
      [
        {Registry, keys: :unique, name: YellowDog.Netman.Registry},
        {YellowDog.Netman.Kernel.Supervisor, []},
        {YellowDog.Netman.EventBus, []},
        {YellowDog.Netman.ProfileStore, []},
        {YellowDog.Netman.Connection.Supervisor, []},
        {YellowDog.Netman.Connection.LeaseCoordinator, []}
      ]
      |> maybe_add_reconciliation_engine(apply_mode)
      |> Kernel.++([{YellowDog.Netman.API.Supervisor, []}])
      |> Kernel.++(console_client_child())

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp maybe_add_reconciliation_engine(children, mode) when mode in [:observe, :observe_first] do
    children
  end

  defp maybe_add_reconciliation_engine(children, _apply_mode) do
    children ++ [{YellowDog.Netman.ReconciliationEngine, []}]
  end

  defp console_client_child do
    config = Application.get_env(:yellow_dog_netman, :console, [])

    if Keyword.get(config, :enabled, false) do
      [{YellowDog.Netman.Console.Client, []}]
    else
      []
    end
  end
end
