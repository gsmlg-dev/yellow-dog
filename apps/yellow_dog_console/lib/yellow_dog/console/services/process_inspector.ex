defmodule YellowDog.Console.ProcessInspector do
  @moduledoc """
  Service for inspecting Erlang/OTP supervision trees.

  Provides introspection capabilities for YellowDog umbrella applications,
  allowing visualization of process hierarchies and status information.
  """

  @yellowdog_apps [
    :yellow_dog,
    :yellow_dog_dns,
    :yellow_dog_dhcpv4,
    :yellow_dog_dhcpv6,
    :yellow_dog_mdns,
    :yellow_dog_console,
    :yellow_dog_telemetry
  ]

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
  Returns the list of YellowDog applications being tracked.
  """
  def yellowdog_apps, do: @yellowdog_apps

  @doc """
  Get supervision trees for all YellowDog applications.

  Returns a list of application tree maps, each containing:
  - app: atom - application name
  - app_label: String.t - human-readable label
  - supervisor: pid | nil - root supervisor PID
  - running: boolean - whether the app is running
  - children: [process_node] - child processes
  """
  @spec get_trees() :: [map()]
  def get_trees do
    @yellowdog_apps
    |> Enum.map(&build_app_tree/1)
  end

  @doc """
  Get detailed status information for a specific process.

  Returns `{:ok, status_map}` or `{:error, :process_not_found}`.
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

  Handles both "#PID<0.123.0>" and "<0.123.0>" formats.
  """
  @spec parse_pid(String.t()) :: {:ok, pid()} | {:error, :invalid_pid}
  def parse_pid(pid_string) when is_binary(pid_string) do
    # Handle "#PID<0.123.0>" format
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

  # Private functions

  defp build_app_tree(app) do
    running = application_started?(app)
    supervisor = if running, do: get_app_supervisor(app), else: nil
    children = if supervisor, do: get_children(supervisor), else: []

    %{
      app: app,
      app_label: get_app_label(app),
      supervisor: supervisor,
      running: running,
      children: children
    }
  end

  defp application_started?(app) do
    Application.started_applications()
    |> Enum.any?(fn {name, _, _} -> name == app end)
  end

  defp get_app_supervisor(app) do
    # Try common supervisor naming patterns
    supervisor_names = [
      # e.g., YellowDog.Dns.Supervisor
      Module.concat([camelize_app(app), Supervisor]),
      # e.g., YellowDog.Console.Supervisor
      Module.concat([camelize_app(app), "Supervisor"]),
      # Direct app module
      camelize_app(app)
    ]

    Enum.find_value(supervisor_names, fn name ->
      case Process.whereis(name) do
        nil -> nil
        pid when is_pid(pid) -> pid
      end
    end) || find_supervisor_from_application(app)
  end

  defp find_supervisor_from_application(app) do
    case Application.get_application(app) do
      nil ->
        nil

      ^app ->
        # Try to find via Application.get_env
        case Application.get_env(app, :supervisor) do
          nil -> nil
          name when is_atom(name) -> Process.whereis(name)
          _ -> nil
        end
    end
  end

  defp camelize_app(app) do
    app
    |> Atom.to_string()
    |> String.split("_")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join()
    |> String.to_atom()
  end

  defp get_children(supervisor_pid) when is_pid(supervisor_pid) do
    try do
      case Supervisor.which_children(supervisor_pid) do
        children when is_list(children) ->
          Enum.map(children, fn {id, pid, type, modules} ->
            build_child_node(id, pid, type, modules)
          end)

        _ ->
          []
      end
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end
  end

  defp get_children(_), do: []

  defp build_child_node(id, pid, type, modules) do
    node_status = get_node_status(pid)
    label = get_node_label(id, pid)

    children =
      if type == :supervisor and is_pid(pid) and node_status == :running do
        get_children(pid)
      else
        []
      end

    %{
      id: id,
      pid: pid,
      type: type,
      modules: modules,
      children: children,
      label: label,
      status: node_status
    }
  end

  defp get_node_status(pid) when is_pid(pid) do
    if Process.alive?(pid), do: :running, else: :undefined
  end

  defp get_node_status(:undefined), do: :undefined
  defp get_node_status(:restarting), do: :restarting
  defp get_node_status(_), do: :undefined

  defp get_node_label(id, pid) when is_pid(pid) do
    case Process.info(pid, :registered_name) do
      {:registered_name, name} when is_atom(name) -> Atom.to_string(name)
      _ -> format_id(id)
    end
  end

  defp get_node_label(id, _), do: format_id(id)

  defp format_id(id) when is_atom(id), do: Atom.to_string(id)
  defp format_id(id) when is_binary(id), do: id
  defp format_id({module, _} = id) when is_atom(module), do: inspect(id)
  defp format_id(id), do: inspect(id)

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

  @doc """
  Get a human-readable label for an application.
  """
  @spec get_app_label(atom()) :: String.t()
  def get_app_label(:yellow_dog), do: "Core"
  def get_app_label(:yellow_dog_dns), do: "DNS"
  def get_app_label(:yellow_dog_dhcpv4), do: "DHCPv4"
  def get_app_label(:yellow_dog_dhcpv6), do: "DHCPv6"
  def get_app_label(:yellow_dog_mdns), do: "mDNS"
  def get_app_label(:yellow_dog_console), do: "Console"
  def get_app_label(:yellow_dog_telemetry), do: "Telemetry"

  def get_app_label(app),
    do: app |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
end
