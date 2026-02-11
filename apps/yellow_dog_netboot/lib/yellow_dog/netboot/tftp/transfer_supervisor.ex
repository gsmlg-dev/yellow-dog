defmodule YellowDog.Netboot.TFTP.TransferSupervisor do
  @moduledoc """
  DynamicSupervisor for active TFTP transfer workers.
  """

  use DynamicSupervisor

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one, max_children: 100)
  end

  @doc "Start a new transfer worker."
  def start_transfer(args) do
    DynamicSupervisor.start_child(__MODULE__, {YellowDog.Netboot.TFTP.Transfer, args})
  end

  @doc "Count active transfers."
  def active_count do
    DynamicSupervisor.count_children(__MODULE__)[:active]
  end
end
