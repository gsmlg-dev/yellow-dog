defmodule YellowDog.Console.Hooks.ServiceScope do
  @moduledoc """
  Resolves an explicitly selected Server or Netman from management state.

  The module is both a scoped HTTP plug, which returns deterministic 404
  responses before a LiveView starts, and a global LiveView `on_mount` hook,
  which supplies selection and connectivity metadata to service pages.
  """

  @behaviour Plug

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, redirect: 2]
  import Plug.Conn, only: [halt: 1, send_resp: 3]

  alias YellowDog.Console.ServicePaths
  alias YellowDog.ManagementCore

  @impl Plug
  def init(target_type) when target_type in [:server, :netman], do: target_type

  @impl Plug
  def call(conn, target_type) do
    id = Map.get(conn.path_params, parameter_name(target_type))

    case fetch(target_type, id) do
      {:ok, _record} -> conn
      {:error, :not_found} -> send_not_found(conn, target_type)
    end
  end

  def on_mount(:default, params, _session, socket) do
    socket = attach_hook(socket, :service_scope, :handle_params, &resolve_params/3)
    resolve_scope(params, socket)
  end

  defp resolve_params(params, _uri, socket), do: resolve_scope(params, socket)

  defp resolve_scope(params, socket) do
    case requested_scope(params) do
      :unscoped ->
        {:cont,
         assign(socket,
           service_scope_state: :unscoped,
           service_online?: false,
           snapshot_observed_at: nil
         )}

      {:selected, target_type, id} ->
        assign_selected(socket, target_type, id)

      {:invalid, target_type} ->
        halt_not_found(socket, target_type)
    end
  end

  defp requested_scope(%{"server_id" => _server_id, "netman_id" => _netman_id}),
    do: {:invalid, :service}

  defp requested_scope(%{"server_id" => server_id}),
    do: selected_scope(:server, server_id)

  defp requested_scope(%{"netman_id" => netman_id}),
    do: selected_scope(:netman, netman_id)

  defp requested_scope(_params), do: :unscoped

  defp selected_scope(:server, server_id) do
    if ServicePaths.valid_server_id?(server_id),
      do: {:selected, :server, server_id},
      else: {:invalid, :server}
  end

  defp selected_scope(:netman, netman_id) do
    if ServicePaths.valid_netman_id?(netman_id),
      do: {:selected, :netman, netman_id},
      else: {:invalid, :netman}
  end

  defp assign_selected(socket, target_type, id) do
    case fetch(target_type, id) do
      {:ok, record} ->
        socket = assign(socket, selection_assign(target_type), record)

        {:cont,
         assign(socket,
           service_scope_state: :selected,
           service_online?: online?(record),
           snapshot_observed_at: Map.get(record, :last_seen_at)
         )}

      {:error, :not_found} ->
        halt_not_found(socket, target_type)
    end
  end

  defp halt_not_found(socket, target_type) do
    socket =
      assign(socket,
        service_scope_state: :not_found,
        service_online?: false,
        snapshot_observed_at: nil
      )

    {:halt, redirect(socket, to: "/service-not-found/#{target_type}")}
  end

  defp fetch(:server, id) do
    if ServicePaths.valid_server_id?(id),
      do: safe_get(:get_server, id),
      else: {:error, :not_found}
  end

  defp fetch(:netman, id) do
    if ServicePaths.valid_netman_id?(id),
      do: safe_get(:get_netman, id),
      else: {:error, :not_found}
  end

  defp safe_get(function, id) do
    case apply(ManagementCore, function, [id]) do
      {:ok, record} -> {:ok, record}
      _other -> {:error, :not_found}
    end
  catch
    :exit, _reason -> {:error, :not_found}
  end

  defp send_not_found(conn, target_type) do
    conn
    |> send_resp(404, not_found_body(target_type))
    |> halt()
  end

  defp parameter_name(:server), do: "server_id"
  defp parameter_name(:netman), do: "netman_id"

  defp selection_assign(:server), do: :selected_server
  defp selection_assign(:netman), do: :selected_netman

  defp online?(%{status: status}), do: status in [:online, "online"]

  defp not_found_body(:server), do: "Server not found"
  defp not_found_body(:netman), do: "Netman not found"
end
