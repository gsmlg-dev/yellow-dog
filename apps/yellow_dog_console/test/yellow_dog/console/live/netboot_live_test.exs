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

    test "shows profile usage stats", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot")

      # With no profiles/devices, should show empty list
      assert html =~ "Boot Profiles"
      # "devices" text appears in the badge template
      # (0 devices when no data)
    end

    test "has refresh button", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot")

      assert has_element?(view, "button", "Refresh")
      html = view |> element("button", "Refresh") |> render_click()
      assert html =~ "Netboot Dashboard"
    end

    test "shows live indicator", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot")

      assert html =~ "animate-pulse"
      assert html =~ "Live"
    end

    test "state stat cards are clickable links to devices page", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot")

      assert has_element?(view, "a[href='/netboot/devices?state=discovered']")
      assert has_element?(view, "a[href='/netboot/devices?state=failed']")
      assert has_element?(view, "a[href='/netboot/devices?state=installed']")
    end

    test "has View All links for profiles and devices sections", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot")

      assert has_element?(view, "a[href='/netboot/profiles']", "View all")
      assert has_element?(view, "a[href='/netboot/devices']", "View all")
    end
  end

  describe "Netboot Devices page" do
    test "mounts with title and search", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/devices")

      assert html =~ "Netboot Devices"
      assert html =~ "Search by MAC"
      assert html =~ "breadcrumbs"
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

    test "has Actions and Tags column headers", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/devices")

      assert html =~ "Actions"
      assert html =~ "Tags"
    end

    test "accepts state filter from URL query params", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/devices?state=failed")

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

    test "bulk_add_tag with empty tag is a no-op", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/devices")

      html = view |> render_hook("bulk_add_tag", %{"tag" => ""})
      # Should not crash
      assert html =~ "Netboot Devices"
    end

    test "bulk_add_tag with selection but service unavailable", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/devices")

      # Add a device to selection, then try to tag
      # Since no devices exist (service unavailable), this just completes gracefully
      html = view |> render_hook("bulk_add_tag", %{"tag" => "test-tag"})
      assert html =~ "Netboot Devices"
    end

    test "bulk_delete event completes gracefully", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/devices")

      html = view |> render_hook("bulk_delete", %{})
      assert html =~ "Deleted 0 device(s)"
    end

    test "filter_by_search matches tags", _context do
      alias YellowDog.Console.NetbootLive.DevicesLive

      devices = [
        %{mac: "AA:AA:AA:AA:AA:AA", hostname: nil, profile_id: nil, tags: ["server", "rack1"]},
        %{mac: "BB:BB:BB:BB:BB:BB", hostname: nil, profile_id: nil, tags: ["desktop"]}
      ]

      result = DevicesLive.filter_by_search(devices, "rack1")
      assert length(result) == 1
      assert hd(result).mac == "AA:AA:AA:AA:AA:AA"
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

    test "has breadcrumb navigation", %{conn: conn} do
      {:ok, view, html} = live(conn, "/netboot/devices/AA:BB:CC:DD:EE:FF")

      assert html =~ "breadcrumbs"
      assert has_element?(view, "a[href='/netboot']", "Netboot")
      assert has_element?(view, "a[href='/netboot/devices']", "Devices")
    end

    test "has copy MAC button with CopyToClipboard hook", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/devices/AA:BB:CC:DD:EE:FF")

      assert has_element?(view, "button#copy-mac[phx-hook=CopyToClipboard]")
      assert has_element?(view, "#device-mac")
    end

    test "renders device info section when device not found", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/devices/AA:BB:CC:DD:EE:FF")

      # With no registry running, device is nil, so we see the warning
      assert html =~ "Device not found"
      # The info card with IP Address only shows when device exists
      refute html =~ "Hardware Info"
    end

    test "add_tag event does not crash when device is nil", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/devices/AA:BB:CC:DD:EE:FF")

      # Device is nil (service unavailable), add_tag should be a no-op
      html = view |> render_hook("add_tag", %{"tag" => "test-tag"})
      # Should not crash, page still renders
      assert html =~ "Device not found"
    end

    test "remove_tag event does not crash when device is nil", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/devices/AA:BB:CC:DD:EE:FF")

      html = view |> render_hook("remove_tag", %{"tag" => "old-tag"})
      assert html =~ "Device not found"
    end

    test "boot script preview not shown when device not found", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/devices/FF:FF:FF:FF:FF:FF")

      refute html =~ "iPXE Boot Script"
    end
  end

  describe "Boot Profiles page" do
    test "mounts with title and breadcrumbs", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/profiles")

      assert html =~ "Boot Profiles"
      assert html =~ "Configured netboot profiles"
      assert html =~ "breadcrumbs"
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

    test "table has devices column", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/profiles")

      assert html =~ "Devices"
    end

    test "columns are sortable", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/profiles")

      # Clickable sort headers exist
      assert has_element?(view, "th[phx-click=sort][phx-value-field=id]")
      assert has_element?(view, "th[phx-click=sort][phx-value-field=description]")
      assert has_element?(view, "th[phx-click=sort][phx-value-field=devices]")

      # Clicking toggles sort direction
      html = view |> element("th[phx-value-field=id]") |> render_click()
      assert html =~ "\u25BC"
    end

    test "sort_profiles sorts by device count", %{conn: _conn} do
      alias YellowDog.Console.NetbootLive.ProfilesLive

      profiles = [
        %{id: "alpha", description: "A"},
        %{id: "beta", description: "B"},
        %{id: "gamma", description: "C"}
      ]

      usage = %{"beta" => 5, "gamma" => 2}

      sorted = ProfilesLive.sort_profiles(profiles, "devices", "desc", usage)
      assert Enum.map(sorted, & &1.id) == ["beta", "gamma", "alpha"]
    end

    test "sort_profiles sorts by id descending", %{conn: _conn} do
      alias YellowDog.Console.NetbootLive.ProfilesLive

      profiles = [
        %{id: "alpha", description: "A"},
        %{id: "charlie", description: "C"},
        %{id: "beta", description: "B"}
      ]

      sorted = ProfilesLive.sort_profiles(profiles, "id", "desc", %{})
      assert Enum.map(sorted, & &1.id) == ["charlie", "beta", "alpha"]
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

    test "kernel and initrd inputs have datalist for autocomplete", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/profiles/new")

      assert has_element?(view, "input[name='profile[kernel]'][list='tftp-files']")
      assert has_element?(view, "input[name='profile[initrd]'][list='tftp-files']")
      assert has_element?(view, "input[name='profile[installer_image]'][list='tftp-files']")
    end

    test "has manifest form fields", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/profiles/new")

      assert has_element?(view, "select[name='profile[disk_layout]']")
      assert has_element?(view, "select[name='profile[slot_strategy]']")
      assert has_element?(view, "input[name='profile[flake]']")
    end

    test "has breadcrumb navigation", %{conn: conn} do
      {:ok, view, html} = live(conn, "/netboot/profiles/new")

      assert html =~ "breadcrumbs"
      assert has_element?(view, "a[href='/netboot']", "Netboot")
      assert has_element?(view, "a[href='/netboot/profiles']", "Profiles")
    end

    test "has cancel and submit buttons", %{conn: conn} do
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

    test "does not show 'Cloned from' when not cloning", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/profiles/new")

      refute html =~ "Cloned from"
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

    test "has delete button in edit mode", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/profiles/test-profile/edit")

      assert has_element?(view, "button[phx-click=delete_profile]", "Delete Profile")
    end

    test "delete button not shown in new mode", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/profiles/new")

      refute has_element?(view, "button[phx-click=delete_profile]")
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

    test "filter_by_search matches kernel and initrd paths" do
      profiles = [
        %{id: "a", description: "Alpha", kernel: "nixos/bzImage", initrd: "nixos/initrd"},
        %{id: "b", description: "Beta", kernel: "ubuntu/vmlinuz", initrd: "ubuntu/initrd"}
      ]

      result = YellowDog.Console.NetbootLive.ProfilesLive.filter_by_search(profiles, "bzImage")
      assert length(result) == 1
      assert hd(result).id == "a"

      result = YellowDog.Console.NetbootLive.ProfilesLive.filter_by_search(profiles, "ubuntu")
      assert length(result) == 1
      assert hd(result).id == "b"
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

    test "new profile editor initializes file_warnings as empty", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/profiles/new")

      # No warning labels should appear initially
      refute html =~ "File not found in TFTP root"
    end
  end

  describe "TFTP Server page" do
    test "mounts with title and breadcrumbs", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/tftp")

      assert html =~ "TFTP Server"
      assert html =~ "Boot file serving"
      assert html =~ "breadcrumbs"
    end

    test "shows status cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/tftp")

      assert html =~ "Status"
      assert html =~ "Port"
      assert html =~ "Files Indexed"
      assert html =~ "Total Size"
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

    test "shows active transfers section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/tftp")

      assert html =~ "Active Transfers"
      assert html =~ "No active transfers"
    end

    test "shows transfer history section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/tftp")

      assert html =~ "Transfer History"
      assert html =~ "No transfer history"
    end

    test "transfer_started adds to active transfers", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/tftp")

      meta = %{
        client_addr: {192, 168, 1, 10},
        file_path: "nixos/bzImage",
        total_size: 8_000_000,
        bytes_sent: 0
      }

      send(view.pid, {:tftp_transfer_started, meta})
      html = render(view)
      assert html =~ "192.168.1.10"
      assert html =~ "nixos/bzImage"
    end

    test "transfer_complete moves to history", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/tftp")

      meta = %{
        client_addr: {10, 0, 0, 1},
        file_path: "rescue/initrd",
        total_size: 4_000_000,
        bytes_sent: 4_000_000
      }

      send(view.pid, {:tftp_transfer_started, meta})
      html = render(view)
      assert html =~ "10.0.0.1"

      complete = Map.merge(meta, %{duration: 1500, bytes: 4_000_000})
      send(view.pid, {:tftp_transfer_complete, complete})
      html = render(view)
      # Should be in history now, not active
      assert html =~ "Complete"
      assert html =~ "1.5s"
    end

    test "history filter works", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/tftp")

      # Add a transfer to history
      meta = %{
        client_addr: {172, 16, 0, 5},
        file_path: "ubuntu/vmlinuz",
        total_size: 10_000_000,
        bytes_sent: 10_000_000,
        duration: 2000,
        bytes: 10_000_000
      }

      send(view.pid, {:tftp_transfer_complete, meta})

      html =
        view
        |> element("input[name=filter]")
        |> render_change(%{"filter" => "ubuntu"})

      assert html =~ "ubuntu/vmlinuz"
    end

    test "filtered_history/2 filters by client and file", _context do
      alias YellowDog.Console.NetbootLive.TftpLive

      history = [
        %{client_addr: {10, 0, 0, 1}, file_path: "nixos/bzImage", bytes: 100, duration: 50},
        %{client_addr: {192, 168, 1, 1}, file_path: "ubuntu/vmlinuz", bytes: 200, duration: 100}
      ]

      assert length(TftpLive.filtered_history(history, "nixos")) == 1
      assert length(TftpLive.filtered_history(history, "192.168")) == 1
      assert length(TftpLive.filtered_history(history, "")) == 2
    end

    test "has export CSV buttons for history and files", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/tftp")

      assert has_element?(view, "button#export-history-csv")
      assert has_element?(view, "button#export-files-csv")
    end

    test "flatten_tree/1 extracts files from nested tree", _context do
      alias YellowDog.Console.NetbootLive.TftpLive

      tree = [
        %{type: :directory, name: "nixos", children: [
          %{type: :file, name: "bzImage", path: "nixos/bzImage", size: 8000},
          %{type: :file, name: "initrd", path: "nixos/initrd", size: 4000}
        ]},
        %{type: :file, name: "pxelinux.0", path: "pxelinux.0", size: 100}
      ]

      files = TftpLive.flatten_tree(tree)
      assert length(files) == 3
      paths = Enum.map(files, & &1.path)
      assert "nixos/bzImage" in paths
      assert "nixos/initrd" in paths
      assert "pxelinux.0" in paths
    end

    test "flatten_tree/1 handles empty tree", _context do
      alias YellowDog.Console.NetbootLive.TftpLive
      assert TftpLive.flatten_tree([]) == []
    end

    test "transfer history has sortable column headers", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/tftp")

      # Add transfers to history so headers render
      meta1 = %{client_addr: {10, 0, 0, 1}, file_path: "a.bin", total_size: 100, bytes_sent: 100, duration: 50, bytes: 100}
      meta2 = %{client_addr: {10, 0, 0, 2}, file_path: "b.bin", total_size: 200, bytes_sent: 200, duration: 100, bytes: 200}

      send(view.pid, {:tftp_transfer_complete, meta1})
      send(view.pid, {:tftp_transfer_complete, meta2})
      _html = render(view)

      assert has_element?(view, "th[phx-click=sort_history][phx-value-field=time]")
      assert has_element?(view, "th[phx-click=sort_history][phx-value-field=client]")
      assert has_element?(view, "th[phx-click=sort_history][phx-value-field=file]")
      assert has_element?(view, "th[phx-click=sort_history][phx-value-field=size]")
      assert has_element?(view, "th[phx-click=sort_history][phx-value-field=status]")
    end

    test "sort_history/3 sorts by size", _context do
      alias YellowDog.Console.NetbootLive.TftpLive

      history = [
        %{client_addr: {10, 0, 0, 1}, file_path: "a", bytes: 100, duration: 50},
        %{client_addr: {10, 0, 0, 2}, file_path: "b", bytes: 500, duration: 80},
        %{client_addr: {10, 0, 0, 3}, file_path: "c", bytes: 200, duration: 30}
      ]

      sorted = TftpLive.sort_history(history, "size", "desc")
      assert Enum.map(sorted, & &1.bytes) == [500, 200, 100]
    end

    test "delete_file event shows error when service unavailable", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/tftp")

      html = view |> render_hook("delete_file", %{"path" => "test/file.bin"})
      assert html =~ "Failed to delete"
    end

    test "shows live indicator", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/tftp")

      assert html =~ "animate-pulse"
      assert html =~ "Live"
    end
  end

  describe "Boot Log page" do
    test "mounts with title and breadcrumbs", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/log")

      assert html =~ "Boot Log"
      assert html =~ "Real-time netboot activity"
      assert html =~ "breadcrumbs"
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

    test "shows paused indicator when paused", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/log")

      html = view |> element("button", "Pause") |> render_click()
      assert html =~ "Paused"
      refute html =~ "animate-pulse"
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

    test "level filter dropdown is present", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/log")

      assert has_element?(view, "select[name=level]")
    end

    test "level filter works", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/log")

      html = view |> element("select[name=level]") |> render_change(%{"level" => "error"})
      assert html =~ "Boot Log"
    end

    test "log table has Level column header", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/log")

      assert html =~ "<th>Level</th>"
    end

    test "device_state_changed to :failed uses warning level", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/log")

      send(view.pid, {:device_state_changed, %{mac: "AA:BB:CC:DD:EE:FF", state: :failed}})
      html = render(view)
      assert html =~ "warning"
      assert html =~ "failed"
    end

    test "device_registered uses info level", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/log")

      send(view.pid, {:device_registered, %{mac: "11:22:33:44:55:66"}})
      html = render(view)
      assert html =~ "info"
      assert html =~ "registered"
    end

    test "tftp_request_rejected uses error level", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/log")

      send(view.pid, {:tftp_request_rejected, %{file: "missing.bin", reason: "not found"}})
      html = render(view)
      assert html =~ "error"
      assert html =~ "rejected"
    end

    test "shows stats cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/log")

      assert html =~ "Total Entries"
      assert html =~ "Errors"
      assert html =~ "Warnings"
      assert html =~ "Buffer"
    end

    test "stats update when events arrive", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/log")

      send(view.pid, {:tftp_request_rejected, %{file: "bad.bin", reason: "not found"}})
      send(view.pid, {:device_state_changed, %{mac: "AA:BB:CC:DD:EE:FF", state: :failed}})
      send(view.pid, {:device_registered, %{mac: "11:22:33:44:55:66"}})
      html = render(view)

      # Should show the count breakdown in stats
      assert html =~ "Total Entries"
    end

    test "shows live indicator", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/log")

      assert html =~ "animate-pulse"
      assert html =~ "Live"
    end
  end

  describe "Boot Log filtering" do
    alias YellowDog.Console.NetbootLive.LogLive

    test "filtered_entries with level filter 'error' returns only errors" do
      entries = [
        %{type: "device", level: "info", message: "registered", time: DateTime.utc_now()},
        %{type: "tftp", level: "error", message: "rejected", time: DateTime.utc_now()},
        %{type: "device", level: "warning", message: "failed", time: DateTime.utc_now()}
      ]

      result = LogLive.filtered_entries(entries, "", "all", "error")
      assert length(result) == 1
      assert hd(result).level == "error"
    end

    test "filtered_entries with level filter 'warning' returns warnings and errors" do
      entries = [
        %{type: "device", level: "info", message: "registered", time: DateTime.utc_now()},
        %{type: "tftp", level: "error", message: "rejected", time: DateTime.utc_now()},
        %{type: "device", level: "warning", message: "failed", time: DateTime.utc_now()}
      ]

      result = LogLive.filtered_entries(entries, "", "all", "warning")
      assert length(result) == 2
      levels = Enum.map(result, & &1.level)
      assert "error" in levels
      assert "warning" in levels
    end

    test "filter_by_level 'all' returns everything" do
      entries = [
        %{level: "info"}, %{level: "warning"}, %{level: "error"}
      ]

      assert length(LogLive.filter_by_level(entries, "all")) == 3
    end

    test "filter_by_level 'info' returns everything (info includes all)" do
      entries = [
        %{level: "info"}, %{level: "warning"}, %{level: "error"}
      ]

      assert length(LogLive.filter_by_level(entries, "info")) == 3
    end
  end

  describe "NetbootComponents.format_time_ago/1" do
    alias YellowDog.Console.NetbootComponents

    test "returns '-' for nil" do
      assert NetbootComponents.format_time_ago(nil) == "-"
    end

    test "returns 'just now' for recent timestamps" do
      assert NetbootComponents.format_time_ago(DateTime.utc_now()) == "just now"
    end

    test "returns minutes ago" do
      ts = DateTime.add(DateTime.utc_now(), -300, :second)
      assert NetbootComponents.format_time_ago(ts) == "5m ago"
    end

    test "returns hours ago" do
      ts = DateTime.add(DateTime.utc_now(), -7200, :second)
      assert NetbootComponents.format_time_ago(ts) == "2h ago"
    end

    test "returns days ago" do
      ts = DateTime.add(DateTime.utc_now(), -172_800, :second)
      assert NetbootComponents.format_time_ago(ts) == "2d ago"
    end

    test "returns date for old timestamps" do
      ts = DateTime.add(DateTime.utc_now(), -700_000, :second)
      assert NetbootComponents.format_time_ago(ts) =~ ~r/^\d{4}-\d{2}-\d{2}$/
    end
  end
end
