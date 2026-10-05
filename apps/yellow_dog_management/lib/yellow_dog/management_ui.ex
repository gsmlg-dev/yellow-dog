defmodule YellowDog.ManagementUI do
  def static_paths, do: ~w(management.css management-live.js images favicon.ico robots.txt)

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]
      import Plug.Conn
      use Gettext, backend: YellowDog.ManagementUI.Gettext
      unquote(verified_routes())
    end
  end

  def html do
    quote do
      use Phoenix.Component
      import Phoenix.Controller, only: [get_csrf_token: 0, view_module: 1, view_template: 1]
      unquote(html_helpers())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView
      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      import Phoenix.HTML
      use PhoenixDuskmoon.Component
      import YellowDog.ManagementUI.CoreComponents
      use Gettext, backend: YellowDog.ManagementUI.Gettext
      alias Phoenix.LiveView.JS
      alias YellowDog.ManagementUI.Layouts
      alias YellowDog.ManagementUI.ServicePaths
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: YellowDog.ManagementUI.Endpoint,
        router: YellowDog.ManagementUI.Router,
        statics: YellowDog.ManagementUI.static_paths()
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
