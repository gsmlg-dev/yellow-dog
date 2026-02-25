defmodule YellowDog.DhcpClient.ConfigWatcherTest do
  use ExUnit.Case, async: false

  alias YellowDog.DhcpClient.ConfigWatcher

  # Tests use async: false because they modify Application env and the global
  # ConfigWatcher state.

  setup do
    prev_config = Application.get_env(:yellow_dog_dhcp_client, :config)
    prev_config_file = Application.get_env(:yellow_dog_dhcp_client, :config_file)

    on_exit(fn ->
      if prev_config,
        do: Application.put_env(:yellow_dog_dhcp_client, :config, prev_config),
        else: Application.delete_env(:yellow_dog_dhcp_client, :config)

      if prev_config_file,
        do: Application.put_env(:yellow_dog_dhcp_client, :config_file, prev_config_file),
        else: Application.delete_env(:yellow_dog_dhcp_client, :config_file)
    end)

    :ok
  end

  # -- status/0 --

  describe "status/0" do
    test "returns a map with expected keys" do
      status = ConfigWatcher.status()

      assert is_map(status)
      assert Map.has_key?(status, :config_file)
      assert Map.has_key?(status, :watching)
      assert Map.has_key?(status, :reload_count)
      assert Map.has_key?(status, :last_reload_at)
      assert Map.has_key?(status, :interfaces)
    end

    test "interfaces is a list" do
      status = ConfigWatcher.status()
      assert is_list(status.interfaces)
    end

    test "reload_count is non-negative integer" do
      status = ConfigWatcher.status()
      assert is_integer(status.reload_count)
      assert status.reload_count >= 0
    end

    test "watching is boolean" do
      status = ConfigWatcher.status()
      assert is_boolean(status.watching)
    end
  end

  # -- reload/0 --

  describe "reload/0" do
    test "returns :ok when no config is set" do
      Application.delete_env(:yellow_dog_dhcp_client, :config)

      assert ConfigWatcher.reload() == :ok
    end

    test "increments reload_count on each call" do
      Application.delete_env(:yellow_dog_dhcp_client, :config)

      before_count = ConfigWatcher.status().reload_count

      assert ConfigWatcher.reload() == :ok
      assert ConfigWatcher.reload() == :ok

      after_count = ConfigWatcher.status().reload_count
      assert after_count >= before_count + 2
    end

    test "updates last_reload_at" do
      Application.delete_env(:yellow_dog_dhcp_client, :config)

      assert ConfigWatcher.reload() == :ok

      status = ConfigWatcher.status()
      assert %DateTime{} = status.last_reload_at
    end

    test "reload with interface config attempts to start interface (may fail on MAC detection)" do
      Application.put_env(:yellow_dog_dhcp_client, :config, %{
        "interface" => "nonexistent_test_iface",
        "mode" => "standalone"
      })

      # reload/0 always returns :ok even when individual interface starts fail
      # (start_interface failures are logged but don't abort reconciliation)
      assert ConfigWatcher.reload() == :ok
    end
  end
end
