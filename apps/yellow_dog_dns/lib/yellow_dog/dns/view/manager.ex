defmodule YellowDog.Dns.View.Manager do
  @moduledoc """
  GenServer for managing DNS views with hot-reload support.

  Maintains the current list of views and provides atomic updates for hot-reload.
  The Handler.UDP can query this manager for the current views instead of storing
  them directly in its state.

  ## Features

  - Atomic view list updates
  - View validation before applying
  - Rollback on validation failure
  - Thread-safe concurrent access
  - Statistics tracking

  ## Usage

      # Start manager with initial views
      {:ok, pid} = View.Manager.start_link(views: initial_views)

      # Get current views
      views = View.Manager.get_views()

      # Update views (atomic)
      :ok = View.Manager.update_views(new_views)

      # Get statistics
      stats = View.Manager.stats()

  ## Integration with ConfigWatcher

      # ConfigWatcher can reload views via Manager
      ConfigWatcher.start_link(
        config_path: "config/views.toml",
        reload_callback: fn views ->
          View.Manager.update_views(views)
        end
      )
  """

  use GenServer
  require Logger

  alias YellowDog.Telemetry
  alias YellowDog.Dns.View

  # Client API

  @doc """
  Starts the View Manager.

  ## Options

  - `:views` - Initial list of views (default: empty list)
  - `:name` - GenServer name (default: `__MODULE__`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    views = Keyword.get(opts, :views, [])
    name = Keyword.get(opts, :name, __MODULE__)

    GenServer.start_link(__MODULE__, views, name: name)
  end

  @doc """
  Get the current list of views.

  Returns the views atomically - the list will not change during iteration.
  """
  @spec get_views(GenServer.server()) :: [View.t()]
  def get_views(server \\ __MODULE__) do
    GenServer.call(server, :get_views)
  end

  @doc """
  Update the view list atomically.

  Validates the new views before applying. Returns `:ok` on success,
  or `{:error, reason}` if validation fails.

  The update is atomic - either all views are updated or none are.
  """
  @spec update_views(GenServer.server(), [View.t()]) :: :ok | {:error, term()}
  def update_views(server \\ __MODULE__, new_views) when is_list(new_views) do
    GenServer.call(server, {:update_views, new_views})
  end

  @doc """
  Get View Manager statistics.

  Returns a map with:
  - `:view_count` - Number of active views
  - `:update_count` - Total number of successful updates
  - `:last_update` - Timestamp of last update (or nil)
  - `:view_names` - List of current view names
  """
  @spec stats(GenServer.server()) :: map()
  def stats(server \\ __MODULE__) do
    GenServer.call(server, :stats)
  end

  @doc """
  Match a client IP to the appropriate view.

  This is a convenience function that gets the current views and
  performs matching. Returns `{:ok, view}` if a match is found,
  or `{:error, :no_match}` if no view matches.
  """
  @spec match_client(GenServer.server(), :inet.ip_address()) ::
          {:ok, View.t()} | {:error, :no_match}
  def match_client(server \\ __MODULE__, client_ip) do
    views = get_views(server)
    View.match_client(client_ip, views)
  end

  # Server Callbacks

  @impl true
  def init(initial_views) do
    state = %{
      views: initial_views,
      update_count: 0,
      last_update: nil
    }

    Telemetry.info("View.Manager started", %{
      view_count: length(initial_views),
      view_names: Enum.map(initial_views, & &1.name)
    })

    {:ok, state}
  end

  @impl true
  def handle_call(:get_views, _from, state) do
    {:reply, state.views, state}
  end

  @impl true
  def handle_call({:update_views, new_views}, _from, state) do
    case validate_views(new_views) do
      :ok ->
        old_views = state.views

        new_state = %{
          state
          | views: new_views,
            update_count: state.update_count + 1,
            last_update: DateTime.utc_now()
        }

        # Log changes
        log_view_changes(old_views, new_views)

        :telemetry.execute(
          [:yellow_dog, :dns, :view, :manager, :update],
          %{view_count: length(new_views)},
          %{
            view_names: Enum.map(new_views, & &1.name),
            update_count: new_state.update_count
          }
        )

        {:reply, :ok, new_state}

      {:error, reason} = error ->
        Telemetry.error("View validation failed", %{reason: inspect(reason)})
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      view_count: length(state.views),
      update_count: state.update_count,
      last_update: state.last_update,
      view_names: Enum.map(state.views, & &1.name)
    }

    {:reply, stats, state}
  end

  # Private Functions

  defp validate_views(views) when is_list(views) do
    cond do
      # Empty list is valid (means no views configured, will use default)
      views == [] ->
        :ok

      # Check all items are View structs
      Enum.all?(views, &is_struct(&1, View)) ->
        validate_view_names(views)

      true ->
        {:error, :invalid_view_type}
    end
  end

  defp validate_views(_), do: {:error, :not_a_list}

  defp validate_view_names(views) do
    # Check for duplicate view names
    names = Enum.map(views, & &1.name)
    unique_names = Enum.uniq(names)

    if length(names) == length(unique_names) do
      :ok
    else
      duplicates = names -- unique_names
      {:error, {:duplicate_view_names, duplicates}}
    end
  end

  defp log_view_changes(old_views, new_views) do
    old_names = MapSet.new(old_views, & &1.name)
    new_names = MapSet.new(new_views, & &1.name)

    added = MapSet.difference(new_names, old_names) |> MapSet.to_list()
    removed = MapSet.difference(old_names, new_names) |> MapSet.to_list()
    kept = MapSet.intersection(old_names, new_names)

    # Find modified views (same name but different configuration)
    modified =
      Enum.filter(kept, fn name ->
        old_view = Enum.find(old_views, &(&1.name == name))
        new_view = Enum.find(new_views, &(&1.name == name))
        old_view != new_view
      end)

    changes = %{
      added: added,
      removed: removed,
      modified: modified,
      total: length(new_views)
    }

    if added != [] or removed != [] or modified != [] do
      Telemetry.info("Views updated", changes)
    end
  end
end
