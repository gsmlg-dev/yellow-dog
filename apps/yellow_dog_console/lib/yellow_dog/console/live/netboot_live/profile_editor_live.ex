defmodule YellowDog.Console.NetbootLive.ProfileEditorLive do
  @moduledoc """
  Boot profile editor for creating and managing boot profiles.

  Supports creating new profiles, editing existing ones, and cloning profiles
  with pre-filled settings. Profiles define iPXE boot scripts with custom arguments,
  architecture selection, and script preview functionality.
  """
  use YellowDog.Console, :live_view

  import YellowDog.Console.ServiceHelper

  alias YellowDog.Console.Layouts
  alias YellowDog.Netboot.Boot.Profile

  @valid_arches ~w(x86_64 aarch64 bios_x86)

  @impl true
  def mount(params, _session, socket) do
    {mode, profile, clone_source} = load_profile(params)

    form_data = profile_to_form(profile)

    device_count =
      if mode == :edit do
        safe_call(
          YellowDog.Netboot.Device.Registry,
          fn ->
            YellowDog.Netboot.Device.Registry.list()
            |> Enum.count(&(&1.profile_id == profile.id))
          end,
          0
        )
      else
        0
      end

    {:ok,
     socket
     |> assign(
       page_title: if(mode == :new, do: "New Boot Profile", else: "Edit: #{profile.id}"),
       mode: mode,
       profile_id: profile.id,
       clone_source: clone_source,
       device_count: device_count,
       valid_arches: @valid_arches,
       errors: %{}
     )
     |> assign(:form, to_form(form_data, as: "profile"))
     |> assign(:file_warnings, %{})
     |> assign(:indexed_files, load_indexed_files())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6">
        <div class="breadcrumbs text-sm">
          <ul>
            <li><.link navigate="/server/netboot">Netboot</.link></li>
            <li><.link navigate="/server/netboot/profiles">Profiles</.link></li>
            <li>{if @mode == :new, do: "New", else: @profile_id}</li>
          </ul>
        </div>

        <div class="flex items-center gap-4">
          <div>
            <h1 class="text-4xl font-bold">
              {if @mode == :new, do: "New Boot Profile", else: "Edit Profile"}
            </h1>
            <p class="mt-1 text-on-surface-variant">
              {if @mode == :new,
                do: "Create a new PXE boot profile",
                else: "Modify boot profile: #{@profile_id}"}
            </p>
            <p :if={@clone_source} class="mt-1 text-sm text-info">
              Cloned from <span class="font-mono font-medium">{@clone_source}</span>
            </p>
            <p :if={@mode == :edit && @device_count > 0} class="mt-1 text-sm text-warning">
              {@device_count} device(s) currently using this profile
            </p>
          </div>
        </div>

        <.card>
          <form phx-submit="save" phx-change="validate" class="space-y-4">
            <div class="form-group w-full">
              <label class="form-label">Profile ID</label>
              <input
                type="text"
                name="profile[id]"
                value={@form[:id].value}
                class={"input w-full #{if @errors[:id], do: "input-error"}"}
                placeholder="e.g. nixos-minimal"
                disabled={@mode == :edit}
              />
              <span :if={@errors[:id]} class="helper-text text-error">{@errors[:id]}</span>
            </div>

            <div class="form-group w-full">
              <label class="form-label">Description</label>
              <input
                type="text"
                name="profile[description]"
                value={@form[:description].value}
                class="input w-full"
                placeholder="e.g. NixOS Minimal Install"
              />
            </div>

            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div class="form-group w-full">
                <label class="form-label">Kernel Path</label>
                <input
                  type="text"
                  name="profile[kernel]"
                  value={@form[:kernel].value}
                  list="tftp-files"
                  class={"input w-full #{if @errors[:kernel], do: "input-error"}"}
                  placeholder="e.g. nixos/bzImage"
                />
                <span :if={@errors[:kernel]} class="helper-text text-error">{@errors[:kernel]}</span>
                <span :if={@file_warnings[:kernel]} class="helper-text text-warning">
                  {@file_warnings[:kernel]} —
                  <.link navigate="/server/netboot/tftp" class="link link-primary">upload</.link>
                </span>
              </div>

              <div class="form-group w-full">
                <label class="form-label">Initrd Path</label>
                <input
                  type="text"
                  name="profile[initrd]"
                  value={@form[:initrd].value}
                  list="tftp-files"
                  class={"input w-full #{if @errors[:initrd], do: "input-error"}"}
                  placeholder="e.g. nixos/initrd.img"
                />
                <span :if={@errors[:initrd]} class="helper-text text-error">{@errors[:initrd]}</span>
                <span :if={@file_warnings[:initrd]} class="helper-text text-warning">
                  {@file_warnings[:initrd]} —
                  <.link navigate="/server/netboot/tftp" class="link link-primary">upload</.link>
                </span>
              </div>
            </div>

            <div class="form-group w-full">
              <label class="form-label">Kernel Arguments</label>
              <input
                type="text"
                name="profile[kernel_args]"
                value={@form[:kernel_args].value}
                class="input w-full"
                placeholder="e.g. init=/nix/store/...-init ip=dhcp"
              />
            </div>

            <div class="form-group w-full">
              <label class="form-label">Installer Image</label>
              <input
                type="text"
                name="profile[installer_image]"
                value={@form[:installer_image].value}
                list="tftp-files"
                class="input w-full"
                placeholder="e.g. nixos/installer.squashfs"
              />
            </div>

            <div class="form-group w-full">
              <label class="form-label">Architectures</label>
              <div class="flex gap-4">
                <label :for={arch <- @valid_arches} class="form-label cursor-pointer gap-2">
                  <input
                    type="checkbox"
                    name="profile[arch][]"
                    value={arch}
                    checked={arch in (@form[:arch].value || [])}
                    class="checkbox checkbox-sm"
                  />
                  {arch}
                </label>
              </div>
            </div>

            <div class="divider">Manifest (Optional)</div>

            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div class="form-group w-full">
                <label class="form-label">Disk Layout</label>
                <select name="profile[disk_layout]" class="select w-full">
                  <option value="" selected={@form[:disk_layout].value in [nil, ""]}>
                    None
                  </option>
                  <option
                    value="single-root-btrfs"
                    selected={@form[:disk_layout].value == "single-root-btrfs"}
                  >
                    Single Root (Btrfs)
                  </option>
                  <option
                    value="single-root-ext4"
                    selected={@form[:disk_layout].value == "single-root-ext4"}
                  >
                    Single Root (ext4)
                  </option>
                  <option value="zfs-mirror" selected={@form[:disk_layout].value == "zfs-mirror"}>
                    ZFS Mirror
                  </option>
                </select>
              </div>

              <div class="form-group w-full">
                <label class="form-label">Slot Strategy</label>
                <select name="profile[slot_strategy]" class="select w-full">
                  <option value="single" selected={@form[:slot_strategy].value in [nil, "single"]}>
                    Single
                  </option>
                  <option value="ab" selected={@form[:slot_strategy].value == "ab"}>
                    A/B
                  </option>
                </select>
              </div>
            </div>

            <div class="form-group w-full">
              <label class="form-label">Flake URL</label>
              <input
                type="text"
                name="profile[flake]"
                value={@form[:flake].value}
                class="input w-full"
                placeholder="e.g. github:user/system#x86_64-linux"
              />
            </div>

            <div class="flex justify-between mt-6">
              <div>
                <button
                  :if={@mode == :edit}
                  type="button"
                  phx-click="delete_profile"
                  phx-disable-with="Deleting..."
                  data-confirm={"Delete profile \"#{@profile_id}\"?"}
                  class="btn btn-error btn-sm"
                >
                  Delete Profile
                </button>
              </div>
              <div class="flex gap-2">
                <.link navigate="/server/netboot/profiles" class="btn btn-ghost">Cancel</.link>
                <button type="submit" class="btn btn-primary" phx-disable-with="Saving...">
                  {if @mode == :new, do: "Create Profile", else: "Save Changes"}
                </button>
              </div>
            </div>
          </form>
        </.card>

        <datalist :if={@indexed_files} id="tftp-files">
          <option :for={path <- indexed_file_list(@indexed_files)} value={path} />
        </datalist>

        <.card :if={@form[:kernel].value != "" and @form[:initrd].value != ""}>
          <h2 class="card-title mb-4">iPXE Script Preview</h2>
          <pre class="bg-surface-container p-4 rounded-lg text-sm font-mono overflow-x-auto whitespace-pre">{render_preview(@form)}</pre>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("validate", %{"profile" => params}, socket) do
    errors = validate_profile(params, socket.assigns.mode)
    form_data = normalize_params(params)
    warnings = check_file_warnings(params, socket.assigns.indexed_files)

    {:noreply,
     socket
     |> assign(:form, to_form(form_data, as: "profile"))
     |> assign(:errors, errors)
     |> assign(:file_warnings, warnings)}
  end

  @impl true
  def handle_event("save", %{"profile" => params}, socket) do
    errors = validate_profile(params, socket.assigns.mode)

    if errors == %{} do
      profile = params_to_profile(params, socket.assigns)

      result =
        safe_call(
          YellowDog.Netboot.Manifest.Store,
          fn -> YellowDog.Netboot.Manifest.Store.put_profile(profile) end,
          {:error, :unavailable}
        )

      case result do
        :ok ->
          {:noreply,
           socket
           |> put_flash(:info, "Profile #{profile.id} saved successfully")
           |> push_navigate(to: "/server/netboot/profiles")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to save: #{inspect(reason)}")}
      end
    else
      {:noreply, assign(socket, :errors, errors)}
    end
  end

  @impl true
  def handle_event("delete_profile", _params, socket) do
    id = socket.assigns.profile_id

    result =
      safe_call(
        YellowDog.Netboot.Manifest.Store,
        fn -> YellowDog.Netboot.Manifest.Store.delete_profile(id) end,
        {:error, :service_unavailable}
      )

    socket =
      case result do
        :ok ->
          socket
          |> put_flash(:info, "Profile '#{id}' deleted successfully")
          |> push_navigate(to: "/server/netboot/profiles")

        {:error, _reason} ->
          put_flash(socket, :error, "Failed to delete profile '#{id}'")
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Private ---

  defp load_profile(%{"id" => id}) do
    case safe_call(
           YellowDog.Netboot.Manifest.Store,
           fn -> YellowDog.Netboot.Manifest.Store.get_profile(id) end,
           {:error, :unavailable}
         ) do
      {:ok, profile} -> {:edit, profile, nil}
      _ -> {:edit, %Profile{id: id, kernel: "", initrd: ""}, nil}
    end
  end

  defp load_profile(%{"clone" => source_id}) do
    case safe_call(
           YellowDog.Netboot.Manifest.Store,
           fn -> YellowDog.Netboot.Manifest.Store.get_profile(source_id) end,
           {:error, :unavailable}
         ) do
      {:ok, profile} ->
        {:new, %{profile | id: "#{profile.id}-copy"}, source_id}

      _ ->
        {:new, %Profile{id: "", kernel: "", initrd: ""}, nil}
    end
  end

  defp load_profile(_params) do
    {:new, %Profile{id: "", kernel: "", initrd: ""}, nil}
  end

  defp profile_to_form(%Profile{} = p) do
    %{
      "id" => p.id || "",
      "description" => p.description || "",
      "kernel" => p.kernel || "",
      "initrd" => p.initrd || "",
      "kernel_args" => p.kernel_args || "",
      "installer_image" => p.installer_image || "",
      "arch" => Enum.map(p.arch, &to_string/1),
      "disk_layout" => Map.get(p.manifest, "disk_layout", ""),
      "slot_strategy" => Map.get(p.manifest, "slot_strategy", "single"),
      "flake" => Map.get(p.manifest, "flake", "")
    }
  end

  defp normalize_params(params) do
    %{
      "id" => Map.get(params, "id", ""),
      "description" => Map.get(params, "description", ""),
      "kernel" => Map.get(params, "kernel", ""),
      "initrd" => Map.get(params, "initrd", ""),
      "kernel_args" => Map.get(params, "kernel_args", ""),
      "installer_image" => Map.get(params, "installer_image", ""),
      "arch" => Map.get(params, "arch", []),
      "disk_layout" => Map.get(params, "disk_layout", ""),
      "slot_strategy" => Map.get(params, "slot_strategy", "single"),
      "flake" => Map.get(params, "flake", "")
    }
  end

  defp params_to_profile(params, assigns) do
    id = if assigns.mode == :edit, do: assigns.profile_id, else: Map.get(params, "id", "")
    arch_list = Map.get(params, "arch", [])

    manifest =
      %{}
      |> maybe_put("disk_layout", Map.get(params, "disk_layout", ""))
      |> maybe_put("slot_strategy", Map.get(params, "slot_strategy", ""))
      |> maybe_put("flake", Map.get(params, "flake", ""))

    %Profile{
      id: id,
      description: Map.get(params, "description"),
      kernel: Map.get(params, "kernel", ""),
      initrd: Map.get(params, "initrd", ""),
      kernel_args: Map.get(params, "kernel_args"),
      installer_image: Map.get(params, "installer_image"),
      arch:
        Enum.flat_map(arch_list, fn a ->
          if a in @valid_arches, do: [String.to_existing_atom(a)], else: []
        end),
      manifest: manifest
    }
  end

  defp render_preview(form) do
    kernel = form[:kernel].value || ""
    initrd = form[:initrd].value || ""
    kernel_args = form[:kernel_args].value || ""

    args =
      [kernel_args, "yellowdog.mac=${mac}", "yellowdog.api=http://<server>:<port>"]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" ")

    """
    #!ipxe
    echo YellowDog Netboot - ${mac}
    dhcp
    set base-url http://<server>:<port>/boot/assets

    kernel ${base-url}/#{kernel} #{args}
    initrd ${base-url}/#{initrd}
    boot\
    """
  end

  defp indexed_file_list(%MapSet{} = files), do: Enum.sort(MapSet.to_list(files))
  defp indexed_file_list(_), do: []

  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp load_indexed_files do
    case safe_call(
           YellowDog.Netboot.TFTP.FileIndex,
           fn -> YellowDog.Netboot.TFTP.FileIndex.list() end,
           nil
         ) do
      nil -> nil
      entries -> MapSet.new(entries, fn {rel_path, _abs_path, _size} -> rel_path end)
    end
  end

  defp check_file_warnings(_params, nil), do: %{}

  defp check_file_warnings(params, file_set) do
    kernel = Map.get(params, "kernel", "") |> String.trim()
    initrd = Map.get(params, "initrd", "") |> String.trim()

    warnings = %{}

    warnings =
      if kernel != "" and kernel not in file_set,
        do: Map.put(warnings, :kernel, "File not found in TFTP root"),
        else: warnings

    warnings =
      if initrd != "" and initrd not in file_set,
        do: Map.put(warnings, :initrd, "File not found in TFTP root"),
        else: warnings

    warnings
  end

  def validate_profile(params, mode) do
    errors = %{}
    id = Map.get(params, "id", "")
    kernel = Map.get(params, "kernel", "")
    initrd = Map.get(params, "initrd", "")

    errors =
      if mode == :new and String.trim(id) == "",
        do: Map.put(errors, :id, "ID is required"),
        else: errors

    errors =
      if mode == :new and not Regex.match?(~r/\A[a-z0-9][a-z0-9_-]*\z/, id) and
           String.trim(id) != "",
         do: Map.put(errors, :id, "ID must be lowercase alphanumeric with hyphens/underscores"),
         else: errors

    errors =
      if String.trim(kernel) == "",
        do: Map.put(errors, :kernel, "Kernel path is required"),
        else: errors

    errors =
      if String.trim(initrd) == "",
        do: Map.put(errors, :initrd, "Initrd path is required"),
        else: errors

    errors
  end
end
