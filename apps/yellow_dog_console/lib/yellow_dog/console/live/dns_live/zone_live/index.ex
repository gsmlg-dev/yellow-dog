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
  alias YellowDog.Dns.ConfigPersistence
  alias YellowDog.Dns.View
  alias YellowDog.Dns.ViewManager
  alias YellowDog.Dns.ZoneController
  alias YellowDog.Tasks
  alias YellowDog.Store.Provider, as: StoreProvider
  alias YellowDog.Store.Zone, as: StoreZone

  @valid_zone_types ~w(auth forward stub cache rpz)
  @default_view_name "default"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "dns:zones")
    end

    {:ok,
     assign(socket,
       page_title: "DNS Zones",
       service_running: service_running?(YellowDog.Dns),
       view_name: @default_view_name,
       zones: [],
       filter: "",
       type_filter: "all",
       delete_confirm: nil,
       zone_form: nil,
       import_form: nil,
       editing_zone: nil,
       form_errors: %{},
       cloud_dns_connectors: []
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
    |> assign(:page_title, "DNS Zones")
    |> assign(:view_name, @default_view_name)
    |> assign(:zone_form, nil)
    |> assign(:import_form, nil)
    |> assign(:editing_zone, nil)
    |> load_zones()
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Zone")
    |> assign(:view_name, @default_view_name)
    |> assign(:editing_zone, nil)
    |> assign(:zone_form, to_form(default_zone_form_data()))
    |> assign(:form_errors, %{})
    |> load_cloud_dns_connectors()
    |> load_zones()
  end

  defp apply_action(socket, :edit, %{"zone_id" => zone_id}) do
    with {:ok, zone} <- get_default_zone_by_id(zone_id),
         {:ok, config} <- get_zone_config(@default_view_name, zone.zone_type, zone.origin) do
      socket
      |> assign(:page_title, "Edit Zone - #{zone.origin}")
      |> assign(:view_name, @default_view_name)
      |> assign(:editing_zone, %{id: zone.id, name: zone.origin, type: zone.zone_type})
      |> assign(:zone_form, to_form(zone_config_form_data(config)))
      |> load_cloud_dns_connectors()
      |> load_zones()
    else
      _ ->
        socket
        |> put_flash(:error, "Zone not found")
        |> push_navigate(to: zones_path())
    end
  end

  defp apply_action(socket, :edit, _params) do
    socket
    |> put_flash(:error, "Zone not found")
    |> push_navigate(to: zones_path())
  end

  defp apply_action(socket, :import, _params) do
    form_data = %{
      "zone_data" => "",
      "format" => "zone"
    }

    socket
    |> assign(:page_title, "Import Zone")
    |> assign(:view_name, @default_view_name)
    |> assign(:import_form, to_form(form_data))
    |> load_zones()
  end

  # ============================================================================
  # Event Handlers
  # ============================================================================

  @impl true
  def handle_event("refresh", _params, socket) do
    socket = enqueue_all_cloud_zone_syncs(socket)
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
    filename = "dns_zones_#{timestamp}.csv"
    {:noreply, push_event(socket, "download_csv", %{content: csv, filename: filename})}
  end

  @impl true
  def handle_event("validate_zone", %{"zone" => zone_params}, socket) do
    # Update form with new values to show/hide fields based on type
    form_data = zone_params_form_data(zone_params, socket.assigns[:editing_zone])
    errors = validate_zone_fields(form_data, socket.assigns.cloud_dns_connectors)

    {:noreply,
     socket
     |> assign(:zone_form, to_form(form_data))
     |> assign(:form_errors, errors)}
  end

  @impl true
  def handle_event("save_zone", %{"zone" => zone_params}, socket) do
    form_data = zone_params_form_data(zone_params, socket.assigns[:editing_zone])
    errors = validate_zone_fields(form_data, socket.assigns.cloud_dns_connectors)

    if map_size(errors) > 0 do
      {:noreply,
       socket
       |> assign(:zone_form, to_form(form_data))
       |> assign(:form_errors, errors)}
    else
      save_zone_impl(socket, form_data)
    end
  end

  @impl true
  def handle_event("import_zone", %{"import" => import_params}, socket) do
    zone_data = import_params["zone_data"]
    format = import_params["format"]

    case format do
      "zone" ->
        import_bind_zone(socket, @default_view_name, zone_data)

      _ ->
        {:noreply, put_flash(socket, :error, "Unsupported import format: #{format}")}
    end
  end

  @impl true
  def handle_event("confirm_delete", %{"id" => zone_id}, socket) do
    case get_default_zone_by_id(zone_id) do
      {:ok, zone} ->
        {:noreply,
         assign(socket, :delete_confirm, %{
           id: zone.id,
           zone_type: zone.zone_type,
           name: zone.origin
         })}

      _ ->
        {:noreply, put_flash(socket, :error, "Zone not found")}
    end
  end

  @impl true
  def handle_event("confirm_delete", _params, socket) do
    {:noreply, put_flash(socket, :error, "Zone not found")}
  end

  @impl true
  def handle_event("delete_zone", _params, socket) do
    %{delete_confirm: %{zone_type: zone_type, name: zone_name}, view_name: view_name} =
      socket.assigns

    _service_result =
      try do
        ZoneController.stop_zone(view_name, zone_type, zone_name)
      catch
        :exit, _ -> {:error, :service_unavailable}
      end

    result = StoreZone.delete_zone(view_name, zone_name)

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
    {:noreply, push_navigate(socket, to: zones_path())}
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
    zone_name = if editing, do: editing.name, else: zone_params["name"]
    zone_type = String.to_existing_atom(zone_type_str)

    # Build config based on zone type
    config = build_zone_config(zone_type, zone_params, socket.assigns.cloud_dns_connectors)

    # Add view_name to config so zone is scoped to this view
    config = Keyword.put(config, :view_name, view_name)

    result =
      try do
        if editing do
          case ZoneController.reload_zone(view_name, editing.type, editing.name, config) do
            :ok -> persist_zone_metadata(view_name, editing.type, editing.name, config)
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
        maybe_enqueue_cloud_dns_sync(view_name, zone_name, zone_type, config)
        save_config_async()
        action = if editing, do: "updated", else: "created"

        {:noreply,
         socket
         |> put_flash(:info, "Zone '#{zone_name}' #{action} successfully")
         |> push_navigate(to: zones_path())}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save zone: #{inspect(reason)}")}
    end
  end

  defp save_zone_impl(socket, _zone_params) do
    {:noreply, put_flash(socket, :error, "Invalid zone type")}
  end

  defp default_zone_form_data do
    %{
      "name" => "",
      "type" => "auth",
      "upstreams" => "",
      "ns_records" => "",
      "mirror_enabled" => "false",
      "mirror_connector" => "",
      "mirror_provider" => "cloudflare",
      "mirror_zone_id" => "",
      "mirror_direction" => "bidirectional",
      "mirror_conflict_strategy" => "local_wins"
    }
  end

  defp zone_params_form_data(params, editing_zone) do
    defaults = default_zone_form_data()

    Map.merge(defaults, %{
      "name" => params["name"] || editing_zone_name(editing_zone) || defaults["name"],
      "type" => params["type"] || editing_zone_type(editing_zone) || defaults["type"],
      "upstreams" => params["upstreams"] || defaults["upstreams"],
      "ns_records" => params["ns_records"] || defaults["ns_records"],
      "mirror_enabled" => normalize_mirror_enabled(params["mirror_enabled"]),
      "mirror_connector" => params["mirror_connector"] || defaults["mirror_connector"],
      "mirror_provider" => params["mirror_provider"] || defaults["mirror_provider"],
      "mirror_zone_id" => params["mirror_zone_id"] || defaults["mirror_zone_id"],
      "mirror_direction" => params["mirror_direction"] || defaults["mirror_direction"],
      "mirror_conflict_strategy" =>
        params["mirror_conflict_strategy"] || defaults["mirror_conflict_strategy"]
    })
  end

  defp zone_config_form_data(config) do
    default_zone_form_data()
    |> Map.merge(%{
      "name" => Map.get(config, :name, ""),
      "type" => config |> Map.get(:type, :auth) |> to_string(),
      "upstreams" => config |> Map.get(:upstreams, []) |> Enum.join("\n"),
      "ns_records" => config |> Map.get(:ns_records, []) |> Enum.join("\n")
    })
    |> Map.merge(cloud_mirror_form_data(Map.get(config, :cloud_mirror)))
  end

  defp editing_zone_name(nil), do: nil
  defp editing_zone_name(%{name: name}), do: name

  defp editing_zone_type(nil), do: nil
  defp editing_zone_type(%{type: type}), do: to_string(type)

  defp cloud_mirror_form_data(nil), do: %{}

  defp cloud_mirror_form_data(mirror) when is_map(mirror) do
    %{
      "mirror_enabled" => normalize_mirror_enabled(mirror_value(mirror, :enabled, false)),
      "mirror_connector" => mirror_value(mirror, :connector_name, ""),
      "mirror_provider" => mirror_value(mirror, :provider, "cloudflare") |> to_string(),
      "mirror_zone_id" => mirror_value(mirror, :zone_id, ""),
      "mirror_direction" => mirror_value(mirror, :direction, "bidirectional") |> to_string(),
      "mirror_conflict_strategy" =>
        mirror_value(mirror, :conflict_strategy, "local_wins") |> to_string()
    }
  end

  defp mirror_value(map, key, default) do
    Map.get(map, key) || Map.get(map, to_string(key)) || default
  end

  def mirror_enabled?(values) when is_list(values), do: Enum.any?(values, &mirror_enabled?/1)
  def mirror_enabled?(true), do: true
  def mirror_enabled?("true"), do: true
  def mirror_enabled?("on"), do: true
  def mirror_enabled?("1"), do: true
  def mirror_enabled?(_value), do: false

  def cloud_mirror_fields(assigns) do
    assigns = assign_new(assigns, :cloud_dns_connectors, fn -> [] end)

    ~H"""
    <div class="space-y-4 border-t border-outline-variant pt-4">
      <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h3 class="text-base font-semibold">Cloud Provider Settings</h3>
          <p class="text-sm text-on-surface-variant">Cloud DNS Mirror</p>
        </div>
        <label class="label cursor-pointer justify-start gap-3 p-0">
          <input type="hidden" name="zone[mirror_enabled]" value="false" />
          <input
            type="checkbox"
            name="zone[mirror_enabled]"
            value="true"
            class="toggle toggle-primary"
            checked={mirror_enabled?(@zone_form[:mirror_enabled].value)}
          />
          <span class="label-text font-semibold">Enable cloud sync</span>
        </label>
      </div>

      <div>
        <div class="form-group">
          <label class="form-label font-semibold">Cloud DNS Connector</label>
          <select
            name="zone[mirror_connector]"
            aria-label="Cloud DNS connector"
            class={"select w-full font-mono #{if @form_errors[:mirror_connector], do: "select-error"}"}
          >
            <option
              value=""
              selected={String.trim(@zone_form[:mirror_connector].value || "") == ""}
            >
              Select Cloud DNS connector
            </option>
            <option
              :for={connector <- @cloud_dns_connectors}
              value={connector.name}
              selected={@zone_form[:mirror_connector].value == connector.name}
            >
              {connector.name} - {provider_label(connector.type)}
            </option>
          </select>
          <%= if @form_errors[:mirror_connector] do %>
            <span class="helper-text text-error">{@form_errors[:mirror_connector]}</span>
          <% else %>
            <span :if={@cloud_dns_connectors == []} class="helper-text">
              No Cloud DNS connectors configured.
            </span>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp normalize_mirror_enabled(value) do
    if mirror_enabled?(value), do: "true", else: "false"
  end

  defp validate_zone_fields(form_data, cloud_dns_connectors) do
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

    validate_cloud_mirror_fields(errors, form_data, cloud_dns_connectors)
  end

  defp validate_cloud_mirror_fields(errors, %{"type" => "auth"} = form_data, cloud_dns_connectors) do
    if mirror_enabled?(form_data["mirror_enabled"]) do
      errors
      |> validate_mirror_connector(form_data["mirror_connector"], cloud_dns_connectors)
    else
      errors
    end
  end

  defp validate_cloud_mirror_fields(errors, _form_data, _cloud_dns_connectors), do: errors

  defp validate_mirror_connector(errors, connector, cloud_dns_connectors) do
    connector = String.trim(connector || "")

    cond do
      connector == "" ->
        Map.put(errors, :mirror_connector, "Cloud DNS connector is required")

      Enum.any?(cloud_dns_connectors, &(&1.name == connector)) ->
        errors

      true ->
        Map.put(errors, :mirror_connector, "Select a configured Cloud DNS connector")
    end
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
                 |> push_navigate(to: zones_path())}

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
                 |> push_navigate(to: zones_path())}

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
  defp build_zone_config(:auth, params, cloud_dns_connectors) do
    [cloud_mirror: cloud_mirror_from_params(params, cloud_dns_connectors)]
  end

  defp build_zone_config(:forward, params, _cloud_dns_connectors) do
    upstreams =
      params["upstreams"]
      |> StringHelper.split_and_trim("\n")

    [upstreams: upstreams]
  end

  defp build_zone_config(:stub, params, _cloud_dns_connectors) do
    ns_records =
      params["ns_records"]
      |> StringHelper.split_and_trim("\n")

    [ns_records: ns_records]
  end

  defp build_zone_config(_type, _params, _cloud_dns_connectors) do
    []
  end

  defp cloud_mirror_from_params(params, cloud_dns_connectors) do
    if mirror_enabled?(params["mirror_enabled"]) do
      connector_name = String.trim(params["mirror_connector"] || "")

      %{
        enabled: true,
        connector_name: connector_name,
        provider: connector_provider(connector_name, cloud_dns_connectors),
        zone_id: String.trim(params["mirror_zone_id"] || ""),
        direction: mirror_direction_atom(params["mirror_direction"]),
        conflict_strategy: mirror_conflict_strategy_atom(params["mirror_conflict_strategy"])
      }
    end
  end

  defp connector_provider(connector_name, cloud_dns_connectors) do
    cloud_dns_connectors
    |> Enum.find(&(&1.name == connector_name))
    |> case do
      %{type: type} -> type
      _ -> :cloudflare
    end
  end

  defp mirror_direction_atom("pull_from_cloud"), do: :pull_from_cloud
  defp mirror_direction_atom("push_to_cloud"), do: :push_to_cloud
  defp mirror_direction_atom(_direction), do: :bidirectional

  defp mirror_conflict_strategy_atom("cloud_wins"), do: :cloud_wins
  defp mirror_conflict_strategy_atom("manual"), do: :manual
  defp mirror_conflict_strategy_atom(_strategy), do: :local_wins

  defp maybe_enqueue_cloud_dns_sync(view_name, zone_name, :auth, config) do
    if cloud_mirror_config_enabled?(Keyword.get(config, :cloud_mirror)) do
      task_key = Tasks.cloud_zone_task_key(view_name, zone_name)

      case Tasks.enqueue(task_key) do
        {:ok, _job} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to enqueue Cloud DNS sync",
            view: view_name,
            zone: zone_name,
            error: inspect(reason)
          )
      end
    else
      :ok
    end
  end

  defp maybe_enqueue_cloud_dns_sync(_view_name, _zone_name, _zone_type, _config), do: :ok

  defp enqueue_all_cloud_zone_syncs(socket) do
    cloud_zone_tasks = Enum.filter(Tasks.list_tasks(), &cloud_zone_task?/1)

    {queued, failed} =
      Enum.reduce(cloud_zone_tasks, {0, []}, fn task, {queued, failed} ->
        case Tasks.enqueue(task.key) do
          {:ok, _job} -> {queued + 1, failed}
          {:error, reason} -> {queued, [{task.key, reason} | failed]}
        end
      end)

    cond do
      failed != [] ->
        Logger.warning("Failed to enqueue Cloud DNS refresh sync",
          failures: inspect(Enum.reverse(failed))
        )

        put_flash(socket, :error, "Unable to queue #{length(failed)} Cloud DNS sync task(s)")

      queued > 0 ->
        put_flash(socket, :info, "Queued Cloud DNS sync for #{queued} zone(s)")

      true ->
        socket
    end
  end

  defp cloud_zone_task?(%{key: key}) when is_binary(key),
    do: String.starts_with?(key, "cloud_zone:")

  defp cloud_zone_task?(_task), do: false

  defp cloud_mirror_config_enabled?(mirror) when is_map(mirror) do
    mirror
    |> mirror_value(:enabled, false)
    |> mirror_enabled?()
  end

  defp cloud_mirror_config_enabled?(_mirror), do: false

  defp persist_zone_metadata(view_name, :auth, zone_name, config) do
    StoreZone.update_zone(view_name, zone_name, %{
      cloud_mirror: Keyword.get(config, :cloud_mirror)
    })
  end

  defp persist_zone_metadata(_view_name, _zone_type, _zone_name, _config), do: :ok

  defp load_zones(socket) do
    zones =
      case StoreZone.list_zones_for_view(@default_view_name) do
        {:ok, zones} -> Enum.map(zones, &zone_row_from_store/1)
        {:error, _reason} -> []
      end

    assign(socket, :zones, zones)
  end

  defp zone_row_from_store(zone) do
    zone_type = Map.get(zone, :zone_type)
    zone_name = Map.get(zone, :origin)

    %{
      id: Map.get(zone, :id),
      type: zone_type,
      name: zone_name,
      cloud_mirror: Map.get(zone, :cloud_mirror),
      record_count: 0,
      query_count: 0
    }
    |> Map.merge(get_zone_stats(@default_view_name, zone_type, zone_name))
  end

  defp get_default_zone_by_id(zone_id) do
    with {:ok, zone} <- StoreZone.get_zone_by_id(zone_id),
         @default_view_name <- Map.get(zone, :view_name) do
      {:ok, zone}
    else
      _ -> {:error, :not_found}
    end
  end

  defp zones_path, do: ~p"/server/dns/zones"
  defp new_zone_path, do: ~p"/server/dns/zones/new"
  defp import_zone_path, do: ~p"/server/dns/zones/import"
  defp edit_zone_path(zone_id), do: ~p"/server/dns/zones/#{zone_id}/edit"
  defp records_path(zone_id), do: ~p"/server/dns/zones/#{zone_id}/records"

  defp load_cloud_dns_connectors(socket) do
    connectors =
      case StoreProvider.list_configs() do
        {:ok, configs} -> configs
        {:error, _reason} -> []
      end

    assign(socket, :cloud_dns_connectors, connectors)
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
        {:ok, merge_store_zone_metadata(config, view_name, zone_type, zone_name)}

      :error ->
        # Fall back to Store metadata, then legacy file persistence.
        case get_zone_config_from_store(view_name, zone_type, zone_name) do
          {:ok, config} ->
            {:ok, config}

          :error ->
            case get_zone_config_from_persistence(view_name, zone_type, zone_name) do
              {:ok, config} ->
                {:ok, merge_store_zone_metadata(config, view_name, zone_type, zone_name)}

              :error ->
                :error
            end
        end
    end
  end

  defp get_zone_config_from_store(view_name, zone_type, zone_name) do
    case StoreZone.get_zone(view_name, zone_name) do
      {:ok, %{zone_type: ^zone_type} = zone} ->
        {:ok,
         %{
           name: zone.origin,
           type: zone.zone_type,
           upstreams: store_forwarders(zone),
           ns_records: store_ns_records(zone),
           cloud_mirror: Map.get(zone, :cloud_mirror)
         }}

      _ ->
        :error
    end
  catch
    _, _ -> :error
  end

  defp store_forwarders(%{forwarders: forwarders}) when is_list(forwarders) do
    Enum.map(forwarders, fn
      %{ip: ip, port: 53} -> ip
      %{ip: ip, port: port} -> "#{ip}:#{port}"
      %{ip: ip} -> ip
      other -> to_string(other)
    end)
  end

  defp store_forwarders(_zone), do: []

  defp store_ns_records(%{ns_records: ns_records}) when is_list(ns_records), do: ns_records
  defp store_ns_records(_zone), do: []

  defp merge_store_zone_metadata(config, view_name, :auth, zone_name) do
    case StoreZone.get_zone(view_name, zone_name) do
      {:ok, zone} -> Map.put(config, :cloud_mirror, Map.get(zone, :cloud_mirror))
      _ -> config
    end
  catch
    _, _ -> config
  end

  defp merge_store_zone_metadata(config, _view_name, _zone_type, _zone_name), do: config

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

  defp cloud_mirror_enabled?(%{cloud_mirror: %{enabled: true}}), do: true
  defp cloud_mirror_enabled?(_zone), do: false

  defp cloud_mirror_provider(%{cloud_mirror: mirror}) when is_map(mirror) do
    Map.get(mirror, :provider) || Map.get(mirror, "provider")
  end

  defp cloud_mirror_provider(_zone), do: nil

  defp provider_label(:cloudflare), do: "Cloudflare DNS"
  defp provider_label(:route53), do: "AWS Route 53"
  defp provider_label("cloudflare"), do: "Cloudflare DNS"
  defp provider_label("route53"), do: "AWS Route 53"
  defp provider_label(nil), do: "-"
  defp provider_label(type), do: to_string(type)

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
