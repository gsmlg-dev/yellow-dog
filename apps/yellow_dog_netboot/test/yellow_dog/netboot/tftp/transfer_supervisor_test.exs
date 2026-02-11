defmodule YellowDog.Netboot.TFTP.TransferSupervisorTest do
  use ExUnit.Case, async: true

  alias YellowDog.Netboot.TFTP.TransferSupervisor

  setup do
    # Start a test-scoped DynamicSupervisor to avoid interfering with the
    # application-managed one.
    name = :"transfer_sup_test_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      DynamicSupervisor.start_link(strategy: :one_for_one, max_children: 100, name: name)

    on_exit(fn ->
      try do
        if Process.alive?(pid), do: DynamicSupervisor.stop(pid, :normal)
      catch
        :exit, _ -> :ok
      end
    end)

    %{sup: name, pid: pid}
  end

  describe "init/1" do
    test "configures one_for_one strategy with max_children 100" do
      assert {:ok, %{strategy: :one_for_one, max_children: 100}} =
               TransferSupervisor.init([])
    end

    test "init ignores extra arguments" do
      assert {:ok, %{strategy: :one_for_one}} = TransferSupervisor.init([:extra, :args])
    end
  end

  describe "active_count/0 (via DynamicSupervisor)" do
    test "returns zero when no transfers active", %{sup: sup} do
      count = DynamicSupervisor.count_children(sup)[:active]
      assert count == 0
    end

    test "increments when a child is started", %{sup: sup} do
      {:ok, _pid} =
        DynamicSupervisor.start_child(sup, {Agent, fn -> :running end})

      count = DynamicSupervisor.count_children(sup)[:active]
      assert count == 1
    end

    test "decrements when a child stops", %{sup: sup} do
      {:ok, child} =
        DynamicSupervisor.start_child(sup, {Agent, fn -> :running end})

      assert DynamicSupervisor.count_children(sup)[:active] == 1

      DynamicSupervisor.terminate_child(sup, child)

      assert DynamicSupervisor.count_children(sup)[:active] == 0
    end

    test "handles multiple children", %{sup: sup} do
      {:ok, _} = DynamicSupervisor.start_child(sup, {Agent, fn -> :a end})
      {:ok, _} = DynamicSupervisor.start_child(sup, {Agent, fn -> :b end})
      {:ok, _} = DynamicSupervisor.start_child(sup, {Agent, fn -> :c end})

      assert DynamicSupervisor.count_children(sup)[:active] == 3
    end
  end

  describe "max_children limit" do
    test "max_children setting is respected" do
      name = :"limited_sup_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        DynamicSupervisor.start_link(strategy: :one_for_one, max_children: 2, name: name)

      {:ok, _} = DynamicSupervisor.start_child(name, {Agent, fn -> :a end})
      {:ok, _} = DynamicSupervisor.start_child(name, {Agent, fn -> :b end})

      assert {:error, :max_children} =
               DynamicSupervisor.start_child(name, {Agent, fn -> :c end})

      DynamicSupervisor.stop(pid, :normal)
    end
  end

  describe "child lifecycle" do
    test "children are independent — one crash doesn't affect others", %{sup: sup} do
      {:ok, agent1} = DynamicSupervisor.start_child(sup, {Agent, fn -> :ok end})
      {:ok, _agent2} = DynamicSupervisor.start_child(sup, {Agent, fn -> :ok end})

      DynamicSupervisor.terminate_child(sup, agent1)

      assert DynamicSupervisor.count_children(sup)[:active] == 1
    end
  end
end
