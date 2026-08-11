defmodule YellowDog.Console.SettingsLive do
  @moduledoc """
  Management-owned aggregate configuration editor for one selected Server.

  The page edits the durable Management draft while the Server is online or
  offline. Applying and rolling back publish immutable aggregate configuration
  versions for delivery through the Server agent.
  """

  use YellowDog.Console, :live_view

  alias YellowDog.Console.ManagementResult
  alias YellowDog.Console.ServerManagement
  alias YellowDog.Console.ServicePaths
  alias YellowDog.Sync.Operation
  alias YellowDog.Sync.ServerOperation

  @services [:dns, :mdns, :dhcpv4, :dhcpv6, :netboot]
  @profiles ~w(cloud_dns local_network dns_only dhcp_only netboot_only custom)
  @in_flight_states [:desired, :delivered, :applying]
  @deployment_in_flight "configuration deployment is already in flight"
  @service_fields %{
    dns: [
      %{key: "hostname", label: "Hostname", type: :string, placeholder: "dns.example.test"},
      %{key: "listen", label: "Listen address", type: :string, placeholder: "0.0.0.0"},
      %{key: "port", label: "Port", type: :integer, placeholder: "53"}
    ],
    mdns: [
      %{key: "hostname", label: "Hostname", type: :string, placeholder: "host.local"},
      %{key: "listen", label: "Listen address", type: :string, placeholder: "0.0.0.0"},
      %{key: "port", label: "Port", type: :integer, placeholder: "5353"},
      %{key: "mode", label: "Mode", type: :string, placeholder: "responder"}
    ],
    dhcpv4: [
      %{key: "listen", label: "Listen address", type: :string, placeholder: "0.0.0.0"},
      %{key: "port", label: "Port", type: :integer, placeholder: "67"}
    ],
    dhcpv6: [
      %{key: "listen", label: "Listen address", type: :string, placeholder: "::"},
      %{key: "port", label: "Port", type: :integer, placeholder: "547"}
    ],
    netboot: [
      %{key: "tftp_port", label: "TFTP port", type: :integer, placeholder: "69"},
      %{
        key: "default_profile",
        label: "Default boot profile",
        type: :string,
        placeholder: "default"
      }
    ]
  }

  @impl true
  def mount(_params, _session, socket) do
    document = default_document(nil)

    {:ok,
     assign(socket,
       page_title: "Server Settings",
       selected_service: :dns,
       draft_revision: 0,
       config_document: document,
       settings_form: settings_form(document, :dns),
       config_versions: [],
       latest_deployment: nil,
       applied_revision: nil,
       in_flight?: false,
       management_error: nil
     )}
  end

  @impl true
  def handle_params(%{"server_id" => _server_id}, _uri, socket) do
    socket = assign(socket, :selected_service, selected_service(socket.assigns.live_action))
    {:noreply, if(connected?(socket), do: load_settings(socket), else: socket)}
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, load_settings(socket)}

  def handle_event("save", %{"settings" => params}, socket) do
    with {:ok, entries} <- typed_service_entries(params, socket.assigns.selected_service),
         document <- merge_service_entries(socket, params["profile"], entries),
         :ok <- validate_document(document),
         %ManagementResult{status: :ok} <-
           ServerManagement.put_config_draft(
             socket.assigns.selected_server.id,
             socket.assigns.draft_revision,
             document
           ) do
      {:noreply,
       socket
       |> load_settings()
       |> put_flash(:info, "Draft saved")}
    else
      %ManagementResult{status: :error, message: message} ->
        {:noreply, put_flash(socket, :error, message)}

      {:error, message} ->
        {:noreply,
         socket
         |> assign(:settings_form, to_form(params, as: "settings"))
         |> put_flash(:error, message)}
    end
  end

  def handle_event("save", _params, socket) do
    {:noreply, put_flash(socket, :error, "Invalid configuration draft")}
  end

  def handle_event("apply", _params, %{assigns: %{in_flight?: true}} = socket) do
    {:noreply, put_flash(socket, :error, @deployment_in_flight)}
  end

  def handle_event("apply", _params, socket) do
    result =
      ServerManagement.publish_config_draft(
        socket.assigns.selected_server.id,
        socket.assigns.draft_revision
      )

    case result do
      %ManagementResult{status: :ok} ->
        {:noreply,
         socket
         |> load_settings()
         |> put_flash(:info, "Waiting for Server acknowledgement")}

      %ManagementResult{status: :error, message: message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("rollback", %{"version" => version}, %{assigns: %{in_flight?: false}} = socket) do
    with {:ok, version} <- parse_version(version),
         %ManagementResult{status: :ok} <-
           ServerManagement.rollback_config(
             socket.assigns.selected_server.id,
             version,
             socket.assigns.draft_revision
           ) do
      {:noreply,
       socket
       |> load_settings()
       |> put_flash(:info, "Rollback published; waiting for Server acknowledgement")}
    else
      %ManagementResult{status: :error, message: message} ->
        {:noreply, put_flash(socket, :error, message)}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("rollback", _params, socket) do
    {:noreply, put_flash(socket, :error, @deployment_in_flight)}
  end

  defp load_settings(socket) do
    server_id = socket.assigns.selected_server.id
    draft_result = ServerManagement.get_config_draft(server_id)
    versions_result = ServerManagement.config_versions(server_id)
    draft = result_value(draft_result, %{draft_revision: 0, document: nil})
    document = draft.document || default_document(socket.assigns.selected_server)
    versions = result_value(versions_result, [])
    latest = List.first(versions)
    latest_applied = Enum.find(versions, &(&1.state == :applied))

    assign(socket,
      page_title:
        "#{socket.assigns.selected_server.name || server_id} — #{service_label(socket.assigns.selected_service)} Settings",
      draft_revision: draft.draft_revision,
      config_document: document,
      settings_form: settings_form(document, socket.assigns.selected_service),
      config_versions: versions,
      latest_deployment: latest,
      applied_revision: latest_applied && latest_applied.applied_revision,
      in_flight?: latest != nil and latest.state in @in_flight_states,
      management_error: first_error([draft_result, versions_result])
    )
  end

  defp default_document(nil) do
    %{"schema_version" => 1, "profile" => "custom", "entries" => []}
  end

  defp default_document(server) do
    profile = server.profile |> profile_name() |> ensure_profile()
    %{"schema_version" => 1, "profile" => profile, "entries" => []}
  end

  defp profile_name(profile) when is_atom(profile), do: Atom.to_string(profile)
  defp profile_name(profile) when is_binary(profile), do: profile
  defp profile_name(_profile), do: "custom"

  defp ensure_profile(profile) when profile in @profiles, do: profile
  defp ensure_profile(_profile), do: "custom"

  defp settings_form(document, service) do
    values = service_entry_values(document, service)

    to_form(
      Map.merge(
        %{
          "profile" => document["profile"],
          "enabled" => enabled_override(values, service)
        },
        Map.new(service_fields(service), fn field ->
          {field.key, field_value(values, Atom.to_string(service), field)}
        end)
      ),
      as: "settings"
    )
  end

  defp typed_service_entries(params, service) when is_map(params) do
    with {:ok, enabled} <- enabled_entry(params["enabled"], service) do
      service_fields(service)
      |> Enum.reduce_while({:ok, enabled}, fn field, {:ok, entries} ->
        case typed_field_entry(params[field.key], service, field) do
          {:ok, nil} -> {:cont, {:ok, entries}}
          {:ok, entry} -> {:cont, {:ok, [entry | entries]}}
          {:error, _message} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, entries} -> {:ok, Enum.reverse(entries)}
        {:error, _message} = error -> error
      end
    end
  end

  defp typed_service_entries(_params, _service), do: {:error, "Invalid settings form"}

  defp enabled_entry("inherit", _service), do: {:ok, []}

  defp enabled_entry(value, service) when value in ["true", "false"] do
    {:ok,
     [
       managed_entry(
         "services.#{service}.enabled",
         "boolean",
         value == "true"
       )
     ]}
  end

  defp enabled_entry(_value, _service), do: {:error, "Invalid service state"}

  defp typed_field_entry(value, _service, _field) when value in [nil, ""], do: {:ok, nil}

  defp typed_field_entry(value, service, %{key: key, type: :string}) when is_binary(value) do
    {:ok, managed_entry("#{service}.#{key}", "string", value)}
  end

  defp typed_field_entry(value, service, %{key: key, type: :integer}) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 1 and integer <= 65_535 ->
        {:ok, managed_entry("#{service}.#{key}", "integer", integer)}

      _invalid ->
        {:error, "#{String.replace(key, "_", " ")} must be between 1 and 65535"}
    end
  end

  defp typed_field_entry(_value, _service, field),
    do: {:error, "Invalid #{String.replace(field.key, "_", " ")}"}

  defp managed_entry(setting, type, value) do
    %{"setting" => setting, "value" => %{"type" => type, "value" => value}}
  end

  defp validate_document(document) do
    with {:ok, operation} <- ServerOperation.fetch("server.config.replace"),
         {:ok, _document} <- Operation.validate_payload(operation, document) do
      :ok
    else
      _invalid -> {:error, "Configuration contains an invalid managed setting"}
    end
  end

  defp merge_service_entries(socket, profile, entries) do
    retained =
      socket.assigns.config_document["entries"]
      |> Enum.reject(&form_owned_entry?(&1, socket.assigns.selected_service))

    socket.assigns.config_document
    |> Map.put("profile", profile)
    |> Map.put("entries", Enum.sort_by(retained ++ entries, & &1["setting"]))
  end

  defp service_entries(document, service) do
    document
    |> Map.get("entries", [])
    |> Enum.filter(&service_entry?(&1, service))
  end

  defp service_entry?(%{"setting" => setting}, service) when is_binary(setting) do
    service = Atom.to_string(service)

    String.starts_with?(setting, "#{service}.") or
      String.starts_with?(setting, "services.#{service}.")
  end

  defp service_entry?(_entry, _service), do: false

  defp form_owned_entry?(%{"setting" => setting}, service) do
    setting == "services.#{service}.enabled" or
      Enum.any?(
        service_fields(service),
        &(&1.key == String.replace_prefix(setting, "#{service}.", ""))
      )
  end

  defp form_owned_entry?(_entry, _service), do: false

  defp service_entry_values(document, service) do
    document
    |> service_entries(service)
    |> Map.new(fn entry -> {entry["setting"], entry["value"]} end)
  end

  defp enabled_override(values, service) do
    case values["services.#{service}.enabled"] do
      %{"type" => "boolean", "value" => true} -> "true"
      %{"type" => "boolean", "value" => false} -> "false"
      _inherited -> "inherit"
    end
  end

  defp field_value(values, service, field) do
    case values["#{service}.#{field.key}"] do
      %{"type" => "string", "value" => value} when field.type == :string -> value
      %{"type" => "integer", "value" => value} when field.type == :integer -> to_string(value)
      _unset -> ""
    end
  end

  defp parse_version(version) when is_binary(version) do
    case Integer.parse(version) do
      {version, ""} when version > 0 -> {:ok, version}
      _invalid -> {:error, "Invalid configuration version"}
    end
  end

  defp parse_version(_version), do: {:error, "Invalid configuration version"}

  defp selected_service(service) when service in @services, do: service
  defp selected_service(_service), do: :dns

  defp result_value(%ManagementResult{status: :ok, value: value}, _fallback), do: value
  defp result_value(_result, fallback), do: fallback

  defp first_error(results) do
    Enum.find_value(results, fn
      %ManagementResult{status: :error, message: message} -> message
      _result -> nil
    end)
  end

  defp settings_tabs(server_id) do
    [
      {:dns, "DNS", ServicePaths.server_path(server_id, :settings_dns)},
      {:mdns, "mDNS", ServicePaths.server_path(server_id, :settings_mdns)},
      {:dhcpv4, "DHCPv4", ServicePaths.server_path(server_id, :settings_dhcpv4)},
      {:dhcpv6, "DHCPv6", ServicePaths.server_path(server_id, :settings_dhcpv6)},
      {:netboot, "Netboot", ServicePaths.server_path(server_id, :settings_netboot)}
    ]
  end

  defp profile_options do
    Enum.map(@profiles, &{String.replace(&1, "_", " ") |> String.capitalize(), &1})
  end

  defp service_fields(service), do: Map.fetch!(@service_fields, service)

  defp service_label(:dns), do: "DNS"
  defp service_label(:mdns), do: "mDNS"
  defp service_label(:dhcpv4), do: "DHCPv4"
  defp service_label(:dhcpv6), do: "DHCPv6"
  defp service_label(:netboot), do: "Netboot"

  defp deployment_label(nil), do: "Not published"
  defp deployment_label(version), do: "Version #{version.version} · #{state_label(version.state)}"

  defp state_label(state) when is_atom(state),
    do: state |> Atom.to_string() |> String.capitalize()

  defp state_label(state) when is_binary(state), do: String.capitalize(state)

  defp version_time(%DateTime{} = time), do: Calendar.strftime(time, "%Y-%m-%d %H:%M:%S UTC")
  defp version_time(_time), do: "Unavailable"
end
