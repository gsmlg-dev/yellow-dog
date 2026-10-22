defmodule YellowDog.ManagementUI.Hooks.Authorization do
  @moduledoc "Authenticate both LiveView mounts; recheck lifetime and policy on every callback."
  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 3]
  alias YellowDog.Management.{Access, Auth, Caller}

  def on_mount(:default, params, session, socket) do
    result =
      if connected?(socket) do
        Auth.socket(
          get_connect_info(socket, :x_headers),
          get_connect_info(socket, :peer_data),
          get_connect_info(socket, :uri),
          session
        )
      else
        Caller.from_session(session["management_caller"])
      end

    with {:ok, caller} <- result,
         :ok <- Access.authorize(caller, "config:read"),
         :ok <- Access.authorize(caller, mount_scope(socket, params)) do
      if connected?(socket),
        do:
          Process.send_after(
            self(),
            :management_auth_expired,
            max(1, caller.expires_at - System.system_time(:second)) * 1000
          )

      socket =
        socket
        |> assign(:caller, caller)
        |> assign(:authorization_scope, mount_scope(socket, params))
        |> attach_hook(:authorization_params, :handle_params, &params_hook/3)
        |> attach_hook(:authorization_events, :handle_event, &event_hook/3)
        |> attach_hook(:authorization_info, :handle_info, &info_hook/2)
        |> attach_hook(:authorization_async, :handle_async, &async_hook/3)

      {:cont, socket}
    else
      _ -> {:halt, redirect(socket, to: "/management")}
    end
  end

  def path_scope(path) do
    case String.split(path, "/", trim: true) do
      ["management", "events" | _] -> "audit:read"
      ["system", "logs" | _] -> "ui:admin"
      ["system", "backups" | _] -> "ui:admin"
      ["system", "process-map" | _] -> "ui:admin"
      ["system", "mac-database" | _] -> "ui:admin"
      ["system", "tasks" | _] -> "ui:admin"
      ["netman" | _] -> "ui:admin"
      ["management", "netman" | _] -> "ui:admin"
      ["management", "servers", "enrollment" | _] -> "ui:admin"
      ["server", _, "connection" | _] -> "ui:admin"
      ["tool" | _] -> "ui:admin"
      _ -> "config:read"
    end
  end

  defp mount_scope(socket, params) do
    module = socket.view |> Module.split() |> List.last()

    cond do
      module == "EventsLive" ->
        "audit:read"

      module in ~w(LogsLive BackupsLive ProcessMapLive MacDatabaseLive TasksLive NetmansLive NetmanLive NetmanConfigLive MacLive WhoisLive GeoipLive) ->
        "ui:admin"

      module == "WorkersLive" and socket.assigns.live_action == :enrollment ->
        "ui:admin"

      module == "WorkerLive" and socket.assigns.live_action == :connection ->
        "ui:admin"

      is_map(params) ->
        "config:read"

      true ->
        "config:read"
    end
  end

  defp params_hook(_params, uri, socket) do
    scope = path_scope(URI.parse(uri).path || "/")
    check(assign(socket, :authorization_scope, scope))
  end

  defp event_hook(_event, _params, socket), do: check(socket)

  defp info_hook(:management_auth_expired, socket),
    do: {:halt, redirect(socket, to: "/management")}

  defp info_hook(_message, socket), do: check(socket)
  defp async_hook(_name, _result, socket), do: check(socket)

  defp check(socket) do
    with :ok <- Access.authorize(socket.assigns.caller, "config:read"),
         :ok <- Access.authorize(socket.assigns.caller, socket.assigns.authorization_scope) do
      {:cont, socket}
    else
      _ -> {:halt, redirect(socket, to: "/management")}
    end
  end
end
