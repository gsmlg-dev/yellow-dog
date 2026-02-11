defmodule YellowDog.Console.NetbootLive.DevicesLive do
  @moduledoc "Netboot device list — tracks discovered PXE devices and their states."
  use YellowDog.Console, :live_view

  import YellowDog.Console.CsvHelper
  import YellowDog.Console.NetbootComponents
  import YellowDog.Console.ServiceHelper

  alias YellowDog.Console.Layouts

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "netboot:devices")
    end

    {:ok,
     socket
     |> assign(
       page_title: "Netboot Devices",
       search_query: "",
       filter_state: "all",
       selected_devices: MapSet.new(),
       bulk_profile: nil,
       sort_field: "last_seen",
       sort_dir: "desc"
     )
     |> load_devices()
     |> load_profiles()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-4xl font-bold">Netboot Devices</h1>
            <p class="mt-2 text-base-content/70">
              PXE boot devices discovered via DHCP and TFTP
            </p>
          </div>
          <button
            phx-click="export_csv"
            id="export-csv"
            phx-hook="CsvDownload"
            class="btn btn-outline btn-sm"
          >
            Export CSV
          </button>
        </div>

        <div class="stats stats-vertical sm:stats-horizontal shadow w-full">
          <div class="stat">
            <div class="stat-title">Total Devices</div>
            <div class="stat-value text-primary">{length(@all_devices)}</div>
          </div>
          <div class="stat">
            <div class="stat-title">Installed</div>
            <div class="stat-value text-success">{@installed_count}</div>
          </div>
          <div class="stat">
            <div class="stat-title">Failed</div>
            <div class="stat-value text-error">{@failed_count}</div>
          </div>
          <div class="stat">
            <div class="stat-title">Showing</div>
            <div class="stat-value text-sm">
              {length(@filtered_devices)}<span class="text-base-content/50 font-normal">/{length(@all_devices)}</span>
            </div>
          </div>
        </div>

        <.card>
          <div class="flex flex-col md:flex-row gap-4">
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
                  placeholder="Search by MAC, hostname, profile, or tag..."
                  value={@search_query}
                  phx-change="search"
                  phx-debounce="300"
                  name="search"
                />
              </label>
            </div>
            <select
              class="select select-bordered"
              phx-change="filter_state"
              name="state"
              value={@filter_state}
            >
              <option value="all">All States</option>
              <option :for={s <- @available_states} value={s}>{s}</option>
            </select>
          </div>
        </.card>

        <div
          :if={MapSet.size(@selected_devices) > 0}
          class="flex items-center gap-3 p-3 bg-primary/10 rounded-lg"
        >
          <span class="text-sm font-medium">
            {MapSet.size(@selected_devices)} device(s) selected
          </span>
          <select
            class="select select-bordered select-sm"
            phx-change="bulk_select_profile"
            name="profile"
          >
            <option value="">Assign Profile...</option>
            <option :for={p <- @profiles} value={p.id}>{p.id}</option>
          </select>
          <button
            :if={@bulk_profile}
            phx-click="bulk_assign_profile"
            class="btn btn-primary btn-sm"
          >
            Apply to {MapSet.size(@selected_devices)} device(s)
          </button>
          <div class="divider divider-horizontal"></div>
          <form phx-submit="bulk_add_tag" class="flex items-center gap-2">
            <input
              type="text"
              name="tag"
              placeholder="Add tag..."
              class="input input-bordered input-sm w-32"
              value=""
            />
            <button type="submit" class="btn btn-outline btn-sm">Tag</button>
          </form>
          <button
            phx-click="bulk_delete"
            class="btn btn-error btn-sm"
            data-confirm={"Delete #{MapSet.size(@selected_devices)} device(s)?"}
          >
            Delete
          </button>
          <button phx-click="bulk_clear" class="btn btn-ghost btn-sm">
            Clear Selection
          </button>
        </div>

        <.card>
          <div class="overflow-x-auto">
            <table class="table table-zebra">
              <thead>
                <tr>
                  <th>
                    <input
                      type="checkbox"
                      class="checkbox checkbox-sm"
                      phx-click="toggle_select_all"
                      checked={
                        @filtered_devices != [] && all_selected?(@filtered_devices, @selected_devices)
                      }
                    />
                  </th>
                  <.sort_header
                    field="mac"
                    label="MAC Address"
                    sort_field={@sort_field}
                    sort_dir={@sort_dir}
                  />
                  <.sort_header
                    field="hostname"
                    label="Hostname"
                    sort_field={@sort_field}
                    sort_dir={@sort_dir}
                  />
                  <.sort_header
                    field="arch"
                    label="Arch"
                    sort_field={@sort_field}
                    sort_dir={@sort_dir}
                  />
                  <.sort_header
                    field="profile_id"
                    label="Profile"
                    sort_field={@sort_field}
                    sort_dir={@sort_dir}
                  />
                  <.sort_header
                    field="state"
                    label="State"
                    sort_field={@sort_field}
                    sort_dir={@sort_dir}
                  />
                  <.sort_header
                    field="install_attempts"
                    label="Install Attempts"
                    sort_field={@sort_field}
                    sort_dir={@sort_dir}
                  />
                  <.sort_header
                    field="last_seen"
                    label="Last Seen"
                    sort_field={@sort_field}
                    sort_dir={@sort_dir}
                  />
                </tr>
              </thead>
              <tbody>
                <tr :if={@filtered_devices == []}>
                  <td colspan="8" class="text-center text-base-content/50 py-8">
                    No devices found
                  </td>
                </tr>
                <tr :for={device <- @filtered_devices}>
                  <td>
                    <input
                      type="checkbox"
                      class="checkbox checkbox-sm"
                      phx-click="toggle_select"
                      phx-value-mac={device.mac}
                      checked={MapSet.member?(@selected_devices, device.mac)}
                    />
                  </td>
                  <td class="font-mono text-sm">
                    <.link navigate={"/netboot/devices/#{device.mac}"} class="link link-primary">
                      {device.mac}
                    </.link>
                  </td>
                  <td>{device.hostname || "-"}</td>
                  <td>
                    <.badge :if={device.arch} color="info" size="sm">{to_string(device.arch)}</.badge>
                    <span :if={!device.arch}>-</span>
                  </td>
                  <td>{device.profile_id || "-"}</td>
                  <td><.state_badge state={device.state} /></td>
                  <td>{device.install_attempts}</td>
                  <td class="text-sm">{format_datetime(device.last_seen)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>
      </div>
    </Layouts.app>
    """
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

  @impl true
  def handle_event("search", %{"search" => query}, socket) do
    {:noreply, socket |> assign(:search_query, query) |> apply_filters()}
  end

  def handle_event("filter_state", %{"state" => state}, socket) do
    {:noreply, socket |> assign(:filter_state, state) |> apply_filters()}
  end

  def handle_event("sort", %{"field" => field}, socket) do
    dir =
      if socket.assigns.sort_field == field,
        do: toggle_dir(socket.assigns.sort_dir),
        else: "asc"

    {:noreply, socket |> assign(sort_field: field, sort_dir: dir) |> apply_filters()}
  end

  def handle_event("export_csv", _params, socket) do
    csv = build_csv(socket.assigns.filtered_devices)
    filename = "netboot_devices_#{Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")}.csv"
    {:noreply, push_event(socket, "download_csv", %{content: csv, filename: filename})}
  end

  def handle_event("toggle_select", %{"mac" => mac}, socket) do
    selected = socket.assigns.selected_devices

    selected =
      if MapSet.member?(selected, mac),
        do: MapSet.delete(selected, mac),
        else: MapSet.put(selected, mac)

    {:noreply, assign(socket, :selected_devices, selected)}
  end

  def handle_event("toggle_select_all", _params, socket) do
    macs = Enum.map(socket.assigns.filtered_devices, & &1.mac)

    selected =
      if all_selected?(socket.assigns.filtered_devices, socket.assigns.selected_devices) do
        MapSet.new()
      else
        MapSet.new(macs)
      end

    {:noreply, assign(socket, :selected_devices, selected)}
  end

  def handle_event("bulk_select_profile", %{"profile" => ""}, socket) do
    {:noreply, assign(socket, :bulk_profile, nil)}
  end

  def handle_event("bulk_select_profile", %{"profile" => profile_id}, socket) do
    {:noreply, assign(socket, :bulk_profile, profile_id)}
  end

  def handle_event("bulk_assign_profile", _params, socket) do
    profile_id = socket.assigns.bulk_profile
    macs = MapSet.to_list(socket.assigns.selected_devices)

    results =
      Enum.map(macs, fn mac ->
        safe_call(
          YellowDog.Netboot.Device.Registry,
          fn -> YellowDog.Netboot.Device.Registry.assign_profile(mac, profile_id) end,
          {:error, :service_unavailable}
        )
      end)

    ok_count = Enum.count(results, &match?({:ok, _}, &1))
    err_count = length(results) - ok_count

    socket =
      socket
      |> assign(:selected_devices, MapSet.new())
      |> assign(:bulk_profile, nil)
      |> load_devices()

    socket =
      cond do
        err_count > 0 && ok_count > 0 ->
          put_flash(
            socket,
            :info,
            "Assigned profile to #{ok_count} device(s), #{err_count} failed"
          )

        err_count > 0 ->
          put_flash(socket, :error, "Failed to assign profile to #{err_count} device(s)")

        true ->
          put_flash(socket, :info, "Assigned \"#{profile_id}\" to #{ok_count} device(s)")
      end

    {:noreply, socket}
  end

  def handle_event("bulk_add_tag", %{"tag" => tag}, socket) do
    tag = String.trim(tag)

    if tag == "" do
      {:noreply, socket}
    else
      macs = MapSet.to_list(socket.assigns.selected_devices)

      Enum.each(macs, fn mac ->
        with {:ok, device} <-
               safe_call(
                 YellowDog.Netboot.Device.Registry,
                 fn -> YellowDog.Netboot.Device.Registry.get(mac) end,
                 {:error, :unavailable}
               ) do
          new_tags = Enum.uniq(device.tags ++ [tag])

          safe_call(
            YellowDog.Netboot.Device.Registry,
            fn -> YellowDog.Netboot.Device.Registry.update_tags(mac, new_tags) end,
            {:error, :unavailable}
          )
        end
      end)

      {:noreply,
       socket
       |> assign(:selected_devices, MapSet.new())
       |> put_flash(:info, "Added tag \"#{tag}\" to #{length(macs)} device(s)")
       |> load_devices()}
    end
  end

  def handle_event("bulk_delete", _params, socket) do
    macs = MapSet.to_list(socket.assigns.selected_devices)

    Enum.each(macs, fn mac ->
      safe_call(
        YellowDog.Netboot.Device.Registry,
        fn -> YellowDog.Netboot.Device.Registry.delete(mac) end,
        :ok
      )
    end)

    {:noreply,
     socket
     |> assign(:selected_devices, MapSet.new())
     |> put_flash(:info, "Deleted #{length(macs)} device(s)")
     |> load_devices()}
  end

  def handle_event("bulk_clear", _params, socket) do
    {:noreply, assign(socket, selected_devices: MapSet.new(), bulk_profile: nil)}
  end

  @impl true
  def handle_info({:device_state_changed, _}, socket), do: {:noreply, load_devices(socket)}
  def handle_info({:device_registered, _}, socket), do: {:noreply, load_devices(socket)}
  def handle_info({:device_deleted, _}, socket), do: {:noreply, load_devices(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_profiles(socket) do
    profiles =
      safe_call(
        YellowDog.Netboot.Manifest.Store,
        fn -> YellowDog.Netboot.Manifest.Store.list_profiles() end,
        []
      )

    assign(socket, :profiles, profiles)
  end

  defp all_selected?([], _selected), do: false

  defp all_selected?(filtered, selected) do
    Enum.all?(filtered, &MapSet.member?(selected, &1.mac))
  end

  defp load_devices(socket) do
    all =
      safe_call(
        YellowDog.Netboot.Device.Registry,
        fn ->
          YellowDog.Netboot.Device.Registry.list()
        end,
        []
      )

    states =
      all
      |> Enum.map(&to_string(&1.state))
      |> Enum.uniq()
      |> Enum.sort()

    socket
    |> assign(:all_devices, all)
    |> assign(:installed_count, Enum.count(all, &(&1.state == :installed)))
    |> assign(:failed_count, Enum.count(all, &(&1.state == :failed)))
    |> assign(:available_states, states)
    |> apply_filters()
  end

  defp apply_filters(socket) do
    devices =
      socket.assigns.all_devices
      |> filter_by_search(socket.assigns.search_query)
      |> filter_by_state(socket.assigns.filter_state)
      |> sort_devices(socket.assigns.sort_field, socket.assigns.sort_dir)

    assign(socket, :filtered_devices, devices)
  end

  def filter_by_search(devices, ""), do: devices

  def filter_by_search(devices, query) do
    q = String.downcase(query)

    Enum.filter(devices, fn d ->
      String.contains?(String.downcase(d.mac), q) ||
        (d.hostname && String.contains?(String.downcase(d.hostname), q)) ||
        (d.profile_id && String.contains?(String.downcase(d.profile_id), q)) ||
        Enum.any?(d.tags, &String.contains?(String.downcase(&1), q))
    end)
  end

  def filter_by_state(devices, "all"), do: devices
  def filter_by_state(devices, state), do: Enum.filter(devices, &(to_string(&1.state) == state))

  def sort_devices(devices, field, dir) do
    sorter = sort_key_fn(field)
    sorted = Enum.sort_by(devices, sorter, &compare_values/2)
    if dir == "desc", do: Enum.reverse(sorted), else: sorted
  end

  defp sort_key_fn("mac"), do: & &1.mac
  defp sort_key_fn("hostname"), do: &(&1.hostname || "")
  defp sort_key_fn("arch"), do: &if(&1.arch, do: to_string(&1.arch), else: "")
  defp sort_key_fn("profile_id"), do: &(&1.profile_id || "")
  defp sort_key_fn("state"), do: &to_string(&1.state)
  defp sort_key_fn("install_attempts"), do: & &1.install_attempts
  defp sort_key_fn("last_seen"), do: & &1.last_seen
  defp sort_key_fn(_), do: & &1.mac

  defp compare_values(nil, _), do: true
  defp compare_values(_, nil), do: false
  defp compare_values(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b) != :gt
  defp compare_values(a, b), do: a <= b

  defp toggle_dir("asc"), do: "desc"
  defp toggle_dir(_), do: "asc"

  defp build_csv(devices) do
    header = "MAC,Hostname,Arch,Profile,State,Install Attempts,Tags,Last Seen\r\n"

    rows =
      Enum.map_join(devices, "\r\n", fn d ->
        [
          csv_escape(d.mac),
          csv_escape(d.hostname || ""),
          csv_escape(if(d.arch, do: to_string(d.arch), else: "")),
          csv_escape(d.profile_id || ""),
          csv_escape(to_string(d.state)),
          csv_escape(to_string(d.install_attempts)),
          csv_escape(Enum.join(d.tags, "; ")),
          csv_escape(format_datetime(d.last_seen))
        ]
        |> Enum.join(",")
      end)

    header <> rows
  end
end
