defmodule YellowDog.ManagementUI.ManagementLive.ProfilesLive do
  use YellowDog.ManagementUI, :live_view

  alias YellowDog.Management.ProfileCatalog

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign_new(:current_path, fn -> "/management/profiles" end)
     |> assign(
       page_title: "Management Profiles",
       server_profiles: ProfileCatalog.list_server_profiles(),
       netman_profiles: ProfileCatalog.list_netman_profiles()
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div id="management-profiles">
        <h1 class="text-3xl font-bold">Management Profiles</h1>
        <p id="management-profiles-help" class="management-help">
          Read-only catalog metadata preserving the original preset defaults, <strong>not actual Worker runtime support</strong>.
          Reading this catalog does not start agents or enable services.
        </p>
        <.profile_table
          title="Server Profiles"
          id="management-server-profiles"
          profiles={@server_profiles}
        />
        <.profile_table
          title="Netman Profiles"
          id="management-netman-profiles"
          profiles={@netman_profiles}
          show_apply_mode
        />
      </div>
    </Layouts.app>
    """
  end

  attr :title, :string, required: true
  attr :id, :string, required: true
  attr :profiles, :list, required: true
  attr :show_apply_mode, :boolean, default: false

  defp profile_table(assigns) do
    ~H"""
    <.card title={@title}>
      <.table id={@id} rows={@profiles}>
        <:col :let={profile} label="Name">{profile.name}</:col>
        <:col :let={profile} label="Description">{profile.description}</:col>
        <:col :let={profile} label="Defaults">{profile_defaults(profile)}</:col>
        <:col :let={profile} :if={@show_apply_mode} label="Apply Mode">
          {profile.apply_mode}
        </:col>
      </.table>
    </.card>
    """
  end

  defp profile_defaults(profile) do
    profile
    |> Map.get(:services, profile[:features])
    |> Enum.filter(fn {_key, enabled?} -> enabled? end)
    |> Enum.map(fn {key, _enabled?} -> to_string(key) end)
    |> Enum.sort()
    |> Enum.join(", ")
    |> case do
      "" -> "—"
      defaults -> defaults
    end
  end
end
