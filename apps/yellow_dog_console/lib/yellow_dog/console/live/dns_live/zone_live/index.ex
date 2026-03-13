defmodule YellowDog.Console.DnsLive.ZoneLive.Index do
  @moduledoc """
  DNS Zones management page with data table.
  Second level of the View -> Zone -> Records hierarchy.
  Shows zones for a specific view.
  """
  use YellowDog.Console, :live_view

  require Logger

  import YellowDog.Console.CsvHelper
  import YellowDog.Console.ServiceHelper
  import YellowDog.Console.StringHelper, only: [downcase_contains?: 2]

  alias YellowDog.Console.StringHelper
  alias YellowDog.Console.Validators
  alias YellowDog.Dns.View
  alias YellowDog.Dns.ViewManager
  alias YellowDog.Dns.ZoneController
  alias YellowDog.Dns.ConfigPersistence

  @valid_zone_types ~w(auth forward stub cache rpz)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "dns:zones")
    end

    {:ok,
     assign(socket,
       page_title: "DNS Zones",
       service_running: service_running?(YellowDog.Dns),
       view_name: nil,
       zones: [],
       filter: "",
       type_filter: "all",
       delete_confirm: nil,
       zone_form: nil,
       import_form: nil,
       editing_zone: nil,
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
    |> assign(:form_errors, %{})
    |> load_zones()
  end

  defp apply_action(socket, :edit, %{
         "view_name" => view_name,
         "zone_type" => zone_type,
         "zone_name" => zone_name
       })
       when zone_type in @valid_zone_types do
    zone_type_atom = String.to_existing_atom(zone_type)

    # If zone type is :unknown (from stale View state), try to resolve the actual type
    zone_type_atom =
      if zone_type_atom == :unknown do
        case resolve_zone_type(view_name, zone_name) do
          {:ok, resolved_type} -> resolved_type
          :error -> :unknown
        end
      else
        zone_type_atom
      end

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
        |> push_navigate(to: ~p"/server/dns/views/#{view_name}/zones")
    end
  end

  defp apply_action(socket, :edit, %{"view_name" => view_name}) do
    socket
    |> put_flash(:error, "Invalid zone type")
    |> push_navigate(to: ~p"/server/dns/views/#{view_name}/zones")
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
  def handle_event("filter", %{"filter" => filter}, socket) do
    {:noreply, assign(socket, :filter, filter)}
  end

  @impl true
  def handle_event("filter_type", %{"type" => type}, socket) do
    {:noreply, assign(socket, :type_filter, type)}
  end

  @impl true
  def handle_event("export_csv", _params, socket) do
    zones =
      filtered_zones(socket.assigns.zones, socket.assigns.filter, socket.assigns.type_filter)

    csv = build_zones_csv(zones)
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")
    filename = "dns_zones_#{socket.assigns.view_name}_#{timestamp}.csv"
    {:noreply, push_event(socket, "download_csv", %{content: csv, filename: filename})}
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

    errors = validate_zone_fields(form_data)

    {:noreply,
     socket
     |> assign(:zone_form, to_form(form_data))
     |> assign(:form_errors, errors)}
  end

  @impl true
  def handle_event("save_zone", %{"zone" => zone_params}, socket) do
    form_data = %{
      "name" => zone_params["name"] || "",
      "type" => zone_params["type"] || "auth",
      "upstreams" => zone_params["upstreams"] || "",
      "ns_records" => zone_params["ns_records"] || ""
    }

    errors = validate_zone_fields(form_data)

    if map_size(errors) > 0 do
      {:noreply,
       socket
       |> assign(:zone_form, to_form(form_data))
       |> assign(:form_errors, errors)}
    else
      save_zone_impl(socket, zone_params)
    end
  end

  @impl true
  def handle_event("import_zone", %{"import" => import_params}, socket) do
    view_name = socket.assigns.view_name
    zone_data = import_params["zone_data"]
    format = import_params["format"]

    case format do
      "zone" ->
        import_bind_zone(socket, view_name, zone_data)

      _ ->
        {:noreply, put_flash(socket, :error, "Unsupported import format: #{format}")}
    end
  end

  @impl true
  def handle_event("confirm_delete", %{"type" => type, "name" => zone_name}, socket)
      when type in @valid_zone_types do
    {:noreply,
     assign(socket, :delete_confirm, %{zone_type: String.to_existing_atom(type), name: zone_name})}
  end

  @impl true
  def handle_event("confirm_delete", _params, socket) do
    {:noreply, put_flash(socket, :error, "Invalid zone type")}
  end

  @impl true
  def handle_event("delete_zone", _params, socket) do
    %{delete_confirm: %{zone_type: zone_type, name: zone_name}, view_name: view_name} =
      socket.assigns

    # Pass view_name for view-scoped zone deletion
    result =
      try do
        ZoneController.stop_zone(view_name, zone_type, zone_name)
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
         |> load_zones()
         |> put_flash(:info, "Zone '#{zone_name}' deleted successfully")}

      {:error, _reason} ->
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
    {:noreply, push_navigate(socket, to: ~p"/server/dns/views/#{view_name}/zones")}
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

  defp save_zone_impl(socket, %{"type" => zone_type_str} = zone_params)
       when zone_type_str in @valid_zone_types do
    editing = socket.assigns[:editing_zone]
    view_name = socket.assigns.view_name
    zone_name = zone_params["name"]
    zone_type = String.to_existing_atom(zone_type_str)

    # Build config based on zone type
    config = build_zone_config(zone_type, zone_params)

    # Add view_name to config so zone is scoped to this view
    config = Keyword.put(config, :view_name, view_name)

    result =
      try do
        if editing do
          case ZoneController.reload_zone(view_name, editing.type, editing.name, config) do
            :ok -> :ok
            {:error, reason} -> {:error, reason}
          end
        else
          case ZoneController.start_zone(zone_type, zone_name, config) do
            {:ok, _pid} ->
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
      catch
        :exit, _ -> {:error, :service_unavailable}
      end

    case result do
      :ok ->
        save_config_async()
        action = if editing, do: "updated", else: "created"

        {:noreply,
         socket
         |> put_flash(:info, "Zone '#{zone_name}' #{action} successfully")
         |> push_navigate(to: ~p"/server/dns/views/#{view_name}/zones")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save zone: #{inspect(reason)}")}
    end
  end

  defp save_zone_impl(socket, _zone_params) do
    {:noreply, put_flash(socket, :error, "Invalid zone type")}
  end

  defp validate_zone_fields(form_data) do
    errors = %{}
    name = form_data["name"]
    zone_type = form_data["type"]

    # Validate zone name (domain name) — only when non-empty
    errors =
      if name != "" do
        case Validators.validate_domain_name(name) do
          :ok -> errors
          {:error, msg} -> Map.put(errors, :name, msg)
        end
      else
        errors
      end

    # Validate upstreams are valid IPs (for forward zones)
    errors =
      if zone_type == "forward" do
        upstreams = form_data["upstreams"] || ""

        invalid =
          upstreams
          |> StringHelper.split_and_trim("\n")
          |> Enum.find(fn ip ->
            Validators.validate_ip(ip, :ipv4) != :ok and
              Validators.validate_ip(ip, :ipv6) != :ok
          end)

        if invalid do
          Map.put(errors, :upstreams, "Invalid IP address: #{invalid}")
        else
          errors
        end
      else
        errors
      end

    # Validate NS records are valid domain names (for stub zones)
    errors =
      if zone_type == "stub" do
        ns_records = form_data["ns_records"] || ""

        invalid =
          ns_records
          |> StringHelper.split_and_trim("\n")
          |> Enum.find(fn ns ->
            Validators.validate_domain_name(ns) != :ok
          end)

        if invalid do
          Map.put(errors, :ns_records, "Invalid domain name: #{invalid}")
        else
          errors
        end
      else
        errors
      end

    errors
  end

  defp import_bind_zone(socket, view_name, zone_data) do
    # Parse the zone data to extract the origin/zone name
    case DNS.Zone.parse_zone_string(zone_data) do
      {:ok, zone} ->
        zone_name = zone.origin || "imported.zone"
        # Remove trailing dot if present
        zone_name = String.trim_trailing(zone_name, ".")

        # Create an auth zone and import the data
        start_result =
          try do
            ZoneController.start_zone(:auth, zone_name, view_name: view_name)
          catch
            :exit, _ -> {:error, :service_unavailable}
          end

        case start_result do
          {:ok, zone_pid} ->
            # Register zone with view
            try do
              case ViewManager.get_view(view_name) do
                {:ok, view_pid} -> View.register_zone(view_pid, :auth, zone_name)
                :error -> :ok
              end
            catch
              :exit, _ -> :ok
            end

            # Import the zone data
            import_result =
              try do
                YellowDog.Dns.Zone.Auth.import_zone_file(zone_pid, zone_data)
              catch
                :exit, _ -> {:error, :service_unavailable}
              end

            case import_result do
              {:ok, stats} ->
                save_config_async()

                {:noreply,
                 socket
                 |> put_flash(
                   :info,
                   "Zone '#{zone_name}' imported with #{stats.records_imported} records"
                 )
                 |> push_navigate(to: ~p"/server/dns/views/#{view_name}/zones")}

              {:error, reason} ->
                {:noreply,
                 put_flash(socket, :error, "Failed to import zone data: #{inspect(reason)}")}
            end

          {:error, {:already_started, existing_pid}} ->
            # Zone already exists — import records into it
            import_result =
              try do
                YellowDog.Dns.Zone.Auth.import_zone_file(existing_pid, zone_data)
              catch
                :exit, _ -> {:error, :service_unavailable}
              end

            case import_result do
              {:ok, stats} ->
                save_config_async()

                {:noreply,
                 socket
                 |> put_flash(
                   :info,
                   "Imported #{stats.records_imported} records into existing zone '#{zone_name}'"
                 )
                 |> push_navigate(to: ~p"/server/dns/views/#{view_name}/zones")}

              {:error, reason} ->
                {:noreply,
                 put_flash(socket, :error, "Failed to import zone data: #{inspect(reason)}")}
            end

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to create zone: #{inspect(reason)}")}
        end

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to parse zone data: #{inspect(reason)}")}
    end
  end

  # Build zone configuration based on zone type
  defp build_zone_config(:auth, _params) do
    # Auth zones don't need extra config (records are added separately)
    []
  end

  defp build_zone_config(:forward, params) do
    upstreams =
      params["upstreams"]
      |> StringHelper.split_and_trim("\n")

    [upstreams: upstreams]
  end

  defp build_zone_config(:stub, params) do
    ns_records =
      params["ns_records"]
      |> StringHelper.split_and_trim("\n")

    [ns_records: ns_records]
  end

  defp build_zone_config(_type, _params) do
    []
  end

  defp load_zones(socket) do
    view_name = socket.assigns.view_name

    # get_view_with_zones always returns {:ok, view} with fallback to persisted config
    {:ok, view} = get_view_with_zones(view_name)
    assign(socket, :zones, view.zones)
  end

  defp get_view_with_zones(view_name) do
    # First try to get from running DNS service
    case get_view_with_zones_from_service(view_name) do
      {:ok, view} ->
        {:ok, view}

      :error ->
        # Fall back to persisted configuration
        get_view_with_zones_from_persistence(view_name)
    end
  end

  defp get_view_with_zones_from_service(view_name) do
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
    catch
      _, _ -> :error
    end
  end

  defp get_view_with_zones_from_persistence(view_name) do
    try do
      case ConfigPersistence.load_all() do
        {:ok, %{zones: zones}} ->
          # Filter zones for this view
          view_zones =
            zones
            |> Enum.filter(fn z ->
              z.view_name == view_name || (z.view_name == "default" && view_name == "default")
            end)
            |> Enum.map(fn z ->
              %{
                type: z.type,
                name: z.name,
                record_count: 0,
                query_count: 0
              }
            end)

          {:ok, %{name: view_name, zones: view_zones}}

        _ ->
          # Return empty zones list if no persisted config
          {:ok, %{name: view_name, zones: []}}
      end
    catch
      _, _ -> {:ok, %{name: view_name, zones: []}}
    end
  end

  defp get_zones_with_details(stats, view_name) do
    zones_config = Map.get(stats, :zones, [])

    Enum.map(zones_config, fn
      {type, name} ->
        zone_stats = get_zone_stats(view_name, type, name)
        Map.merge(%{type: type, name: name}, zone_stats)

      name when is_binary(name) ->
        # View has a plain string zone (from TOML persistence without type info).
        # Try to resolve the actual type from running ZoneController processes.
        case resolve_zone_type(view_name, name) do
          {:ok, type} ->
            zone_stats = get_zone_stats(view_name, type, name)
            Map.merge(%{type: type, name: name}, zone_stats)

          :error ->
            %{type: :unknown, name: name, record_count: 0, query_count: 0}
        end
    end)
  end

  # Resolve zone type by checking running zone processes, then persisted config
  defp resolve_zone_type(view_name, zone_name) do
    # Try 1: Check running ZoneController processes
    case resolve_zone_type_from_controller(view_name, zone_name) do
      {:ok, _type} = result ->
        result

      :error ->
        # Try 2: Check persisted zone config (zones.toml)
        resolve_zone_type_from_persistence(view_name, zone_name)
    end
  end

  defp resolve_zone_type_from_controller(view_name, zone_name) do
    try do
      ZoneController.list_zones_for_view(view_name)
      |> Enum.find_value(fn
        {type, name, _pid} when name == zone_name -> {:ok, type}
        _ -> nil
      end)
      |> Kernel.||(:error)
    catch
      _, _ -> :error
    end
  end

  defp resolve_zone_type_from_persistence(view_name, zone_name) do
    case ConfigPersistence.load_all() do
      {:ok, %{zones: zones}} ->
        case Enum.find(zones, fn z ->
               z.name == zone_name &&
                 (z.view_name == view_name ||
                    (z.view_name == "default" && view_name == "default"))
             end) do
          %{type: type} -> {:ok, type}
          _ -> :error
        end

      _ ->
        :error
    end
  catch
    _, _ -> :error
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
    catch
      _, _ -> %{record_count: 0, query_count: 0}
    end
  end

  defp get_zone_config(view_name, zone_type, zone_name) do
    # First try to get config from running DNS service
    case get_zone_config_from_service(view_name, zone_type, zone_name) do
      {:ok, config} ->
        {:ok, config}

      :error ->
        # Fall back to persisted configuration
        get_zone_config_from_persistence(view_name, zone_type, zone_name)
    end
  end

  defp get_zone_config_from_service(view_name, zone_type, zone_name) do
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
    catch
      _, _ -> :error
    end
  end

  defp get_zone_config_from_persistence(view_name, zone_type, zone_name) do
    try do
      case ConfigPersistence.load_all() do
        {:ok, %{zones: zones}} ->
          # Find the matching zone in persisted config
          zone =
            Enum.find(zones, fn z ->
              z.name == zone_name &&
                z.type == zone_type &&
                (z.view_name == view_name || (z.view_name == "default" && view_name == "default"))
            end)

          if zone do
            {:ok,
             %{
               name: zone.name,
               type: zone.type,
               upstreams: zone[:upstreams] || [],
               ns_records: zone[:ns_records] || []
             }}
          else
            :error
          end

        _ ->
          :error
      end
    catch
      _, _ -> :error
    end
  end

  defp zone_module(:auth), do: YellowDog.Dns.Zone.Auth
  defp zone_module(:forward), do: YellowDog.Dns.Zone.Forward
  defp zone_module(:stub), do: YellowDog.Dns.Zone.Stub
  defp zone_module(:cache), do: YellowDog.Dns.Zone.Cache

  # ============================================================================
  # Filtering & CSV Export
  # ============================================================================

  def filtered_zones(zones, filter, type_filter) do
    zones
    |> filter_by_name(filter)
    |> filter_by_type(type_filter)
  end

  defp filter_by_name(zones, ""), do: zones

  defp filter_by_name(zones, filter) do
    filter_lower = String.downcase(filter)

    Enum.filter(zones, fn zone ->
      downcase_contains?(zone.name, filter_lower)
    end)
  end

  defp filter_by_type(zones, "all"), do: zones

  defp filter_by_type(zones, type) when type in @valid_zone_types do
    type_atom = String.to_existing_atom(type)
    Enum.filter(zones, fn zone -> zone.type == type_atom end)
  end

  defp filter_by_type(zones, _type), do: zones

  def unique_zone_types(zones) do
    zones
    |> Enum.map(& &1.type)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp build_zones_csv(zones) do
    header = "Zone Name,Type,Records,Queries\r\n"

    rows =
      Enum.map_join(zones, "\r\n", fn zone ->
        [
          csv_escape(zone.name),
          csv_escape(zone_type_label(zone.type)),
          to_string(Map.get(zone, :record_count, 0)),
          to_string(Map.get(zone, :query_count, 0))
        ]
        |> Enum.join(",")
      end)

    header <> rows
  end

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
          Logger.warning("Failed to save DNS config", error: inspect(reason))
      end
    end)
  end
end
