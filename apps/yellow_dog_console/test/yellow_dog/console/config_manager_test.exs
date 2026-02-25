defmodule YellowDog.Console.ConfigManagerTest do
  use ExUnit.Case, async: true

  alias YellowDog.Console.ConfigManager

  @test_config_dir "test/fixtures/config"
  @test_config_path Path.join(@test_config_dir, "test_config.toml")

  setup do
    # Create test directory
    File.mkdir_p!(@test_config_dir)

    # Create test configuration file
    test_config = """
    # Test Configuration
    [core]
    dns = true
    mdns = false

    [dns]
    listen = "0.0.0.0"
    port = 53

    [mdns]
    listen = "0.0.0.0"
    port = 5353
    """

    File.write!(@test_config_path, test_config)

    on_exit(fn ->
      # Cleanup test files
      File.rm_rf!(@test_config_dir)
    end)

    {:ok, config_path: @test_config_path}
  end

  describe "load_config/1" do
    test "loads valid TOML configuration", %{config_path: path} do
      assert {:ok, config} = ConfigManager.load_config(path)
      assert %{"core" => %{"dns" => true}} = config
      assert %{"dns" => %{"port" => 53}} = config
    end

    test "returns default config for missing file" do
      assert {:ok, config} = ConfigManager.load_config("/nonexistent/path.toml")
      assert config["core"]["dns"] == true
      assert config["dns"]["port"] == 53
      assert config["dhcpv4"]["port"] == 67
    end

    @tag :capture_log
    test "returns error for corrupted TOML" do
      corrupt_path = Path.join(@test_config_dir, "corrupt.toml")
      File.write!(corrupt_path, "this is not valid TOML {{{")

      assert {:error, :invalid_toml} = ConfigManager.load_config(corrupt_path)
    end
  end

  describe "save_config/3" do
    test "updates configuration values", %{config_path: path} do
      updates = %{
        "dns.port" => 5353,
        "dns.listen" => "127.0.0.1"
      }

      assert :ok = ConfigManager.save_config(path, updates, backup: false)

      # Verify updates applied
      {:ok, config} = ConfigManager.load_config(path)
      assert config["dns"]["port"] == 5353
      assert config["dns"]["listen"] == "127.0.0.1"

      # Verify valid TOML with section structure
      content = File.read!(path)
      assert content =~ "[core]"
      assert content =~ "[dns]"
    end

    test "can add new sections via updates", %{config_path: path} do
      updates = %{"netboot.enabled" => true, "netboot.tftp_port" => 69}

      assert :ok = ConfigManager.save_config(path, updates, backup: false)

      {:ok, config} = ConfigManager.load_config(path)
      assert config["netboot"]["enabled"] == true
      assert config["netboot"]["tftp_port"] == 69
      # Original sections preserved
      assert config["core"]["dns"] == true
    end

    test "creates backup before saving by default", %{config_path: path} do
      updates = %{"dns.port" => 5353}

      assert :ok = ConfigManager.save_config(path, updates)

      backups = ConfigManager.list_backups(path)
      assert length(backups) == 1
    end

    test "skips backup when backup: false option", %{config_path: path} do
      updates = %{"dns.port" => 5353}

      assert :ok = ConfigManager.save_config(path, updates, backup: false)

      backups = ConfigManager.list_backups(path)
      assert length(backups) == 0
    end

    test "verifies TOML after save by default", %{config_path: path} do
      # This would normally catch corruption, but we'll test valid case
      updates = %{"dns.port" => 8080}

      assert :ok = ConfigManager.save_config(path, updates)

      {:ok, config} = ConfigManager.load_config(path)
      assert config["dns"]["port"] == 8080
    end
  end

  describe "create_backup/1" do
    test "creates timestamped backup file", %{config_path: path} do
      assert {:ok, backup_path} = ConfigManager.create_backup(path)

      assert File.exists?(backup_path)
      assert backup_path =~ ~r/\.backup\.\d{8}T\d{6,}Z$/
    end

    @tag :capture_log
    test "returns error for nonexistent file" do
      assert {:error, :file_not_found} =
               ConfigManager.create_backup("/nonexistent/file.toml")
    end

    test "rotates old backups to keep last 10" do
      # Create 15 backups
      for _ <- 1..15 do
        ConfigManager.create_backup(@test_config_path)
        # Ensure unique timestamps
        Process.sleep(10)
      end

      backups = ConfigManager.list_backups(@test_config_path)
      assert length(backups) <= 10
    end
  end

  describe "list_backups/1" do
    test "lists backup files in chronological order", %{config_path: path} do
      # Create multiple backups
      ConfigManager.create_backup(path)
      Process.sleep(10)
      ConfigManager.create_backup(path)
      Process.sleep(10)
      ConfigManager.create_backup(path)

      backups = ConfigManager.list_backups(path)
      assert length(backups) == 3

      # Verify chronological order
      assert backups == Enum.sort(backups)
    end

    test "returns empty list when no backups exist", %{config_path: path} do
      backups = ConfigManager.list_backups(path)
      assert backups == []
    end
  end

  describe "restore_backup/2" do
    test "restores configuration from backup", %{config_path: path} do
      # Create backup of original
      {:ok, backup_path} = ConfigManager.create_backup(path)

      # Modify config
      updates = %{"dns.port" => 9999}
      ConfigManager.save_config(path, updates, backup: false)

      # Restore from backup
      assert :ok = ConfigManager.restore_backup(path, backup_path)

      # Verify restored to original
      {:ok, config} = ConfigManager.load_config(path)
      assert config["dns"]["port"] == 53
    end

    test "creates backup of current config before restoring", %{config_path: path} do
      {:ok, backup_path} = ConfigManager.create_backup(path)

      # Modify config
      ConfigManager.save_config(path, %{"dns.port" => 9999}, backup: false)

      initial_backup_count = length(ConfigManager.list_backups(path))

      # Restore (should create backup first)
      ConfigManager.restore_backup(path, backup_path)

      final_backup_count = length(ConfigManager.list_backups(path))
      assert final_backup_count > initial_backup_count
    end
  end

  describe "create_default_config/1" do
    test "creates valid default configuration" do
      default_path = Path.join(@test_config_dir, "default.toml")

      assert :ok = ConfigManager.create_default_config(default_path)
      assert File.exists?(default_path)

      {:ok, config} = ConfigManager.load_config(default_path)
      assert config["core"]["dns"] == true
      assert config["dns"]["port"] == 53
      assert config["dhcpv4"]["pools"] != nil
    end
  end

  describe "create_minimal_config/1" do
    test "creates valid minimal configuration" do
      minimal_path = Path.join(@test_config_dir, "minimal.toml")

      assert :ok = ConfigManager.create_minimal_config(minimal_path)
      assert File.exists?(minimal_path)

      {:ok, config} = ConfigManager.load_config(minimal_path)
      assert config["core"]["dns"] == false
      assert config["dns"]["port"] == 53
    end
  end
end
