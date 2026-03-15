defmodule YellowDog.Netman.Kernel.EtsRescueCoverageTest do
  @moduledoc """
  Tests covering the ArgumentError rescue blocks in all kernel modules.

  Each kernel module (LinkMonitor, AddressManager, NeighborMonitor,
  RouteManager, RuleManager) has public ETS-reading functions with
  `rescue ArgumentError ->` guards for the case where the named table
  does not exist (e.g., before GenServer initializes or after a crash).

  We trigger these by:
  1. Suspending the GenServer (prevents concurrent ETS writes)
  2. Renaming the named ETS table so lookups fail
  3. Calling the public function → ArgumentError rescue fires
  4. Restoring the table name
  5. Resuming the GenServer
  """
  use ExUnit.Case

  alias YellowDog.Netman.Kernel.{
    AddressManager,
    LinkMonitor,
    NeighborMonitor,
    RouteManager,
    RuleManager
  }

  @moduletag :capture_log

  # Safely rename-away a named ETS table, call a function, then restore.
  # Uses :sys.suspend/resume so the owning GenServer does not process
  # messages (and attempt ETS writes) while the table is renamed.
  defp with_table_renamed(module, table, fun) do
    backup = :"#{table}_rescue_backup"
    :sys.suspend(module)

    on_exit(fn ->
      # Idempotent restore: only rename back if backup still exists
      if :ets.whereis(backup) != :undefined do
        :ets.rename(backup, table)
      end

      :sys.resume(module)
    end)

    :ets.rename(table, backup)

    try do
      fun.()
    after
      if :ets.whereis(backup) != :undefined do
        :ets.rename(backup, table)
      end

      :sys.resume(module)
    end
  end

  describe "LinkMonitor ArgumentError rescues" do
    test "list_links/0 returns [] when ETS table does not exist" do
      with_table_renamed(LinkMonitor, :netman_links, fn ->
        assert LinkMonitor.list_links() == []
      end)
    end

    test "get_link/1 returns nil when ETS table does not exist" do
      with_table_renamed(LinkMonitor, :netman_links, fn ->
        assert LinkMonitor.get_link("eth0") == nil
      end)
    end
  end

  describe "AddressManager ArgumentError rescues" do
    test "get_addresses/1 returns [] when ETS table does not exist" do
      with_table_renamed(AddressManager, :netman_addresses, fn ->
        assert AddressManager.get_addresses("eth0") == []
      end)
    end

    test "list_all/0 returns %{} when ETS table does not exist" do
      with_table_renamed(AddressManager, :netman_addresses, fn ->
        assert AddressManager.list_all() == %{}
      end)
    end
  end

  describe "NeighborMonitor ArgumentError rescues" do
    test "list_neighbors/0 returns [] when ETS table does not exist" do
      with_table_renamed(NeighborMonitor, :netman_neighbors, fn ->
        assert NeighborMonitor.list_neighbors() == []
      end)
    end
  end

  describe "RouteManager ArgumentError rescues" do
    test "list_all/0 returns [] when ETS table does not exist" do
      with_table_renamed(RouteManager, :netman_routes, fn ->
        assert RouteManager.list_all() == []
      end)
    end
  end

  describe "RuleManager ArgumentError rescues" do
    test "list_rules/0 returns [] when ETS table does not exist" do
      with_table_renamed(RuleManager, :netman_rules, fn ->
        assert RuleManager.list_rules() == []
      end)
    end
  end
end
