defmodule YellowDog.Console.DnsLive.ZoneDetailLive do
  @moduledoc """
  DNS Zone detail page showing resource records.
  """
  use YellowDog.Console, :live_view

  alias YellowDog.Dns.ZoneController

  @impl true
  def mount(%{"view_name" => view_name, "zone_name" => zone_name}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "dns:zones")
    end

    zone = get_zone_details(zone_name)

    {:ok,
     socket
     |> assign(:page_title, "Zone: #{zone_name}")
     |> assign(:view_name, view_name)
     |> assign(:zone_name, zone_name)
     |> assign(:zone, zone)
     |> assign(:filter, "")
     |> assign(:type_filter, "all")}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    zone = get_zone_details(socket.assigns.zone_name)
    {:noreply, assign(socket, :zone, zone)}
  end

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) do
    {:noreply, assign(socket, :filter, filter)}
  end

  @impl true
  def handle_event("filter_type", %{"type" => type}, socket) do
    {:noreply, assign(socket, :type_filter, type)}
  end

  @impl true
  def handle_info({:zone_updated, zone_name}, socket) do
    if zone_name == socket.assigns.zone_name do
      zone = get_zone_details(zone_name)
      {:noreply, assign(socket, :zone, zone)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp get_zone_details(zone_name) do
    # Try to find the zone in any zone type
    zone_types = [:auth, :forward, :stub, :cache]

    Enum.find_value(zone_types, fn zone_type ->
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

            %{
              name: zone_name,
              type: zone_type,
              pid: pid,
              record_count: Map.get(stats, :record_count, length(records)),
              query_count: Map.get(stats, :query_count, 0),
              hit_count: Map.get(stats, :hit_count, 0),
              miss_count: Map.get(stats, :miss_count, 0),
              created_at: Map.get(stats, :created_at),
              records: records,
              # For forward zones
              upstreams: Map.get(stats, :upstreams, [])
            }

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
