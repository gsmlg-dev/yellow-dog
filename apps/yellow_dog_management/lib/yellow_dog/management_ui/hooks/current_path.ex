defmodule YellowDog.ManagementUI.Hooks.CurrentPath do
  @moduledoc """
  LiveView on_mount hook that tracks the current path for sidebar highlighting.

  Attaches shared hooks for layout-level behavior:

  - capture the URI on every navigation, making @current_path available in all
    LiveView assigns
  - acknowledge theme switcher events handled on the client
  """

  import Phoenix.LiveView, only: [attach_hook: 4]
  import Phoenix.Component, only: [assign: 3]

  alias YellowDog.ManagementUI.ServicePaths

  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> attach_hook(:current_path, :handle_params, &set_current_path/3)
      |> attach_hook(:theme_changed, :handle_event, &handle_theme_changed/3)

    {:cont, socket}
  end

  defp set_current_path(_params, uri, socket) do
    path = URI.parse(uri).path || "/"
    {:cont, assign(socket, :current_path, path)}
  end

  @doc "Returns decoded matched-route params without query-string identities."
  def route_path_params(socket, uri) do
    parsed_uri = URI.parse(uri)

    segments =
      for segment <- String.split(parsed_uri.path || "/", "/", trim: true),
          do: URI.decode(segment)

    %{path_params: path_params} =
      Phoenix.Router.route_info(socket.router, "GET", segments, parsed_uri.host)

    path_params
  end

  @doc """
  Returns the concrete service selection encoded in a scoped console path.

  Selector paths have no selection. Scoped paths identify the requested
  Server or Netman, without reserving identifiers for old route aliases.
  """
  @spec selection_for_path(String.t() | nil) :: {:server | :netman, String.t()} | nil
  def selection_for_path(path) when is_binary(path) do
    case path |> URI.parse() |> Map.get(:path, "/") |> String.split("/", trim: true) do
      ["server", segment | _rest] -> decode_selection(:server, segment)
      ["netman", segment | _rest] -> decode_selection(:netman, segment)
      _segments -> nil
    end
  end

  def selection_for_path(_path), do: nil

  defp decode_selection(target_type, segment) do
    id = URI.decode(segment)

    case target_type do
      :server -> if ServicePaths.valid_server_id?(id), do: {:server, id}
      :netman -> if ServicePaths.valid_netman_id?(id), do: {:netman, id}
    end
  rescue
    ArgumentError -> nil
  end

  defp handle_theme_changed("theme_changed", _params, socket), do: {:halt, socket}
  defp handle_theme_changed(_event, _params, socket), do: {:cont, socket}
end
