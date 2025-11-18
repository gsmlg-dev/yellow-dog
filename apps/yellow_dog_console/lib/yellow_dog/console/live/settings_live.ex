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

  alias YellowDog.Console.ConfigManager
  alias YellowDog.Console.Settings.{ConfigurationVersion, ServiceConfiguration}
  alias YellowDog.Console.ServiceManager

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    config_path = get_config_path()

    with {:ok, config} <- ConfigManager.load_config(config_path),
         version_info <- ConfigurationVersion.get_version(config_path) do
      socket =
        socket
        |> assign(:config_path, config_path)
        |> assign(:config, config)
        |> assign(:version_info, version_info)
        |> assign(:active_tab, :dns)
        |> assign(:show_conflict_modal, false)
        |> assign(:show_recovery_modal, false)
        |> assign(:changeset, nil)
        |> assign(:pending_changes, %{})
        |> load_service_forms()

      {:ok, socket}
    else
      {:error, reason} ->
        Logger.error("Failed to load configuration: #{inspect(reason)}")

        socket =
          socket
          |> put_flash(:error, "Failed to load configuration: #{inspect(reason)}")
          |> assign(:config_path, config_path)
          |> assign(:config, %{})
          |> assign(:version_info, %{version: 0, timestamp: 0, file_path: config_path})
          |> assign(:active_tab, :dns)
          |> assign(:show_conflict_modal, false)
          |> assign(:show_recovery_modal, false)
          |> assign(:changeset, nil)
          |> assign(:pending_changes, %{})
          |> load_service_forms()

        {:ok, socket}
    end
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    tab_atom = String.to_existing_atom(tab)
    {:noreply, assign(socket, :active_tab, tab_atom)}
  end

  def handle_event("validate_" <> service, %{"service_configuration" => params}, socket) do
    service_atom = String.to_existing_atom(service)
    changeset = validate_service_config(service_atom, params)

    socket =
      socket
      |> assign(:"#{service}_changeset", changeset)
      |> maybe_update_pending_changes(service_atom, changeset)

    {:noreply, socket}
  end

  def handle_event("save_" <> service, %{"service_configuration" => params}, socket) do
    service_atom = String.to_existing_atom(service)
    changeset = validate_service_config(service_atom, params)

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

  def handle_event("apply_changes_" <> service, _params, socket) do
    service_atom = String.to_existing_atom(service)
    handle_apply_changes(socket, service_atom)
  end

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

  def handle_event("close_conflict_modal", _params, socket) do
    {:noreply, assign(socket, :show_conflict_modal, false)}
  end

  def handle_event("close_recovery_modal", _params, socket) do
    {:noreply, assign(socket, :show_recovery_modal, false)}
  end

  def handle_event("restore_backup", %{"backup_path" => backup_path}, socket) do
    case ConfigManager.restore_backup(backup_path, socket.assigns.config_path) do
      :ok ->
        # Reload configuration after restore
        handle_event("reload_config", %{}, socket)

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to restore backup: #{inspect(reason)}")}
    end
  end

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
  end

  defp build_changeset(service, config) do
    service_config = Map.get(config, to_string(service), %{})
    core_config = Map.get(config, "core", %{})
    enabled = Map.get(core_config, to_string(service), false)

    attrs =
      service_config
      |> Map.put("enabled", enabled)
      |> Map.put("service_type", service)

    ServiceConfiguration.changeset(%ServiceConfiguration{}, attrs)
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
    updates = %{}

    updates =
      if changes.gateway,
        do: Map.put(updates, "#{service_key}.gateway", changes.gateway),
        else: updates

    updates =
      if changes.domain,
        do: Map.put(updates, "#{service_key}.domain", changes.domain),
        else: updates

    updates =
      if changes.dns_servers && length(changes.dns_servers) > 0,
        do: Map.put(updates, "#{service_key}.dns_servers", changes.dns_servers),
        else: updates

    updates
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

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"
end
