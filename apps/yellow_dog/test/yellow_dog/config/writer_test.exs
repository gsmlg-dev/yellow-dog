defmodule YellowDog.Config.WriterTest do
  use ExUnit.Case, async: true

  alias YellowDog.Config.Writer

  @test_dir "test/fixtures/writer"

  setup do
    File.mkdir_p!(@test_dir)
    path = Path.join(@test_dir, "config_#{:rand.uniform(100_000)}.toml")

    on_exit(fn -> File.rm_rf!(@test_dir) end)

    %{path: path}
  end

  describe "apply_updates/2" do
    test "updates existing key" do
      config = %{"dns" => %{"port" => 53, "listen" => "0.0.0.0"}}
      result = Writer.apply_updates(config, %{"dns.port" => 5353})

      assert result["dns"]["port"] == 5353
      assert result["dns"]["listen"] == "0.0.0.0"
    end

    test "creates new key in existing section" do
      config = %{"dns" => %{"port" => 53}}
      result = Writer.apply_updates(config, %{"dns.listen" => "127.0.0.1"})

      assert result["dns"]["listen"] == "127.0.0.1"
      assert result["dns"]["port"] == 53
    end

    test "creates entirely new section" do
      config = %{"dns" => %{"port" => 53}}
      result = Writer.apply_updates(config, %{"netboot.enabled" => true})

      assert result["netboot"]["enabled"] == true
      assert result["dns"]["port"] == 53
    end

    test "handles multiple updates at once" do
      config = %{"core" => %{"dns" => true, "mdns" => true}}

      updates = %{
        "core.dns" => false,
        "core.mdns" => false,
        "dns.port" => 5353
      }

      result = Writer.apply_updates(config, updates)

      assert result["core"]["dns"] == false
      assert result["core"]["mdns"] == false
      assert result["dns"]["port"] == 5353
    end

    test "handles deeply nested updates" do
      config = %{"mdns" => %{"services" => %{"format" => "toml"}}}
      result = Writer.apply_updates(config, %{"mdns.services.format" => "json"})

      assert result["mdns"]["services"]["format"] == "json"
    end

    test "handles list values (pools)" do
      config = %{"dhcpv4" => %{"port" => 67}}

      pools = [%{"name" => "pool1", "range_start" => "10.0.0.100"}]
      result = Writer.apply_updates(config, %{"dhcpv4.pools" => pools})

      assert result["dhcpv4"]["pools"] == pools
      assert result["dhcpv4"]["port"] == 67
    end

    test "empty updates returns original config" do
      config = %{"dns" => %{"port" => 53}}
      assert Writer.apply_updates(config, %{}) == config
    end

    test "top-level key update" do
      config = %{"data_dir" => "data"}
      result = Writer.apply_updates(config, %{"data_dir" => "/var/lib/yd"})

      assert result["data_dir"] == "/var/lib/yd"
    end
  end

  describe "write_config/3" do
    test "writes valid config to file", %{path: path} do
      config = %{
        "core" => %{"dns" => true},
        "dns" => %{"listen" => "0.0.0.0", "port" => 53}
      }

      assert :ok = Writer.write_config(path, config)
      assert File.exists?(path)

      # Verify the file is valid TOML
      {:ok, decoded} = Toml.decode_file(path)
      assert decoded["core"]["dns"] == true
      assert decoded["dns"]["port"] == 53
    end

    test "includes header comment", %{path: path} do
      config = %{"dns" => %{"port" => 53}}
      assert :ok = Writer.write_config(path, config)

      content = File.read!(path)
      assert content =~ "# Yellow Dog Configuration"
    end

    test "custom header", %{path: path} do
      config = %{"dns" => %{"port" => 53}}
      assert :ok = Writer.write_config(path, config, header: "# My Config")

      content = File.read!(path)
      assert content =~ "# My Config"
    end

    test "validates before writing", %{path: path} do
      config = %{"dns" => %{"port" => 0}}
      assert {:error, {:validation_failed, _errors}} = Writer.write_config(path, config)

      refute File.exists?(path)
    end

    test "skips validation when validate: false", %{path: path} do
      config = %{"dns" => %{"port" => 0}}
      assert :ok = Writer.write_config(path, config, validate: false)
      assert File.exists?(path)
    end

    test "creates parent directories", %{path: _path} do
      deep_path = Path.join([@test_dir, "sub", "dir", "config.toml"])
      config = %{"dns" => %{"port" => 53}}

      assert :ok = Writer.write_config(deep_path, config)
      assert File.exists?(deep_path)
    end

    test "round-trips full default config", %{path: path} do
      config = YellowDog.Config.Schema.defaults()

      assert :ok = Writer.write_config(path, config, validate: false)

      {:ok, decoded} = Toml.decode_file(path)
      assert decoded == config
    end
  end

  describe "write_defaults/1" do
    test "writes full default config", %{path: path} do
      assert :ok = Writer.write_defaults(path)

      {:ok, decoded} = Toml.decode_file(path)
      assert decoded["core"]["dns"] == true
      assert decoded["dns"]["port"] == 53
      assert decoded["dhcpv4"]["pools"] != nil
    end
  end

  describe "write_minimal/1" do
    test "writes minimal config with all services disabled", %{path: path} do
      assert :ok = Writer.write_minimal(path)

      {:ok, decoded} = Toml.decode_file(path)
      assert decoded["core"]["dns"] == false
      assert decoded["core"]["mdns"] == false
    end
  end

  describe "full pipeline: load → update → write → reload" do
    test "update-then-reload preserves all values", %{path: path} do
      # Write initial config
      initial = %{
        "core" => %{"dns" => true, "mdns" => true, "dhcpv4" => true, "dhcpv6" => true},
        "dns" => %{"listen" => "0.0.0.0", "port" => 53}
      }

      :ok = Writer.write_config(path, initial)

      # Load, apply updates, write back
      {:ok, loaded} = Toml.decode_file(path)
      updated = Writer.apply_updates(loaded, %{"dns.port" => 5353, "dns.listen" => "127.0.0.1"})
      :ok = Writer.write_config(path, updated)

      # Reload and verify
      {:ok, reloaded} = Toml.decode_file(path)
      assert reloaded["dns"]["port"] == 5353
      assert reloaded["dns"]["listen"] == "127.0.0.1"
      assert reloaded["core"]["dns"] == true
    end

    test "adding a new section via update", %{path: path} do
      # Write initial config without netboot section
      initial = %{
        "core" => %{"dns" => true, "mdns" => true, "dhcpv4" => true, "dhcpv6" => true},
        "dns" => %{"listen" => "0.0.0.0", "port" => 53}
      }

      :ok = Writer.write_config(path, initial)

      # Load and add a new section
      {:ok, loaded} = Toml.decode_file(path)

      updated =
        Writer.apply_updates(loaded, %{"netboot.enabled" => true, "netboot.tftp_port" => 69})

      :ok = Writer.write_config(path, updated, validate: false)

      # Reload and verify new section exists
      {:ok, reloaded} = Toml.decode_file(path)
      assert reloaded["netboot"]["enabled"] == true
      assert reloaded["netboot"]["tftp_port"] == 69
    end
  end
end
