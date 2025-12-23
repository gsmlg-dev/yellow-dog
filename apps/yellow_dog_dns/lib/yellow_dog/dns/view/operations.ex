defmodule YellowDog.Dns.View.Operations do
  @moduledoc """
  Operations API for runtime control and management of DNS views.

  Provides high-level operations for:
  - Manual view management (add, remove, update)
  - System health checks
  - Statistics and metrics
  - Hot-reload control
  - Diagnostics and troubleshooting

  ## Usage

      # Get comprehensive system status
      Operations.status()

      # Health check
      Operations.health_check()

      # Manual view management
      Operations.add_view(view)
      Operations.remove_view("view_name")
      Operations.update_view("view_name", updated_view)

      # Statistics
      Operations.get_metrics()

      # Hot-reload control
      Operations.enable_hot_reload()
      Operations.disable_hot_reload()
      Operations.trigger_reload()

  """

  alias YellowDog.Telemetry
  alias YellowDog.Dns.View
  alias YellowDog.Dns.View.Manager, as: ViewManager
  alias YellowDog.Dns.View.ConfigWatcher

  ## Public API - View Management

  @doc """
  Add a new view to the system.

  The view is validated before being added. If validation fails,
  returns an error and the existing views are not modified.

  ## Examples

      iex> view = View.new("guests", "10.99.0.0/16", ["guest.example.com"], true)
      iex> Operations.add_view(view)
      {:ok, %{added: ["guests"], total_views: 3}}

      iex> duplicate_view = View.new("existing", "any", [], true)
      iex> Operations.add_view(duplicate_view)
      {:error, {:duplicate_view_name, "existing"}}
  """
  @spec add_view(View.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def add_view(view, opts \\ []) do
    manager_pid = Keyword.get(opts, :manager_pid, ViewManager)

    with {:ok, current_views} <- get_views(manager_pid),
         :ok <- validate_new_view(view, current_views),
         new_views <- current_views ++ [view],
         :ok <- ViewManager.update_views(manager_pid, new_views) do
      Telemetry.info("View added via Operations API", %{
        view_name: view.name,
        total_views: length(new_views)
      })

      {:ok, %{added: [view.name], total_views: length(new_views)}}
    end
  end

  @doc """
  Remove a view from the system by name.

  Returns error if view doesn't exist or if it's the last view.

  ## Examples

      iex> Operations.remove_view("old_view")
      {:ok, %{removed: ["old_view"], total_views: 2}}

      iex> Operations.remove_view("nonexistent")
      {:error, :view_not_found}
  """
  @spec remove_view(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def remove_view(view_name, opts \\ []) do
    manager_pid = Keyword.get(opts, :manager_pid, ViewManager)

    with {:ok, current_views} <- get_views(manager_pid),
         {:ok, view} <- find_view_by_name(current_views, view_name),
         :ok <- validate_can_remove(current_views),
         new_views <- List.delete(current_views, view),
         :ok <- ViewManager.update_views(manager_pid, new_views) do
      Telemetry.info("View removed via Operations API", %{
        view_name: view_name,
        total_views: length(new_views)
      })

      {:ok, %{removed: [view_name], total_views: length(new_views)}}
    end
  end

  @doc """
  Update an existing view with new configuration.

  The view is identified by name. The updated view must have the same name.

  ## Examples

      iex> updated = View.new("internal", "localnets", ["corp.example.com", "new.example.com"], true)
      iex> Operations.update_view("internal", updated)
      {:ok, %{updated: ["internal"], total_views: 3}}
  """
  @spec update_view(String.t(), View.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_view(view_name, updated_view, opts \\ []) do
    manager_pid = Keyword.get(opts, :manager_pid, ViewManager)

    with :ok <- validate_view_name_matches(view_name, updated_view),
         {:ok, current_views} <- get_views(manager_pid),
         {:ok, _old_view} <- find_view_by_name(current_views, view_name),
         new_views <- replace_view(current_views, view_name, updated_view),
         :ok <- ViewManager.update_views(manager_pid, new_views) do
      Telemetry.info("View updated via Operations API", %{
        view_name: view_name,
        total_views: length(new_views)
      })

      {:ok, %{updated: [view_name], total_views: length(new_views)}}
    end
  end

  @doc """
  Replace all views with a new set.

  This is an atomic operation - either all views are replaced or none are.

  ## Examples

      iex> new_views = [View.new("v1", "any", [], true), View.new("v2", "localhost", [], false)]
      iex> Operations.replace_all_views(new_views)
      {:ok, %{total_views: 2, previous_count: 3}}
  """
  @spec replace_all_views([View.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def replace_all_views(new_views, opts \\ []) when is_list(new_views) do
    manager_pid = Keyword.get(opts, :manager_pid, ViewManager)

    with {:ok, current_views} <- get_views(manager_pid),
         :ok <- ViewManager.update_views(manager_pid, new_views) do
      Telemetry.info("All views replaced via Operations API", %{
        previous_count: length(current_views),
        new_count: length(new_views)
      })

      {:ok, %{total_views: length(new_views), previous_count: length(current_views)}}
    end
  end

  ## Public API - Status and Health

  @doc """
  Get comprehensive system status including all components.

  Returns detailed status of ViewManager, ConfigWatcher (if running),
  and overall health information.

  ## Examples

      iex> Operations.status()
      {:ok, %{
        manager: %{view_count: 3, update_count: 5, ...},
        watcher: %{watching: true, reload_count: 2, ...},
        health: :healthy,
        uptime: 3600
      }}
  """
  @spec status(keyword()) :: {:ok, map()} | {:error, term()}
  def status(opts \\ []) do
    manager_pid = Keyword.get(opts, :manager_pid, ViewManager)
    watcher_pid = Keyword.get(opts, :watcher_pid)

    with {:ok, manager_stats} <- safe_get_manager_stats(manager_pid),
         watcher_status <- safe_get_watcher_status(watcher_pid) do
      status_map = %{
        manager: manager_stats,
        watcher: watcher_status,
        health: determine_health(manager_stats, watcher_status),
        timestamp: DateTime.utc_now()
      }

      {:ok, status_map}
    end
  end

  @doc """
  Perform comprehensive health check of the hot-reload system.

  Returns `:healthy`, `:degraded`, or `:unhealthy` along with details.

  ## Examples

      iex> Operations.health_check()
      {:ok, %{
        status: :healthy,
        checks: %{
          manager: :passing,
          watcher: :passing,
          views: :passing
        },
        details: %{...}
      }}
  """
  @spec health_check(keyword()) :: {:ok, map()}
  def health_check(opts \\ []) do
    manager_pid = Keyword.get(opts, :manager_pid, ViewManager)
    watcher_pid = Keyword.get(opts, :watcher_pid)

    checks = %{
      manager: check_manager_health(manager_pid),
      watcher: check_watcher_health(watcher_pid),
      views: check_views_health(manager_pid),
      configuration: check_configuration_health()
    }

    overall_status = determine_overall_health(checks)

    health_report = %{
      status: overall_status,
      checks: checks,
      details: build_health_details(checks),
      timestamp: DateTime.utc_now()
    }

    {:ok, health_report}
  end

  ## Public API - Metrics and Statistics

  @doc """
  Get comprehensive metrics for monitoring and dashboards.

  Returns aggregated metrics from all components.

  ## Examples

      iex> Operations.get_metrics()
      {:ok, %{
        views: %{count: 3, names: [...]},
        reloads: %{total: 12, successful: 11, failed: 1},
        operations: %{add: 2, remove: 1, update: 3},
        performance: %{avg_reload_time_ms: 8}
      }}
  """
  @spec get_metrics(keyword()) :: {:ok, map()} | {:error, term()}
  def get_metrics(opts \\ []) do
    manager_pid = Keyword.get(opts, :manager_pid, ViewManager)
    watcher_pid = Keyword.get(opts, :watcher_pid)

    with {:ok, manager_stats} <- safe_get_manager_stats(manager_pid),
         watcher_status <- safe_get_watcher_status(watcher_pid) do
      metrics = %{
        views: extract_view_metrics(manager_stats),
        reloads: extract_reload_metrics(watcher_status),
        operations: extract_operation_metrics(manager_stats),
        timestamp: DateTime.utc_now()
      }

      {:ok, metrics}
    end
  end

  ## Public API - Hot-Reload Control

  @doc """
  Manually trigger a configuration reload from file.

  This bypasses the automatic file watching and forces an immediate reload.

  ## Examples

      iex> Operations.trigger_reload()
      {:ok, %{status: :reloaded, view_count: 3}}

      iex> Operations.trigger_reload()
      {:error, :watcher_not_running}
  """
  @spec trigger_reload(keyword()) :: {:ok, map()} | {:error, term()}
  def trigger_reload(opts \\ []) do
    watcher_pid = Keyword.get(opts, :watcher_pid)

    case find_watcher_pid(watcher_pid) do
      {:ok, pid} ->
        case ConfigWatcher.reload(pid) do
          :ok ->
            Telemetry.info("Manual reload triggered via Operations API")
            {:ok, %{status: :reloaded, triggered_at: DateTime.utc_now()}}

          {:error, reason} ->
            Telemetry.error("Manual reload failed", %{reason: inspect(reason)})
            {:error, reason}
        end

      {:error, :not_found} ->
        {:error, :watcher_not_running}
    end
  end

  @doc """
  Get the current configuration file path being watched.

  ## Examples

      iex> Operations.get_config_path()
      {:ok, "config/views.toml"}
  """
  @spec get_config_path() :: {:ok, String.t()} | {:error, :not_configured}
  def get_config_path do
    case Application.get_env(:yellow_dog_dns, :views_config_path) do
      nil -> {:error, :not_configured}
      path -> {:ok, path}
    end
  end

  @doc """
  Check if hot-reload is currently enabled.

  ## Examples

      iex> Operations.hot_reload_enabled?()
      true
  """
  @spec hot_reload_enabled?() :: boolean()
  def hot_reload_enabled? do
    Application.get_env(:yellow_dog_dns, :hot_reload_enabled, false)
  end

  ## Public API - Diagnostics

  @doc """
  List all current views with detailed information.

  ## Examples

      iex> Operations.list_views()
      {:ok, [
        %{name: "internal", match_clients: "localnets", zones: [...], ...},
        %{name: "external", match_clients: "any", zones: [...], ...}
      ]}
  """
  @spec list_views(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_views(opts \\ []) do
    manager_pid = Keyword.get(opts, :manager_pid, ViewManager)

    with {:ok, views} <- get_views(manager_pid) do
      view_details =
        Enum.map(views, fn view ->
          %{
            name: view.name,
            match_clients: format_match_clients(view.match_clients),
            zones: view.zones,
            recursion_enabled: view.recursion_enabled,
            zone_count: length(view.zones)
          }
        end)

      {:ok, view_details}
    end
  end

  @doc """
  Get detailed information about a specific view.

  ## Examples

      iex> Operations.get_view_info("internal")
      {:ok, %{name: "internal", match_clients: "localnets", ...}}
  """
  @spec get_view_info(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_view_info(view_name, opts \\ []) do
    manager_pid = Keyword.get(opts, :manager_pid, ViewManager)

    with {:ok, views} <- get_views(manager_pid),
         {:ok, view} <- find_view_by_name(views, view_name) do
      info = %{
        name: view.name,
        match_clients: format_match_clients(view.match_clients),
        zones: view.zones,
        recursion_enabled: view.recursion_enabled,
        zone_count: length(view.zones),
        match_clients_details: inspect_match_clients(view.match_clients)
      }

      {:ok, info}
    end
  end

  @doc """
  Test which view a client IP would match.

  Useful for debugging and verifying ACL configuration.

  ## Examples

      iex> Operations.test_client_match({192, 168, 1, 100})
      {:ok, %{matched_view: "internal", client_ip: "192.168.1.100"}}
  """
  @spec test_client_match(:inet.ip_address(), keyword()) :: {:ok, map()} | {:error, term()}
  def test_client_match(client_ip, opts \\ []) do
    manager_pid = Keyword.get(opts, :manager_pid, ViewManager)

    with {:ok, views} <- get_views(manager_pid),
         {:ok, matched_view} <- View.match_client(client_ip, views) do
      result = %{
        matched_view: matched_view.name,
        client_ip: format_ip(client_ip),
        recursion_enabled: matched_view.recursion_enabled,
        accessible_zones: matched_view.zones
      }

      {:ok, result}
    else
      {:error, :no_match} ->
        {:error, %{reason: :no_match, client_ip: format_ip(client_ip)}}
    end
  end

  ## Private Functions - Validation

  defp validate_new_view(view, current_views) do
    names = Enum.map(current_views, & &1.name)

    if view.name in names do
      {:error, {:duplicate_view_name, view.name}}
    else
      :ok
    end
  end

  defp validate_can_remove(current_views) do
    if length(current_views) <= 1 do
      {:error, :cannot_remove_last_view}
    else
      :ok
    end
  end

  defp validate_view_name_matches(expected_name, view) do
    if view.name == expected_name do
      :ok
    else
      {:error, {:name_mismatch, expected_name, view.name}}
    end
  end

  defp find_view_by_name(views, name) do
    case Enum.find(views, &(&1.name == name)) do
      nil -> {:error, :view_not_found}
      view -> {:ok, view}
    end
  end

  defp replace_view(views, name, new_view) do
    Enum.map(views, fn view ->
      if view.name == name, do: new_view, else: view
    end)
  end

  ## Private Functions - Status and Health

  defp safe_get_manager_stats(manager_pid) do
    try do
      stats = ViewManager.stats(manager_pid)
      {:ok, stats}
    catch
      :exit, _reason ->
        {:error, :manager_unavailable}
    end
  end

  defp safe_get_watcher_status(nil), do: %{status: :not_running}

  defp safe_get_watcher_status(watcher_pid) do
    try do
      ConfigWatcher.status(watcher_pid)
    catch
      :exit, reason ->
        %{status: :unavailable, error: inspect(reason)}
    end
  end

  defp determine_health(manager_stats, watcher_status) do
    cond do
      is_map(manager_stats) and manager_stats != %{} and
          (watcher_status == %{status: :not_running} or
             (is_map(watcher_status) and watcher_status[:watching] == true)) ->
        :healthy

      is_map(manager_stats) and manager_stats != %{} ->
        :degraded

      true ->
        :unhealthy
    end
  end

  defp check_manager_health(manager_pid) do
    try do
      ViewManager.stats(manager_pid)
      :passing
    catch
      :exit, _ -> :failing
    end
  end

  defp check_watcher_health(nil), do: :not_applicable

  defp check_watcher_health(watcher_pid) do
    try do
      status = ConfigWatcher.status(watcher_pid)

      if status.watching and status.error_count < 5 do
        :passing
      else
        :warning
      end
    catch
      :exit, _ -> :failing
    end
  end

  defp check_views_health(manager_pid) do
    try do
      stats = ViewManager.stats(manager_pid)

      if stats.view_count > 0 do
        :passing
      else
        :warning
      end
    catch
      :exit, _ -> :failing
    end
  end

  defp check_configuration_health do
    hot_reload = Application.get_env(:yellow_dog_dns, :hot_reload_enabled, false)
    config_path = Application.get_env(:yellow_dog_dns, :views_config_path)

    cond do
      not hot_reload -> :not_applicable
      is_nil(config_path) -> :warning
      File.exists?(config_path) -> :passing
      true -> :failing
    end
  end

  defp determine_overall_health(checks) do
    check_values = Map.values(checks)

    cond do
      Enum.any?(check_values, &(&1 == :failing)) -> :unhealthy
      Enum.any?(check_values, &(&1 == :warning)) -> :degraded
      true -> :healthy
    end
  end

  defp build_health_details(checks) do
    Enum.reduce(checks, %{}, fn {component, status}, acc ->
      Map.put(acc, component, %{status: status, message: health_message(component, status)})
    end)
  end

  defp health_message(:manager, :passing), do: "ViewManager is operational"
  defp health_message(:manager, :failing), do: "ViewManager is not responding"
  defp health_message(:watcher, :passing), do: "ConfigWatcher is active and watching"
  defp health_message(:watcher, :warning), do: "ConfigWatcher has errors"
  defp health_message(:watcher, :failing), do: "ConfigWatcher is not responding"
  defp health_message(:watcher, :not_applicable), do: "Hot-reload is disabled"
  defp health_message(:views, :passing), do: "Views are configured"
  defp health_message(:views, :warning), do: "No views configured"
  defp health_message(:views, :failing), do: "Cannot access views"
  defp health_message(:configuration, :passing), do: "Configuration file exists"
  defp health_message(:configuration, :warning), do: "Configuration file not found"
  defp health_message(:configuration, :failing), do: "Configuration is invalid"
  defp health_message(:configuration, :not_applicable), do: "Hot-reload is disabled"
  defp health_message(_, _), do: "Unknown status"

  ## Private Functions - Metrics

  defp extract_view_metrics(manager_stats) when is_map(manager_stats) do
    %{
      count: manager_stats[:view_count] || 0,
      names: manager_stats[:view_names] || []
    }
  end

  defp extract_view_metrics(_), do: %{count: 0, names: []}

  defp extract_reload_metrics(watcher_status) when is_map(watcher_status) do
    %{
      total: (watcher_status[:reload_count] || 0) + (watcher_status[:error_count] || 0),
      successful: watcher_status[:reload_count] || 0,
      failed: watcher_status[:error_count] || 0,
      last_reload: watcher_status[:last_reload]
    }
  end

  defp extract_reload_metrics(_), do: %{total: 0, successful: 0, failed: 0}

  defp extract_operation_metrics(manager_stats) when is_map(manager_stats) do
    %{
      update_count: manager_stats[:update_count] || 0,
      last_update: manager_stats[:last_update]
    }
  end

  defp extract_operation_metrics(_), do: %{update_count: 0}

  ## Private Functions - Helpers

  defp get_views(manager_pid) do
    try do
      views = ViewManager.get_views(manager_pid)
      {:ok, views}
    catch
      :exit, reason ->
        {:error, {:manager_error, reason}}
    end
  end

  defp find_watcher_pid(nil) do
    # Try to find watcher in process registry
    case Process.whereis(ConfigWatcher) do
      nil -> {:error, :not_found}
      pid -> {:ok, pid}
    end
  end

  defp find_watcher_pid(pid) when is_pid(pid), do: {:ok, pid}
  defp find_watcher_pid(_), do: {:error, :not_found}

  defp format_match_clients(match_clients) when is_atom(match_clients),
    do: to_string(match_clients)

  defp format_match_clients(match_clients) when is_binary(match_clients), do: match_clients
  defp format_match_clients(match_clients), do: inspect(match_clients)

  defp inspect_match_clients(match_clients) do
    %{
      type: match_clients_type(match_clients),
      pattern: format_match_clients(match_clients)
    }
  end

  defp match_clients_type(:any), do: :match_all
  defp match_clients_type(:all), do: :match_all
  defp match_clients_type(:localhost), do: :localhost_only
  defp match_clients_type(:localnets), do: :private_networks
  defp match_clients_type(pattern) when is_binary(pattern), do: :cidr_or_acl
  defp match_clients_type({_, _, _, _}), do: :ipv4_address
  defp match_clients_type({_, _, _, _, _, _, _, _}), do: :ipv6_address
  defp match_clients_type(_), do: :custom

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"

  defp format_ip({a, b, c, d, e, f, g, h}) do
    parts = [a, b, c, d, e, f, g, h]
    hex_parts = Enum.map(parts, &Integer.to_string(&1, 16))
    Enum.join(hex_parts, ":")
  end
end
