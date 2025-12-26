defmodule YellowDog.Dns.ViewManager do
  @moduledoc """
  Supervisor for DNS view processes.

  The ViewManager supervises View processes and routes requests
  to the appropriate view based on client IP matching.

  ## Responsibilities

  - Supervises View processes
  - Routes requests to appropriate View based on ACL matching
  - Manages view lifecycle (add/remove/update views)
  - Provides view statistics

  ## View Selection

  Views are evaluated in order of registration. The first view whose ACL
  matches the client IP handles the request. If no view matches, the
  default view is used.
  """

  use DynamicSupervisor

  alias YellowDog.Telemetry
  alias YellowDog.Dns.TSI
  alias YellowDog.Dns.ViewProcess

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

  Finds the matching view based on client IP and delegates resolution
  to that view process.

  ## Parameters

  - `tsi` - Telemetry Span Item with request context
  - `query` - DNS query message

  ## Returns

  - `{:ok, response}` on success
  - `{:error, reason}` on failure
  """
  @spec resolve(TSI.t()) :: {:ok, DNS.Message.t()} | {:error, atom()}
  def resolve(%TSI{} = tsi) do
    resolve(__MODULE__, tsi)
  end

  @spec resolve(Supervisor.supervisor(), TSI.t()) :: {:ok, DNS.Message.t()} | {:error, atom()}
  def resolve(supervisor, %TSI{} = tsi) do
    case find_matching_view(supervisor, tsi.client_ip) do
      {:ok, view_pid} ->
        ViewProcess.resolve(view_pid, tsi)

      {:error, :no_match} ->
        # Use default view if exists
        case find_default_view(supervisor) do
          {:ok, view_pid} ->
            ViewProcess.resolve(view_pid, tsi)

          :error ->
            Telemetry.warning("No matching view for client", %{
              client_ip: format_ip(tsi.client_ip)
            })

            {:error, :refused}
        end
    end
  end

  @doc """
  Starts a new view process.

  ## Parameters

  - `view_config` - View configuration (name, acl, zones, etc.)

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
      start: {ViewProcess, :start_link, [config]},
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
  @spec list_views() :: [{String.t(), pid()}]
  def list_views do
    list_views(__MODULE__)
  end

  @spec list_views(Supervisor.supervisor()) :: [{String.t(), pid()}]
  def list_views(supervisor) do
    DynamicSupervisor.which_children(supervisor)
    |> Enum.filter(fn {_id, pid, _type, _modules} -> is_pid(pid) end)
    |> Enum.map(fn {{:view, name}, pid, _type, _modules} ->
      {name, pid}
    end)
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
      Enum.map(views, fn {name, pid} ->
        {name, ViewProcess.stats(pid)}
      end)
      |> Map.new()

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
    current = list_views(supervisor) |> Map.new()
    new_names = Enum.map(view_configs, &get_view_name/1) |> MapSet.new()
    current_names = Map.keys(current) |> MapSet.new()

    # Stop removed views
    removed = MapSet.difference(current_names, new_names)

    Enum.each(removed, fn name ->
      stop_view(supervisor, name)
    end)

    # Start or update views
    Enum.each(view_configs, fn config ->
      name = get_view_name(config)

      case Map.get(current, name) do
        nil ->
          # New view
          start_view(supervisor, config)

        pid ->
          # Existing view - update config
          ViewProcess.reload(pid, config)
      end
    end)

    Telemetry.info("Views updated", %{
      added: MapSet.difference(new_names, current_names) |> MapSet.size(),
      removed: MapSet.size(removed),
      total: length(view_configs)
    })

    :ok
  end

  # Private Functions

  defp find_matching_view(supervisor, client_ip) do
    views = DynamicSupervisor.which_children(supervisor)

    Enum.find_value(views, {:error, :no_match}, fn
      {{:view, _name}, pid, _type, _modules} when is_pid(pid) ->
        if ViewProcess.matches?(pid, client_ip) do
          {:ok, pid}
        else
          nil
        end

      _ ->
        nil
    end)
  end

  defp find_default_view(supervisor) do
    find_view(supervisor, "default")
  end

  defp find_view(supervisor, view_name) do
    children = DynamicSupervisor.which_children(supervisor)

    case Enum.find(children, fn {id, _pid, _type, _modules} ->
           id == {:view, view_name}
         end) do
      {{:view, ^view_name}, pid, _type, _modules} when is_pid(pid) ->
        {:ok, pid}

      _ ->
        :error
    end
  end

  defp normalize_config(config) when is_map(config), do: config
  defp normalize_config(config) when is_list(config), do: Map.new(config)

  defp get_view_name(config) when is_map(config), do: Map.get(config, :name)
  defp get_view_name(config) when is_list(config), do: Keyword.get(config, :name)

  defp format_ip(ip) when is_tuple(ip), do: :inet.ntoa(ip) |> to_string()
  defp format_ip(ip), do: inspect(ip)
end
