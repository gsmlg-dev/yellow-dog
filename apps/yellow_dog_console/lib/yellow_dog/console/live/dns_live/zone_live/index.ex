defmodule YellowDog.Console.DnsLive.ZoneLive.Index do
  @moduledoc """
  DNS Zones management page with data table.
  Second level of the View -> Zone -> Records hierarchy.
  Shows zones for a specific view.
  """
  use YellowDog.Console, :live_view

  alias YellowDog.Dns.View
  alias YellowDog.Dns.ViewManager
  alias YellowDog.Dns.ZoneController
  alias YellowDog.Dns.ConfigPersistence

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "dns:zones")
    end

    {:ok,
     socket
     |> assign(:page_title, "DNS Zones")
     |> assign(:view_name, nil)
     |> assign(:zones, [])
     |> assign(:delete_confirm, nil)
     |> assign(:zone_form, nil)
     |> assign(:import_form, nil)
     |> assign(:editing_zone, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  # ============================================================================
  # Action Handlers
  # ============================================================================

  defp apply_action(socket, :index, %{"view_name" => view_name}) do
    socket
    |> assign(:page_title, "Zones - #{view_name}")
    |> assign(:view_name, view_name)
    |> assign(:zone_form, nil)
    |> assign(:import_form, nil)
    |> assign(:editing_zone, nil)
    |> load_zones()
  end

  defp apply_action(socket, :new, %{"view_name" => view_name}) do
    form_data = %{
      "name" => "",
      "type" => "auth",
      "upstreams" => "",
      "ns_records" => ""
    }

    socket
    |> assign(:page_title, "New Zone - #{view_name}")
    |> assign(:view_name, view_name)
    |> assign(:editing_zone, nil)
    |> assign(:zone_form, to_form(form_data))
    |> load_zones()
  end

  defp apply_action(socket, :edit, %{
         "view_name" => view_name,
         "zone_type" => zone_type,
         "zone_name" => zone_name
       }) do
    zone_type_atom = String.to_existing_atom(zone_type)

    case get_zone_config(view_name, zone_type_atom, zone_name) do
      {:ok, config} ->
        form_data = %{
          "name" => config.name,
          "type" => to_string(config.type),
          "upstreams" => Enum.join(config.upstreams || [], "\n"),
          "ns_records" => Enum.join(config.ns_records || [], "\n")
        }

        socket
        |> assign(:page_title, "Edit Zone - #{zone_name}")
        |> assign(:view_name, view_name)
        |> assign(:editing_zone, %{name: zone_name, type: zone_type_atom})
        |> assign(:zone_form, to_form(form_data))
        |> load_zones()

      :error ->
        socket
        |> put_flash(:error, "Zone '#{zone_name}' not found")
        |> push_navigate(to: ~p"/dns/views/#{view_name}/zones")
    end
  end

  defp apply_action(socket, :import, %{"view_name" => view_name}) do
    form_data = %{
      "zone_data" => "",
      "format" => "zone"
    }

    socket
    |> assign(:page_title, "Import Zone - #{view_name}")
    |> assign(:view_name, view_name)
    |> assign(:import_form, to_form(form_data))
    |> load_zones()
  end

  # ============================================================================
  # Event Handlers
  # ============================================================================

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_zones(socket)}
  end

  @impl true
  def handle_event("validate_zone", %{"zone" => zone_params}, socket) do
    # Update form with new values to show/hide fields based on type
    form_data = %{
      "name" => zone_params["name"] || "",
      "type" => zone_params["type"] || "auth",
      "upstreams" => zone_params["upstreams"] || "",
      "ns_records" => zone_params["ns_records"] || ""
    }

    {:noreply, assign(socket, :zone_form, to_form(form_data))}
  end

  @impl true
  def handle_event("save_zone", %{"zone" => zone_params}, socket) do
    editing = socket.assigns[:editing_zone]
    view_name = socket.assigns.view_name
    zone_name = zone_params["name"]
    zone_type = String.to_existing_atom(zone_params["type"])

    # Build config based on zone type
    config = build_zone_config(zone_type, zone_params)

    # Add view_name to config so zone is scoped to this view
    config = Keyword.put(config, :view_name, view_name)

    result =
      if editing do
        # Pass view_name for view-scoped zone lookup
        case ZoneController.reload_zone(view_name, editing.type, editing.name, config) do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end
      else
        case ZoneController.start_zone(zone_type, zone_name, config) do
          {:ok, _pid} ->
            # Register zone with view
            if view_name do
              case ViewManager.get_view(view_name) do
                {:ok, pid} ->
                  View.register_zone(pid, zone_type, zone_name)
                  :ok

                :error ->
                  :ok
              end
            else
              :ok
            end

          {:error, reason} ->
            {:error, reason}
        end
      end

    case result do
      :ok ->
        # Persist configuration to files
        save_config_async()
        action = if editing, do: "updated", else: "created"

        {:noreply,
         socket
         |> put_flash(:info, "Zone '#{zone_name}' #{action} successfully")
         |> push_navigate(to: ~p"/dns/views/#{view_name}/zones")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save zone: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("import_zone", %{"import" => import_params}, socket) do
    view_name = socket.assigns.view_name
    zone_data = import_params["zone_data"]
    _format = import_params["format"]

    # TODO: Implement zone file parsing and import
    _ = zone_data

    {:noreply,
     socket
     |> put_flash(:info, "Zone import feature coming soon - data received")
     |> push_navigate(to: ~p"/dns/views/#{view_name}/zones")}
  end

  @impl true
  def handle_event("confirm_delete", %{"type" => type, "name" => zone_name}, socket) do
    {:noreply,
     assign(socket, :delete_confirm, %{zone_type: String.to_existing_atom(type), name: zone_name})}
  end

  @impl true
  def handle_event("delete_zone", _params, socket) do
    %{zone_type: zone_type, name: zone_name} = socket.assigns.delete_confirm
    view_name = socket.assigns.view_name

    # Pass view_name for view-scoped zone deletion
    case ZoneController.stop_zone(view_name, zone_type, zone_name) do
      :ok ->
        # Persist configuration to files
        save_config_async()

        {:noreply,
         socket
         |> assign(:delete_confirm, nil)
         |> load_zones()
         |> put_flash(:info, "Zone '#{zone_name}' deleted successfully")}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> assign(:delete_confirm, nil)
         |> put_flash(:error, "Zone '#{zone_name}' not found")}
    end
  end

  @impl true
  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, :delete_confirm, nil)}
  end

  @impl true
  def handle_event("cancel", _params, socket) do
    view_name = socket.assigns.view_name
    {:noreply, push_navigate(socket, to: ~p"/dns/views/#{view_name}/zones")}
  end

  # ============================================================================
  # PubSub Handlers
  # ============================================================================

  @impl true
  def handle_info({:zone_updated, _zone_name}, socket) do
    {:noreply, load_zones(socket)}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Build zone configuration based on zone type
  defp build_zone_config(:auth, _params) do
    # Auth zones don't need extra config (records are added separately)
    []
  end

  defp build_zone_config(:forward, params) do
    upstreams =
      params["upstreams"]
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    [upstreams: upstreams]
  end

  defp build_zone_config(:stub, params) do
    ns_records =
      params["ns_records"]
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    [ns_records: ns_records]
  end

  defp build_zone_config(_type, _params) do
    []
  end

  defp load_zones(socket) do
    view_name = socket.assigns.view_name

    zones =
      case get_view_with_zones(view_name) do
        {:ok, view} -> view.zones
        :error -> []
      end

    assign(socket, :zones, zones)
  end

  defp get_view_with_zones(view_name) do
    try do
      case ViewManager.get_view(view_name) do
        {:ok, pid} ->
          stats = View.stats(pid)
          zones = get_zones_with_details(stats, view_name)

          view = %{
            name: view_name,
            zones: zones
          }

          {:ok, view}

        :error ->
          :error
      end
    rescue
      _ -> :error
    end
  end

  defp get_zones_with_details(stats, view_name) do
    zones_config = Map.get(stats, :zones, [])

    Enum.map(zones_config, fn
      {type, name} ->
        zone_stats = get_zone_stats(view_name, type, name)
        Map.merge(%{type: type, name: name}, zone_stats)

      name when is_binary(name) ->
        %{type: :unknown, name: name, record_count: 0, query_count: 0}
    end)
  end

  defp get_zone_stats(view_name, type, name) do
    try do
      # Use view-scoped zone lookup
      case ZoneController.find_zone(view_name, type, name) do
        {:ok, pid} ->
          module = zone_module(type)
          stats = module.stats(pid)

          %{
            record_count: Map.get(stats, :record_count, 0),
            query_count: Map.get(stats, :query_count, 0)
          }

        :error ->
          %{record_count: 0, query_count: 0}
      end
    rescue
      _ -> %{record_count: 0, query_count: 0}
    end
  end

  defp get_zone_config(view_name, zone_type, zone_name) do
    try do
      # Use view-scoped zone lookup
      case ZoneController.find_zone(view_name, zone_type, zone_name) do
        {:ok, pid} ->
          module = zone_module(zone_type)
          stats = module.stats(pid)

          config = %{
            name: zone_name,
            type: zone_type,
            upstreams: Map.get(stats, :upstreams, []),
            ns_records: Map.get(stats, :ns_records, [])
          }

          {:ok, config}

        :error ->
          :error
      end
    rescue
      _ -> :error
    end
  end

  defp zone_module(:auth), do: YellowDog.Dns.Zone.Auth
  defp zone_module(:forward), do: YellowDog.Dns.Zone.Forward
  defp zone_module(:stub), do: YellowDog.Dns.Zone.Stub
  defp zone_module(:cache), do: YellowDog.Dns.Zone.Cache

  def zone_type_badge(:auth), do: "primary"
  def zone_type_badge(:forward), do: "secondary"
  def zone_type_badge(:stub), do: "accent"
  def zone_type_badge(:cache), do: "info"
  def zone_type_badge(_), do: "ghost"

  def zone_type_label(:auth), do: "Authoritative"
  def zone_type_label(:forward), do: "Forward"
  def zone_type_label(:stub), do: "Stub"
  def zone_type_label(:cache), do: "Cache"
  def zone_type_label(_), do: "Unknown"

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
