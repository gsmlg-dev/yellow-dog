defmodule YellowDog.Dns.ViewManager do
  @moduledoc """
  Supervisor that manages DNS View processes.

  The ViewManager supervises View processes and routes requests to the
  appropriate view based on priority and ACL matching.

  ## Children

  - View processes (one per configured view, ordered by priority)
  - Default view process (always exists, cannot be deleted, matches any)

  ## Request Routing

  1. Receive request from connection process (with PID)
  2. Evaluate views in priority order
  3. Match client against view ACL (client IP or EDNS client subnet if enabled)
  4. First matching view wins
  5. If no match → route to default view (ACL matches any)
  6. Forward to matched View (with connection process PID)
  """

  use DynamicSupervisor

  alias YellowDog.Telemetry
  alias YellowDog.Dns.View
  alias YellowDog.Dns.ConfigPersistence

  @doc """
  Starts the ViewManager supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    Telemetry.info("ViewManager starting")
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Resolves a DNS query through the appropriate view.

  Routes the request to the matching view based on client IP ACL matching.
  The view is selected by priority order - first matching view wins.

  ## Parameters

  - `connection_pid` - PID of the connection process for response routing
  - `client_ip` - Client IP address for ACL matching
  - `query_id` - DNS query ID for tracking
  - `query` - DNS query message

  ## Returns

  - `{:ok, response}` on success
  - `{:error, reason}` on failure
  """
  @spec resolve(pid(), :inet.ip_address(), non_neg_integer(), DNS.Message.t()) ::
          {:ok, DNS.Message.t()} | {:error, atom()}
  def resolve(connection_pid, client_ip, query_id, query) do
    resolve(__MODULE__, connection_pid, client_ip, query_id, query)
  end

  @spec resolve(
          Supervisor.supervisor(),
          pid(),
          :inet.ip_address(),
          non_neg_integer(),
          DNS.Message.t()
        ) :: {:ok, DNS.Message.t()} | {:error, atom()}
  def resolve(supervisor, connection_pid, client_ip, query_id, query) do
    # Find matching view by priority
    case find_matching_view(supervisor, client_ip) do
      {:ok, view_pid, view_name} ->
        # Notify connection process of view match
        send(connection_pid, {:view_matched, query_id, view_name})

        # Delegate resolution to view
        View.resolve(view_pid, connection_pid, query_id, query)

      {:error, :no_match} ->
        # Use default view if exists
        case find_default_view(supervisor) do
          {:ok, view_pid} ->
            send(connection_pid, {:view_matched, query_id, "default"})
            View.resolve(view_pid, connection_pid, query_id, query)

          :error ->
            Telemetry.warning("No matching view for client", %{
              client_ip: format_ip(client_ip)
            })

            {:error, :refused}
        end
    end
  end

  @doc """
  Starts a new view process.

  ## Parameters

  - `view_config` - View configuration map with:
    - `:name` - View name (required)
    - `:priority` - Priority for matching (lower = higher priority)
    - `:acl` - ACL configuration (`:any` matches all)
    - `:zones` - List of zone references
    - `:rpz_zones` - List of RPZ zone references (ordered by specificity)
    - `:recursion_enabled` - Enable recursive resolution
    - `:ecs_enabled` - Enable EDNS client subnet matching

  ## Returns

  - `{:ok, pid}` on success
  - `{:error, reason}` on failure
  """
  @spec start_view(map() | keyword()) :: DynamicSupervisor.on_start_child()
  def start_view(view_config) do
    start_view(__MODULE__, view_config)
  end

  @spec start_view(Supervisor.supervisor(), map() | keyword()) ::
          DynamicSupervisor.on_start_child()
  def start_view(supervisor, view_config) do
    config = normalize_config(view_config)
    view_name = Map.get(config, :name) || Keyword.get(view_config, :name)

    child_spec = %{
      id: {:view, view_name},
      start: {View, :start_link, [config]},
      restart: :permanent,
      type: :worker
    }

    case DynamicSupervisor.start_child(supervisor, child_spec) do
      {:ok, pid} = result ->
        Telemetry.info("View started", %{name: view_name, pid: inspect(pid)})
        result

      {:error, reason} = error ->
        Telemetry.error("Failed to start view", %{name: view_name, reason: inspect(reason)})
        error
    end
  end

  @doc """
  Stops a view process.
  """
  @spec stop_view(String.t()) :: :ok | {:error, :not_found}
  def stop_view(view_name) do
    stop_view(__MODULE__, view_name)
  end

  @spec stop_view(Supervisor.supervisor(), String.t()) :: :ok | {:error, :not_found}
  def stop_view(supervisor, view_name) do
    case find_view(supervisor, view_name) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(supervisor, pid)
        Telemetry.info("View stopped", %{name: view_name})
        :ok

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Enables a view by name.
  """
  @spec enable_view(String.t()) :: :ok | {:error, :not_found}
  def enable_view(view_name), do: enable_view(__MODULE__, view_name)

  @spec enable_view(Supervisor.supervisor(), String.t()) :: :ok | {:error, :not_found}
  def enable_view(supervisor, view_name) do
    case find_view(supervisor, view_name) do
      {:ok, pid} ->
        View.set_enabled(pid, true)
        Telemetry.info("View enabled", %{name: view_name})
        :ok

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Disables a view by name. Disabled views do not match any queries.
  """
  @spec disable_view(String.t()) :: :ok | {:error, :not_found}
  def disable_view(view_name), do: disable_view(__MODULE__, view_name)

  @spec disable_view(Supervisor.supervisor(), String.t()) :: :ok | {:error, :not_found}
  def disable_view(supervisor, view_name) do
    case find_view(supervisor, view_name) do
      {:ok, pid} ->
        View.set_enabled(pid, false)
        Telemetry.info("View disabled", %{name: view_name})
        :ok

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Deletes a view and its associated zones.

  This is a destructive operation that:
  1. Stops all zones belonging to the view
  2. Terminates the view process
  """
  @spec delete_view(String.t()) :: :ok | {:error, :not_found}
  def delete_view(view_name), do: delete_view(__MODULE__, view_name)

  @spec delete_view(Supervisor.supervisor(), String.t()) :: :ok | {:error, :not_found}
  def delete_view(supervisor, view_name) do
    case find_view(supervisor, view_name) do
      {:ok, _pid} ->
        # Stop associated zones first
        try do
          zones = YellowDog.Dns.ZoneController.list_zones_for_view(view_name)

          Enum.each(zones, fn {zone_type, zone_name, _pid} ->
            YellowDog.Dns.ZoneController.stop_zone(view_name, zone_type, zone_name)
          end)
        rescue
          _e in [ArgumentError, RuntimeError, MatchError, FunctionClauseError] -> :ok
        catch
          :exit, _ -> :ok
        end

        # Stop the view
        stop_view(supervisor, view_name)

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Gets a view process by name.
  """
  @spec get_view(String.t()) :: {:ok, pid()} | :error
  def get_view(view_name) do
    get_view(__MODULE__, view_name)
  end

  @spec get_view(Supervisor.supervisor(), String.t()) :: {:ok, pid()} | :error
  def get_view(supervisor, view_name) do
    find_view(supervisor, view_name)
  end

  @doc """
  Lists all active views.
  """
  @spec list_views() :: [{String.t(), pid(), integer()}]
  def list_views do
    list_views(__MODULE__)
  end

  @spec list_views(Supervisor.supervisor()) :: [{String.t(), pid(), integer()}]
  def list_views(supervisor) do
    for {_id, pid, _type, _modules} <- DynamicSupervisor.which_children(supervisor),
        is_pid(pid) do
      # DynamicSupervisor always returns :undefined as id, so we get the name from the View process
      {View.get_name(pid), pid, get_view_priority(pid)}
    end
    |> Enum.sort_by(fn {_name, _pid, priority} -> priority end)
  end

  @doc """
  Returns statistics for all views.
  """
  @spec stats() :: map()
  def stats do
    stats(__MODULE__)
  end

  @spec stats(Supervisor.supervisor()) :: map()
  def stats(supervisor) do
    views = list_views(supervisor)

    view_stats =
      Map.new(views, fn {name, pid, priority} ->
        {name, Map.put(View.stats(pid), :priority, priority)}
      end)

    %{
      view_count: length(views),
      views: view_stats
    }
  end

  @doc """
  Updates views from configuration.

  Compares current views with new configuration and:
  - Starts new views
  - Stops removed views
  - Updates existing views
  """
  @spec update_views([map() | keyword()]) :: :ok | {:error, term()}
  def update_views(view_configs) do
    update_views(__MODULE__, view_configs)
  end

  @spec update_views(Supervisor.supervisor(), [map() | keyword()]) :: :ok | {:error, term()}
  def update_views(supervisor, view_configs) do
    current =
      MapSet.new(list_views(supervisor), fn {name, _pid, _prio} -> name end)

    new_names = MapSet.new(view_configs, &get_view_name/1)
    current_names = current

    # Stop removed views (except default)
    removed = MapSet.difference(current_names, new_names)

    Enum.each(removed, fn name ->
      if name != "default" do
        stop_view(supervisor, name)
      end
    end)

    # Start or update views
    Enum.each(view_configs, fn config ->
      name = get_view_name(config)

      case get_view(supervisor, name) do
        {:ok, pid} ->
          # Existing view - update config
          View.reload(pid, config)

        :error ->
          # New view
          start_view(supervisor, config)
      end
    end)

    Telemetry.info("Views updated", %{
      added: MapSet.difference(new_names, current_names) |> MapSet.size(),
      removed: MapSet.size(removed),
      total: length(view_configs)
    })

    :ok
  end

  # Persistence Functions

  @doc """
  Saves current view configuration to the data directory.

  Collects all view configurations and persists them to TOML files.

  ## Parameters
  - `data_path` - Optional path to the DNS data directory (default: from config)
  - `opts` - Options passed to ConfigPersistence

  ## Returns
  - `:ok` on success
  - `{:error, reason}` on failure
  """
  @spec save_config(String.t(), keyword()) :: :ok | {:error, term()}
  def save_config(data_path \\ ConfigPersistence.default_data_path(), opts \\ []) do
    views = ConfigPersistence.collect_views()
    ConfigPersistence.save_views(data_path, views, opts)
  end

  @doc """
  Loads view configuration from the data directory and applies it.

  ## Parameters
  - `data_path` - Optional path to the DNS data directory (default: from config)

  ## Returns
  - `:ok` on success
  - `{:error, reason}` on failure
  """
  @spec load_config(String.t()) :: :ok | {:error, term()}
  def load_config(data_path \\ ConfigPersistence.default_data_path()) do
    load_config(__MODULE__, data_path)
  end

  @spec load_config(Supervisor.supervisor(), String.t()) :: :ok | {:error, term()}
  def load_config(supervisor, data_path) do
    views_path = Path.join(data_path, "views.toml")

    case YellowDog.Dns.ViewStore.load_views(views_path) do
      {:ok, views} when views != [] ->
        # Convert view configs to the format expected by update_views
        view_configs =
          Enum.map(views, fn view ->
            %{
              name: view.name,
              priority: view[:priority] || 100,
              acl: view[:match_clients] || view[:acl],
              zones: view[:zones] || [],
              recursion_enabled: view[:recursion] || false,
              ecs_enabled: view[:ecs_enabled] || false
            }
          end)

        update_views(supervisor, view_configs)

      {:ok, []} ->
        Telemetry.info("No views found in config file", %{path: views_path})
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  # Private Functions

  defp find_matching_view(supervisor, client_ip) do
    # Get all views sorted by priority
    views = list_views(supervisor)

    # Find first matching view (excluding default for now)
    result =
      Enum.find_value(views, fn {name, pid, _priority} ->
        if name != "default" and View.matches?(pid, client_ip) do
          {:ok, pid, name}
        else
          nil
        end
      end)

    case result do
      nil -> {:error, :no_match}
      match -> match
    end
  end

  defp find_default_view(supervisor) do
    find_view(supervisor, "default")
  end

  defp find_view(supervisor, view_name) do
    # DynamicSupervisor always returns :undefined as id, so we need to check each child
    children = DynamicSupervisor.which_children(supervisor)

    result =
      Enum.find_value(children, fn {_id, pid, _type, _modules} ->
        if is_pid(pid) do
          try do
            if View.get_name(pid) == view_name do
              {:ok, pid}
            else
              nil
            end
          catch
            :exit, _ -> nil
          end
        else
          nil
        end
      end)

    result || :error
  end

  defp get_view_priority(pid) do
    try do
      View.get_priority(pid)
    catch
      _, _ -> :infinity
    end
  end

  defp normalize_config(config) when is_map(config), do: config
  defp normalize_config(config) when is_list(config), do: Map.new(config)

  defp get_view_name(config) when is_map(config), do: Map.get(config, :name)
  defp get_view_name(config) when is_list(config), do: Keyword.get(config, :name)

  defp format_ip(ip) when is_tuple(ip), do: :inet.ntoa(ip) |> to_string()
  defp format_ip(ip), do: inspect(ip)
end
