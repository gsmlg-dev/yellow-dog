defmodule YellowDog.Console.DnsLive.ViewLive.Index do
  @moduledoc "Management-backed DNS views for one selected Server."

  use YellowDog.Console, :live_view

  import YellowDog.Console.DnsLive.ManagementComponents, only: [input: 1]

  alias YellowDog.Console.DnsLive.ManagementComponents
  alias YellowDog.Console.DnsLive.ManagementSupport
  alias YellowDog.Console.ManagementResult
  alias YellowDog.Console.ServerManagement

  @form %{
    "view_name" => "",
    "match_clients" => "0.0.0.0/0, ::/0",
    "recursion" => "true"
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "DNS Views",
       subscribed_server_id: nil,
       route_params: %{},
       views: [],
       view_form: to_form(@form, as: "view"),
       management_error: nil,
       operation_result: nil,
       cached_observed_at: nil,
       commands_enabled?: false
     )}
  end

  @impl true
  def handle_params(%{"server_id" => server_id} = params, _uri, socket) do
    socket =
      socket
      |> ManagementSupport.subscribe(server_id)
      |> assign(:route_params, params)

    socket = if connected?(socket), do: load_views(socket, server_id), else: socket
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  @impl true
  def handle_event("create_view", %{"view" => params}, socket) do
    with :ok <- ManagementSupport.mutable(socket) do
      result =
        ServerManagement.dns_views_create(
          ManagementSupport.selected_id(socket),
          view_payload(params),
          ManagementSupport.command_options(nil)
        )

      {:noreply,
       socket |> put_resource(result) |> ManagementSupport.finish(result, "View created")}
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("update_view", %{"view" => params}, socket) do
    with :ok <- ManagementSupport.mutable(socket),
         {:ok, name} <- edit_route_identity(socket, "view_name", "View"),
         {:ok, revision} <- view_revision(socket.assigns.views, name) do
      payload = params |> Map.put("view_name", name) |> view_payload()

      result =
        ServerManagement.dns_views_update(
          ManagementSupport.selected_id(socket),
          payload,
          ManagementSupport.command_options(revision)
        )

      {:noreply,
       socket
       |> put_resource(result, name)
       |> ManagementSupport.finish(result, "View updated")}
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("delete_view", %{"view_name" => name}, socket) do
    with :ok <- ManagementSupport.mutable(socket),
         {:ok, revision} <- view_revision(socket.assigns.views, name) do
      result =
        ServerManagement.dns_views_delete(
          ManagementSupport.selected_id(socket),
          %{"view_name" => name},
          ManagementSupport.command_options(revision)
        )

      socket =
        if result.status == :ok,
          do: update(socket, :views, &Enum.reject(&1, fn view -> view["view_name"] == name end)),
          else: socket

      {:noreply, ManagementSupport.finish(socket, result, "View deleted")}
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl true
  def handle_info({:server_connection, _state, %{server_id: server_id}}, socket)
      when server_id == socket.assigns.selected_server.id do
    socket =
      socket
      |> ManagementSupport.refresh_selected_server(server_id)
      |> load_views(server_id)

    {:noreply, apply_action(socket, socket.assigns.live_action, socket.assigns.route_params)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp load_views(socket, server_id) do
    result = ServerManagement.dns_views_list(server_id)

    assign(socket,
      page_title: "#{socket.assigns.selected_server.name || server_id} — DNS Views",
      views: ManagementSupport.items(result),
      management_error: if(ManagementSupport.error_result?(result), do: result),
      cached_observed_at:
        ManagementSupport.cached_observed_at(
          [result],
          socket.assigns.selected_server.last_seen_at
        ),
      commands_enabled?: socket.assigns.service_online?
    )
  end

  defp apply_action(socket, :new, _params) do
    assign(socket,
      page_title: "New DNS View",
      view_form: to_form(@form, as: "view")
    )
  end

  defp apply_action(socket, :edit, %{"view_name" => view_name}) do
    case Enum.find(socket.assigns.views, &(&1["view_name"] == view_name)) do
      nil ->
        socket
        |> assign(:view_form, to_form(@form, as: "view"))
        |> put_flash(:error, "View is not present in the selected Server snapshot")

      view ->
        assign(socket,
          page_title: "Edit DNS View",
          view_form: to_form(view_form_values(view), as: "view")
        )
    end
  end

  defp apply_action(socket, :index, _params), do: socket

  defp view_form_values(view) do
    %{
      "view_name" => view["view_name"],
      "match_clients" => Enum.join(view["match_clients"] || [], ", "),
      "recursion" => to_string(view["recursion"] == true)
    }
  end

  defp view_payload(params) do
    %{
      "view_name" => String.trim(params["view_name"] || ""),
      "match_clients" => ManagementSupport.csv(params["match_clients"]),
      "recursion" => ManagementSupport.boolean(params["recursion"])
    }
  end

  defp view_revision(views, name) do
    case ManagementSupport.find_digest(views, &(&1["view_name"] == name)) do
      revision when is_binary(revision) -> {:ok, revision}
      _missing -> {:error, "View is not present in the selected Server snapshot"}
    end
  end

  defp put_resource(socket, result), do: put_resource(socket, result, nil)

  defp put_resource(
         socket,
         %ManagementResult{status: :ok, value: %{"resource" => resource}},
         previous_name
       ) do
    replaced_names = MapSet.new([resource["view_name"], previous_name])

    views = [
      resource
      | Enum.reject(socket.assigns.views, &MapSet.member?(replaced_names, &1["view_name"]))
    ]

    assign(socket, :views, Enum.sort_by(views, & &1["view_name"]))
  end

  defp put_resource(socket, _result, _previous_name), do: socket

  defp edit_route_identity(socket, key, resource) do
    case {socket.assigns.live_action, socket.assigns.route_params[key]} do
      {:edit, value} when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, "#{resource} update requires an edit route"}
    end
  end
end
