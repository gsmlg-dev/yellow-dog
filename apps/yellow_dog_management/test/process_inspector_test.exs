defmodule YellowDog.Management.ProcessInspectorTest do
  use ExUnit.Case, async: true

  alias YellowDog.ManagementUI.ProcessInspector

  test "the tree is rooted at the real Management supervisor and its actual children" do
    root_pid = Process.whereis(YellowDog.Management.Supervisor)
    assert is_pid(root_pid)
    tree = ProcessInspector.get_tree()
    assert tree.pid == root_pid
    assert tree.id == YellowDog.Management.Supervisor
    assert tree.label == "Management"
    assert tree.type == :supervisor
    assert tree.status == :running

    actual_children = Supervisor.which_children(root_pid)

    for {child_id, child_pid, child_type, _modules} <- actual_children do
      assert Enum.any?(tree.children, fn child ->
               child.id == child_id and child.pid == child_pid and child.type == child_type
             end)
    end

    assert length(tree.children) == length(actual_children)
    assert ProcessInspector.contains_pid?(tree, root_pid)
    refute ProcessInspector.contains_pid?(tree, self())
    refute ProcessInspector.contains_pid?(tree, :undefined)
    refute ProcessInspector.contains_pid?(nil, root_pid)
  end

  test "PID parsing and process properties use actual live processes" do
    root_pid = Process.whereis(YellowDog.Management.Supervisor)
    assert {:ok, ^root_pid} = ProcessInspector.parse_pid(inspect(root_pid))

    assert {:ok, ^root_pid} =
             ProcessInspector.parse_pid(:erlang.pid_to_list(root_pid) |> to_string())

    assert {:error, :invalid_pid} = ProcessInspector.parse_pid("not-a-pid")
    assert {:error, :invalid_pid} = ProcessInspector.parse_pid(nil)

    assert {:ok, status} = ProcessInspector.get_process_status(root_pid)
    assert status.pid == root_pid
    assert status.registered_name == YellowDog.Management.Supervisor
    assert status.alive
    assert is_atom(status.status)
    assert is_binary(status.current_function)
    assert is_integer(status.message_queue_len)
    assert is_integer(status.memory)
    assert is_binary(status.memory_human)
    assert is_integer(status.reductions)
    assert is_list(status.links)
    assert is_list(status.monitors)
  end

  test "terminated and invalid processes return an explicit not-found result" do
    {process_pid, monitor_ref} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^monitor_ref, :process, ^process_pid, :normal}
    assert {:error, :process_not_found} = ProcessInspector.get_process_status(process_pid)
    assert {:error, :process_not_found} = ProcessInspector.get_process_status(:undefined)
  end

  test "expansion lays out actual descendants and counts the complete tree" do
    tree = ProcessInspector.get_tree()
    assert tree.children != []

    collapsed = ProcessInspector.calculate_layout(tree)
    refute collapsed.expanded
    assert collapsed.x == 0
    assert collapsed.y == 0

    expanded =
      ProcessInspector.calculate_layout(tree,
        expanded_pids: MapSet.new([tree.pid]),
        node_width: 160,
        node_height: 36,
        h_spacing: 20,
        v_spacing: 50
      )

    assert expanded.expanded
    assert Enum.all?(expanded.children, &(&1.x == 180))
    positions = Enum.map(expanded.children, & &1.y)
    assert positions == Enum.sort(positions)
    assert length(Enum.uniq(positions)) == length(positions)
    assert ProcessInspector.count_nodes(tree) > length(tree.children)
    assert ProcessInspector.count_nodes(nil) == 0

    {width, height} = ProcessInspector.calculate_dimensions(expanded)
    assert width >= 400
    assert height >= 200

    {collapsed_width, collapsed_height} = ProcessInspector.calculate_dimensions(collapsed)
    assert collapsed_width == 400
    assert collapsed_height == 200
  end

  test "MFA and memory formatting retain the original property display" do
    assert ProcessInspector.format_mfa({Enum, :map, 2}) == "Enum.map/2"
    assert ProcessInspector.format_mfa(nil) == "N/A"
    assert ProcessInspector.format_memory(0) == "0 B"
    assert ProcessInspector.format_memory(1024) == "1.0 KB"
    assert ProcessInspector.format_memory(1_048_576) == "1.0 MB"
    assert ProcessInspector.format_memory(1_073_741_824) == "1.0 GB"
    assert ProcessInspector.format_memory(nil) == "0 B"
  end
end
