defmodule YellowDog.Console.ProcessInspector do
  @moduledoc """
  Service for inspecting Erlang/OTP supervision trees.

  Builds a complete process tree starting from YellowDog.Supervisor,
  suitable for SVG diagram rendering.
  """

  @process_info_keys [
    :registered_name,
    :current_function,
    :message_queue_len,
    :memory,
    :status,
    :links,
    :monitors,
    :reductions
  ]

  @doc """
  Get the complete supervision tree starting from YellowDog.Supervisor.

  Returns a tree structure suitable for SVG rendering:
  %{
    id: term(),
    pid: pid(),
    label: String.t(),
    type: :supervisor | :worker,
    status: :running | :restarting | :undefined,
    children: [tree_node()]
  }
  """
  @spec get_tree() :: map() | nil
  def get_tree do
    case Process.whereis(YellowDog.Supervisor) do
      nil -> nil
      pid -> build_tree_from_supervisor(pid, "YellowDog.Supervisor")
    end
  end

  @doc """
  Get detailed status information for a specific process.
  """
  @spec get_process_status(pid()) :: {:ok, map()} | {:error, :process_not_found}
  def get_process_status(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      case :erlang.process_info(pid, @process_info_keys) do
        nil ->
          {:error, :process_not_found}

        info ->
          {:ok,
           %{
             pid: pid,
             registered_name: get_registered_name(info),
             current_function: format_mfa(Keyword.get(info, :current_function)),
             message_queue_len: Keyword.get(info, :message_queue_len, 0),
             memory: Keyword.get(info, :memory, 0),
             memory_human: format_memory(Keyword.get(info, :memory, 0)),
             status: Keyword.get(info, :status),
             links: Keyword.get(info, :links, []),
             monitors: Keyword.get(info, :monitors, []),
             reductions: Keyword.get(info, :reductions, 0),
             alive: true
           }}
      end
    else
      {:error, :process_not_found}
    end
  end

  def get_process_status(_), do: {:error, :process_not_found}

  @doc """
  Parse a PID from its string representation.
  """
  @spec parse_pid(String.t()) :: {:ok, pid()} | {:error, :invalid_pid}
  def parse_pid(pid_string) when is_binary(pid_string) do
    cleaned =
      pid_string
      |> String.replace("#PID", "")
      |> String.trim()

    try do
      pid = :erlang.list_to_pid(String.to_charlist(cleaned))
      {:ok, pid}
    rescue
      _ -> {:error, :invalid_pid}
    catch
      _, _ -> {:error, :invalid_pid}
    end
  end

  def parse_pid(_), do: {:error, :invalid_pid}

  @doc """
  Calculate tree layout positions for SVG rendering.

  Returns tree with added x, y coordinates for each node.
  Uses a top-down tree layout algorithm.
  """
  @spec calculate_layout(map(), keyword()) :: map()
  def calculate_layout(tree, opts \\ []) do
    node_width = Keyword.get(opts, :node_width, 180)
    node_height = Keyword.get(opts, :node_height, 40)
    h_spacing = Keyword.get(opts, :h_spacing, 30)
    v_spacing = Keyword.get(opts, :v_spacing, 60)

    # First pass: calculate subtree widths
    tree_with_widths = calculate_subtree_widths(tree, node_width, h_spacing)

    # Second pass: assign x, y positions
    assign_positions(tree_with_widths, 0, 0, node_width, node_height, v_spacing)
  end

  @doc """
  Count total nodes in the tree.
  """
  @spec count_nodes(map() | nil) :: non_neg_integer()
  def count_nodes(nil), do: 0

  def count_nodes(%{children: children}) do
    1 + Enum.sum(Enum.map(children, &count_nodes/1))
  end

  def count_nodes(_), do: 1

  @doc """
  Calculate the dimensions needed for the SVG canvas.
  """
  @spec calculate_dimensions(map(), keyword()) :: {non_neg_integer(), non_neg_integer()}
  def calculate_dimensions(tree, opts \\ []) do
    node_width = Keyword.get(opts, :node_width, 180)
    node_height = Keyword.get(opts, :node_height, 40)
    h_spacing = Keyword.get(opts, :h_spacing, 30)
    v_spacing = Keyword.get(opts, :v_spacing, 60)
    padding = Keyword.get(opts, :padding, 40)

    depth = tree_depth(tree)
    max_width = tree_max_width(tree)

    width = max_width * (node_width + h_spacing) + padding * 2
    height = depth * (node_height + v_spacing) + padding * 2

    {max(width, 400), max(height, 200)}
  end

  # Private functions

  defp build_tree_from_supervisor(pid, label) when is_pid(pid) do
    children =
      try do
        Supervisor.which_children(pid)
        |> Enum.map(fn {id, child_pid, type, _modules} ->
          build_child_node(id, child_pid, type)
        end)
        |> Enum.reject(&is_nil/1)
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    %{
      id: label,
      pid: pid,
      label: label,
      type: :supervisor,
      status: :running,
      children: children
    }
  end

  defp build_child_node(id, pid, type) when is_pid(pid) do
    label = get_node_label(id, pid)
    status = if Process.alive?(pid), do: :running, else: :undefined

    children =
      if type == :supervisor and status == :running do
        try do
          Supervisor.which_children(pid)
          |> Enum.map(fn {child_id, child_pid, child_type, _modules} ->
            build_child_node(child_id, child_pid, child_type)
          end)
          |> Enum.reject(&is_nil/1)
        rescue
          _ -> []
        catch
          :exit, _ -> []
        end
      else
        []
      end

    %{
      id: id,
      pid: pid,
      label: label,
      type: type,
      status: status,
      children: children
    }
  end

  defp build_child_node(id, :undefined, type) do
    %{
      id: id,
      pid: :undefined,
      label: format_id(id),
      type: type,
      status: :undefined,
      children: []
    }
  end

  defp build_child_node(id, :restarting, type) do
    %{
      id: id,
      pid: :restarting,
      label: format_id(id),
      type: type,
      status: :restarting,
      children: []
    }
  end

  defp build_child_node(_, _, _), do: nil

  defp get_node_label(id, pid) when is_pid(pid) do
    case Process.info(pid, :registered_name) do
      {:registered_name, name} when is_atom(name) and name != [] ->
        name |> Atom.to_string() |> shorten_module_name()

      _ ->
        format_id(id)
    end
  end

  defp get_node_label(id, _), do: format_id(id)

  defp format_id(id) when is_atom(id) do
    id |> Atom.to_string() |> shorten_module_name()
  end

  defp format_id({module, _} = _id) when is_atom(module) do
    module |> Atom.to_string() |> shorten_module_name()
  end

  defp format_id(id) when is_binary(id), do: shorten_module_name(id)
  defp format_id(id), do: inspect(id) |> shorten_module_name()

  defp shorten_module_name(name) when is_binary(name) do
    # Remove common prefixes to make labels shorter
    name
    |> String.replace(~r/^Elixir\./, "")
    |> String.replace(~r/^YellowDog\./, "YD.")
  end

  defp get_registered_name(info) do
    case Keyword.get(info, :registered_name) do
      [] -> nil
      name when is_atom(name) -> name
      _ -> nil
    end
  end

  # Layout calculation functions

  defp calculate_subtree_widths(node, node_width, h_spacing) do
    children = Map.get(node, :children, [])

    if Enum.empty?(children) do
      Map.put(node, :subtree_width, node_width)
    else
      children_with_widths =
        Enum.map(children, &calculate_subtree_widths(&1, node_width, h_spacing))

      total_width =
        children_with_widths
        |> Enum.map(& &1.subtree_width)
        |> Enum.sum()
        |> Kernel.+(h_spacing * (length(children_with_widths) - 1))
        |> max(node_width)

      node
      |> Map.put(:children, children_with_widths)
      |> Map.put(:subtree_width, total_width)
    end
  end

  defp assign_positions(node, x, y, node_width, node_height, v_spacing) do
    subtree_width = Map.get(node, :subtree_width, node_width)
    node_x = x + (subtree_width - node_width) / 2
    node_y = y

    children = Map.get(node, :children, [])

    if Enum.empty?(children) do
      node
      |> Map.put(:x, node_x)
      |> Map.put(:y, node_y)
    else
      children_y = y + node_height + v_spacing

      {positioned_children, _} =
        Enum.reduce(children, {[], x}, fn child, {acc, current_x} ->
          child_width = Map.get(child, :subtree_width, node_width)

          positioned_child =
            assign_positions(child, current_x, children_y, node_width, node_height, v_spacing)

          {acc ++ [positioned_child], current_x + child_width + 30}
        end)

      node
      |> Map.put(:x, node_x)
      |> Map.put(:y, node_y)
      |> Map.put(:children, positioned_children)
    end
  end

  defp tree_depth(nil), do: 0

  defp tree_depth(%{children: []}), do: 1

  defp tree_depth(%{children: children}) do
    1 + (children |> Enum.map(&tree_depth/1) |> Enum.max(fn -> 0 end))
  end

  defp tree_depth(_), do: 1

  defp tree_max_width(nil), do: 0

  defp tree_max_width(%{children: []}), do: 1

  defp tree_max_width(%{children: children}) do
    children_width = children |> Enum.map(&tree_max_width/1) |> Enum.sum()
    max(1, children_width)
  end

  defp tree_max_width(_), do: 1

  @doc """
  Format an MFA tuple as a human-readable string.
  """
  @spec format_mfa(mfa :: {module(), atom(), non_neg_integer()} | nil) :: String.t()
  def format_mfa({m, f, a}) when is_atom(m) and is_atom(f) and is_integer(a) do
    "#{inspect(m)}.#{f}/#{a}"
  end

  def format_mfa(_), do: "N/A"

  @doc """
  Format bytes as a human-readable memory string.
  """
  @spec format_memory(bytes :: non_neg_integer()) :: String.t()
  def format_memory(bytes) when is_integer(bytes) and bytes >= 0 do
    cond do
      bytes >= 1_073_741_824 ->
        "#{Float.round(bytes / 1_073_741_824, 2)} GB"

      bytes >= 1_048_576 ->
        "#{Float.round(bytes / 1_048_576, 2)} MB"

      bytes >= 1024 ->
        "#{Float.round(bytes / 1024, 2)} KB"

      true ->
        "#{bytes} B"
    end
  end

  def format_memory(_), do: "0 B"
end
