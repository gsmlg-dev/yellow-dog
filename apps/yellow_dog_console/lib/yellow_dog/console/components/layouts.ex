defmodule YellowDog.Console.Layouts do
  @moduledoc """
  This module holds different layouts used by your application.

  Layouts are defined as function components following Phoenix 1.8+ pattern.
  The "root" layout is a skeleton rendered as part of the application router.
  The "app" layout is set as the default layout on both
  `use YellowDog.Console, :controller` and `use YellowDog.Console, :live_view`.
  """
  use YellowDog.Console, :html

  alias Phoenix.LiveView.JS
  alias YellowDog.Console.Components.Sidebar

  embed_templates "layouts/*"

  @doc """
  App layout for pages that need additional wrapping.
  Can be used as a layout (receives @inner_content) or as a component (receives inner_block slot).
  """
  attr :flash, :map, default: %{}, doc: "the map of flash messages"
  attr :current_user, :any, default: nil, doc: "the current user"
  attr :current_path, :string, default: nil, doc: "current page path for sidebar highlighting"
  slot :inner_block, doc: "the inner content when used as a component"

  def app(assigns) do
    assigns =
      assign_new(assigns, :content, fn ->
        if Map.has_key?(assigns, :inner_content) do
          assigns.inner_content
        else
          nil
        end
      end)

    assigns = assign_new(assigns, :current_path, fn -> nil end)

    ~H"""
    <div id="yd-layout" class="yd-layout h-full">
      <.navbar current_user={@current_user} current_path={@current_path} />

      <div class="yd-body">
        <%= if @current_path do %>
          <.live_component module={Sidebar} id="app-sidebar" current_path={@current_path} />
        <% end %>

        <div class="yd-main flex flex-col min-w-0">
          <div class="flex-1 overflow-auto">
            <div class="w-full px-4 sm:px-6 lg:px-8 py-6">
              <.flash_group flash={@flash} />
              <%= if @content do %>
                {@content}
              <% else %>
                {render_slot(@inner_block)}
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @nav_sections [
    %{label: "Management", icon: "account-cog", path: "/management"},
    %{label: "Servers", icon: "server-network", path: "/server/dashboard"},
    %{label: "Netman", icon: "lan", path: "/netman"},
    %{label: "Tools", icon: "wrench", path: "/tool/geoip"},
    %{label: "System", icon: "cog", path: "/system/process-map"}
  ]

  defp navbar(assigns) do
    nav_sections =
      if YellowDog.Console.Plugs.ManagementReleaseOnly.management_release_only?() do
        Enum.take(@nav_sections, 1)
      else
        @nav_sections
      end

    assigns = assign(assigns, :nav_sections, nav_sections)

    ~H"""
    <.dm_navbar class="appbar-primary appbar-bordered">
      <:start_part>
        <button
          class="btn btn-ghost lg:hidden"
          aria-label="Open menu"
          phx-click={JS.toggle_class("yd-sidebar-open", to: "#yd-layout")}
        >
          <.dm_mdi name="menu" class="w-6 h-6" />
        </button>
        <.link navigate="/" class="btn btn-ghost text-xl font-bold text-primary-content">
          <span>Yellow</span>
          <span class="text-warning">Dog</span>
        </.link>
      </:start_part>
      <:center_part>
        <ul class="hidden lg:flex gap-1">
          <li :for={section <- @nav_sections}>
            <.link
              navigate={section.path}
              class={["btn btn-ghost btn-sm", nav_active?(@current_path, section.label)]}
            >
              <.dm_mdi name={section.icon} class="w-5 h-5" />
              <span>{section.label}</span>
            </.link>
          </li>
        </ul>
      </:center_part>
      <:end_part>
        <.dm_theme_switcher id="theme-toggle" />
        <.dm_dropdown id="notifications-dropdown">
          <:trigger>
            <button class="btn btn-ghost btn-circle" aria-label="Notifications">
              <.dm_mdi name="bell-outline" class="w-6 h-6" />
            </button>
          </:trigger>
          <:content>
            <div class="card bg-surface-container shadow-sm p-4 min-w-64">
              <h3 class="font-semibold mb-2">Notifications</h3>
              <p class="text-sm text-on-surface-variant">No new notifications</p>
            </div>
          </:content>
        </.dm_dropdown>
      </:end_part>
    </.dm_navbar>
    """
  end

  defp nav_active?(nil, _section), do: nil

  defp nav_active?(current_path, section) do
    if Sidebar.section_for_path(current_path) == section do
      "btn-active"
    end
  end

  @doc """
  Renders flash notices.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages to display"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"
  attr :kind, :atom, values: [:info, :error], doc: "used to determine flash kind"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} class="space-y-2">
      <.flash kind={:info} title="Success!" flash={@flash} />
      <.flash kind={:error} title="Error!" flash={@flash} />
      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={show(".phx-client-error #client-error")}
        phx-connected={hide("#client-error")}
        hidden
      >
        Attempting to reconnect <.dm_mdi name="loading" class="ml-1 w-3 h-3 animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={show(".phx-server-error #server-error")}
        phx-connected={hide("#server-error")}
        hidden
      >
        Hang in there while we get back on track
        <.dm_mdi name="loading" class="ml-1 w-3 h-3 animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Renders a single flash notice.
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used to determine alert styling"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class={[
        "alert cursor-pointer",
        @kind == :info && "alert-success",
        @kind == :error && "alert-error"
      ]}
      {@rest}
    >
      <.dm_mdi :if={@kind == :info} name="check-circle-outline" class="w-6 h-6" />
      <.dm_mdi :if={@kind == :error} name="close-circle-outline" class="w-6 h-6" />
      <div>
        <h3 :if={@title} class="font-bold">{@title}</h3>
        <div class="text-sm">{msg}</div>
      </div>
    </div>
    """
  end
end
