defmodule YellowDog.Console.DnsLive.ViewLive.Index do
  @moduledoc """
  DNS Views management page with data table.
  First level of the View -> Zone -> Records hierarchy.
  """
  use YellowDog.Console, :live_view

  alias YellowDog.Dns.View
  alias YellowDog.Dns.ViewManager
  alias YellowDog.Dns.ConfigPersistence

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "dns:views")
    end

    {:ok,
     socket
     |> assign(:page_title, "DNS Views")
     |> assign(:views, list_views())
     |> assign(:delete_confirm, nil)
     |> assign(:view_form, nil)
     |> assign(:editing_view, nil)
     |> assign(:is_default_view, false)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  # ============================================================================
  # Action Handlers
  # ============================================================================

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "DNS Views")
    |> assign(:view_form, nil)
    |> assign(:editing_view, nil)
    |> assign(:is_default_view, false)
    |> refresh_views()
  end

  defp apply_action(socket, :new, _params) do
    form_data = %{
      "name" => "",
      "priority" => "100",
      "recursion_enabled" => "true",
      "ecs_enabled" => "false"
    }

    socket
    |> assign(:page_title, "New View")
    |> assign(:editing_view, nil)
    |> assign(:view_form, to_form(form_data))
  end

  defp apply_action(socket, :edit, %{"view_name" => view_name}) do
    case get_view_config(view_name) do
      {:ok, config} ->
        is_default = is_default_view?(view_name)

        # For default view, priority is :infinity (shown as "∞")
        priority_display =
          if is_default do
            "∞"
          else
            to_string(config.priority)
          end

        form_data = %{
          "name" => config.name,
          "priority" => priority_display,
          "recursion_enabled" => to_string(config.recursion_enabled),
          "ecs_enabled" => to_string(config.ecs_enabled)
        }

        socket
        |> assign(:page_title, "Edit View - #{view_name}")
        |> assign(:editing_view, view_name)
        |> assign(:is_default_view, is_default)
        |> assign(:view_form, to_form(form_data))

      :error ->
        socket
        |> put_flash(:error, "View '#{view_name}' not found")
        |> push_navigate(to: ~p"/dns/views")
    end
  end

  # ============================================================================
  # Event Handlers
  # ============================================================================

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, refresh_views(socket)}
  end

  @impl true
  def handle_event("save_view", %{"view" => view_params}, socket) do
    editing = socket.assigns[:editing_view]
    is_default = socket.assigns[:is_default_view] || false

    # Default view always has priority :infinity (not editable)
    priority =
      if is_default do
        :infinity
      else
        String.to_integer(view_params["priority"])
      end

    config = %{
      name: view_params["name"],
      priority: priority,
      recursion_enabled: view_params["recursion_enabled"] == "true",
      ecs_enabled: view_params["ecs_enabled"] == "true"
    }

    result =
      if editing do
        case ViewManager.get_view(editing) do
          {:ok, pid} ->
            View.reload(pid, config)
            :ok

          :error ->
            {:error, :not_found}
        end
      else
        case ViewManager.start_view(config) do
          {:ok, _pid} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end

    case result do
      :ok ->
        # Persist configuration to files
        save_config_async()
        action = if editing, do: "updated", else: "created"

        {:noreply,
         socket
         |> put_flash(:info, "View '#{config.name}' #{action} successfully")
         |> push_navigate(to: ~p"/dns/views")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save view: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("confirm_delete", %{"name" => view_name}, socket) do
    {:noreply, assign(socket, :delete_confirm, view_name)}
  end

  @impl true
  def handle_event("delete_view", _params, socket) do
    view_name = socket.assigns.delete_confirm

    if is_default_view?(view_name) do
      {:noreply,
       socket
       |> assign(:delete_confirm, nil)
       |> put_flash(:error, "Cannot delete the default view")}
    else
      case ViewManager.stop_view(view_name) do
        :ok ->
          # Persist configuration to files
          save_config_async()

          {:noreply,
           socket
           |> assign(:delete_confirm, nil)
           |> refresh_views()
           |> put_flash(:info, "View '#{view_name}' deleted successfully")}

        {:error, :not_found} ->
          {:noreply,
           socket
           |> assign(:delete_confirm, nil)
           |> put_flash(:error, "View '#{view_name}' not found")}
      end
    end
  end

  @impl true
  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, :delete_confirm, nil)}
  end

  @impl true
  def handle_event("cancel", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/dns/views")}
  end

  # ============================================================================
  # PubSub Handlers
  # ============================================================================

  @impl true
  def handle_info({:view_updated, _view_name}, socket) do
    {:noreply, refresh_views(socket)}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp refresh_views(socket) do
    assign(socket, :views, list_views())
  end

  defp is_default_view?(view_name), do: view_name == "default"

  defp list_views do
    try do
      views = ViewManager.list_views()

      Enum.map(views, fn {view_name, pid, priority} ->
        stats = View.stats(pid)

        %{
          name: view_name,
          priority: priority,
          recursion_enabled: Map.get(stats, :recursion_enabled, false),
          ecs_enabled: Map.get(stats, :ecs_enabled, false),
          zone_count: length(Map.get(stats, :zones, [])),
          query_count: Map.get(stats, :query_count, 0)
        }
      end)
      |> Enum.sort_by(& &1.priority)
    rescue
      _ -> []
    end
  end

  defp get_view_config(view_name) do
    try do
      case ViewManager.get_view(view_name) do
        {:ok, pid} ->
          stats = View.stats(pid)

          config = %{
            name: stats.name,
            priority: stats.priority,
            recursion_enabled: stats.recursion_enabled,
            ecs_enabled: stats.ecs_enabled
          }

          {:ok, config}

        :error ->
          :error
      end
    rescue
      _ -> :error
    end
  end

  defp save_config_async do
    Task.start(fn ->
      case ConfigPersistence.save_current() do
        :ok ->
          :ok

        {:error, reason} ->
          require Logger
          Logger.warning("Failed to save DNS config: #{inspect(reason)}")
      end
    end)
  end
end
