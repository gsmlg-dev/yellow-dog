defmodule YellowDog.Console.Hooks.CurrentPath do
  @moduledoc """
  LiveView on_mount hook that tracks the current path for sidebar highlighting.

  Attaches shared hooks for layout-level behavior:

  - capture the URI on every navigation, making @current_path available in all
    LiveView assigns
  - acknowledge theme switcher events handled on the client
  """

  import Phoenix.LiveView, only: [attach_hook: 4]
  import Phoenix.Component, only: [assign: 3]

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

  defp handle_theme_changed("theme_changed", _params, socket), do: {:halt, socket}
  defp handle_theme_changed(_event, _params, socket), do: {:cont, socket}
end
