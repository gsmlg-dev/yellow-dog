defmodule YellowDog.Console.SettingsLive do
  @moduledoc """
  LiveView for YellowDog service settings management.

  Provides a tabbed interface for configuring DNS, mDNS, DHCPv4, and DHCPv6 services
  with real-time validation, optimistic locking, and atomic persistence.

  ## Features
    - Service-specific configuration tabs
    - Real-time form validation with Ecto changesets
    - Optimistic locking to prevent concurrent update conflicts
    - Atomic TOML file updates with backup/restore
    - Service restart coordination
    - Comprehensive error handling and user feedback
  """

  use YellowDog.Console, :live_view

  import YellowDog.Console.FormatHelper, only: [format_bytes: 1]

  alias YellowDog.Console.ConfigManager
  alias YellowDog.Console.ServiceManager
  alias YellowDog.Console.Settings.{ConfigurationVersion, ServiceConfiguration}

  @impl true
  def mount(_params, _session, socket) do
    config_path = get_config_path()

    with {:ok, config} <- ConfigManager.load_config(config_path),
         version_info <- ConfigurationVersion.get_version(config_path) do
      socket =
        socket
        |> assign(
          page_title: "Settings",
          config_path: config_path,
          config: config,
          version_info: version_info,
          show_conflict_modal: false,
          show_recovery_modal: false,
          changeset: nil,
          pending_changes: %{},
          show_pool_form: false,
          pool_form_mode: nil,
          pool_form_service: nil,
          editing_pool: nil
        )
        |> load_service_forms()

      {:ok, socket}
    else
      {:error, reason} ->
        :telemetry.execute(
          [:yellow_dog, :console, :settings, :config_load_error],
          %{count: 1},
          %{source: __MODULE__, reason: inspect(reason), severity: :error}
        )

        socket =
          socket
          |> assign(
            page_title: "Settings",
            config_path: config_path,
            config: %{},
            version_info: %{version: 0, timestamp: 0, file_path: config_path},
            show_conflict_modal: false,
            show_recovery_modal: false,
            changeset: nil,
            pending_changes: %{},
            show_pool_form: false,
            pool_form_mode: nil,
            pool_form_service: nil,
            editing_pool: nil
          )
          |> put_flash(:error, "Failed to load configuration: #{inspect(reason)}")
          |> load_service_forms()

        {:ok, socket}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    # live_action comes from the router (e.g., :dns, :mdns, :dhcpv4, :dhcpv6)
    {:noreply, assign(socket, :active_tab, socket.assigns.live_action)}
  end

  @valid_settings_services ~w(dns mdns dhcpv4 dhcpv6 netboot)

  @impl true
  def handle_event("validate_" <> service, %{"service_configuration" => params}, socket)
      when service in @valid_settings_services do
    service_atom = String.to_existing_atom(service)
    changeset = validate_service_config(service_atom, params)

    socket =
      socket
      |> assign(:"#{service}_changeset", changeset)
      |> maybe_update_pending_changes(service_atom, changeset)

    {:noreply, socket}
  end

  @impl true
  def handle_event("save_" <> service, %{"service_configuration" => params}, socket)
      when service in @valid_settings_services do
    service_atom = String.to_existing_atom(service)

    # Get existing changeset to preserve pools
    existing_changeset = Map.get(socket.assigns, :"#{service}_changeset")
    existing_pools = Ecto.Changeset.get_field(existing_changeset, :pools) || []

    # Convert pool structs to maps for changeset
    pool_maps =
      Enum.map(existing_pools, fn pool ->
        Map.from_struct(pool)
        |> Map.drop([:__meta__])
      end)

    # Add pools to params
    params_with_pools = Map.put(params, "pools", pool_maps)

    # Create new changeset from params with pools
    changeset = validate_service_config(service_atom, params_with_pools)

    if changeset.valid? do
      handle_save(socket, service_atom, changeset)
    else
      socket =
        socket
        |> assign(:"#{service}_changeset", changeset)
        |> put_flash(:error, "Please fix validation errors before saving")

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("apply_changes_" <> service, _params, socket)
      when service in @valid_settings_services do
    service_atom = String.to_existing_atom(service)
    handle_apply_changes(socket, service_atom)
  end

  @impl true
  def handle_event("dns_reload_all", _params, socket) do
    case dns_reload(:all) do
      :ok ->
        {:noreply, put_flash(socket, :info, "DNS configuration reloaded successfully")}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Failed to reload DNS configuration: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("dns_reload_views", _params, socket) do
    case dns_reload(:views) do
      :ok ->
        {:noreply, put_flash(socket, :info, "DNS views reloaded successfully")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to reload DNS views: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("dns_reload_acls", _params, socket) do
    case dns_reload(:acls) do
      :ok ->
        {:noreply, put_flash(socket, :info, "DNS ACLs reloaded successfully")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to reload DNS ACLs: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("reload_config", _params, socket) do
    config_path = socket.assigns.config_path

    case ConfigManager.load_config(config_path) do
      {:ok, config} ->
        version_info = ConfigurationVersion.get_version(config_path)

        socket =
          socket
          |> assign(:config, config)
          |> assign(:version_info, version_info)
          |> assign(:pending_changes, %{})
          |> load_service_forms()
          |> put_flash(:info, "Configuration reloaded from disk")

        {:noreply, socket}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Failed to reload configuration: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("close_conflict_modal", _params, socket) do
    {:noreply, assign(socket, :show_conflict_modal, false)}
  end

  @impl true
  def handle_event("close_recovery_modal", _params, socket) do
    {:noreply, assign(socket, :show_recovery_modal, false)}
  end

  @impl true
  def handle_event("restore_backup", %{"backup_path" => backup_path}, socket) do
    case ConfigManager.restore_backup(backup_path, socket.assigns.config_path) do
      :ok ->
        # Reload configuration after restore
        handle_event("reload_config", %{}, socket)

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to restore backup: #{inspect(reason)}")}
    end
  end

  @valid_pool_events ~w(dhcpv4_pool dhcpv6_pool)

  # Pool management events
  @impl true
  def handle_event("add_" <> service_and_pool, _params, socket)
      when service_and_pool in @valid_pool_events do
    # Parse service type from event name (e.g., "dhcpv4_pool" -> :dhcpv4)
    service =
      service_and_pool
      |> String.replace_suffix("_pool", "")
      |> String.to_existing_atom()

    protocol = if service == :dhcpv4, do: :ipv4, else: :ipv6

    socket =
      socket
      |> assign(:show_pool_form, true)
      |> assign(:pool_form_mode, :create)
      |> assign(:pool_form_service, service)
      |> assign(:pool_form_protocol, protocol)
      |> assign(:editing_pool, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("edit_" <> service_and_pool, %{"pool-id" => pool_id}, socket)
      when service_and_pool in @valid_pool_events do
    # Parse service type from event name
    service =
      service_and_pool
      |> String.replace_suffix("_pool", "")
      |> String.to_existing_atom()

    protocol = if service == :dhcpv4, do: :ipv4, else: :ipv6
    changeset = Map.get(socket.assigns, :"#{service}_changeset")
    pools = Ecto.Changeset.get_field(changeset, :pools) || []
    pool = Enum.find(pools, &(&1.id == pool_id))

    if pool do
      socket =
        socket
        |> assign(:show_pool_form, true)
        |> assign(:pool_form_mode, :edit)
        |> assign(:pool_form_service, service)
        |> assign(:pool_form_protocol, protocol)
        |> assign(:editing_pool, pool)

      {:noreply, socket}
    else
      {:noreply, put_flash(socket, :error, "Pool not found")}
    end
  end

  @impl true
  def handle_event("delete_" <> service_and_pool, %{"pool-id" => pool_id}, socket)
      when service_and_pool in @valid_pool_events do
    # Parse service type from event name
    service =
      service_and_pool
      |> String.replace_suffix("_pool", "")
      |> String.to_existing_atom()

    changeset = Map.get(socket.assigns, :"#{service}_changeset")
    pools = Ecto.Changeset.get_field(changeset, :pools) || []
    updated_pools = Enum.reject(pools, &(&1.id == pool_id))

    # Update changeset by putting the new pools list directly
    updated_changeset = Ecto.Changeset.put_embed(changeset, :pools, updated_pools)

    socket =
      socket
      |> assign(:"#{service}_changeset", updated_changeset)
      |> maybe_update_pending_changes(service, updated_changeset)
      |> put_flash(:info, "Pool deleted successfully")

    {:noreply, socket}
  end

  @impl true
  def handle_event("close_pool_form", _params, socket) do
    socket =
      socket
      |> assign(:show_pool_form, false)
      |> assign(:pool_form_mode, nil)
      |> assign(:pool_form_service, nil)
      |> assign(:pool_form_protocol, nil)
      |> assign(:editing_pool, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_info(:close_pool_form, socket) do
    handle_event("close_pool_form", %{}, socket)
  end

  @impl true
  def handle_info({:pool_saved, service, pool, mode}, socket) do
    changeset = Map.get(socket.assigns, :"#{service}_changeset")
    pools = Ecto.Changeset.get_field(changeset, :pools) || []

    updated_pools =
      case mode do
        :create ->
          # Add new pool to the list
          pools ++ [pool]

        :edit ->
          # Replace existing pool with updated one
          Enum.map(pools, fn p ->
            if p.id == pool.id, do: pool, else: p
          end)
      end

    # Update changeset by putting the new pools list directly
    updated_changeset = Ecto.Changeset.put_embed(changeset, :pools, updated_pools)

    flash_message =
      case mode do
        :create -> "Pool added successfully"
        :edit -> "Pool updated successfully"
      end

    socket =
      socket
      |> assign(:"#{service}_changeset", updated_changeset)
      |> maybe_update_pending_changes(service, updated_changeset)
      |> assign(:show_pool_form, false)
      |> assign(:pool_form_mode, nil)
      |> assign(:pool_form_service, nil)
      |> assign(:pool_form_protocol, nil)
      |> assign(:editing_pool, nil)
      |> put_flash(:info, flash_message)

    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # Private Functions

  defp get_config_path do
    Application.get_env(:yellow_dog_console, :config_path, "/etc/yellowdog/config.toml")
  end

  defp load_service_forms(socket) do
    config = socket.assigns.config

    socket
    |> assign(:dns_changeset, build_changeset(:dns, config))
    |> assign(:mdns_changeset, build_changeset(:mdns, config))
    |> assign(:dhcpv4_changeset, build_changeset(:dhcpv4, config))
    |> assign(:dhcpv6_changeset, build_changeset(:dhcpv6, config))
    |> assign(:netboot_changeset, build_changeset(:netboot, config))
    |> assign(:netboot_profiles, list_boot_profiles())
  end

  defp build_changeset(service, config) do
    service_config = Map.get(config, to_string(service), %{})
    core_config = Map.get(config, "core", %{})
    enabled = Map.get(core_config, to_string(service), false)

    # Merge with defaults for this service
    defaults = get_service_defaults(service)

    attrs =
      defaults
      |> Map.merge(normalize_config_keys(service, service_config))
      |> Map.put("enabled", enabled)
      |> Map.put("service_type", service)
      |> maybe_add_pools(service, service_config)

    ServiceConfiguration.changeset(%ServiceConfiguration{}, attrs)
  end

  # Netboot uses tftp_port in TOML but we map it to generic port field
  defp normalize_config_keys(:netboot, config) do
    config
    |> Map.put("port", Map.get(config, "tftp_port", Map.get(config, "port", 69)))
  end

  defp normalize_config_keys(_service, config), do: config

  defp get_service_defaults(:dns) do
    %{
      "listen" => "0.0.0.0",
      "port" => 53
    }
  end

  defp get_service_defaults(:mdns) do
    %{
      "listen" => "0.0.0.0",
      "port" => 5353,
      "mode" => "responder"
    }
  end

  defp get_service_defaults(:dhcpv4) do
    %{
      "listen" => "0.0.0.0",
      "port" => 67,
      "gateway" => "192.168.1.1",
      "domain" => "local",
      "dns_servers" => ["8.8.8.8", "8.8.4.4"]
    }
  end

  defp get_service_defaults(:dhcpv6) do
    %{
      "listen" => "::",
      "port" => 547,
      "domain" => "local",
      "dns_servers" => ["2001:4860:4860::8888", "2001:4860:4860::8844"]
    }
  end

  defp get_service_defaults(:netboot) do
    %{
      "listen" => "0.0.0.0",
      "port" => 69,
      "tftp_root" => "/srv/netboot/tftp",
      "default_profile" => ""
    }
  end

  defp maybe_add_pools(attrs, service, service_config)
       when service in [:dhcpv4, :dhcpv6] do
    pools = Map.get(service_config, "pools", [])

    # Convert pools to proper format with protocol field
    protocol = if service == :dhcpv4, do: :ipv4, else: :ipv6

    formatted_pools =
      Enum.map(pools, fn pool ->
        pool
        |> Map.put("protocol", protocol)
        |> ensure_pool_id()
      end)

    Map.put(attrs, "pools", formatted_pools)
  end

  defp maybe_add_pools(attrs, _service, _service_config), do: attrs

  defp ensure_pool_id(pool) do
    if Map.has_key?(pool, "id") do
      pool
    else
      Map.put(pool, "id", Ecto.UUID.generate())
    end
  end

  defp validate_service_config(service, params) do
    attrs = Map.put(params, "service_type", service)
    ServiceConfiguration.changeset(%ServiceConfiguration{}, attrs)
  end

  defp maybe_update_pending_changes(socket, service, changeset) do
    if changeset.valid? do
      changes = Ecto.Changeset.apply_changes(changeset)
      pending = Map.put(socket.assigns.pending_changes, service, changes)
      assign(socket, :pending_changes, pending)
    else
      socket
    end
  end

  defp handle_save(socket, service, changeset) do
    config_path = socket.assigns.config_path
    version_info = socket.assigns.version_info
    changes = Ecto.Changeset.apply_changes(changeset)

    # Build TOML updates from changeset
    updates = build_toml_updates(service, changes)

    # Attempt save with optimistic locking
    with :ok <-
           ConfigurationVersion.compare_and_swap(
             config_path,
             version_info.version,
             version_info.timestamp
           ),
         {:ok, _backup_path} <- ConfigManager.create_backup(config_path),
         :ok <- ConfigManager.update_config(config_path, updates) do
      # Success - reload configuration and update version
      new_version_info = ConfigurationVersion.get_version(config_path)

      case ConfigManager.load_config(config_path) do
        {:ok, new_config} ->
          socket =
            socket
            |> assign(:config, new_config)
            |> assign(:version_info, new_version_info)
            |> assign(:"#{service}_changeset", build_changeset(service, new_config))
            |> update_pending_changes_after_save(service)
            |> put_flash(:info, "Configuration saved successfully")

          emit_telemetry(:config_saved, %{service: service})
          {:noreply, socket}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Saved but failed to reload: #{inspect(reason)}")}
      end
    else
      {:error, :version_mismatch} ->
        socket =
          socket
          |> assign(:show_conflict_modal, true)
          |> assign(:conflict_service, service)
          |> put_flash(:error, "Configuration was modified by another user. Please reload.")

        {:noreply, socket}

      {:error, :file_modified} ->
        socket =
          socket
          |> assign(:show_conflict_modal, true)
          |> assign(:conflict_service, service)
          |> put_flash(
            :error,
            "Configuration file was modified externally. Please reload."
          )

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save configuration: #{inspect(reason)}")}
    end
  end

  defp handle_apply_changes(socket, service) do
    pending = Map.get(socket.assigns.pending_changes, service)

    if pending do
      # Extract new configuration for service
      new_config = extract_service_config(pending)

      case ServiceManager.apply_and_restart(service, new_config) do
        :ok ->
          socket =
            socket
            |> remove_pending_change(service)
            |> put_flash(:info, "Service #{service} restarted successfully")

          emit_telemetry(:service_applied, %{service: service})
          {:noreply, socket}

        {:error, reason} ->
          socket =
            put_flash(
              socket,
              :error,
              "Failed to restart service #{service}: #{inspect(reason)}"
            )

          emit_telemetry(:service_apply_failed, %{service: service, reason: reason})
          {:noreply, socket}
      end
    else
      {:noreply, put_flash(socket, :info, "No pending changes to apply")}
    end
  end

  defp build_toml_updates(:netboot, changes) do
    base = %{
      "core.netboot" => changes.enabled,
      "netboot.tftp_port" => changes.port,
      "netboot.tftp_root" => changes.tftp_root
    }

    if changes.default_profile && changes.default_profile != "" do
      Map.put(base, "netboot.default_profile", changes.default_profile)
    else
      base
    end
  end

  defp build_toml_updates(service, changes) do
    service_key = to_string(service)

    base_updates = %{
      "core.#{service_key}" => changes.enabled,
      "#{service_key}.listen" => changes.listen,
      "#{service_key}.port" => changes.port
    }

    # Add service-specific fields
    service_specific =
      case service do
        :mdns ->
          if changes.mode, do: %{"#{service_key}.mode" => to_string(changes.mode)}, else: %{}

        :dhcpv4 ->
          dhcp_updates(service_key, changes)

        :dhcpv6 ->
          dhcp_updates(service_key, changes)

        _ ->
          %{}
      end

    Map.merge(base_updates, service_specific)
  end

  defp dhcp_updates(service_key, changes) do
    updates =
      [
        {changes.gateway, "#{service_key}.gateway"},
        {changes.domain, "#{service_key}.domain"}
      ]
      |> Enum.reject(fn {val, _key} -> is_nil(val) end)
      |> Map.new(fn {val, key} -> {key, val} end)

    updates =
      if changes.dns_servers && changes.dns_servers != [],
        do: Map.put(updates, "#{service_key}.dns_servers", changes.dns_servers),
        else: updates

    # Handle pools for DHCP services
    pools = changes.pools || []
    formatted_pools = Enum.map(pools, &format_pool_for_toml/1)
    Map.put(updates, "#{service_key}.pools", formatted_pools)
  end

  defp list_boot_profiles do
    try do
      YellowDog.Netboot.Manifest.Store.list_profiles()
    catch
      _, _ -> []
    end
  end

  defp format_pool_for_toml(pool) do
    base = %{
      "name" => pool.name,
      "range_start" => pool.range_start,
      "range_end" => pool.range_end
    }

    optional =
      [
        {"lease_time", pool.lease_time},
        {"gateway", pool.gateway},
        {"preferred_lifetime", pool.preferred_lifetime},
        {"valid_lifetime", pool.valid_lifetime}
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
      |> Map.new()

    optional =
      if pool.dns_servers && pool.dns_servers != [],
        do: Map.put(optional, "dns_servers", pool.dns_servers),
        else: optional

    Map.merge(base, optional)
  end

  defp extract_service_config(pending_changes) do
    %{
      "enabled" => pending_changes.enabled,
      "listen" => pending_changes.listen,
      "port" => pending_changes.port
    }
  end

  defp update_pending_changes_after_save(socket, service) do
    # After saving to file, store the configuration (needs service restart to apply)
    changeset = Map.get(socket.assigns, :"#{service}_changeset")
    config = Ecto.Changeset.apply_changes(changeset)
    pending = Map.put(socket.assigns.pending_changes, service, config)
    assign(socket, :pending_changes, pending)
  end

  defp remove_pending_change(socket, service) do
    pending = Map.delete(socket.assigns.pending_changes, service)
    assign(socket, :pending_changes, pending)
  end

  defp emit_telemetry(event, metadata) do
    :telemetry.execute(
      [:yellow_dog, :console, :settings, event],
      %{timestamp: System.monotonic_time()},
      metadata
    )
  end

  defp list_backups(config_path) do
    backup_dir = Path.dirname(config_path)
    base_name = Path.basename(config_path)

    case File.ls(backup_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.starts_with?(&1, "#{base_name}.backup."))
        |> Enum.map(fn filename ->
          path = Path.join(backup_dir, filename)

          # Extract timestamp from filename (format: config.toml.backup.20250118T123045Z)
          timestamp_str =
            filename
            |> String.replace_prefix("#{base_name}.backup.", "")

          # Format timestamp for display
          timestamp_display =
            case parse_backup_timestamp(timestamp_str) do
              {:ok, dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
              _ -> timestamp_str
            end

          # Get file size
          size =
            case File.stat(path) do
              {:ok, %{size: bytes}} -> format_bytes(bytes)
              _ -> "unknown"
            end

          %{
            path: path,
            timestamp: timestamp_display,
            size: size
          }
        end)
        |> Enum.sort_by(& &1.timestamp, :desc)

      {:error, _} ->
        []
    end
  end

  defp parse_backup_timestamp(timestamp_str) do
    # Parse ISO 8601 basic format: 20250118T123045Z
    case Regex.run(~r/^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$/, timestamp_str) do
      [_, year, month, day, hour, minute, second] ->
        DateTime.new(
          Date.new!(String.to_integer(year), String.to_integer(month), String.to_integer(day)),
          Time.new!(String.to_integer(hour), String.to_integer(minute), String.to_integer(second))
        )

      _ ->
        {:error, :invalid_format}
    end
  end

  defp dns_reload(scope) do
    try do
      case scope do
        :all -> YellowDog.Dns.ConfigWatcher.reload()
        :views -> YellowDog.Dns.ConfigWatcher.reload_views()
        :acls -> YellowDog.Dns.ConfigWatcher.reload_acls()
      end
    rescue
      e -> {:error, Exception.message(e)}
    catch
      :exit, reason -> {:error, reason}
    end
  end
end
