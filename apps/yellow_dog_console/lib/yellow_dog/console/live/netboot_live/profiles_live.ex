defmodule YellowDog.Console.NetbootLive.ProfilesLive do
  @moduledoc "Boot profiles management — list, view, and manage boot profiles."
  use YellowDog.Console, :live_view

  import YellowDog.Console.CsvHelper
  import YellowDog.Console.ServiceHelper

  alias YellowDog.Console.Layouts

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Boot Profiles",
       search_query: "",
       sort_field: "id",
       sort_dir: "asc"
     )
     |> load_profiles()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-4xl font-bold">Boot Profiles</h1>
            <p class="mt-2 text-base-content/70">
              Configured netboot profiles for PXE provisioning
            </p>
          </div>
          <div class="flex gap-2">
            <.link navigate="/netboot/profiles/new" class="btn btn-primary btn-sm">
              New Profile
            </.link>
            <button
              phx-click="export_csv"
              id="export-csv"
              phx-hook="CsvDownload"
              class="btn btn-outline btn-sm"
            >
              Export CSV
            </button>
          </div>
        </div>

        <div class="stats stats-vertical sm:stats-horizontal shadow w-full">
          <div class="stat">
            <div class="stat-title">Total Profiles</div>
            <div class="stat-value text-primary">{length(@all_profiles)}</div>
          </div>
          <div class="stat">
            <div class="stat-title">Default Profile</div>
            <div class="stat-value text-sm">{@default_profile || "None"}</div>
          </div>
        </div>

        <.card>
          <div class="flex-1">
            <label class="input input-bordered flex items-center gap-2">
              <svg
                xmlns="http://www.w3.org/2000/svg"
                viewBox="0 0 16 16"
                fill="currentColor"
                class="h-4 w-4 opacity-70"
              >
                <path
                  fill-rule="evenodd"
                  d="M9.965 11.026a5 5 0 1 1 1.06-1.06l2.755 2.754a.75.75 0 1 1-1.06 1.06l-2.755-2.754ZM10.5 7a3.5 3.5 0 1 1-7 0 3.5 3.5 0 0 1 7 0Z"
                  clip-rule="evenodd"
                />
              </svg>
              <input
                type="text"
                class="grow"
                placeholder="Search by ID, description, kernel, or initrd..."
                value={@search_query}
                phx-change="search"
                phx-debounce="300"
                name="search"
              />
            </label>
          </div>
        </.card>

        <.card>
          <div class="overflow-x-auto">
            <table class="table table-zebra">
              <thead>
                <tr>
                  <.sort_header
                    field="id"
                    label="ID"
                    sort_field={@sort_field}
                    sort_dir={@sort_dir}
                  />
                  <.sort_header
                    field="description"
                    label="Description"
                    sort_field={@sort_field}
                    sort_dir={@sort_dir}
                  />
                  <th>Kernel</th>
                  <th>Initrd</th>
                  <th>Architectures</th>
                  <.sort_header
                    field="devices"
                    label="Devices"
                    sort_field={@sort_field}
                    sort_dir={@sort_dir}
                  />
                  <th>Actions</th>
                </tr>
              </thead>
              <tbody>
                <tr :if={@filtered_profiles == []}>
                  <td colspan="7" class="text-center text-base-content/50 py-8">
                    No boot profiles configured
                  </td>
                </tr>
                <tr :for={p <- @filtered_profiles}>
                  <td class="font-mono font-medium">
                    {p.id}
                    <.badge :if={p.id == @default_profile} color="primary" size="sm" class="ml-1">
                      default
                    </.badge>
                  </td>
                  <td class="max-w-xs truncate" title={p.description || ""}>{p.description || "-"}</td>
                  <td class="text-sm font-mono">{p.kernel}</td>
                  <td class="text-sm font-mono">{p.initrd}</td>
                  <td>
                    <.badge :for={arch <- p.arch} color="info" size="sm" class="mr-1">
                      {to_string(arch)}
                    </.badge>
                    <span :if={p.arch == []}>Any</span>
                  </td>
                  <td>
                    <.badge color="ghost" size="sm">
                      {Map.get(@profile_usage, p.id, 0)}
                    </.badge>
                  </td>
                  <td>
                    <div class="flex gap-1">
                      <.link
                        navigate={"/netboot/profiles/#{p.id}/edit"}
                        class="btn btn-ghost btn-xs"
                      >
                        Edit
                      </.link>
                      <.link
                        navigate={"/netboot/profiles/new?clone=#{p.id}"}
                        class="btn btn-ghost btn-xs"
                      >
                        Clone
                      </.link>
                      <button
                        phx-click="delete_profile"
                        phx-value-id={p.id}
                        data-confirm={"Delete profile \"#{p.id}\"?"}
                        class="btn btn-ghost btn-xs text-error"
                      >
                        Delete
                      </button>
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("search", %{"search" => query}, socket) do
    {:noreply, socket |> assign(:search_query, query) |> apply_filters()}
  end

  def handle_event("export_csv", _params, socket) do
    csv = build_csv(socket.assigns.filtered_profiles, socket.assigns.profile_usage)
    filename = "boot_profiles_#{Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")}.csv"
    {:noreply, push_event(socket, "download_csv", %{content: csv, filename: filename})}
  end

  def handle_event("sort", %{"field" => field}, socket) do
    dir =
      if socket.assigns.sort_field == field,
        do: toggle_dir(socket.assigns.sort_dir),
        else: "asc"

    {:noreply, socket |> assign(sort_field: field, sort_dir: dir) |> apply_filters()}
  end

  def handle_event("delete_profile", %{"id" => id}, socket) do
    safe_call(
      YellowDog.Netboot.Manifest.Store,
      fn -> YellowDog.Netboot.Manifest.Store.delete_profile(id) end,
      :ok
    )

    {:noreply,
     socket
     |> put_flash(:info, "Profile #{id} deleted")
     |> load_profiles()}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_profiles(socket) do
    profiles =
      safe_call(
        YellowDog.Netboot.Manifest.Store,
        fn ->
          YellowDog.Netboot.Manifest.Store.list_profiles()
        end,
        []
      )

    default =
      safe_call(
        YellowDog.Netboot.Manifest.Store,
        fn ->
          YellowDog.Netboot.Manifest.Store.default_profile_id()
        end,
        nil
      )

    devices =
      safe_call(
        YellowDog.Netboot.Device.Registry,
        fn -> YellowDog.Netboot.Device.Registry.list() end,
        []
      )

    profile_usage =
      devices
      |> Enum.filter(& &1.profile_id)
      |> Enum.frequencies_by(& &1.profile_id)

    socket
    |> assign(:all_profiles, profiles)
    |> assign(:default_profile, default)
    |> assign(:profile_usage, profile_usage)
    |> apply_filters()
  end

  defp apply_filters(socket) do
    filtered =
      socket.assigns.all_profiles
      |> filter_by_search(socket.assigns.search_query)
      |> sort_profiles(
        socket.assigns.sort_field,
        socket.assigns.sort_dir,
        socket.assigns.profile_usage
      )

    assign(socket, :filtered_profiles, filtered)
  end

  def filter_by_search(profiles, ""), do: profiles

  def filter_by_search(profiles, query) do
    q = String.downcase(query)

    Enum.filter(profiles, fn p ->
      String.contains?(String.downcase(p.id), q) ||
        (p.description && String.contains?(String.downcase(p.description), q)) ||
        (Map.get(p, :kernel) && String.contains?(String.downcase(p.kernel), q)) ||
        (Map.get(p, :initrd) && String.contains?(String.downcase(p.initrd), q))
    end)
  end

  defp sort_header(assigns) do
    ~H"""
    <th
      phx-click="sort"
      phx-value-field={@field}
      class="cursor-pointer select-none hover:bg-base-200"
    >
      <div class="flex items-center gap-1">
        {@label}
        <span :if={@sort_field == @field} class="text-xs">
          {if @sort_dir == "asc", do: "\u25B2", else: "\u25BC"}
        </span>
      </div>
    </th>
    """
  end

  def sort_profiles(profiles, field, dir, usage) do
    sorter = sort_key_fn(field, usage)
    sorted = Enum.sort_by(profiles, sorter)
    if dir == "desc", do: Enum.reverse(sorted), else: sorted
  end

  defp sort_key_fn("id", _usage), do: &String.downcase(&1.id)
  defp sort_key_fn("description", _usage), do: &String.downcase(&1.description || "")
  defp sort_key_fn("devices", usage), do: &Map.get(usage, &1.id, 0)
  defp sort_key_fn(_, _usage), do: &String.downcase(&1.id)

  defp toggle_dir("asc"), do: "desc"
  defp toggle_dir(_), do: "asc"

  defp build_csv(profiles, usage) do
    header = "ID,Description,Kernel,Initrd,Kernel Args,Architectures,Devices\r\n"

    rows =
      Enum.map_join(profiles, "\r\n", fn p ->
        [
          csv_escape(p.id),
          csv_escape(p.description || ""),
          csv_escape(p.kernel),
          csv_escape(p.initrd),
          csv_escape(p.kernel_args || ""),
          csv_escape(Enum.map_join(p.arch, "; ", &to_string/1)),
          csv_escape(to_string(Map.get(usage, p.id, 0)))
        ]
        |> Enum.join(",")
      end)

    header <> rows
  end
end
