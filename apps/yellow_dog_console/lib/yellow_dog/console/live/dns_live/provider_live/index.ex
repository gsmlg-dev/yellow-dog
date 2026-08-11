defmodule YellowDog.Console.DnsLive.ProviderLive.Index do
  @moduledoc "Management-backed DNS providers for one selected Server."

  use YellowDog.Console, :live_view

  alias YellowDog.Console.DnsLive.ManagementComponents
  alias YellowDog.Console.DnsLive.ManagementSupport
  alias YellowDog.Console.ServerManagement

  @credential_mutation_unavailable "Provider credential references cannot yet be materialized by the selected Server"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "DNS Providers",
       subscribed_server_id: nil,
       providers: [],
       management_error: nil,
       operation_result: nil,
       cached_observed_at: nil,
       commands_enabled?: false
     )}
  end

  @impl true
  def handle_params(%{"server_id" => server_id}, _uri, socket) do
    socket = ManagementSupport.subscribe(socket, server_id)
    {:noreply, if(connected?(socket), do: load_providers(socket, server_id), else: socket)}
  end

  @impl true
  def handle_event("create_provider", _params, socket),
    do: {:noreply, put_flash(socket, :error, @credential_mutation_unavailable)}

  def handle_event("delete_provider", %{"provider_id" => provider_id}, socket) do
    with :ok <- ManagementSupport.mutable(socket),
         {:ok, revision} <- provider_revision(socket.assigns.providers, provider_id) do
      result =
        ServerManagement.dns_providers_delete(
          ManagementSupport.selected_id(socket),
          %{"provider_id" => provider_id},
          ManagementSupport.command_options(revision)
        )

      socket =
        if result.status == :ok,
          do:
            update(socket, :providers, fn providers ->
              Enum.reject(providers, &(&1["provider_id"] == provider_id))
            end),
          else: socket

      {:noreply, ManagementSupport.finish(socket, result, "Provider deleted")}
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
     |> load_providers(server_id)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp load_providers(socket, server_id) do
    result = ServerManagement.dns_providers_list(server_id)

    assign(socket,
      page_title: "#{socket.assigns.selected_server.name || server_id} — DNS Providers",
      providers: ManagementSupport.items(result),
      management_error: if(ManagementSupport.error_result?(result), do: result),
      cached_observed_at:
        ManagementSupport.cached_observed_at(
          [result],
          socket.assigns.selected_server.last_seen_at
        ),
      commands_enabled?: socket.assigns.service_online?
    )
  end

  defp provider_revision(providers, provider_id) do
    case ManagementSupport.find_digest(providers, &(&1["provider_id"] == provider_id)) do
      revision when is_binary(revision) -> {:ok, revision}
      _missing -> {:error, "Provider is not present in the selected Server snapshot"}
    end
  end
end
