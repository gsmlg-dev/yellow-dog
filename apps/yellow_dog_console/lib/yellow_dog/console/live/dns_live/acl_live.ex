defmodule YellowDog.Console.DnsLive.AclLive do
  @moduledoc "Management-backed DNS ACLs for one selected Server."

  use YellowDog.Console, :live_view

  import YellowDog.Console.DnsLive.ManagementComponents, only: [input: 1]

  alias YellowDog.Console.DnsLive.ManagementComponents
  alias YellowDog.Console.DnsLive.ManagementSupport
  alias YellowDog.Console.ManagementResult
  alias YellowDog.Console.ServerManagement

  @form %{"acl_id" => "", "networks" => "", "action" => "allow"}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "DNS ACLs",
       subscribed_server_id: nil,
       acls: [],
       acl_form: to_form(@form, as: "acl"),
       management_error: nil,
       operation_result: nil,
       cached_observed_at: nil,
       commands_enabled?: false
     )}
  end

  @impl true
  def handle_params(%{"server_id" => server_id}, _uri, socket) do
    socket = ManagementSupport.subscribe(socket, server_id)
    {:noreply, if(connected?(socket), do: load_acls(socket, server_id), else: socket)}
  end

  @impl true
  def handle_event("create_acl", %{"acl" => params}, socket) do
    with :ok <- ManagementSupport.mutable(socket) do
      result =
        ServerManagement.dns_acls_create(
          ManagementSupport.selected_id(socket),
          acl_payload(params),
          ManagementSupport.command_options(nil)
        )

      {:noreply,
       socket |> put_resource(result) |> ManagementSupport.finish(result, "ACL created")}
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("update_acl", %{"acl" => %{"acl_id" => acl_id} = params}, socket) do
    with :ok <- ManagementSupport.mutable(socket),
         {:ok, revision} <- acl_revision(socket.assigns.acls, acl_id) do
      result =
        ServerManagement.dns_acls_update(
          ManagementSupport.selected_id(socket),
          acl_payload(params),
          ManagementSupport.command_options(revision)
        )

      {:noreply,
       socket |> put_resource(result) |> ManagementSupport.finish(result, "ACL updated")}
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("delete_acl", %{"acl_id" => acl_id}, socket) do
    with :ok <- ManagementSupport.mutable(socket),
         {:ok, revision} <- acl_revision(socket.assigns.acls, acl_id) do
      result =
        ServerManagement.dns_acls_delete(
          ManagementSupport.selected_id(socket),
          %{"acl_id" => acl_id},
          ManagementSupport.command_options(revision)
        )

      socket =
        if result.status == :ok,
          do: update(socket, :acls, &Enum.reject(&1, fn acl -> acl["acl_id"] == acl_id end)),
          else: socket

      {:noreply, ManagementSupport.finish(socket, result, "ACL deleted")}
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
     |> load_acls(server_id)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp load_acls(socket, server_id) do
    result = ServerManagement.dns_acls_list(server_id)

    assign(socket,
      page_title: "#{socket.assigns.selected_server.name || server_id} — DNS ACLs",
      acls: ManagementSupport.items(result),
      management_error: if(ManagementSupport.error_result?(result), do: result),
      cached_observed_at:
        ManagementSupport.cached_observed_at(
          [result],
          socket.assigns.selected_server.last_seen_at
        ),
      commands_enabled?: socket.assigns.service_online?
    )
  end

  defp acl_payload(params) do
    %{
      "acl_id" => String.trim(params["acl_id"] || ""),
      "networks" => ManagementSupport.csv(params["networks"]),
      "action" => params["action"] || "deny"
    }
  end

  defp acl_revision(acls, acl_id) do
    case ManagementSupport.find_digest(acls, &(&1["acl_id"] == acl_id)) do
      revision when is_binary(revision) -> {:ok, revision}
      _missing -> {:error, "ACL is not present in the selected Server snapshot"}
    end
  end

  defp put_resource(socket, %ManagementResult{status: :ok, value: %{"resource" => resource}}) do
    acls = [resource | Enum.reject(socket.assigns.acls, &(&1["acl_id"] == resource["acl_id"]))]
    assign(socket, :acls, Enum.sort_by(acls, & &1["acl_id"]))
  end

  defp put_resource(socket, _result), do: socket
end
