defmodule YellowDog.Console.ProcessInspectorTest do
  @moduledoc """
  Comprehensive unit tests for YellowDog.Console.ProcessInspector.

  Tests cover:
  - Module structure and exports
  - PID parsing
  - Process status retrieval
  - Memory formatting
  - MFA formatting
  - Tree layout calculations
  - Node counting
  - Dimension calculations
  """
  use ExUnit.Case, async: true

  alias YellowDog.Console.ProcessInspector

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(ProcessInspector)
    end

    test "exports get_tree/0" do
      Code.ensure_loaded!(ProcessInspector)
      assert Kernel.function_exported?(ProcessInspector, :get_tree, 0)
    end

    test "exports get_process_status/1" do
      Code.ensure_loaded!(ProcessInspector)
      assert Kernel.function_exported?(ProcessInspector, :get_process_status, 1)
    end

    test "exports parse_pid/1" do
      Code.ensure_loaded!(ProcessInspector)
      assert Kernel.function_exported?(ProcessInspector, :parse_pid, 1)
    end

    test "exports calculate_layout/1" do
      Code.ensure_loaded!(ProcessInspector)
      assert Kernel.function_exported?(ProcessInspector, :calculate_layout, 1)
    end

    test "exports calculate_layout/2" do
      Code.ensure_loaded!(ProcessInspector)
      assert Kernel.function_exported?(ProcessInspector, :calculate_layout, 2)
    end

    test "exports count_nodes/1" do
      Code.ensure_loaded!(ProcessInspector)
      assert Kernel.function_exported?(ProcessInspector, :count_nodes, 1)
    end

    test "exports calculate_dimensions/1" do
      Code.ensure_loaded!(ProcessInspector)
      assert Kernel.function_exported?(ProcessInspector, :calculate_dimensions, 1)
    end

    test "exports format_mfa/1" do
      Code.ensure_loaded!(ProcessInspector)
      assert Kernel.function_exported?(ProcessInspector, :format_mfa, 1)
    end

    test "exports format_memory/1" do
      Code.ensure_loaded!(ProcessInspector)
      assert Kernel.function_exported?(ProcessInspector, :format_memory, 1)
    end
  end

  describe "parse_pid/1" do
    test "parses valid PID string" do
      # Get current process PID as string
      pid_string = inspect(self())

      assert {:ok, parsed_pid} = ProcessInspector.parse_pid(pid_string)
      assert is_pid(parsed_pid)
      assert parsed_pid == self()
    end

    test "parses PID string with #PID prefix" do
      pid_string = "#PID" <> inspect(self())

      assert {:ok, parsed_pid} = ProcessInspector.parse_pid(pid_string)
      assert is_pid(parsed_pid)
    end

    test "handles PID string with extra whitespace" do
      pid_string = "  " <> inspect(self()) <> "  "

      assert {:ok, parsed_pid} = ProcessInspector.parse_pid(pid_string)
      assert is_pid(parsed_pid)
    end

    test "returns error for invalid PID string" do
      assert {:error, :invalid_pid} = ProcessInspector.parse_pid("not-a-pid")
    end

    test "returns error for empty string" do
      assert {:error, :invalid_pid} = ProcessInspector.parse_pid("")
    end

    test "returns error for nil" do
      assert {:error, :invalid_pid} = ProcessInspector.parse_pid(nil)
    end

    test "returns error for integer" do
      assert {:error, :invalid_pid} = ProcessInspector.parse_pid(12345)
    end

    test "returns error for malformed PID format" do
      assert {:error, :invalid_pid} = ProcessInspector.parse_pid("<0.1.2.3>")
    end
  end

  describe "get_process_status/1" do
    test "returns status for current process" do
      assert {:ok, status} = ProcessInspector.get_process_status(self())

      assert is_map(status)
      assert status.pid == self()
      assert status.alive == true
      assert is_integer(status.memory)
      assert status.memory > 0
      assert is_binary(status.memory_human)
      assert is_integer(status.message_queue_len)
      assert is_integer(status.reductions)
    end

    test "returns registered name if process is registered" do
      # Create and register a simple process
      test_name = :"test_process_#{System.unique_integer()}"
      pid = spawn(fn -> Process.sleep(:infinity) end)
      Process.register(pid, test_name)

      on_exit(fn ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)
      end)

      assert {:ok, status} = ProcessInspector.get_process_status(pid)
      assert status.registered_name == test_name
    end

    test "returns nil registered_name for unregistered process" do
      pid = spawn(fn -> Process.sleep(:infinity) end)

      on_exit(fn ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)
      end)

      assert {:ok, status} = ProcessInspector.get_process_status(pid)
      assert status.registered_name == nil
    end

    test "returns error for dead process" do
      pid = spawn(fn -> :ok end)
      Process.sleep(50)

      assert {:error, :process_not_found} = ProcessInspector.get_process_status(pid)
    end

    test "returns error for invalid input" do
      assert {:error, :process_not_found} = ProcessInspector.get_process_status("not-a-pid")
      assert {:error, :process_not_found} = ProcessInspector.get_process_status(nil)
      assert {:error, :process_not_found} = ProcessInspector.get_process_status(12345)
    end

    test "includes current function" do
      assert {:ok, status} = ProcessInspector.get_process_status(self())

      assert is_binary(status.current_function)
    end

    test "includes links list" do
      assert {:ok, status} = ProcessInspector.get_process_status(self())

      assert is_list(status.links)
    end

    test "includes monitors list" do
      assert {:ok, status} = ProcessInspector.get_process_status(self())

      assert is_list(status.monitors)
    end
  end

  describe "format_mfa/1" do
    test "formats valid MFA tuple" do
      mfa = {Enum, :map, 2}

      result = ProcessInspector.format_mfa(mfa)

      assert is_binary(result)
      assert result == "Enum.map/2"
    end

    test "formats MFA with module as atom" do
      mfa = {:erlang, :apply, 3}

      result = ProcessInspector.format_mfa(mfa)

      assert result == ":erlang.apply/3"
    end

    test "returns N/A for nil" do
      assert ProcessInspector.format_mfa(nil) == "N/A"
    end

    test "returns N/A for invalid input" do
      assert ProcessInspector.format_mfa("not an mfa") == "N/A"
      assert ProcessInspector.format_mfa({:only, :two}) == "N/A"
      assert ProcessInspector.format_mfa({1, 2, 3}) == "N/A"
    end

    test "handles complex module names" do
      mfa = {YellowDog.Console.ProcessInspector, :get_tree, 0}

      result = ProcessInspector.format_mfa(mfa)

      assert result =~ "YellowDog.Console.ProcessInspector"
      assert result =~ "get_tree/0"
    end
  end

  describe "format_memory/1" do
    test "formats bytes" do
      assert ProcessInspector.format_memory(0) == "0 B"
      assert ProcessInspector.format_memory(512) == "512 B"
      assert ProcessInspector.format_memory(1023) == "1023 B"
    end

    test "formats kilobytes" do
      assert ProcessInspector.format_memory(1024) == "1.0 KB"
      assert ProcessInspector.format_memory(2048) == "2.0 KB"
      assert ProcessInspector.format_memory(1536) == "1.5 KB"
    end

    test "formats megabytes" do
      assert ProcessInspector.format_memory(1_048_576) == "1.0 MB"
      assert ProcessInspector.format_memory(2_097_152) == "2.0 MB"
      assert ProcessInspector.format_memory(1_572_864) == "1.5 MB"
    end

    test "formats gigabytes" do
      assert ProcessInspector.format_memory(1_073_741_824) == "1.0 GB"
      assert ProcessInspector.format_memory(2_147_483_648) == "2.0 GB"
    end

    test "handles invalid input" do
      assert ProcessInspector.format_memory(-1) == "0 B"
      assert ProcessInspector.format_memory("invalid") == "0 B"
      assert ProcessInspector.format_memory(nil) == "0 B"
    end

    test "rounds to 2 decimal places" do
      # 1.234 KB
      result = ProcessInspector.format_memory(1263)
      assert String.match?(result, ~r/^\d+\.\d{1,2} KB$/)
    end
  end

  describe "count_nodes/1" do
    test "returns 0 for nil" do
      assert ProcessInspector.count_nodes(nil) == 0
    end

    test "returns 1 for single node without children" do
      node = %{id: :test, children: []}

      assert ProcessInspector.count_nodes(node) == 1
    end

    test "returns 1 for node without children key" do
      node = %{id: :test}

      assert ProcessInspector.count_nodes(node) == 1
    end

    test "counts all nodes in tree" do
      tree = %{
        id: :root,
        children: [
          %{id: :child1, children: []},
          %{
            id: :child2,
            children: [
              %{id: :grandchild1, children: []},
              %{id: :grandchild2, children: []}
            ]
          }
        ]
      }

      assert ProcessInspector.count_nodes(tree) == 5
    end

    test "handles deep nesting" do
      tree = %{
        id: :level1,
        children: [
          %{
            id: :level2,
            children: [
              %{
                id: :level3,
                children: [
                  %{id: :level4, children: []}
                ]
              }
            ]
          }
        ]
      }

      assert ProcessInspector.count_nodes(tree) == 4
    end
  end

  describe "calculate_layout/1 and calculate_layout/2" do
    test "adds x and y coordinates to single node" do
      tree = %{
        id: :root,
        pid: self(),
        label: "Root",
        type: :supervisor,
        status: :running,
        children: []
      }

      result = ProcessInspector.calculate_layout(tree)

      assert Map.has_key?(result, :x)
      assert Map.has_key?(result, :y)
      assert result.x >= 0
      assert result.y >= 0
    end

    test "accepts custom options" do
      tree = %{
        id: :root,
        pid: self(),
        label: "Root",
        type: :supervisor,
        status: :running,
        children: []
      }

      result =
        ProcessInspector.calculate_layout(tree,
          node_width: 200,
          node_height: 50,
          h_spacing: 100,
          v_spacing: 20
        )

      assert Map.has_key?(result, :x)
      assert Map.has_key?(result, :y)
    end

    test "positions children to the right of parent" do
      parent_pid = self()
      child_pid = spawn(fn -> Process.sleep(:infinity) end)

      on_exit(fn ->
        if Process.alive?(child_pid), do: Process.exit(child_pid, :kill)
      end)

      tree = %{
        id: :root,
        pid: parent_pid,
        label: "Root",
        type: :supervisor,
        status: :running,
        children: [
          %{
            id: :child,
            pid: child_pid,
            label: "Child",
            type: :worker,
            status: :running,
            children: []
          }
        ]
      }

      expanded_pids = MapSet.new([parent_pid])
      result = ProcessInspector.calculate_layout(tree, expanded_pids: expanded_pids)

      # When expanded, children should be positioned
      if result.expanded do
        [child] = result.children
        assert child.x > result.x
      end
    end

    test "marks expanded state based on expanded_pids" do
      pid = self()

      tree = %{
        id: :root,
        pid: pid,
        label: "Root",
        type: :supervisor,
        status: :running,
        children: []
      }

      # Not expanded
      result = ProcessInspector.calculate_layout(tree, expanded_pids: MapSet.new())
      assert result.expanded == false

      # Expanded
      result = ProcessInspector.calculate_layout(tree, expanded_pids: MapSet.new([pid]))
      assert result.expanded == true
    end
  end

  describe "calculate_dimensions/1 and calculate_dimensions/2" do
    test "returns tuple of width and height" do
      tree = %{
        id: :root,
        x: 0,
        y: 0,
        children: []
      }

      {width, height} = ProcessInspector.calculate_dimensions(tree)

      assert is_integer(width)
      assert is_integer(height)
      assert width > 0
      assert height > 0
    end

    test "respects minimum dimensions" do
      tree = %{
        id: :root,
        x: 0,
        y: 0,
        children: []
      }

      {width, height} = ProcessInspector.calculate_dimensions(tree)

      assert width >= 400
      assert height >= 200
    end

    test "accepts custom padding" do
      tree = %{
        id: :root,
        x: 100,
        y: 100,
        children: []
      }

      {width1, height1} = ProcessInspector.calculate_dimensions(tree, padding: 40)
      {width2, height2} = ProcessInspector.calculate_dimensions(tree, padding: 100)

      # Larger padding should result in larger dimensions
      assert width2 > width1
      assert height2 > height1
    end

    test "calculates dimensions for tree with children" do
      tree = %{
        id: :root,
        x: 0,
        y: 0,
        children: [
          %{id: :child1, x: 200, y: 0, children: []},
          %{id: :child2, x: 200, y: 100, children: []}
        ]
      }

      {width, height} = ProcessInspector.calculate_dimensions(tree)

      # Dimensions should account for child positions
      assert width > 200
      assert height > 100
    end
  end

  describe "get_tree/0" do
    test "returns nil or map" do
      result = ProcessInspector.get_tree()

      assert is_nil(result) or is_map(result)
    end

    test "returns valid tree structure when supervisors are running" do
      result = ProcessInspector.get_tree()

      if result do
        assert Map.has_key?(result, :id)
        assert Map.has_key?(result, :label)
        assert Map.has_key?(result, :type)
        assert Map.has_key?(result, :status)
        assert Map.has_key?(result, :children)
      end
    end
  end
end
