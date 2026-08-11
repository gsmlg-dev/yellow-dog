defmodule YellowDog.Console.DnsLive.ProviderLive.Show do
  @moduledoc "Management-backed DNS provider details for one selected Server."

  use YellowDog.Console, :live_view

  import YellowDog.Console.DnsLive.ManagementComponents, only: [input: 1]

  alias YellowDog.Console.DnsLive.ManagementComponents
  alias YellowDog.Console.DnsLive.ManagementSupport
  alias YellowDog.Console.ManagementResult
  alias YellowDog.Console.ServerManagement

  @credential_mutation_unavailable "Provider credential references cannot yet be materialized by the selected Server"

  @form %{
    "provider_id" => "",
    "provider_type" => "cloudflare",
    "endpoint" => "",
    "credential_ref" => ""
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "DNS Provider",
       subscribed_server_id: nil,
       provider_id: nil,
       view_name: "default",
       provider: nil,
       zones: [],
       provider_form: to_form(@form, as: "provider"),
       selection_form: to_form(%{"view_name" => "default"}, as: "selection"),
       management_error: nil,
       operation_result: nil,
       cached_observed_at: nil,
       commands_enabled?: false
     )}
  end

  @impl true
  def handle_params(%{"server_id" => server_id, "name" => provider_id} = params, _uri, socket) do
    view_name = params["view_name"] || "default"

    socket =
      socket
      |> ManagementSupport.subscribe(server_id)
      |> assign(
        provider_id: provider_id,
        view_name: view_name,
        selection_form: to_form(%{"view_name" => view_name}, as: "selection")
      )

    {:noreply, if(connected?(socket), do: load_provider(socket, server_id), else: socket)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_provider(socket, ManagementSupport.selected_id(socket))}
  end

  def handle_event("select_view", %{"selection" => %{"view_name" => view_name}}, socket) do
    path =
      ServicePaths.server_path(
        ManagementSupport.selected_id(socket),
        {:dns_provider, socket.assigns.provider_id}
      ) <> "?" <> URI.encode_query(%{"view_name" => view_name})

    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("update_provider", _params, socket),
    do: {:noreply, put_flash(socket, :error, @credential_mutation_unavailable)}

  def handle_event("sync_zone", params, socket) do
    reference = %{"view_name" => params["view_name"], "zone_name" => params["zone_name"]}

    with :ok <- ManagementSupport.mutable(socket),
         {:ok, revision} <- zone_revision(socket.assigns.zones, reference) do
      result =
        ServerManagement.dns_zones_sync(
          ManagementSupport.selected_id(socket),
          Map.put(reference, "provider_id", socket.assigns.provider_id),
          ManagementSupport.command_options(revision)
        )

      message =
        case result do
          %ManagementResult{status: :ok, value: %{"changed_records" => count}} ->
            "Synchronized #{count} #{if count == 1, do: "record", else: "records"}"

          _result ->
            nil
        end

      {:noreply, ManagementSupport.finish(socket, result, message)}
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl true
  def handle_info({:server_connection, _state, %{server_id: server_id}}, socket)
      when server_id == socket.assigns.selected_server.id do
    {:noreply,
     socket
     |> ManagementSupport.refresh_selected_server(server_id)
     |> load_provider(server_id)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp load_provider(socket, server_id) do
    providers_result = ServerManagement.dns_providers_list(server_id)

    zones_result =
      ServerManagement.dns_zones_list(server_id, %{"view_name" => socket.assigns.view_name})

    results = [providers_result, zones_result]

    provider =
      providers_result
      |> ManagementSupport.items()
      |> Enum.find(&(&1["provider_id"] == socket.assigns.provider_id))

    zones =
      zones_result
      |> ManagementSupport.items()
      |> Enum.filter(&(&1["provider_id"] == socket.assigns.provider_id))

    assign(socket,
      page_title:
        "#{socket.assigns.selected_server.name || server_id} — #{socket.assigns.provider_id}",
      provider: provider,
      zones: zones,
      provider_form: to_form(provider_form(provider), as: "provider"),
      management_error: ManagementSupport.first_error(results),
      cached_observed_at:
        ManagementSupport.cached_observed_at(results, socket.assigns.selected_server.last_seen_at),
      commands_enabled?: socket.assigns.service_online? and not is_nil(provider)
    )
  end

  defp provider_form(nil), do: @form

  defp provider_form(provider) do
    Map.merge(@form, %{
      "provider_id" => provider["provider_id"],
      "provider_type" => provider["provider_type"],
      "endpoint" => provider["endpoint"] || "",
      "credential_ref" => provider["credential_ref"]
    })
  end

  defp zone_revision(zones, reference) do
    revision =
      ManagementSupport.find_digest(zones, fn zone ->
        zone["view_name"] == reference["view_name"] and
          zone["zone_name"] == reference["zone_name"]
      end)

    if is_binary(revision),
      do: {:ok, revision},
      else: {:error, "Zone is not present in the selected Server snapshot"}
  end
end
