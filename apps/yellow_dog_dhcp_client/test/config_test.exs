defmodule YellowDog.DhcpClient.ConfigTest do
  use ExUnit.Case, async: false

  alias YellowDog.DhcpClient.Config
  alias YellowDog.DhcpClient.OSIntegration.{HookNM, Standalone}

  # Config tests are async: false because they use Application.put_env/delete_env

  setup do
    prev_config = Application.get_env(:yellow_dog_dhcp_client, :config)
    prev_config_file = Application.get_env(:yellow_dog_dhcp_client, :config_file)

    on_exit(fn ->
      if prev_config do
        Application.put_env(:yellow_dog_dhcp_client, :config, prev_config)
      else
        Application.delete_env(:yellow_dog_dhcp_client, :config)
      end

      if prev_config_file do
        Application.put_env(:yellow_dog_dhcp_client, :config_file, prev_config_file)
      else
        Application.delete_env(:yellow_dog_dhcp_client, :config_file)
      end
    end)

    :ok
  end

  # -- load/1 --

  describe "load/1" do
    test "loads default config when no application env is set" do
      Application.delete_env(:yellow_dog_dhcp_client, :config)

      config = Config.load("eth0")

      assert config.interface == "eth0"
      assert config.mode == :standalone
      assert config.hostname == nil
      assert config.vendor_class == "YellowDog"
      assert config.selection_window_ms == 1000
      assert config.dad_enabled == true
      assert config.dad_probes == 3
      assert config.dad_wait_ms == 2000
    end

    test "reads hostname from config" do
      Application.put_env(:yellow_dog_dhcp_client, :config, %{"hostname" => "my-node"})
      config = Config.load("eth0")
      assert config.hostname == "my-node"
    end

    test "hostname defaults to nil when not set" do
      Application.put_env(:yellow_dog_dhcp_client, :config, %{"mode" => "standalone"})
      config = Config.load("eth0")
      assert config.hostname == nil
    end

    test "loads standalone sub-config defaults" do
      Application.delete_env(:yellow_dog_dhcp_client, :config)

      config = Config.load("eth0")

      assert config.standalone.manage_routes == true
      assert config.standalone.manage_dns == true
      assert config.standalone.dns_method == :resolvconf
    end

    test "loads hook sub-config defaults" do
      Application.delete_env(:yellow_dog_dhcp_client, :config)

      config = Config.load("eth0")

      assert config.hook.backend == :networkmanager
    end

    test "reads config from Application env with atom keys" do
      Application.put_env(:yellow_dog_dhcp_client, :config, %{
        mode: :hook,
        vendor_class: "CustomVendor",
        selection_window_ms: 500,
        dad_probes: 5,
        dad_wait_ms: 3000
      })

      config = Config.load("wlan0")

      assert config.interface == "wlan0"
      assert config.mode == :hook
      assert config.vendor_class == "CustomVendor"
      assert config.selection_window_ms == 500
      assert config.dad_probes == 5
      assert config.dad_wait_ms == 3000
    end

    test "respects false values in config (dad_enabled: false)" do
      Application.put_env(:yellow_dog_dhcp_client, :config, %{
        dad_enabled: false
      })

      config = Config.load("eth0")

      assert config.dad_enabled == false
    end

    test "reads config from Application env with string keys" do
      Application.put_env(:yellow_dog_dhcp_client, :config, %{
        "mode" => "hook",
        "vendor_class" => "StringVendor",
        "selection_window_ms" => 750
      })

      config = Config.load("eth0")

      assert config.mode == :hook
      assert config.vendor_class == "StringVendor"
      assert config.selection_window_ms == 750
    end

    test "reads named interface section from config" do
      Application.put_env(:yellow_dog_dhcp_client, :config, %{
        "eth0" => %{
          "mode" => "standalone",
          "vendor_class" => "Eth0Vendor"
        },
        "wlan0" => %{
          "mode" => "hook",
          "vendor_class" => "Wlan0Vendor"
        }
      })

      eth0_config = Config.load("eth0")
      assert eth0_config.mode == :standalone
      assert eth0_config.vendor_class == "Eth0Vendor"

      wlan0_config = Config.load("wlan0")
      assert wlan0_config.mode == :hook
      assert wlan0_config.vendor_class == "Wlan0Vendor"
    end

    test "falls back to defaults for unknown mode string" do
      Application.put_env(:yellow_dog_dhcp_client, :config, %{
        "mode" => "invalid_mode_value"
      })

      config = Config.load("eth0")
      assert config.mode == :standalone
    end

    test "parses standalone sub-config from Application env" do
      Application.put_env(:yellow_dog_dhcp_client, :config, %{
        "standalone" => %{
          "dns_method" => "systemd-resolved"
        }
      })

      config = Config.load("eth0")

      assert config.standalone.dns_method == :systemd_resolved
    end

    test "parses standalone dns_method direct from Application env" do
      Application.put_env(:yellow_dog_dhcp_client, :config, %{
        "standalone" => %{
          "dns_method" => "direct"
        }
      })

      config = Config.load("eth0")

      assert config.standalone.dns_method == :direct
    end

    test "parses hook sub-config from Application env" do
      Application.put_env(:yellow_dog_dhcp_client, :config, %{
        "hook" => %{
          "backend" => "systemd-networkd"
        }
      })

      config = Config.load("eth0")

      assert config.hook.backend == :systemd_networkd
    end

    test "falls back to default dns_method for unknown value" do
      Application.put_env(:yellow_dog_dhcp_client, :config, %{
        "standalone" => %{
          "dns_method" => "unknown_method"
        }
      })

      config = Config.load("eth0")
      assert config.standalone.dns_method == :resolvconf
    end

    test "falls back to default hook backend for unknown value" do
      Application.put_env(:yellow_dog_dhcp_client, :config, %{
        "hook" => %{
          "backend" => "unknown_backend"
        }
      })

      config = Config.load("eth0")
      assert config.hook.backend == :networkmanager
    end
  end

  # -- load handles missing config gracefully --

  test "load handles missing config gracefully when config is nil" do
    Application.delete_env(:yellow_dog_dhcp_client, :config)

    # This should not raise, even when YellowDog.Config is not available
    config = Config.load("eth0")

    assert config.interface == "eth0"
    assert config.mode == :standalone
  end

  test "load handles non-map config value gracefully" do
    Application.put_env(:yellow_dog_dhcp_client, :config, "not_a_map")

    config = Config.load("eth0")

    # Should fall back to defaults
    assert config.interface == "eth0"
    assert config.mode == :standalone
  end

  # -- mac parsing --

  describe "mac parsing" do
    test "parses colon-separated MAC from string config" do
      Application.put_env(:yellow_dog_dhcp_client, :config, %{
        "mac" => "AA:BB:CC:DD:EE:FF"
      })

      config = Config.load("eth0")
      assert config.mac == <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>
    end

    test "parses dash-separated MAC from string config" do
      Application.put_env(:yellow_dog_dhcp_client, :config, %{
        "mac" => "AA-BB-CC-DD-EE-FF"
      })

      config = Config.load("eth0")
      assert config.mac == <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>
    end

    test "parses lowercase MAC" do
      Application.put_env(:yellow_dog_dhcp_client, :config, %{
        "mac" => "aa:bb:cc:dd:ee:ff"
      })

      config = Config.load("eth0")
      assert config.mac == <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>
    end

    test "preserves 6-byte binary MAC passed directly" do
      mac = <<0x01, 0x02, 0x03, 0x04, 0x05, 0x06>>

      Application.put_env(:yellow_dog_dhcp_client, :config, %{
        mac: mac
      })

      config = Config.load("eth0")
      assert config.mac == mac
    end

    test "mac defaults to nil when not set" do
      Application.delete_env(:yellow_dog_dhcp_client, :config)
      config = Config.load("eth0")
      assert config.mac == nil
    end

    test "invalid MAC string returns nil" do
      Application.put_env(:yellow_dog_dhcp_client, :config, %{
        "mac" => "not-a-mac"
      })

      config = Config.load("eth0")
      assert config.mac == nil
    end

    test "non-binary non-nil MAC returns nil" do
      Application.put_env(:yellow_dog_dhcp_client, :config, %{
        mac: 12345
      })

      config = Config.load("eth0")
      assert config.mac == nil
    end
  end

  # -- os_integration_module/1 --

  describe "os_integration_module/1" do
    test "returns Standalone for :standalone mode" do
      assert Config.os_integration_module(%{mode: :standalone}) == Standalone
    end

    test "returns HookNM for :hook mode" do
      assert Config.os_integration_module(%{mode: :hook}) == HookNM
    end

    test "returns Standalone for full config struct with standalone mode" do
      Application.delete_env(:yellow_dog_dhcp_client, :config)
      config = Config.load("eth0")

      assert Config.os_integration_module(config) == Standalone
    end

    test "returns HookNM for full config struct with hook mode" do
      Application.put_env(:yellow_dog_dhcp_client, :config, %{mode: :hook})
      config = Config.load("eth0")

      assert Config.os_integration_module(config) == HookNM
    end
  end

  # -- config_file_path/0 --

  describe "config_file_path/0" do
    test "returns nil when no config file is set" do
      Application.delete_env(:yellow_dog_dhcp_client, :config_file)
      Application.delete_env(:yellow_dog, :config_file)

      assert Config.config_file_path() == nil
    end

    test "returns dhcp_client config_file when set" do
      Application.put_env(:yellow_dog_dhcp_client, :config_file, "/etc/yd/dhcp.toml")

      assert Config.config_file_path() == "/etc/yd/dhcp.toml"
    end
  end

  # -- load_all/0 --

  describe "load_all/0" do
    test "returns empty map when no config set" do
      Application.delete_env(:yellow_dog_dhcp_client, :config)

      result = Config.load_all()

      # With no config, load_raw_section returns %{} which has no "interface" key
      # and no sub-maps with "mode" key, so result is %{}
      assert result == %{}
    end

    test "returns single interface config when interface key is present" do
      Application.put_env(:yellow_dog_dhcp_client, :config, %{
        "interface" => "eth0",
        "mode" => "standalone"
      })

      result = Config.load_all()

      assert Map.has_key?(result, "eth0")
      assert result["eth0"].interface == "eth0"
      assert result["eth0"].mode == :standalone
    end

    test "returns multi-interface config" do
      Application.put_env(:yellow_dog_dhcp_client, :config, %{
        "eth0" => %{"mode" => "standalone"},
        "wlan0" => %{"mode" => "hook"}
      })

      result = Config.load_all()

      assert Map.has_key?(result, "eth0")
      assert Map.has_key?(result, "wlan0")
      assert result["eth0"].mode == :standalone
      assert result["wlan0"].mode == :hook
    end

    test "filters out sections without mode key in multi-interface config" do
      Application.put_env(:yellow_dog_dhcp_client, :config, %{
        "eth0" => %{"mode" => "standalone"},
        "metadata" => %{"description" => "not an interface section"}
      })

      result = Config.load_all()

      assert Map.has_key?(result, "eth0")
      refute Map.has_key?(result, "metadata")
    end
  end
end
