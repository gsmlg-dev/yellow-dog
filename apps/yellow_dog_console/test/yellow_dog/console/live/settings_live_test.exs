defmodule YellowDog.Console.SettingsLiveTest do
  use YellowDog.Console.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias YellowDog.Console.ConfigManager
  alias YellowDog.Console.Settings.ConfigurationVersion

  setup do
    # Create temporary config file for testing
    config_dir = System.tmp_dir!()
    config_path = Path.join(config_dir, "test_config_#{:rand.uniform(100_000)}.toml")

    # Write default test configuration
    default_config = """
    [core]
    dns = true
    mdns = true
    dhcpv4 = false
    dhcpv6 = false

    [dns]
    listen = "0.0.0.0"
    port = 5353

    [mdns]
    listen = "0.0.0.0"
    port = 5353
    mode = "responder"

    [dhcpv4]
    listen = "0.0.0.0"
    port = 6767

    [dhcpv6]
    listen = "::"
    port = 5667
    """

    File.write!(config_path, default_config)

    # Configure test environment
    Application.put_env(:yellow_dog_console, :config_path, config_path)

    # Start ConfigurationVersion Agent if not already started
    case Process.whereis(ConfigurationVersion) do
      nil -> start_supervised!(ConfigurationVersion)
      _pid -> :ok
    end

    on_exit(fn ->
      # Clean up config file and backups
      File.rm_rf(config_dir)
    end)

    %{config_path: config_path}
  end

  describe "SettingsLive mount" do
    test "successfully mounts with valid configuration", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/settings")

      assert html =~ "Service Settings"
      assert html =~ "Configure YellowDog network services"
      assert has_element?(view, "button[phx-value-tab='dns']")
      assert has_element?(view, "button[phx-value-tab='mdns']")
      assert has_element?(view, "button[phx-value-tab='dhcpv4']")
      assert has_element?(view, "button[phx-value-tab='dhcpv6']")
    end

    test "displays current configuration version", %{conn: conn, config_path: config_path} do
      version_info = ConfigurationVersion.get_version(config_path)
      {:ok, _view, html} = live(conn, ~p"/settings")

      assert html =~ "Config Version: #{version_info.version}"
    end

    test "loads DNS service configuration correctly", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      # Check DNS tab is active by default
      assert has_element?(view, "button.tab.tab-active[phx-value-tab='dns']")

      # Verify DNS form fields are populated
      assert has_element?(view, "input[name='service_configuration[listen]'][value='0.0.0.0']")
      assert has_element?(view, "input[name='service_configuration[port]'][value='5353']")
      assert has_element?(view, "input[name='service_configuration[enabled]'][checked]")
    end

    test "handles missing configuration file gracefully", %{conn: conn} do
      # Set non-existent config path
      Application.put_env(:yellow_dog_console, :config_path, "/nonexistent/config.toml")

      {:ok, view, _html} = live(conn, ~p"/settings")

      # Page should load without crashing, showing empty state
      rendered = render(view)
      assert rendered =~ "Service Settings"
      assert rendered =~ "Config Version: 0"
      # Should show form with default/empty values
      assert has_element?(view, "form")
    end
  end

  describe "SettingsLive tab navigation" do
    test "switches between tabs on click", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      # Initially on DNS tab
      assert has_element?(view, "button.tab.tab-active[phx-value-tab='dns']")

      # Click mDNS tab
      view
      |> element("button[phx-value-tab='mdns']")
      |> render_click()

      assert has_element?(view, "button.tab.tab-active[phx-value-tab='mdns']")
      refute has_element?(view, "button.tab.tab-active[phx-value-tab='dns']")

      # Click DHCPv4 tab
      view
      |> element("button[phx-value-tab='dhcpv4']")
      |> render_click()

      assert has_element?(view, "button.tab.tab-active[phx-value-tab='dhcpv4']")

      # Click back to DNS
      view
      |> element("button[phx-value-tab='dns']")
      |> render_click()

      assert has_element?(view, "button.tab.tab-active[phx-value-tab='dns']")
    end

    test "preserves form state when switching tabs", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      # Modify DNS configuration
      view
      |> form("form", service_configuration: %{listen: "127.0.0.1", port: 5454})
      |> render_change()

      # Switch to mDNS tab
      view
      |> element("button[phx-value-tab='mdns']")
      |> render_click()

      # Switch back to DNS tab
      view
      |> element("button[phx-value-tab='dns']")
      |> render_click()

      # Verify DNS form still has modified values
      assert has_element?(view, "input[name='service_configuration[listen]'][value='127.0.0.1']")
      assert has_element?(view, "input[name='service_configuration[port]'][value='5454']")
    end
  end

  describe "SettingsLive DNS configuration validation" do
    test "validates listen address format", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      # Enter invalid IP address
      html =
        view
        |> form("form", service_configuration: %{listen: "999.999.999.999", port: 53})
        |> render_change()

      assert html =~ "must be a valid IP address"
      assert has_element?(view, "input.input-error[name='service_configuration[listen]']")
    end

    test "validates port range", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      # Enter port below range
      html =
        view
        |> form("form", service_configuration: %{listen: "0.0.0.0", port: 0})
        |> render_change()

      assert html =~ "must be greater than 0"

      # Enter port above range
      html =
        view
        |> form("form", service_configuration: %{listen: "0.0.0.0", port: 99999})
        |> render_change()

      assert html =~ "must be less than or equal to 65535"
    end

    test "disables save button when validation fails", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      # Enter invalid data
      view
      |> form("form", service_configuration: %{listen: "invalid", port: 53})
      |> render_change()

      # Save button should be disabled
      assert has_element?(view, "button[type='submit'].btn-disabled")
    end

    test "enables save button when all fields are valid", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      # Enter valid data
      view
      |> form("form", service_configuration: %{listen: "127.0.0.1", port: 5353, enabled: true})
      |> render_change()

      # Save button should be enabled
      refute has_element?(view, "button[type='submit'].btn-disabled")
    end
  end

  describe "SettingsLive DNS configuration save" do
    test "successfully saves valid DNS configuration", %{conn: conn, config_path: config_path} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      # Modify and save DNS configuration
      html =
        view
        |> form("form", service_configuration: %{listen: "127.0.0.1", port: 5454, enabled: true})
        |> render_submit()

      # Verify flash message
      assert html =~ "Configuration saved successfully"

      # Verify configuration was persisted to file
      {:ok, config} = ConfigManager.load_config(config_path)
      assert config["dns"]["listen"] == "127.0.0.1"
      assert config["dns"]["port"] == 5454
      assert config["core"]["dns"] == true
    end

    test "creates backup before saving", %{conn: conn, config_path: config_path} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      # Save configuration
      view
      |> form("form", service_configuration: %{listen: "127.0.0.1", port: 5353, enabled: true})
      |> render_submit()

      # Verify backup was created
      backup_dir = Path.dirname(config_path)
      base_name = Path.basename(config_path)

      {:ok, files} = File.ls(backup_dir)
      backup_files = Enum.filter(files, &String.starts_with?(&1, "#{base_name}.backup."))

      assert length(backup_files) > 0
    end

    test "increments version after successful save", %{conn: conn, config_path: config_path} do
      initial_version = ConfigurationVersion.get_version(config_path).version

      {:ok, view, _html} = live(conn, ~p"/settings")

      # Save configuration
      view
      |> form("form", service_configuration: %{listen: "127.0.0.1", port: 5353, enabled: true})
      |> render_submit()

      # Verify version was incremented
      new_version = ConfigurationVersion.get_version(config_path).version
      assert new_version == initial_version + 1
    end

    test "prevents save when validation errors exist", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      # Attempt to save invalid configuration
      html =
        view
        |> form("form", service_configuration: %{listen: "invalid", port: 99999, enabled: true})
        |> render_submit()

      # Verify error message
      assert html =~ "Please fix validation errors before saving"
    end
  end

  describe "SettingsLive apply changes" do
    test "shows apply button when pending changes exist", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      # Save configuration (creates pending changes)
      view
      |> form("form", service_configuration: %{listen: "127.0.0.1", port: 5454, enabled: true})
      |> render_submit()

      # Verify apply button appears with pending badge
      assert has_element?(view, "button[phx-click='apply_changes_dns']")
      assert has_element?(view, ".badge", "Pending Changes")
    end

    test "hides apply button when no pending changes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      # No changes made
      refute has_element?(view, "button[phx-click='apply_changes_dns']")
      assert has_element?(view, ".badge", "Saved")
    end

    test "applies changes and restarts service", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      # Save configuration
      view
      |> form("form", service_configuration: %{listen: "127.0.0.1", port: 5454, enabled: true})
      |> render_submit()

      # Click apply changes
      view
      |> element("button[phx-click='apply_changes_dns']")
      |> render_click()

      # Note: ServiceManager.apply_and_restart will fail in test environment
      # because services aren't actually running. We're testing the UI flow.
      # In real implementation, this would trigger service restart.

      # Verify UI feedback (error expected in test env)
      assert render(view) =~ "Failed to restart service"
    end
  end

  describe "SettingsLive optimistic locking conflict" do
    test "detects concurrent modification and shows conflict modal", %{
      conn: conn,
      config_path: config_path
    } do
      {:ok, view, _html} = live(conn, ~p"/settings")

      # Simulate external modification (another user/process)
      {:ok, _config} = ConfigManager.load_config(config_path)

      # Use the correct update format for ConfigManager
      updates = %{"dns.port" => 9999}
      ConfigManager.save_config(config_path, updates)
      ConfigurationVersion.increment_version()

      # Attempt to save from LiveView (should detect conflict)
      view
      |> form("form", service_configuration: %{listen: "127.0.0.1", port: 5454, enabled: true})
      |> render_submit()

      # Verify conflict modal is shown
      html = render(view)
      assert html =~ "Configuration Conflict Detected"
      assert html =~ "modified by another user"
    end

    test "reload button in conflict modal refreshes configuration", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      # Trigger conflict (simplified - in real test would need concurrent modification)
      # For now, just test the reload functionality

      html =
        view
        |> element("button[phx-click='reload_config']")
        |> render_click()

      assert html =~ "Configuration reloaded from disk"
    end
  end

  describe "SettingsLive configuration reload" do
    test "reloads configuration from disk", %{conn: conn, config_path: config_path} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      # Externally modify configuration file
      ConfigManager.save_config(config_path, %{"dns.port" => 7777})

      # Reload configuration in LiveView
      html =
        view
        |> element("button[phx-click='reload_config']")
        |> render_click()

      # Verify new configuration is loaded
      assert has_element?(view, "input[name='service_configuration[port]'][value='7777']")
      assert html =~ "Configuration reloaded from disk"
    end

    test "clears pending changes on reload", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      # Make changes
      view
      |> form("form", service_configuration: %{listen: "127.0.0.1", port: 5454, enabled: true})
      |> render_submit()

      # Verify pending changes badge
      assert has_element?(view, ".badge", "Pending Changes")

      # Reload configuration
      view
      |> element("button[phx-click='reload_config']")
      |> render_click()

      # Verify pending changes cleared
      assert has_element?(view, ".badge", "Saved")
      refute has_element?(view, "button[phx-click='apply_changes_dns']")
    end
  end

  describe "SettingsLive configuration persistence" do
    test "persists enabled/disabled toggle", %{conn: conn, config_path: config_path} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      # Disable DNS service
      view
      |> form("form", service_configuration: %{listen: "0.0.0.0", port: 5353, enabled: false})
      |> render_submit()

      # Verify persisted to file
      {:ok, config} = ConfigManager.load_config(config_path)
      assert config["core"]["dns"] == false
    end

    test "preserves TOML section comments", %{conn: conn, config_path: config_path} do
      # Add comments to config file
      config_with_comments = """
      # Core service configuration
      [core]
      dns = true
      mdns = true
      dhcpv4 = false
      dhcpv6 = false

      # DNS configuration
      [dns]
      listen = "0.0.0.0"
      port = 5353

      # mDNS configuration
      [mdns]
      listen = "0.0.0.0"
      port = 5353
      mode = "responder"

      [dhcpv4]
      listen = "0.0.0.0"
      port = 6767

      [dhcpv6]
      listen = "::"
      port = 5667
      """

      File.write!(config_path, config_with_comments)

      {:ok, view, _html} = live(conn, ~p"/settings")

      # Modify DNS port
      view
      |> form("form", service_configuration: %{listen: "0.0.0.0", port: 5454, enabled: true})
      |> render_submit()

      # Verify section comments are preserved (inline comments are not preserved)
      content = File.read!(config_path)
      assert content =~ "# Core service configuration"
      assert content =~ "# DNS configuration"
      assert content =~ "port = 5454"
    end

    test "handles multiple sequential saves correctly", %{conn: conn, config_path: config_path} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      # First save
      view
      |> form("form", service_configuration: %{listen: "127.0.0.1", port: 5353, enabled: true})
      |> render_submit()

      # Second save
      view
      |> form("form", service_configuration: %{listen: "0.0.0.0", port: 5454, enabled: false})
      |> render_submit()

      # Third save
      view
      |> form("form", service_configuration: %{listen: "192.168.1.1", port: 5555, enabled: true})
      |> render_submit()

      # Verify final state
      {:ok, config} = ConfigManager.load_config(config_path)
      assert config["dns"]["listen"] == "192.168.1.1"
      assert config["dns"]["port"] == 5555
      assert config["core"]["dns"] == true
    end
  end

  describe "SettingsLive mDNS configuration" do
    test "loads mDNS configuration correctly", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      # Switch to mDNS tab
      view
      |> element("button[phx-value-tab='mdns']")
      |> render_click()

      # Verify mDNS form fields are populated from config
      assert has_element?(view, "input[name='service_configuration[listen]'][value='0.0.0.0']")
      assert has_element?(view, "input[name='service_configuration[port]'][value='5353']")
      assert has_element?(view, "input[name='service_configuration[enabled]'][checked]")
      assert has_element?(view, "select[name='service_configuration[mode]']")
    end

    test "validates mDNS mode field is required", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      # Switch to mDNS tab
      view
      |> element("button[phx-value-tab='mdns']")
      |> render_click()

      # Try to save without mode (by clearing it)
      html =
        view
        |> form("form",
          service_configuration: %{listen: "0.0.0.0", port: 5353, enabled: true, mode: ""}
        )
        |> render_submit()

      assert html =~ "can&#39;t be blank" or html =~ "is invalid"
    end

    test "successfully saves valid mDNS configuration", %{conn: conn, config_path: config_path} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      # Switch to mDNS tab
      view
      |> element("button[phx-value-tab='mdns']")
      |> render_click()

      # Modify and save mDNS configuration
      html =
        view
        |> form("form",
          service_configuration: %{listen: "127.0.0.1", port: 5454, enabled: true, mode: "hybrid"}
        )
        |> render_submit()

      # Verify flash message
      assert html =~ "Configuration saved successfully"

      # Verify configuration was persisted to file
      {:ok, config} = ConfigManager.load_config(config_path)
      assert config["mdns"]["listen"] == "127.0.0.1"
      assert config["mdns"]["port"] == 5454
      assert config["mdns"]["mode"] == "hybrid"
      assert config["core"]["mdns"] == true
    end

    test "toggles mDNS service enabled status", %{conn: conn, config_path: config_path} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      # Switch to mDNS tab
      view
      |> element("button[phx-value-tab='mdns']")
      |> render_click()

      # Disable mDNS service
      view
      |> form("form",
        service_configuration: %{listen: "0.0.0.0", port: 5353, enabled: false, mode: "responder"}
      )
      |> render_submit()

      # Verify persisted to file
      {:ok, config} = ConfigManager.load_config(config_path)
      assert config["core"]["mdns"] == false
    end

    test "validates mode must be responder or hybrid", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      # Switch to mDNS tab
      view
      |> element("button[phx-value-tab='mdns']")
      |> render_click()

      # The select dropdown should only show valid options
      # This test verifies the component structure
      assert has_element?(
               view,
               "select[name='service_configuration[mode]'] option[value='responder']"
             )

      assert has_element?(
               view,
               "select[name='service_configuration[mode]'] option[value='hybrid']"
             )
    end

    test "preserves mDNS changes when switching tabs", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      # Switch to mDNS tab
      view
      |> element("button[phx-value-tab='mdns']")
      |> render_click()

      # Modify mDNS configuration
      view
      |> form("form",
        service_configuration: %{listen: "192.168.1.1", port: 5454, enabled: true, mode: "hybrid"}
      )
      |> render_change()

      # Switch to DNS tab
      view
      |> element("button[phx-value-tab='dns']")
      |> render_click()

      # Switch back to mDNS tab
      view
      |> element("button[phx-value-tab='mdns']")
      |> render_click()

      # Verify mDNS form still has modified values
      assert has_element?(
               view,
               "input[name='service_configuration[listen]'][value='192.168.1.1']"
             )

      assert has_element?(view, "input[name='service_configuration[port]'][value='5454']")

      assert has_element?(
               view,
               "select[name='service_configuration[mode]'] option[value='hybrid'][selected]"
             )
    end

    test "shows apply button when mDNS has pending changes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      # Switch to mDNS tab
      view
      |> element("button[phx-value-tab='mdns']")
      |> render_click()

      # Save configuration (creates pending changes)
      view
      |> form("form",
        service_configuration: %{listen: "127.0.0.1", port: 5454, enabled: true, mode: "hybrid"}
      )
      |> render_submit()

      # Verify apply button appears
      assert has_element?(view, "button[phx-click='apply_changes_mdns']")
      assert has_element?(view, ".badge", "Pending Changes")
    end
  end
end
