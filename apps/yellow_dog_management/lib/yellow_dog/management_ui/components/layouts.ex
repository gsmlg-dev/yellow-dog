defmodule YellowDog.ManagementUI.Layouts do
  use YellowDog.ManagementUI, :html

  alias YellowDog.Management.BuildInfo
  alias YellowDog.ManagementUI.Components.Sidebar
  alias YellowDog.ManagementUI.Hooks.CurrentPath
  alias YellowDog.ManagementUI.Navigation

  embed_templates "layouts/*"

  attr :flash, :map, default: %{}
  attr :current_path, :string, default: nil
  attr :servers, :list, default: []
  attr :netmans, :list, default: []
  slot :inner_block

  def app(assigns) do
    assigns =
      assigns
      |> assign_new(:content, fn -> assigns[:inner_content] end)
      |> assign_new(:current_path, fn -> nil end)
      |> assign_new(:servers, fn -> [] end)
      |> assign_new(:netmans, fn -> [] end)
      |> assign(:navigation_scope, CurrentPath.selection_for_path(assigns[:current_path]))

    ~H"""
    <div
      id="yd-layout"
      class="yd-layout"
      phx-window-keydown={
        JS.focus(to: "#yd-layout.yd-sidebar-open #mobile-navigation-toggle")
        |> JS.remove_class("yd-sidebar-open", to: "#yd-layout")
        |> JS.set_attribute({"aria-expanded", "false"}, to: "#mobile-navigation-toggle")
      }
      phx-key="Escape"
    >
      <.navbar current_path={@current_path} />
      <div class="yd-body">
        <.live_component
          :if={@current_path}
          module={Sidebar}
          id="app-sidebar"
          current_path={@current_path}
          navigation_scope={@navigation_scope}
          servers={@servers}
          netmans={@netmans}
        />
        <main id="workspace" class="yd-main">
          <div class="yd-page">
            <.flash_group flash={@flash} />
            <%= if @content do %>
              {@content}
            <% else %>
              {render_slot(@inner_block)}
            <% end %>
          </div>
        </main>
      </div>
    </div>
    """
  end

  defp navbar(assigns) do
    assigns =
      assigns
      |> assign(:nav_sections, Navigation.sections())
      |> assign(:build_info, BuildInfo.info())

    ~H"""
    <.dm_navbar class="navbar-bordered bg-surface text-on-surface">
      <:start_part>
        <button
          id="mobile-navigation-toggle"
          type="button"
          class="btn btn-ghost btn-square yd-menu-toggle"
          aria-label="Open menu"
          aria-controls="app-sidebar"
          aria-expanded="false"
          phx-click={
            JS.toggle_class("yd-sidebar-open", to: "#yd-layout")
            |> JS.toggle_attribute({"aria-expanded", "true", "false"})
            |> JS.dispatch("duskmoon:left-menu:set-collapsed",
              to: "#app-sidebar-navigation",
              detail: %{collapsed: false}
            )
          }
        >
          <.dm_mdi name="menu" width="24" height="24" />
        </button>
        <.link
          navigate="/management/servers"
          class="btn btn-ghost text-xl font-bold"
        >
          <span>Yellow</span>
          <span class="text-warning">Dog</span>
        </.link>
        <.dm_tooltip
          :let={trigger_attrs}
          id="app-version-details"
          content={version_details(@build_info)}
          color="secondary"
          position="bottom"
          class="tooltip-rich"
        >
          <button
            id="app-version"
            type="button"
            class="badge badge-secondary badge-md rounded-full shrink-0"
            aria-label={"Version #{@build_info.display_version}; build details"}
            aria-description={version_details(@build_info)}
            {trigger_attrs}
          >
            {@build_info.display_version}
          </button>
        </.dm_tooltip>
      </:start_part>
      <:center_part>
        <nav aria-label="Main navigation" class="hidden lg:block">
          <ul class="yd-sections">
            <li :for={section <- @nav_sections}>
              <.link
                navigate={section.path}
                data-section={section.id}
                class={[
                  "btn btn-ghost btn-sm",
                  nav_active?(@current_path, section.id)
                ]}
                aria-current={nav_active?(@current_path, section.id) && "page"}
              >
                <.dm_mdi name={section.icon} width="20" height="20" />
                <span>{section.label}</span>
              </.link>
            </li>
          </ul>
        </nav>
      </:center_part>
      <:end_part>
        <.dm_theme_switcher id="theme-toggle" />
        <.dm_dropdown id="notifications-dropdown">
          <:trigger class="btn btn-ghost btn-circle">
            <span class="sr-only">Notifications</span>
            <.dm_mdi name="bell-outline" width="24" height="24" />
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

  defp version_details(info) do
    Enum.join(
      [
        "Version: #{info.version}",
        "Environment: #{info.environment}",
        "Git ref: #{info.git_ref}",
        "Git commit: #{info.git_commit}",
        "Release time: #{info.release_time}",
        "Built at: #{info.built_at}"
      ],
      "\n"
    )
  end

  defp nav_active?(nil, _section), do: nil

  defp nav_active?(current_path, section) do
    if Navigation.section_for_path(current_path) == section, do: "btn-active"
  end

  attr :flash, :map, required: true
  attr :id, :string, default: "flash-group"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} class="yd-flashes">
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
        Attempting to reconnect
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
      </.flash>
    </div>
    """
  end

  attr :id, :string
  attr :flash, :map, default: %{}
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error]
  attr :rest, :global
  slot :inner_block

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class={["alert", @kind == :info && "alert-success", @kind == :error && "alert-error"]}
      {@rest}
    >
      <.dm_mdi :if={@kind == :info} name="check-circle-outline" width="24" height="24" />
      <.dm_mdi :if={@kind == :error} name="close-circle-outline" width="24" height="24" />
      <div>
        <h3 :if={@title}>{@title}</h3>
        <div>{msg}</div>
      </div>
    </div>
    """
  end
end
