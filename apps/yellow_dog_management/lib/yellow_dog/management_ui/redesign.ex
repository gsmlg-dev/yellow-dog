defmodule YellowDog.ManagementUI.Redesign do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and so on.

  This can be used in your application as:

      use YellowDog.ManagementUI.Redesign, :controller
      use YellowDog.ManagementUI.Redesign, :html

  The definitions below will be executed for every controller,
  component, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.
  """

  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller,
        formats: [:html, :json]

      import Plug.Conn
      import YellowDog.ManagementUI.Redesign.Gettext

      unquote(verified_routes())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      unquote(html_helpers())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      on_mount YellowDog.ManagementUI.Redesign.Hooks.CurrentPath
      on_mount YellowDog.ManagementUI.Redesign.Hooks.ServiceScope

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
      # HTML escaping functionality
      import Phoenix.HTML
      # Duskmoon UI components
      use PhoenixDuskmoon.Component
      import PhoenixDuskmoon.Component.Action.Button, except: [dm_btn: 1]
      import YellowDog.ManagementUI.Redesign.Components.Button
      # Core UI components and translation
      import YellowDog.ManagementUI.Redesign.CoreComponents
      import YellowDog.ManagementUI.Redesign.Gettext

      # Shortcut for generating JS commands
      alias Phoenix.LiveView.JS

      # Layouts for easy access in templates
      alias YellowDog.ManagementUI.Redesign.Layouts
      alias YellowDog.ManagementUI.Redesign.ServicePaths

      # Verified routes for ~p sigil
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: YellowDog.ManagementUI.Endpoint,
        router: YellowDog.ManagementUI.Router,
        statics: YellowDog.ManagementUI.Redesign.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
