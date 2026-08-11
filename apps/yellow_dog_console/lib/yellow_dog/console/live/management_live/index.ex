defmodule YellowDog.Console.ManagementLive.Index do
  @moduledoc """
  Skeleton pages for the YellowDog management console section.
  """

  use YellowDog.Console, :live_view

  alias YellowDog.Console.Layouts
  alias YellowDog.Console.ManagementLive.Data
  alias YellowDog.Console.ServicePaths

  @tabs [
    {:overview, "Overview", "/management"},
    {:servers, "Servers", "/management/servers"},
    {:netman, "Netman", "/management/netman"},
    {:profiles, "Profiles", "/management/profiles"},
    {:config, "Config", "/management/config"},
    {:events, "Events", "/management/events"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Management Overview",
       tabs: @tabs,
       servers: [],
       netmans: [],
       server_profiles: [],
       netman_profiles: [],
       events: [],
       config_versions: [],
       command_outcomes: []
     )}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply,
     assign(socket,
       page_title: page_title(socket.assigns.live_action),
       servers: Data.list_servers(),
       netmans: Data.list_netmans(),
       server_profiles: Data.list_server_profiles(),
       netman_profiles: Data.list_netman_profiles(),
       events: Data.list_events(),
       config_versions: Data.list_config_versions(),
       command_outcomes: Data.list_command_outcomes()
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="max-w-7xl">
        <div class="flex justify-between items-center mb-6">
          <div>
            <h1 class="text-3xl font-bold">{@page_title}</h1>
            <p class="text-sm text-on-surface-variant mt-1">
              Manage YellowDog servers, Netman instances, profiles, configuration, and events.
            </p>
          </div>
        </div>

        <.management_tabs tabs={@tabs} active={@live_action} />

        <.overview
          :if={@live_action == :overview}
          servers={@servers}
          netmans={@netmans}
          server_profiles={@server_profiles}
          netman_profiles={@netman_profiles}
          events={@events}
        />
        <.servers :if={@live_action == :servers} servers={@servers} />
        <.netman :if={@live_action == :netman} netmans={@netmans} />
        <.profiles
          :if={@live_action == :profiles}
          server_profiles={@server_profiles}
          netman_profiles={@netman_profiles}
        />
        <.config :if={@live_action == :config} versions={@config_versions} />
        <.events
          :if={@live_action == :events}
          events={@events}
          command_outcomes={@command_outcomes}
        />
      </div>
    </Layouts.app>
    """
  end

  defp page_title(:overview), do: "Management Overview"
  defp page_title(:servers), do: "Management Servers"
  defp page_title(:netman), do: "Management Netman"
  defp page_title(:profiles), do: "Management Profiles"
  defp page_title(:config), do: "Management Config"
  defp page_title(:events), do: "Management Events"

  defp management_tabs(assigns) do
    ~H"""
    <div class="tabs tabs-boxed mb-6">
      <.link
        :for={{tab, label, path} <- @tabs}
        navigate={path}
        class={["tab", @active == tab && "tab-active"]}
      >
        {label}
      </.link>
    </div>
    """
  end

  defp overview(assigns) do
    assigns =
      assign(assigns,
        profile_count: length(assigns.server_profiles) + length(assigns.netman_profiles),
        recent_events: Enum.take(assigns.events, 5)
      )

    ~H"""
    <div class="space-y-6">
      <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-4 gap-4">
        <.card class="bg-surface">
          <.stat title="Servers" value={to_string(length(@servers))} desc="Registered service nodes" />
        </.card>
        <.card class="bg-surface">
          <.stat
            title="Netman Instances"
            value={to_string(length(@netmans))}
            desc="Managed network agents"
          />
        </.card>
        <.card class="bg-surface">
          <.stat title="Profiles" value={to_string(@profile_count)} desc="Server and Netman profiles" />
        </.card>
        <.card class="bg-surface">
          <.stat
            title="Recent Events"
            value={to_string(length(@recent_events))}
            desc="Latest management events"
          />
        </.card>
      </div>

      <.card title="Recent Events">
        <.events_list events={@recent_events} />
      </.card>
    </div>
    """
  end

  defp servers(assigns) do
    ~H"""
    <.card title="Service Nodes">
      <.empty_state :if={@servers == []} text="No servers registered yet." />
      <.table id="management-servers" rows={@servers}>
        <:col :let={server} label="ID">
          <.target_link target_type={:server} target_id={raw_field(server, :id)} />
        </:col>
        <:col :let={server} label="Name">{field(server, :name)}</:col>
        <:col :let={server} label="Profile">{field(server, :profile)}</:col>
        <:col :let={server} label="Status"><.status value={raw_field(server, :status)} /></:col>
        <:col :let={server} label="Services">{list_field(server, :services)}</:col>
        <:col :let={server} label="Last Seen">{field(server, :last_seen_at)}</:col>
      </.table>
    </.card>
    """
  end

  defp netman(assigns) do
    ~H"""
    <.card title="Netman Instances">
      <.empty_state :if={@netmans == []} text="No Netman instances registered yet." />
      <.table id="management-netmans" rows={@netmans}>
        <:col :let={netman} label="ID">
          <.target_link target_type={:netman} target_id={raw_field(netman, :id)} />
        </:col>
        <:col :let={netman} label="Name">{field(netman, :name)}</:col>
        <:col :let={netman} label="Profile">{field(netman, :profile)}</:col>
        <:col :let={netman} label="Status"><.status value={raw_field(netman, :status)} /></:col>
        <:col :let={netman} label="Features">{list_field(netman, :features)}</:col>
        <:col :let={netman} label="Apply Mode">{field(netman, :apply_mode)}</:col>
        <:col :let={netman} label="Last Seen">{field(netman, :last_seen_at)}</:col>
      </.table>
    </.card>
    """
  end

  defp profiles(assigns) do
    ~H"""
    <div class="grid grid-cols-1 xl:grid-cols-2 gap-6">
      <.profile_table
        title="Server Profiles"
        id="management-server-profiles"
        profiles={@server_profiles}
      />
      <.profile_table
        title="Netman Profiles"
        id="management-netman-profiles"
        profiles={@netman_profiles}
      />
    </div>
    """
  end

  defp profile_table(assigns) do
    ~H"""
    <.card title={@title}>
      <.empty_state :if={@profiles == []} text="No profiles available yet." />
      <.table id={@id} rows={@profiles}>
        <:col :let={profile} label="Name">{field(profile, :name)}</:col>
        <:col :let={profile} label="Description">{field(profile, :description)}</:col>
        <:col :let={profile} label="Defaults">{profile_defaults(profile)}</:col>
      </.table>
    </.card>
    """
  end

  defp config(assigns) do
    ~H"""
    <.card title="Published Config Versions">
      <.empty_state :if={@versions == []} text="No configuration versions published yet." />
      <.table id="management-config-versions" rows={@versions}>
        <:col :let={version} label="Target">
          <.target_link
            target_type={raw_field(version, :target_type)}
            target_id={raw_field(version, :target_id)}
          />
        </:col>
        <:col :let={version} label="Version">{field(version, :version)}</:col>
        <:col :let={version} label="Operation">{field(version, :operation)}</:col>
        <:col :let={version} label="State">
          <.status value={raw_field(version, :state)} />
        </:col>
        <:col :let={version} label="Digest">
          <code class="text-xs break-all">{field(version, :digest)}</code>
        </:col>
        <:col :let={version} label="Published">{field(version, :published_at)}</:col>
        <:col :let={version} label="State Changed">{field(version, :state_changed_at)}</:col>
        <:col :let={version} label="Failure Phase">{field(version, :failure_phase)}</:col>
        <:col :let={version} label="Rollback">{rollback_field(version)}</:col>
      </.table>
    </.card>
    """
  end

  defp events(assigns) do
    assigns =
      assign(assigns,
        server_events: filter_events(assigns.events, :server),
        netman_events: filter_events(assigns.events, :netman)
      )

    ~H"""
    <div class="space-y-6">
      <div class="grid grid-cols-1 xl:grid-cols-2 gap-6">
        <.card title="Server Events">
          <.events_list events={@server_events} empty_text="No server events recorded yet." />
        </.card>

        <.card title="Netman Events">
          <.events_list events={@netman_events} empty_text="No Netman events recorded yet." />
        </.card>
      </div>

      <.card title="Command Outcomes">
        <.empty_state
          :if={@command_outcomes == []}
          text="No management commands recorded yet."
        />
        <.table id="management-command-outcomes" rows={@command_outcomes}>
          <:col :let={outcome} label="Target">
            <.target_link
              target_type={raw_field(outcome, :target_type)}
              target_id={raw_field(outcome, :target_id)}
            />
          </:col>
          <:col :let={outcome} label="Operation">{field(outcome, :operation)}</:col>
          <:col :let={outcome} label="Outcome">
            <.status value={raw_field(outcome, :state)} />
          </:col>
          <:col :let={outcome} label="Updated">{field(outcome, :updated_at)}</:col>
          <:col :let={outcome} label="Detail">{command_detail(outcome)}</:col>
        </.table>
      </.card>
    </div>
    """
  end

  defp events_list(assigns) do
    assigns =
      assign_new(assigns, :empty_text, fn ->
        "No management events recorded yet."
      end)

    ~H"""
    <.empty_state :if={@events == []} text={@empty_text} />
    <div class="divide-y divide-outline-variant">
      <div :for={event <- @events} class="py-3">
        <div class="flex flex-wrap items-center gap-2">
          <.badge color="info" size="sm">{field(event, :type, "event")}</.badge>
          <span class="font-semibold">{field(event, :message)}</span>
        </div>
        <div class="text-xs text-on-surface-variant mt-1">
          <.target_link
            target_type={raw_field(event, :source)}
            target_id={raw_field(event, :source_id)}
          /> · {field(event, :occurred_at)}
        </div>
      </div>
    </div>
    """
  end

  defp filter_events(events, source) do
    Enum.filter(events, &(raw_field(&1, :source) == source))
  end

  defp empty_state(assigns) do
    ~H"""
    <p class="text-sm text-on-surface-variant py-4">{@text}</p>
    """
  end

  defp status(assigns) do
    assigns = assign(assigns, :label, format_value(assigns.value, "Unknown"))

    ~H"""
    <.badge color={status_color(@value)} size="sm">{@label}</.badge>
    """
  end

  defp status_color(value) when value in [:online, :running, "online", "running"], do: "success"

  defp status_color(value)
       when value in [:applied, :completed, "applied", "completed"],
       do: "success"

  defp status_color(value) when value in [:degraded, :warning, "degraded", "warning"],
    do: "warning"

  defp status_color(value)
       when value in [
              :desired,
              :delivered,
              :applying,
              :pending,
              "desired",
              "delivered",
              "applying",
              "pending"
            ],
       do: "warning"

  defp status_color(value) when value in [:offline, :failed, "offline", "failed"], do: "error"
  defp status_color(_value), do: "ghost"

  defp field(item, key, default \\ "—"), do: item |> raw_field(key) |> format_value(default)

  defp list_field(item, key) do
    item
    |> raw_field(key)
    |> format_list()
  end

  defp profile_defaults(profile) do
    defaults = raw_field(profile, :services) || raw_field(profile, :features) || %{}

    format_list(defaults)
  end

  defp target_link(assigns) do
    assigns = assign(assigns, :path, direct_target_path(assigns.target_type, assigns.target_id))

    ~H"""
    <.link :if={@path} navigate={@path} class="link link-primary">{@target_id}</.link>
    <span :if={is_nil(@path)}>{format_value(@target_id, "—")}</span>
    """
  end

  defp direct_target_path(target_type, target_id) when target_type in [:server, "server"] do
    if ServicePaths.valid_server_id?(target_id),
      do: ServicePaths.server_path(target_id, :dashboard),
      else: nil
  end

  defp direct_target_path(target_type, target_id) when target_type in [:netman, "netman"] do
    if ServicePaths.valid_netman_id?(target_id),
      do: ServicePaths.netman_path(target_id, :overview),
      else: nil
  end

  defp direct_target_path(_target_type, _target_id), do: nil

  defp rollback_field(version) do
    case raw_field(version, :rollback) do
      nil -> "—"
      rollback when is_map(rollback) -> format_detail_map(rollback)
      rollback -> format_value(rollback, "—")
    end
  end

  defp command_detail(outcome) do
    raw_field(outcome, :error_message) || raw_field(outcome, :unknown_reason) || "—"
  end

  defp format_detail_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map_join(", ", fn {key, value} ->
      "#{format_value(key, "")}=#{format_detail_value(value)}"
    end)
  end

  defp format_detail_value(value) when is_map(value), do: format_detail_map(value)

  defp format_detail_value(value) when is_list(value),
    do: Enum.map_join(value, ",", &format_detail_value/1)

  defp format_detail_value(value), do: format_value(value, "")

  defp raw_field(item, key) when is_map(item) do
    Map.get(item, key) || Map.get(item, to_string(key))
  end

  defp raw_field(item, key) when is_list(item), do: Keyword.get(item, key)
  defp raw_field(_item, _key), do: nil

  defp format_list(nil), do: "—"
  defp format_list([]), do: "—"

  defp format_list(items) when is_list(items) do
    items
    |> Enum.map(&format_value(&1, ""))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(", ")
  end

  defp format_list(items) when is_map(items) do
    items
    |> Enum.filter(fn {_key, enabled?} -> enabled? end)
    |> Enum.map(fn {key, _enabled?} -> format_value(key, "") end)
    |> Enum.join(", ")
    |> case do
      "" -> "—"
      value -> value
    end
  end

  defp format_list(value), do: format_value(value, "—")

  defp format_value(nil, default), do: default
  defp format_value("", default), do: default

  defp format_value(%DateTime{} = value, _default),
    do: Calendar.strftime(value, "%Y-%m-%d %H:%M:%S UTC")

  defp format_value(%NaiveDateTime{} = value, _default),
    do: Calendar.strftime(value, "%Y-%m-%d %H:%M:%S")

  defp format_value(value, _default) when is_atom(value),
    do: value |> Atom.to_string() |> String.replace("_", " ")

  defp format_value(value, _default) when is_binary(value), do: value
  defp format_value(value, _default), do: to_string(value)
end
