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

  @doc """
  Root layout with navbar + sidebar structure using DaisyUI.
  """
  attr :current_user, :any, default: nil

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" class="h-full">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={get_csrf_token()} />
        <.live_title suffix=" · Yellow Dog Console">
          <%= assigns[:page_title] || "Yellow Dog Console" %>
        </.live_title>
        <link phx-track-static rel="stylesheet" href={~p"/assets/app.css"} />
        <script defer phx-track-static type="text/javascript" src={~p"/assets/app.js"}>
        </script>
      </head>
      <body class="h-full" data-theme="light">
        <div class="drawer lg:drawer-open">
          <input id="main-drawer" type="checkbox" class="drawer-toggle" />

          <div class="drawer-content flex flex-col">
            <!-- Navbar -->
            <.navbar />

            <!-- Main content -->
            <main class="flex-1 overflow-y-auto bg-base-200">
              <%= @inner_content %>
            </main>
          </div>

          <!-- Sidebar -->
          <.sidebar />
        </div>

        <!-- Toast container for notifications -->
        <div id="toast-container" class="toast toast-top toast-end z-50" phx-update="stream">
        </div>
      </body>
    </html>
    """
  end

  @doc """
  App layout for pages that need additional wrapping.
  """
  def app(assigns) do
    ~H"""
    <div class="container mx-auto px-4 sm:px-6 lg:px-8 py-6">
      <.flash_group flash={@flash} />
      <%= @inner_content %>
    </div>
    """
  end

  # Top navbar component with branding, search, and utilities.
  defp navbar(assigns) do
    ~H"""
    <div class="navbar bg-base-100 shadow-lg">
      <div class="flex-none lg:hidden">
        <label for="main-drawer" class="btn btn-square btn-ghost">
          <svg
            xmlns="http://www.w3.org/2000/svg"
            fill="none"
            viewBox="0 0 24 24"
            class="inline-block h-6 w-6 stroke-current"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M4 6h16M4 12h16M4 18h16"
            >
            </path>
          </svg>
        </label>
      </div>

      <div class="flex-1">
        <a href="/" class="btn btn-ghost text-xl font-bold">
          <span class="text-primary">Yellow</span>
          <span class="text-warning">Dog</span>
        </a>
      </div>

      <div class="flex-none gap-2">
        <!-- Search -->
        <div class="form-control hidden md:block">
          <input
            type="text"
            placeholder="Search..."
            class="input input-bordered input-sm w-full max-w-xs"
          />
        </div>

        <!-- Theme Toggle -->
        <label class="swap swap-rotate btn btn-ghost btn-circle">
          <input
            type="checkbox"
            id="theme-toggle"
            class="theme-controller"
            phx-hook="ThemeToggle"
          />
          <!-- Sun icon -->
          <svg
            class="swap-on h-6 w-6 fill-current"
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 24 24"
          >
            <path d="M5.64,17l-.71.71a1,1,0,0,0,0,1.41,1,1,0,0,0,1.41,0l.71-.71A1,1,0,0,0,5.64,17ZM5,12a1,1,0,0,0-1-1H3a1,1,0,0,0,0,2H4A1,1,0,0,0,5,12Zm7-7a1,1,0,0,0,1-1V3a1,1,0,0,0-2,0V4A1,1,0,0,0,12,5ZM5.64,7.05a1,1,0,0,0,.7.29,1,1,0,0,0,.71-.29,1,1,0,0,0,0-1.41l-.71-.71A1,1,0,0,0,4.93,6.34Zm12,.29a1,1,0,0,0,.7-.29l.71-.71a1,1,0,1,0-1.41-1.41L17,5.64a1,1,0,0,0,0,1.41A1,1,0,0,0,17.66,7.34ZM21,11H20a1,1,0,0,0,0,2h1a1,1,0,0,0,0-2Zm-9,8a1,1,0,0,0-1,1v1a1,1,0,0,0,2,0V20A1,1,0,0,0,12,19ZM18.36,17A1,1,0,0,0,17,18.36l.71.71a1,1,0,0,0,1.41,0,1,1,0,0,0,0-1.41ZM12,6.5A5.5,5.5,0,1,0,17.5,12,5.51,5.51,0,0,0,12,6.5Zm0,9A3.5,3.5,0,1,1,15.5,12,3.5,3.5,0,0,1,12,15.5Z" />
          </svg>
          <!-- Moon icon -->
          <svg
            class="swap-off h-6 w-6 fill-current"
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 24 24"
          >
            <path d="M21.64,13a1,1,0,0,0-1.05-.14,8.05,8.05,0,0,1-3.37.73A8.15,8.15,0,0,1,9.08,5.49a8.59,8.59,0,0,1,.25-2A1,1,0,0,0,8,2.36,10.14,10.14,0,1,0,22,14.05,1,1,0,0,0,21.64,13Zm-9.5,6.69A8.14,8.14,0,0,1,7.08,5.22v.27A10.15,10.15,0,0,0,17.22,15.63a9.79,9.79,0,0,0,2.1-.22A8.11,8.11,0,0,1,12.14,19.73Z" />
          </svg>
        </label>

        <!-- Notifications -->
        <div class="dropdown dropdown-end">
          <div tabindex="0" role="button" class="btn btn-ghost btn-circle">
            <div class="indicator">
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="h-6 w-6"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M15 17h5l-1.405-1.405A2.032 2.032 0 0118 14.158V11a6.002 6.002 0 00-4-5.659V5a2 2 0 10-4 0v.341C7.67 6.165 6 8.388 6 11v3.159c0 .538-.214 1.055-.595 1.436L4 17h5m6 0v1a3 3 0 11-6 0v-1m6 0H9"
                />
              </svg>
              <span class="badge badge-xs badge-primary indicator-item"></span>
            </div>
          </div>
          <div
            tabindex="0"
            class="card card-compact dropdown-content bg-base-100 z-[1] mt-3 w-80 shadow-xl"
          >
            <div class="card-body">
              <h3 class="card-title">Notifications</h3>
              <p class="text-sm text-base-content/70">No new notifications</p>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Sidebar navigation with service sections.
  defp sidebar(assigns) do
    ~H"""
    <div class="drawer-side">
      <label for="main-drawer" aria-label="close sidebar" class="drawer-overlay"></label>

      <ul class="menu bg-base-100 text-base-content min-h-full w-80 p-4">
        <!-- Dashboard -->
        <li class="menu-title">
          <span>Dashboard</span>
        </li>
        <li>
          <a href="/" class="gap-3">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="h-5 w-5"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M3 12l2-2m0 0l7-7 7 7M5 10v10a1 1 0 001 1h3m10-11l2 2m-2-2v10a1 1 0 01-1 1h-3m-6 0a1 1 0 001-1v-4a1 1 0 011-1h2a1 1 0 011 1v4a1 1 0 001 1m-6 0h6"
              />
            </svg>
            <span>Overview</span>
          </a>
        </li>
        <li>
          <a href="/dashboard" class="gap-3">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="h-5 w-5"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z"
              />
            </svg>
            <span>Services</span>
          </a>
        </li>

        <!-- Services Section -->
        <li class="menu-title mt-4">
          <span>Services</span>
        </li>

        <!-- DNS -->
        <li>
          <details>
            <summary class="gap-3">
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="h-5 w-5"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M21 12a9 9 0 01-9 9m9-9a9 9 0 00-9-9m9 9H3m9 9a9 9 0 01-9-9m9 9c1.657 0 3-4.03 3-9s-1.343-9-3-9m0 18c-1.657 0-3-4.03-3-9s1.343-9 3-9m-9 9a9 9 0 019-9"
                />
              </svg>
              <span>DNS</span>
              <div class="badge badge-success badge-sm">Running</div>
            </summary>
            <ul>
              <li><a href="/dns">Overview</a></li>
              <li><a href="/dns/zones">Zones</a></li>
              <li><a href="/dns/cache">Cache</a></li>
              <li><a href="/dns/views">Views</a></li>
            </ul>
          </details>
        </li>

        <!-- DHCPv4 -->
        <li>
          <details>
            <summary class="gap-3">
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="h-5 w-5"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M5 12h14M5 12a2 2 0 01-2-2V6a2 2 0 012-2h14a2 2 0 012 2v4a2 2 0 01-2 2M5 12a2 2 0 00-2 2v4a2 2 0 002 2h14a2 2 0 002-2v-4a2 2 0 00-2-2m-2-4h.01M17 16h.01"
                />
              </svg>
              <span>DHCPv4</span>
              <div class="badge badge-success badge-sm">Running</div>
            </summary>
            <ul>
              <li><a href="/dhcpv4">Overview</a></li>
              <li><a href="/dhcpv4/leases">Leases</a></li>
              <li><a href="/dhcpv4">Pools</a></li>
            </ul>
          </details>
        </li>

        <!-- DHCPv6 -->
        <li>
          <details>
            <summary class="gap-3">
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="h-5 w-5"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M5 12h14M5 12a2 2 0 01-2-2V6a2 2 0 012-2h14a2 2 0 012 2v4a2 2 0 01-2 2M5 12a2 2 0 00-2 2v4a2 2 0 002 2h14a2 2 0 002-2v-4a2 2 0 00-2-2m-2-4h.01M17 16h.01"
                />
              </svg>
              <span>DHCPv6</span>
              <div class="badge badge-error badge-sm">Stopped</div>
            </summary>
            <ul>
              <li><a href="/dhcpv6">Overview</a></li>
              <li><a href="/dhcpv6/leases">Leases</a></li>
              <li><a href="/dhcpv6">Pools</a></li>
            </ul>
          </details>
        </li>

        <!-- mDNS -->
        <li>
          <details open>
            <summary class="gap-3">
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="h-5 w-5"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M8.111 16.404a5.5 5.5 0 017.778 0M12 20h.01m-7.08-7.071c3.904-3.905 10.236-3.905 14.141 0M1.394 9.393c5.857-5.857 15.355-5.857 21.213 0"
                />
              </svg>
              <span>mDNS</span>
              <div class="badge badge-success badge-sm">Running</div>
            </summary>
            <ul>
              <li><a href="/mdns">Overview</a></li>
              <li><a href="/mdns/services">Services</a></li>
              <li><a href="/mdns/discovery">Discovery</a></li>
              <li><a href="/mdns/monitor">Monitor</a></li>
            </ul>
          </details>
        </li>

        <!-- Settings -->
        <li class="menu-title mt-4">
          <span>System</span>
        </li>
        <li>
          <a href="/settings" class="gap-3">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="h-5 w-5"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z"
              />
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"
              />
            </svg>
            <span>Settings</span>
          </a>
        </li>
        <li>
          <a href="/logs" class="gap-3">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="h-5 w-5"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"
              />
            </svg>
            <span>Logs</span>
          </a>
        </li>
      </ul>
    </div>
    """
  end

  @doc """
  Renders flash notices using DaisyUI alerts.
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
        Attempting to reconnect <Heroicons.arrow_path class="ml-1 h-3 w-3 animate-spin" />
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
        <Heroicons.arrow_path class="ml-1 h-3 w-3 animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Renders a single flash notice using DaisyUI alert.
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
      <svg
        xmlns="http://www.w3.org/2000/svg"
        class="h-6 w-6 shrink-0 stroke-current"
        fill="none"
        viewBox="0 0 24 24"
      >
        <path
          :if={@kind == :info}
          stroke-linecap="round"
          stroke-linejoin="round"
          stroke-width="2"
          d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"
        />
        <path
          :if={@kind == :error}
          stroke-linecap="round"
          stroke-linejoin="round"
          stroke-width="2"
          d="M10 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2m7-2a9 9 0 11-18 0 9 9 0 0118 0z"
        />
      </svg>
      <div>
        <h3 :if={@title} class="font-bold"><%= @title %></h3>
        <div class="text-sm"><%= msg %></div>
      </div>
    </div>
    """
  end
end
