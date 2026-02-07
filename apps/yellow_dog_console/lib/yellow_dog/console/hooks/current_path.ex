defmodule YellowDog.Console.Hooks.CurrentPath do
  @moduledoc """
  LiveView on_mount hook that tracks the current path for sidebar highlighting.

  Attaches a handle_params hook to capture the URI on every navigation,
  making @current_path available in all LiveView assigns.
  """

  import Phoenix.LiveView, only: [attach_hook: 4]
  import Phoenix.Component, only: [assign: 3]

  def on_mount(:default, _params, _session, socket) do
    {:cont, attach_hook(socket, :current_path, :handle_params, &set_current_path/3)}
  end

  defp set_current_path(_params, uri, socket) do
    path = URI.parse(uri).path || "/"
    {:cont, assign(socket, :current_path, path)}
  end
end
