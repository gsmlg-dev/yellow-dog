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

  # All YellowDog application supervisors to include in the process map
  @app_supervisors [
    YellowDog.Supervisor,
    YellowDog.Console.Supervisor,
    YellowDog.Telemetry.Supervisor
  ]

  @doc """
  Get the complete supervision tree for all YellowDog applications.

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
    # Build trees for all running YellowDog application supervisors
    app_trees =
      @app_supervisors
      |> Enum.map(fn supervisor_name ->
        case Process.whereis(supervisor_name) do
          nil -> nil
          pid -> build_tree_from_supervisor(pid, format_supervisor_label(supervisor_name))
        end
      end)
      |> Enum.reject(&is_nil/1)

    case app_trees do
      [] ->
        nil

      [single_tree] ->
        single_tree

      trees ->
        # Create a virtual root node containing all application supervisors
        %{
          id: :yellow_dog_apps,
          pid: self(),
          label: "YellowDog",
          type: :supervisor,
          status: :running,
          children: trees
        }
    end
  end

  defp format_supervisor_label(YellowDog.Supervisor), do: "Core"
  defp format_supervisor_label(YellowDog.Console.Supervisor), do: "Console"
  defp format_supervisor_label(YellowDog.Telemetry.Supervisor), do: "Telemetry"
  defp format_supervisor_label(name), do: name |> Atom.to_string() |> shorten_module_name()

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
    catch
      _, _ -> {:error, :invalid_pid}
    end
  end

  def parse_pid(_), do: {:error, :invalid_pid}

  @doc """
  Calculate tree layout positions for SVG rendering.

  Returns tree with added x, y coordinates for each node.
  Uses a horizontal left-to-right tree layout algorithm.
  """
  @spec calculate_layout(map(), keyword()) :: map()
  def calculate_layout(tree, opts \\ []) do
    node_width = Keyword.get(opts, :node_width, 180)
    node_height = Keyword.get(opts, :node_height, 40)
    h_spacing = Keyword.get(opts, :h_spacing, 60)
    v_spacing = Keyword.get(opts, :v_spacing, 10)
    expanded_pids = Keyword.get(opts, :expanded_pids, MapSet.new())

    # Horizontal layout: parent on left, children on right, stacked vertically
    {laid_out, _} =
      layout_node_horizontal(
        tree,
        0,
        0,
        node_width,
        node_height,
        h_spacing,
        v_spacing,
        expanded_pids
      )

    laid_out
  end

  defp layout_node_horizontal(
         node,
         x,
         y,
         node_width,
         node_height,
         h_spacing,
         v_spacing,
         expanded_pids
       ) do
    children = Map.get(node, :children, [])
    pid = Map.get(node, :pid)
    is_expanded = is_pid(pid) and MapSet.member?(expanded_pids, pid)

    # If no children or collapsed, just position this node
    if children == [] or not is_expanded do
      node_with_pos =
        node
        |> Map.put(:x, x)
        |> Map.put(:y, y)
        |> Map.put(:expanded, is_expanded)

      {node_with_pos, y + node_height + v_spacing}
    else
      # Children go to the right of parent
      children_x = x + node_width + h_spacing

      # Layout all children vertically stacked
      {reversed_children, next_y} =
        Enum.reduce(children, {[], y}, fn child, {acc, current_y} ->
          {laid_out_child, new_y} =
            layout_node_horizontal(
              child,
              children_x,
              current_y,
              node_width,
              node_height,
              h_spacing,
              v_spacing,
              expanded_pids
            )

          {[laid_out_child | acc], new_y}
        end)

      laid_out_children = Enum.reverse(reversed_children)

      # Center parent vertically relative to children
      children_start = y
      children_end = next_y - v_spacing
      parent_y = children_start + (children_end - children_start - node_height) / 2
      parent_y = max(y, parent_y)

      node_with_pos =
        node
        |> Map.put(:x, x)
        |> Map.put(:y, parent_y)
        |> Map.put(:children, laid_out_children)
        |> Map.put(:expanded, is_expanded)

      {node_with_pos, next_y}
    end
  end

  @doc """
  Count total nodes in the tree.
  """
  @spec count_nodes(map() | nil) :: non_neg_integer()
  def count_nodes(nil), do: 0

  def count_nodes(%{children: children}) do
    1 + Enum.sum_by(children, &count_nodes/1)
  end

  def count_nodes(_), do: 1

  @doc """
  Calculate the dimensions needed for the SVG canvas based on actual laid out tree.
  """
  @spec calculate_dimensions(map(), keyword()) :: {non_neg_integer(), non_neg_integer()}
  def calculate_dimensions(tree, opts \\ []) do
    padding = Keyword.get(opts, :padding, 40)
    node_width = Keyword.get(opts, :node_width, 180)
    node_height = Keyword.get(opts, :node_height, 40)

    # Calculate actual bounds from laid out tree
    {max_x, max_y} = find_max_bounds(tree, 0, 0)

    width = trunc(max_x + node_width + padding * 2)
    height = trunc(max_y + node_height + padding * 2)

    {max(width, 400), max(height, 200)}
  end

  defp find_max_bounds(nil, max_x, max_y), do: {max_x, max_y}

  defp find_max_bounds(%{x: x, y: y, children: children}, max_x, max_y) do
    current_max_x = max(max_x, x)
    current_max_y = max(max_y, y)

    Enum.reduce(children, {current_max_x, current_max_y}, fn child, {mx, my} ->
      find_max_bounds(child, mx, my)
    end)
  end

  defp find_max_bounds(%{x: x, y: y}, max_x, max_y) do
    {max(max_x, x), max(max_y, y)}
  end

  defp find_max_bounds(_, max_x, max_y), do: {max_x, max_y}

  # Private functions

  defp build_tree_from_supervisor(pid, label) when is_pid(pid) do
    children =
      try do
        Supervisor.which_children(pid)
        |> Enum.map(fn {id, child_pid, type, _modules} ->
          build_child_node(id, child_pid, type)
        end)
        |> Enum.reject(&is_nil/1)
      catch
        _, _ -> []
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
        catch
          _, _ -> []
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
    |> String.replace("YellowDog.Console.", "Console.")
    |> String.replace("YellowDog.Telemetry.", "Telemetry.")
    |> String.replace(~r/^YellowDog\./, "YD.")
  end

  defp get_registered_name(info) do
    case Keyword.get(info, :registered_name) do
      [] -> nil
      name when is_atom(name) -> name
      _ -> nil
    end
  end

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
