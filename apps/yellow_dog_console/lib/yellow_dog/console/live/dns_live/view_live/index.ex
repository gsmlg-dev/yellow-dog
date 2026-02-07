defmodule YellowDog.Console.DnsLive.ViewLive.Index do
  @moduledoc """
  DNS Views management page with data table.
  First level of the View -> Zone -> Records hierarchy.
  """
  use YellowDog.Console, :live_view

  require Logger

  import YellowDog.Console.CsvHelper
  import YellowDog.Console.FormatHelper, only: [format_ip: 1, filtered_countries: 2]
  import YellowDog.Console.ServiceHelper

  alias YellowDog.Console.Validators
  alias YellowDog.Dns.View
  alias YellowDog.Dns.ViewManager
  alias YellowDog.Dns.ConfigPersistence

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "dns:views")
    end

    {:ok,
     assign(socket,
       page_title: "DNS Views",
       service_running: service_running?(YellowDog.Dns),
       views: list_views(),
       filter: "",
       status_filter: "all",
       delete_confirm: nil,
       view_form: nil,
       editing_view: nil,
       is_default_view: false,
       countries: GeoIpDb.list_countries(),
       selected_countries: [],
       country_search: "",
       form_errors: %{}
     )}
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
    |> assign(:selected_countries, [])
    |> assign(:country_search, "")
    |> refresh_views()
  end

  defp apply_action(socket, :new, _params) do
    form_data = %{
      "name" => "",
      "priority" => "100",
      "recursion_enabled" => "true",
      "ecs_enabled" => "false",
      "acl_type" => "any",
      "fallback_forwarders" => "",
      "fallback_timeout" => "2000",
      "fallback_retries" => "1"
    }

    socket
    |> assign(:page_title, "New View")
    |> assign(:editing_view, nil)
    |> assign(:is_default_view, false)
    |> assign(:selected_countries, [])
    |> assign(:country_search, "")
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

        # Extract ACL type and selected countries
        {acl_type, selected_countries} = parse_acl_for_form(config.acl)

        # Format fallback forwarders for display
        fallback_display =
          (config.fallback_forwarders || [])
          |> Enum.map(fn
            {ip, port} when port == 53 -> format_ip(ip)
            {ip, port} -> "#{format_ip(ip)}:#{port}"
            ip when is_tuple(ip) -> format_ip(ip)
            s when is_binary(s) -> s
          end)
          |> Enum.join("\n")

        form_data = %{
          "name" => config.name,
          "priority" => priority_display,
          "recursion_enabled" => to_string(config.recursion_enabled),
          "ecs_enabled" => to_string(config.ecs_enabled),
          "acl_type" => acl_type,
          "fallback_forwarders" => fallback_display,
          "fallback_timeout" => to_string(config.fallback_timeout || 2000),
          "fallback_retries" => to_string(config.fallback_retries || 1)
        }

        socket
        |> assign(:page_title, "Edit View - #{view_name}")
        |> assign(:editing_view, view_name)
        |> assign(:is_default_view, is_default)
        |> assign(:selected_countries, selected_countries)
        |> assign(:country_search, "")
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
  def handle_event("filter", %{"filter" => filter}, socket) do
    {:noreply, assign(socket, :filter, filter)}
  end

  @impl true
  def handle_event("filter_status", %{"status" => status}, socket) do
    {:noreply, assign(socket, :status_filter, status)}
  end

  @impl true
  def handle_event("export_csv", _params, socket) do
    views =
      filtered_views(socket.assigns.views, socket.assigns.filter, socket.assigns.status_filter)

    csv = build_views_csv(views)
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")
    filename = "dns_views_#{timestamp}.csv"
    {:noreply, push_event(socket, "download_csv", %{content: csv, filename: filename})}
  end

  @impl true
  def handle_event("toggle_enabled", %{"name" => view_name}, socket) do
    result =
      try do
        ViewManager.get_view(view_name)
      catch
        :exit, _ -> :error
      end

    case result do
      {:ok, pid} ->
        try do
          current = View.is_enabled?(pid)
          View.set_enabled(pid, !current)
          save_config_async()
          action = if current, do: "disabled", else: "enabled"

          {:noreply,
           socket
           |> refresh_views()
           |> put_flash(:info, "View '#{view_name}' #{action}")}
        catch
          :exit, _ ->
            {:noreply, put_flash(socket, :error, "View '#{view_name}' not found")}
        end

      :error ->
        {:noreply, put_flash(socket, :error, "View '#{view_name}' not found")}
    end
  end

  @impl true
  def handle_event("validate_view", %{"view" => view_params}, socket) do
    errors = validate_view_fields(view_params)
    {:noreply, assign(socket, :form_errors, errors)}
  end

  @impl true
  def handle_event("save_view", %{"view" => view_params}, socket) do
    errors = validate_view_fields(view_params)

    if map_size(errors) > 0 do
      {:noreply, assign(socket, :form_errors, errors)}
    else
      save_view_impl(socket, view_params)
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
      result =
        try do
          ViewManager.stop_view(view_name)
        catch
          :exit, _ -> {:error, :service_unavailable}
        end

      case result do
        :ok ->
          # Persist configuration to files
          save_config_async()

          {:noreply,
           socket
           |> assign(:delete_confirm, nil)
           |> refresh_views()
           |> put_flash(:info, "View '#{view_name}' deleted successfully")}

        {:error, _reason} ->
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
    {:noreply,
     socket
     |> assign(:selected_countries, [])
     |> assign(:country_search, "")
     |> push_navigate(to: ~p"/dns/views")}
  end

  @impl true
  def handle_event("toggle_country", %{"code" => code}, socket) do
    selected = socket.assigns.selected_countries

    updated =
      if code in selected do
        List.delete(selected, code)
      else
        [code | selected]
      end

    {:noreply, assign(socket, :selected_countries, Enum.sort(updated))}
  end

  @impl true
  def handle_event("search_country", %{"search" => search}, socket) do
    {:noreply, assign(socket, :country_search, search)}
  end

  @impl true
  def handle_event("clear_country_search", _params, socket) do
    {:noreply, assign(socket, :country_search, "")}
  end

  @impl true
  def handle_event("acl_type_changed", %{"view" => %{"acl_type" => acl_type}}, socket) do
    form = socket.assigns.view_form

    form_data = %{
      "name" => form[:name].value,
      "priority" => form[:priority].value,
      "recursion_enabled" => form[:recursion_enabled].value,
      "ecs_enabled" => form[:ecs_enabled].value,
      "acl_type" => acl_type,
      "fallback_forwarders" => form[:fallback_forwarders].value,
      "fallback_timeout" => form[:fallback_timeout].value,
      "fallback_retries" => form[:fallback_retries].value
    }

    {:noreply, assign(socket, :view_form, to_form(form_data))}
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

  defp save_view_impl(socket, view_params) do
    editing = socket.assigns[:editing_view]
    is_default = socket.assigns[:is_default_view] || false

    priority =
      if is_default do
        :infinity
      else
        case Integer.parse(view_params["priority"] || "100") do
          {n, ""} -> n
          _ -> 100
        end
      end

    acl_config =
      if is_default do
        :any
      else
        build_acl_config(view_params["acl_type"], socket.assigns.selected_countries)
      end

    fallback_forwarders = parse_forwarders(view_params["fallback_forwarders"] || "")

    fallback_timeout =
      case Integer.parse(view_params["fallback_timeout"] || "2000") do
        {n, _} -> n
        :error -> 2000
      end

    fallback_retries =
      case Integer.parse(view_params["fallback_retries"] || "1") do
        {n, _} -> n
        :error -> 1
      end

    config = %{
      name: view_params["name"],
      priority: priority,
      recursion_enabled: view_params["recursion_enabled"] == "true",
      ecs_enabled: view_params["ecs_enabled"] == "true",
      acl: acl_config,
      fallback_forwarders: fallback_forwarders,
      fallback_timeout: fallback_timeout,
      fallback_retries: fallback_retries
    }

    result =
      try do
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
      catch
        :exit, _ -> {:error, :service_unavailable}
      end

    case result do
      :ok ->
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

  defp validate_view_fields(params) do
    errors = %{}
    name = params["name"] || ""
    forwarders = params["fallback_forwarders"] || ""

    # Validate view name (alphanumeric, hyphens, underscores)
    errors =
      if name != "" and not (name =~ ~r/^[a-zA-Z0-9_-]+$/) do
        Map.put(errors, :name, "Name must be alphanumeric with hyphens or underscores")
      else
        errors
      end

    # Validate fallback forwarders are valid IPs
    errors =
      if forwarders != "" do
        invalid =
          forwarders
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.find(fn entry ->
            # Strip optional :port suffix
            ip =
              case String.split(entry, ":", parts: 2) do
                [ip, _port] -> ip
                [ip] -> ip
              end

            Validators.validate_ip(ip, :ipv4) != :ok and
              Validators.validate_ip(ip, :ipv6) != :ok
          end)

        if invalid do
          Map.put(errors, :fallback_forwarders, "Invalid IP address: #{invalid}")
        else
          errors
        end
      else
        errors
      end

    errors
  end

  defp refresh_views(socket) do
    assign(socket, :views, list_views())
  end

  # ============================================================================
  # Filtering & CSV Export
  # ============================================================================

  def filtered_views(views, filter, status_filter) do
    views
    |> filter_views_by_name(filter)
    |> filter_views_by_status(status_filter)
  end

  defp filter_views_by_name(views, ""), do: views

  defp filter_views_by_name(views, filter) do
    filter_lower = String.downcase(filter)

    Enum.filter(views, fn view ->
      String.contains?(String.downcase(view.name), filter_lower)
    end)
  end

  defp filter_views_by_status(views, "all"), do: views
  defp filter_views_by_status(views, "active"), do: Enum.filter(views, & &1.enabled)
  defp filter_views_by_status(views, "disabled"), do: Enum.reject(views, & &1.enabled)

  defp build_views_csv(views) do
    header = "View Name,Status,Priority,Recursion,ECS,Zones,Queries\r\n"

    rows =
      Enum.map_join(views, "\r\n", fn view ->
        priority_str =
          if view.priority == :infinity, do: "infinity", else: to_string(view.priority)

        [
          csv_escape(view.name),
          if(view.enabled, do: "Active", else: "Disabled"),
          priority_str,
          if(view.recursion_enabled, do: "Enabled", else: "Disabled"),
          if(view.ecs_enabled, do: "Enabled", else: "Disabled"),
          to_string(view.zone_count),
          to_string(view.query_count)
        ]
        |> Enum.join(",")
      end)

    header <> rows
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
          enabled: Map.get(stats, :enabled, true),
          recursion_enabled: Map.get(stats, :recursion_enabled, false),
          ecs_enabled: Map.get(stats, :ecs_enabled, false),
          zone_count: length(Map.get(stats, :zones, [])),
          query_count: Map.get(stats, :query_count, 0)
        }
      end)
      |> Enum.sort_by(& &1.priority)
    catch
      _, _ -> []
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
            ecs_enabled: stats.ecs_enabled,
            acl: Map.get(stats, :acl, :any),
            fallback_forwarders: Map.get(stats, :fallback_forwarders, []),
            fallback_timeout: Map.get(stats, :fallback_timeout, 2000),
            fallback_retries: Map.get(stats, :fallback_retries, 1)
          }

          {:ok, config}

        :error ->
          :error
      end
    catch
      _, _ -> :error
    end
  end

  defp parse_acl_for_form(acl) do
    case acl do
      :any -> {"any", []}
      :none -> {"none", []}
      "localhost" -> {"localhost", []}
      "localnets" -> {"localnets", []}
      rules when is_list(rules) -> extract_acl_type_and_countries(rules)
      _ -> {"any", []}
    end
  end

  defp extract_acl_type_and_countries(rules) do
    # Check if rules contain geo rules
    geo_countries =
      Enum.flat_map(rules, fn
        {:allow, {:geo, countries}} -> countries
        {:deny, {:geo, countries}} -> countries
        _ -> []
      end)

    if geo_countries != [] do
      {"geo", Enum.sort(Enum.uniq(geo_countries))}
    else
      {"custom", []}
    end
  end

  defp build_acl_config(acl_type, selected_countries) do
    case acl_type do
      "any" -> :any
      "none" -> :none
      "localhost" -> "localhost"
      "localnets" -> "localnets"
      "geo" when selected_countries != [] -> [{:allow, {:geo, selected_countries}}]
      "geo" -> :any
      _ -> :any
    end
  end

  defp parse_forwarders(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn entry ->
      case String.split(entry, ":") do
        [ip, port_str] ->
          case Integer.parse(port_str) do
            {port, _} -> {parse_ip_tuple(ip), port}
            :error -> {parse_ip_tuple(ip), 53}
          end

        [ip] ->
          {parse_ip_tuple(ip), 53}
      end
    end)
  end

  defp parse_ip_tuple(ip_str) do
    case :inet.parse_address(String.to_charlist(ip_str)) do
      {:ok, ip} -> ip
      {:error, _} -> {0, 0, 0, 0}
    end
  end

  defp save_config_async do
    Task.start(fn ->
      case ConfigPersistence.save_current() do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to save DNS config", error: inspect(reason))
      end
    end)
  end
end
