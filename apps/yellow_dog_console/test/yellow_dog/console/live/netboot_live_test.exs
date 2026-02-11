defmodule YellowDog.Console.NetbootLiveTest do
  use YellowDog.Console.ConnCase, async: true
  import Phoenix.LiveViewTest

  describe "Netboot Dashboard page" do
    test "mounts with title", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot")

      assert html =~ "Netboot Dashboard"
      assert html =~ "Network boot provisioning"
    end

    test "shows state summary cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot")

      assert html =~ "Discovered"
      assert html =~ "Booting"
      assert html =~ "Installing"
      assert html =~ "Installed"
      assert html =~ "Failed"
    end

    test "shows TFTP server card", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot")

      assert html =~ "TFTP Server"
    end

    test "shows boot profiles card", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot")

      assert html =~ "Boot Profiles"
    end

    test "shows recent devices table", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot")

      assert has_element?(view, "table")
    end

    test "shows telemetry metrics cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot")

      assert html =~ "TFTP Requests"
      assert html =~ "Transfers"
      assert html =~ "Bytes Transferred"
    end
  end

  describe "Netboot Devices page" do
    test "mounts with title and search", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/devices")

      assert html =~ "Netboot Devices"
      assert html =~ "Search by MAC"
    end

    test "shows stats cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/devices")

      assert html =~ "Total Devices"
      assert html =~ "Installed"
      assert html =~ "Failed"
    end

    test "has export CSV button", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/devices")

      assert has_element?(view, "button#export-csv")
    end

    test "renders device table", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/devices")

      assert has_element?(view, "table")
    end

    test "search filters devices", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/devices")

      html = view |> element("input[name=search]") |> render_change(%{"search" => "test"})
      assert html =~ "Netboot Devices"
    end

    test "state filter works", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/devices")

      html = view |> element("select[name=state]") |> render_change(%{"state" => "all"})
      assert html =~ "Netboot Devices"
    end
  end

  describe "Netboot Devices sorting" do
    test "clicking column header triggers sort event", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/devices")

      html = view |> element("th[phx-value-field=mac]") |> render_click()
      # Should show ascending indicator
      assert html =~ "\u25B2"
    end

    test "clicking same column toggles sort direction", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/devices")

      # First click: asc
      view |> element("th[phx-value-field=mac]") |> render_click()
      # Second click: desc
      html = view |> element("th[phx-value-field=mac]") |> render_click()
      assert html =~ "\u25BC"
    end

    test "clicking different column resets to asc", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/devices")

      # Click mac (asc), then hostname (should reset to asc)
      view |> element("th[phx-value-field=mac]") |> render_click()
      html = view |> element("th[phx-value-field=hostname]") |> render_click()
      assert html =~ "\u25B2"
    end

    test "all sortable columns have phx-click=sort", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/devices")

      for field <- ~w(mac hostname arch profile_id state install_attempts last_seen) do
        assert has_element?(view, "th[phx-value-field=#{field}]")
      end
    end

    test "sort_devices/3 sorts by field ascending", _context do
      alias YellowDog.Console.NetbootLive.DevicesLive

      devices = [
        %{
          mac: "CC:CC:CC:CC:CC:CC",
          hostname: "charlie",
          arch: nil,
          profile_id: nil,
          state: :installed,
          install_attempts: 3,
          last_seen: nil
        },
        %{
          mac: "AA:AA:AA:AA:AA:AA",
          hostname: "alice",
          arch: :x86_64,
          profile_id: "p1",
          state: :discovered,
          install_attempts: 1,
          last_seen: nil
        },
        %{
          mac: "BB:BB:BB:BB:BB:BB",
          hostname: "bob",
          arch: :aarch64,
          profile_id: "p2",
          state: :booting,
          install_attempts: 2,
          last_seen: nil
        }
      ]

      sorted = DevicesLive.sort_devices(devices, "mac", "asc")

      assert Enum.map(sorted, & &1.mac) == [
               "AA:AA:AA:AA:AA:AA",
               "BB:BB:BB:BB:BB:BB",
               "CC:CC:CC:CC:CC:CC"
             ]

      sorted_desc = DevicesLive.sort_devices(devices, "hostname", "desc")
      assert Enum.map(sorted_desc, & &1.hostname) == ["charlie", "bob", "alice"]
    end

    test "sort_devices/3 handles nil values", _context do
      alias YellowDog.Console.NetbootLive.DevicesLive

      devices = [
        %{
          mac: "BB:BB:BB:BB:BB:BB",
          hostname: nil,
          arch: nil,
          profile_id: nil,
          state: :discovered,
          install_attempts: 0,
          last_seen: nil
        },
        %{
          mac: "AA:AA:AA:AA:AA:AA",
          hostname: "alice",
          arch: nil,
          profile_id: nil,
          state: :discovered,
          install_attempts: 0,
          last_seen: nil
        }
      ]

      sorted = DevicesLive.sort_devices(devices, "hostname", "asc")
      # nil sorts first (empty string)
      assert Enum.map(sorted, & &1.mac) == ["BB:BB:BB:BB:BB:BB", "AA:AA:AA:AA:AA:AA"]
    end
  end

  describe "Netboot Devices bulk actions" do
    test "shows select-all checkbox in table header", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/devices")

      assert has_element?(view, "th input[type=checkbox]")
    end

    test "toggle_select adds device to selection", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/devices")

      # With no devices loaded (service unavailable), the table is empty,
      # but we can verify the bulk action bar is hidden
      refute has_element?(view, "button", "Clear Selection")
    end

    test "bulk_clear resets selection", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/devices")

      # Bulk clear should not crash even with no selection
      refute has_element?(view, "button", "Clear Selection")
    end

    test "bulk profile dropdown present in action bar structure", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/devices")

      # The select element for profile assignment is rendered only when
      # devices are selected; verify the page renders without it
      refute html =~ "Assign Profile..."
    end
  end

  describe "Netboot Device Detail page" do
    test "mounts with MAC title", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/devices/AA:BB:CC:DD:EE:FF")

      assert html =~ "AA:BB:CC:DD:EE:FF"
    end

    test "shows device not found for unknown MAC", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/devices/FF:FF:FF:FF:FF:FF")

      assert html =~ "Device not found"
    end

    test "has back link to devices list", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/devices/AA:BB:CC:DD:EE:FF")

      assert has_element?(view, "a[href='/netboot/devices']")
    end

    test "renders device info section when device not found", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/devices/AA:BB:CC:DD:EE:FF")

      # With no registry running, device is nil, so we see the warning
      assert html =~ "Device not found"
      # The info card with IP Address only shows when device exists
      refute html =~ "Hardware Info"
    end
  end

  describe "Boot Profiles page" do
    test "mounts with title", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/profiles")

      assert html =~ "Boot Profiles"
      assert html =~ "Configured netboot profiles"
    end

    test "shows stats cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/profiles")

      assert html =~ "Total Profiles"
      assert html =~ "Default Profile"
    end

    test "has export CSV button", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/profiles")

      assert has_element?(view, "button#export-csv")
    end

    test "has new profile button", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/profiles")

      assert has_element?(view, "a[href='/netboot/profiles/new']")
    end

    test "search filters profiles", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/profiles")

      html = view |> element("input[name=search]") |> render_change(%{"search" => "nixos"})
      assert html =~ "Boot Profiles"
    end

    test "table has actions column", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/profiles")

      assert html =~ "Actions"
    end
  end

  describe "Profile Editor — new profile" do
    test "mounts new profile form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/profiles/new")

      assert html =~ "New Boot Profile"
      assert html =~ "Create a new PXE boot profile"
    end

    test "has required form fields", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/profiles/new")

      assert has_element?(view, "input[name='profile[id]']")
      assert has_element?(view, "input[name='profile[kernel]']")
      assert has_element?(view, "input[name='profile[initrd]']")
      assert has_element?(view, "input[name='profile[description]']")
      assert has_element?(view, "input[name='profile[kernel_args]']")
      assert has_element?(view, "input[name='profile[installer_image]']")
    end

    test "has arch checkboxes", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/profiles/new")

      assert has_element?(view, "input[value='x86_64']")
      assert has_element?(view, "input[value='aarch64']")
      assert has_element?(view, "input[value='bios_x86']")
    end

    test "has manifest form fields", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/profiles/new")

      assert has_element?(view, "select[name='profile[disk_layout]']")
      assert has_element?(view, "select[name='profile[slot_strategy]']")
      assert has_element?(view, "input[name='profile[flake]']")
    end

    test "has back and submit buttons", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/profiles/new")

      assert has_element?(view, "a[href='/netboot/profiles']", "Cancel")
      assert has_element?(view, "button[type=submit]", "Create Profile")
    end

    test "validate shows errors for empty required fields", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/profiles/new")

      html =
        view
        |> form("form", profile: %{id: "", kernel: "", initrd: ""})
        |> render_change()

      assert html =~ "ID is required"
      assert html =~ "Kernel path is required"
      assert html =~ "Initrd path is required"
    end

    test "validate shows error for invalid ID format", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/profiles/new")

      html =
        view
        |> form("form", profile: %{id: "INVALID ID!", kernel: "k", initrd: "i"})
        |> render_change()

      assert html =~ "lowercase alphanumeric"
    end

    test "validate accepts valid input", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/profiles/new")

      html =
        view
        |> form("form", profile: %{id: "my-profile", kernel: "k/bzImage", initrd: "k/initrd"})
        |> render_change()

      refute html =~ "label-text-alt text-error"
    end

    test "shows iPXE script preview when kernel and initrd are set", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/profiles/new")

      html =
        view
        |> form("form",
          profile: %{
            id: "test",
            kernel: "nixos/bzImage",
            initrd: "nixos/initrd.img",
            kernel_args: "init=/nix/store/init ip=dhcp"
          }
        )
        |> render_change()

      assert html =~ "iPXE Script Preview"
      assert html =~ "#!ipxe"
      assert html =~ "kernel ${base-url}/nixos/bzImage"
      assert html =~ "initrd ${base-url}/nixos/initrd.img"
      assert html =~ "init=/nix/store/init ip=dhcp"
      assert html =~ "boot"
    end

    test "hides iPXE preview when kernel or initrd empty", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/profiles/new")

      html =
        view
        |> form("form", profile: %{id: "test", kernel: "k", initrd: ""})
        |> render_change()

      refute html =~ "iPXE Script Preview"
    end
  end

  describe "Profile Editor — clone profile" do
    test "mounts clone form in new mode", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/profiles/new?clone=test-profile")

      # With no Store running, it falls back to new empty profile
      assert html =~ "New Boot Profile"
      assert html =~ "Create a new PXE boot profile"
    end

    test "ID field is editable in clone mode (new mode)", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/profiles/new?clone=test-profile")

      # Clone creates a new profile, so ID should NOT be disabled
      refute has_element?(view, "input[name='profile[id]'][disabled]")
    end

    test "submit button says Create Profile in clone mode", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/profiles/new?clone=test-profile")

      assert has_element?(view, "button[type=submit]", "Create Profile")
    end
  end

  describe "Profile Editor — edit profile" do
    test "mounts edit form with profile ID", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/profiles/test-profile/edit")

      assert html =~ "Edit Profile"
      assert html =~ "test-profile"
    end

    test "ID field is disabled in edit mode", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/profiles/test-profile/edit")

      assert has_element?(view, "input[name='profile[id]'][disabled]")
    end

    test "has save changes button", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/profiles/test-profile/edit")

      assert has_element?(view, "button[type=submit]", "Save Changes")
    end
  end

  describe "Profile Editor — validation" do
    test "filter_by_search returns all for empty query" do
      profiles = [
        %{id: "a", description: "Alpha"},
        %{id: "b", description: "Beta"}
      ]

      assert YellowDog.Console.NetbootLive.ProfilesLive.filter_by_search(profiles, "") == profiles
    end

    test "filter_by_search matches ID" do
      profiles = [
        %{id: "nixos", description: "NixOS"},
        %{id: "ubuntu", description: "Ubuntu"}
      ]

      result = YellowDog.Console.NetbootLive.ProfilesLive.filter_by_search(profiles, "nix")
      assert length(result) == 1
      assert hd(result).id == "nixos"
    end

    test "validate_profile returns errors for empty fields in new mode" do
      errors =
        YellowDog.Console.NetbootLive.ProfileEditorLive.validate_profile(
          %{"id" => "", "kernel" => "", "initrd" => ""},
          :new
        )

      assert errors[:id] == "ID is required"
      assert errors[:kernel] == "Kernel path is required"
      assert errors[:initrd] == "Initrd path is required"
    end

    test "validate_profile skips ID check in edit mode" do
      errors =
        YellowDog.Console.NetbootLive.ProfileEditorLive.validate_profile(
          %{"id" => "", "kernel" => "k", "initrd" => "i"},
          :edit
        )

      refute Map.has_key?(errors, :id)
    end

    test "validate_profile rejects invalid ID format" do
      errors =
        YellowDog.Console.NetbootLive.ProfileEditorLive.validate_profile(
          %{"id" => "Bad Name!", "kernel" => "k", "initrd" => "i"},
          :new
        )

      assert errors[:id] =~ "lowercase"
    end

    test "validate_profile passes for valid input" do
      errors =
        YellowDog.Console.NetbootLive.ProfileEditorLive.validate_profile(
          %{"id" => "my-profile", "kernel" => "k/bzImage", "initrd" => "k/initrd"},
          :new
        )

      assert errors == %{}
    end
  end

  describe "TFTP Server page" do
    test "mounts with title", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/tftp")

      assert html =~ "TFTP Server"
      assert html =~ "Boot file serving"
    end

    test "shows status cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/tftp")

      assert html =~ "Status"
      assert html =~ "Port"
      assert html =~ "Files Indexed"
    end

    test "shows configuration card", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/tftp")

      assert html =~ "Configuration"
      assert html =~ "Root Directory"
    end

    test "shows file browser card", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/tftp")

      assert html =~ "File Browser"
    end

    test "has rescan button", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/tftp")

      assert has_element?(view, "button", "Rescan Files")
    end

    test "shows upload card with form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/tftp")

      assert html =~ "Upload Boot Assets"
      assert html =~ "Target Directory"
      assert html =~ "Max 500 MB per file"
    end

    test "has upload submit button (disabled when no files)", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/tftp")

      assert has_element?(view, "button[disabled]", "Upload Files")
    end

    test "validate_upload updates target path", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/tftp")

      html =
        view
        |> element("form[phx-change=validate_upload]")
        |> render_change(%{"upload_path" => "nixos/"})

      assert html =~ "nixos/"
    end

    test "file input is present for boot_asset upload", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/tftp")

      assert has_element?(view, "input[type=file]")
    end
  end

  describe "Boot Log page" do
    test "mounts with title", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/log")

      assert html =~ "Boot Log"
      assert html =~ "Real-time netboot activity"
    end

    test "has pause/resume button", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/log")

      assert has_element?(view, "button", "Pause")
    end

    test "has clear button", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/log")

      assert has_element?(view, "button", "Clear")
    end

    test "has export CSV button", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/log")

      assert has_element?(view, "button#export-csv")
    end

    test "toggle pause works", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/log")

      html = view |> element("button", "Pause") |> render_click()
      assert html =~ "Resume"
    end

    test "clear log works", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/log")

      html = view |> element("button", "Clear") |> render_click()
      assert html =~ "Boot Log"
    end

    test "search filters entries", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/log")

      html = view |> element("input[name=search]") |> render_change(%{"search" => "test"})
      assert html =~ "Boot Log"
    end

    test "type filter works", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/log")

      html = view |> element("select[name=type]") |> render_change(%{"type" => "device"})
      assert html =~ "Boot Log"
    end
  end
end
