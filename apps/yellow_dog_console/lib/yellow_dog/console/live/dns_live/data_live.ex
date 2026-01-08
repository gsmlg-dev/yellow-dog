defmodule YellowDog.Console.DnsLive.DataLive do
  @moduledoc """
  DNS Data page with hierarchical navigation: View → Zone → Resource Records.
  Uses breadcrumb navigation and supports drill-down into views and zones.
  """
  use YellowDog.Console, :live_view

  alias YellowDog.Dns.View
  alias YellowDog.Dns.ViewManager
  alias YellowDog.Dns.ZoneController

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "dns:views")
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "dns:zones")
    end

    {:ok,
     socket
     |> assign(:page_title, "DNS Data")
     |> assign(:show_view_form, false)
     |> assign(:editing_view, nil)
     |> assign(:view_form, to_form(%{"name" => "", "priority" => "100", "recursion_enabled" => "true", "ecs_enabled" => "false"}))
     |> assign(:delete_confirm, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :views, _params) do
    socket
    |> assign(:page_title, "DNS Data - Views")
    |> assign(:view_name, nil)
    |> assign(:zone_name, nil)
    |> assign(:views, list_views())
  end

  defp apply_action(socket, :zones, %{"view_name" => view_name}) do
    case get_view_with_zones(view_name) do
      {:ok, view} ->
        socket
        |> assign(:page_title, "DNS Data - #{view_name}")
        |> assign(:view_name, view_name)
        |> assign(:zone_name, nil)
        |> assign(:view, view)

      :error ->
        socket
        |> assign(:page_title, "View Not Found")
        |> assign(:view_name, view_name)
        |> assign(:zone_name, nil)
        |> assign(:view, nil)
        |> put_flash(:error, "View '#{view_name}' not found")
    end
  end

  defp apply_action(socket, :records, %{"view_name" => view_name, "zone_name" => zone_name}) do
    case get_zone_with_records(zone_name) do
      {:ok, zone} ->
        socket
        |> assign(:page_title, "DNS Data - #{zone_name}")
        |> assign(:view_name, view_name)
        |> assign(:zone_name, zone_name)
        |> assign(:zone, zone)
        |> assign(:filter, "")
        |> assign(:type_filter, "all")

      :error ->
        socket
        |> assign(:page_title, "Zone Not Found")
        |> assign(:view_name, view_name)
        |> assign(:zone_name, zone_name)
        |> assign(:zone, nil)
        |> assign(:filter, "")
        |> assign(:type_filter, "all")
        |> put_flash(:error, "Zone '#{zone_name}' not found")
    end
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, get_current_params(socket))}
  end

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) do
    {:noreply, assign(socket, :filter, filter)}
  end

  @impl true
  def handle_event("filter_type", %{"type" => type}, socket) do
    {:noreply, assign(socket, :type_filter, type)}
  end

  # View management events

  @impl true
  def handle_event("new_view", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_view_form, true)
     |> assign(:editing_view, nil)
     |> assign(:view_form, to_form(%{"name" => "", "priority" => "100", "recursion_enabled" => "true", "ecs_enabled" => "false"}))}
  end

  @impl true
  def handle_event("edit_view", %{"name" => view_name}, socket) do
    case get_view_config(view_name) do
      {:ok, config} ->
        form_data = %{
          "name" => config.name,
          "priority" => to_string(config.priority),
          "recursion_enabled" => to_string(config.recursion_enabled),
          "ecs_enabled" => to_string(config.ecs_enabled)
        }

        {:noreply,
         socket
         |> assign(:show_view_form, true)
         |> assign(:editing_view, view_name)
         |> assign(:view_form, to_form(form_data))}

      :error ->
        {:noreply, put_flash(socket, :error, "View '#{view_name}' not found")}
    end
  end

  @impl true
  def handle_event("confirm_delete", %{"name" => view_name}, socket) do
    {:noreply, assign(socket, :delete_confirm, view_name)}
  end

  @impl true
  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :delete_confirm, nil)}
  end

  @impl true
  def handle_event("delete_view", %{"name" => view_name}, socket) do
    if is_default_view?(view_name) do
      {:noreply,
       socket
       |> assign(:delete_confirm, nil)
       |> put_flash(:error, "Cannot delete the default view")}
    else
      case ViewManager.stop_view(view_name) do
        :ok ->
          {:noreply,
           socket
           |> assign(:delete_confirm, nil)
           |> assign(:views, list_views())
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
  def handle_event("save_view", %{"view" => view_params}, socket) do
    editing = socket.assigns.editing_view

    config = %{
      name: view_params["name"],
      priority: String.to_integer(view_params["priority"]),
      recursion_enabled: view_params["recursion_enabled"] == "true",
      ecs_enabled: view_params["ecs_enabled"] == "true"
    }

    result =
      if editing do
        # Update existing view
        case ViewManager.get_view(editing) do
          {:ok, pid} ->
            View.reload(pid, config)
            :ok

          :error ->
            {:error, :not_found}
        end
      else
        # Create new view
        case ViewManager.start_view(config) do
          {:ok, _pid} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end

    case result do
      :ok ->
        action = if editing, do: "updated", else: "created"

        {:noreply,
         socket
         |> assign(:show_view_form, false)
         |> assign(:editing_view, nil)
         |> assign(:views, list_views())
         |> put_flash(:info, "View '#{config.name}' #{action} successfully")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save view: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("close_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_view_form, false)
     |> assign(:editing_view, nil)
     |> assign(:delete_confirm, nil)}
  end

  @impl true
  def handle_info({:view_updated, _view_name}, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, get_current_params(socket))}
  end

  @impl true
  def handle_info({:zone_updated, _zone_name}, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, get_current_params(socket))}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp get_current_params(socket) do
    params = %{}
    params = if socket.assigns[:view_name], do: Map.put(params, "view_name", socket.assigns.view_name), else: params
    params = if socket.assigns[:zone_name], do: Map.put(params, "zone_name", socket.assigns.zone_name), else: params
    params
  end

  # View management helpers

  defp is_default_view?(view_name), do: view_name == "default"

  defp get_view_config(view_name) do
    try do
      case ViewManager.get_view(view_name) do
        {:ok, pid} ->
          stats = View.stats(pid)

          config = %{
            name: stats.name,
            priority: stats.priority,
            recursion_enabled: stats.recursion_enabled,
            ecs_enabled: stats.ecs_enabled,
            zones: stats.zones,
            rpz_zones: stats.rpz_zones
          }

          {:ok, config}

        :error ->
          :error
      end
    rescue
      _ -> :error
    end
  end

  # Data fetching functions

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

  defp get_view_with_zones(view_name) do
    try do
      case ViewManager.get_view(view_name) do
        {:ok, pid} ->
          stats = View.stats(pid)
          zones = get_zones_with_details(stats)

          view = %{
            name: view_name,
            pid: pid,
            priority: Map.get(stats, :priority, 100),
            recursion_enabled: Map.get(stats, :recursion_enabled, false),
            ecs_enabled: Map.get(stats, :ecs_enabled, false),
            zones: zones,
            query_count: Map.get(stats, :query_count, 0)
          }

          {:ok, view}

        :error ->
          :error
      end
    rescue
      _ -> :error
    end
  end

  defp get_zones_with_details(stats) do
    zones_config = Map.get(stats, :zones, [])

    Enum.map(zones_config, fn
      {type, name} ->
        zone_stats = get_zone_stats(type, name)
        Map.merge(%{type: type, name: name}, zone_stats)

      name when is_binary(name) ->
        %{type: :unknown, name: name, record_count: 0, query_count: 0}
    end)
  end

  defp get_zone_stats(type, name) do
    try do
      case ZoneController.find_zone(type, name) do
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

  defp get_zone_with_records(zone_name) do
    zone_types = [:auth, :forward, :stub, :cache]

    Enum.find_value(zone_types, :error, fn zone_type ->
      try do
        case ZoneController.find_zone(zone_type, zone_name) do
          {:ok, pid} ->
            module = zone_module(zone_type)
            stats = module.stats(pid)

            records =
              if zone_type == :auth do
                get_auth_zone_records(pid)
              else
                []
              end

            zone = %{
              name: zone_name,
              type: zone_type,
              pid: pid,
              record_count: Map.get(stats, :record_count, length(records)),
              query_count: Map.get(stats, :query_count, 0),
              hit_count: Map.get(stats, :hit_count, 0),
              miss_count: Map.get(stats, :miss_count, 0),
              records: records,
              upstreams: Map.get(stats, :upstreams, [])
            }

            {:ok, zone}

          :error ->
            nil
        end
      rescue
        _ -> nil
      end
    end)
  end

  defp get_auth_zone_records(pid) do
    try do
      YellowDog.Dns.Zone.Auth.get_all_records(pid)
      |> Enum.map(fn record ->
        %{
          name: format_record_name(record.name),
          type: record.type,
          ttl: record.ttl,
          class: record.class,
          rdata: format_rdata(record.type, record.rdata)
        }
      end)
      |> Enum.sort_by(fn r -> {r.name, record_type_order(r.type)} end)
    rescue
      _ -> []
    end
  end

  # Helper functions

  defp zone_module(:auth), do: YellowDog.Dns.Zone.Auth
  defp zone_module(:forward), do: YellowDog.Dns.Zone.Forward
  defp zone_module(:stub), do: YellowDog.Dns.Zone.Stub
  defp zone_module(:cache), do: YellowDog.Dns.Zone.Cache

  defp zone_type_badge(:auth), do: "primary"
  defp zone_type_badge(:forward), do: "secondary"
  defp zone_type_badge(:stub), do: "accent"
  defp zone_type_badge(:cache), do: "info"
  defp zone_type_badge(_), do: "ghost"

  defp zone_type_label(:auth), do: "Authoritative"
  defp zone_type_label(:forward), do: "Forward"
  defp zone_type_label(:stub), do: "Stub"
  defp zone_type_label(:cache), do: "Cache"
  defp zone_type_label(_), do: "Unknown"

  defp record_type_badge(:a), do: "primary"
  defp record_type_badge(:aaaa), do: "primary"
  defp record_type_badge(:cname), do: "secondary"
  defp record_type_badge(:ns), do: "accent"
  defp record_type_badge(:mx), do: "info"
  defp record_type_badge(:txt), do: "warning"
  defp record_type_badge(:soa), do: "success"
  defp record_type_badge(:srv), do: "info"
  defp record_type_badge(:ptr), do: "accent"
  defp record_type_badge(_), do: "ghost"

  defp record_type_order(:soa), do: 0
  defp record_type_order(:ns), do: 1
  defp record_type_order(:a), do: 2
  defp record_type_order(:aaaa), do: 3
  defp record_type_order(:cname), do: 4
  defp record_type_order(:mx), do: 5
  defp record_type_order(:txt), do: 6
  defp record_type_order(:srv), do: 7
  defp record_type_order(:ptr), do: 8
  defp record_type_order(_), do: 99

  # Record formatting functions

  defp format_record_name(%DNS.Message.Domain{} = domain), do: to_string(domain)
  defp format_record_name(name) when is_binary(name), do: name
  defp format_record_name(name), do: inspect(name)

  defp format_rdata(:a, rdata), do: format_ipv4(rdata)
  defp format_rdata(:aaaa, rdata), do: format_ipv6(rdata)
  defp format_rdata(:cname, rdata), do: format_domain(rdata)
  defp format_rdata(:ns, rdata), do: format_domain(rdata)
  defp format_rdata(:ptr, rdata), do: format_domain(rdata)
  defp format_rdata(:mx, rdata), do: format_mx(rdata)
  defp format_rdata(:txt, rdata), do: format_txt(rdata)
  defp format_rdata(:soa, rdata), do: format_soa(rdata)
  defp format_rdata(:srv, rdata), do: format_srv(rdata)
  defp format_rdata(_type, rdata), do: inspect(rdata)

  defp format_ipv4(%{address: addr}) when is_tuple(addr), do: :inet.ntoa(addr) |> to_string()
  defp format_ipv4(addr) when is_tuple(addr), do: :inet.ntoa(addr) |> to_string()
  defp format_ipv4(rdata), do: inspect(rdata)

  defp format_ipv6(%{address: addr}) when is_tuple(addr), do: :inet.ntoa(addr) |> to_string()
  defp format_ipv6(addr) when is_tuple(addr), do: :inet.ntoa(addr) |> to_string()
  defp format_ipv6(rdata), do: inspect(rdata)

  defp format_domain(%{name: name}), do: to_string(name)
  defp format_domain(%DNS.Message.Domain{} = domain), do: to_string(domain)
  defp format_domain(name) when is_binary(name), do: name
  defp format_domain(rdata), do: inspect(rdata)

  defp format_mx(%{preference: pref, exchange: exchange}), do: "#{pref} #{format_domain(exchange)}"
  defp format_mx(rdata), do: inspect(rdata)

  defp format_txt(%{txt_data: data}) when is_list(data), do: Enum.join(data, " ")
  defp format_txt(%{txt_data: data}) when is_binary(data), do: data
  defp format_txt(data) when is_binary(data), do: data
  defp format_txt(rdata), do: inspect(rdata)

  defp format_soa(%{mname: mname, rname: rname, serial: serial}) do
    "#{format_domain(mname)} #{format_domain(rname)} #{serial}"
  end

  defp format_soa(rdata), do: inspect(rdata)

  defp format_srv(%{priority: priority, weight: weight, port: port, target: target}) do
    "#{priority} #{weight} #{port} #{format_domain(target)}"
  end

  defp format_srv(rdata), do: inspect(rdata)

  # Filtering functions

  defp filtered_records(records, filter, type_filter) do
    records
    |> filter_by_name(filter)
    |> filter_by_type(type_filter)
  end

  defp filter_by_name(records, ""), do: records
  defp filter_by_name(records, nil), do: records

  defp filter_by_name(records, filter) do
    filter_lower = String.downcase(filter)

    Enum.filter(records, fn r ->
      String.downcase(r.name) |> String.contains?(filter_lower)
    end)
  end

  defp filter_by_type(records, "all"), do: records

  defp filter_by_type(records, type_str) do
    type = String.to_existing_atom(type_str)
    Enum.filter(records, fn r -> r.type == type end)
  rescue
    _ -> records
  end

  defp unique_record_types(records) do
    records
    |> Enum.map(& &1.type)
    |> Enum.uniq()
    |> Enum.sort_by(&record_type_order/1)
  end

  defp calculate_hit_rate(hits, misses) do
    total = hits + misses

    if total > 0 do
      round(hits / total * 100)
    else
      0
    end
  end
end
