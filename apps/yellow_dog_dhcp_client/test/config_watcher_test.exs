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

    test "emits config_watcher:reconciled telemetry when interfaces change" do
      ref = make_ref()
      self_pid = self()

      :telemetry.attach(
        "test-cw-reconciled-#{inspect(ref)}",
        [:yellow_dog, :dhcp_client, :config_watcher, :reconciled],
        fn _event, measurements, metadata, _config ->
          send(self_pid, {:reconciled, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("test-cw-reconciled-#{inspect(ref)}") end)

      # Set a config with a non-existent interface — reconcile fires because
      # the set of interfaces changed (added one)
      Application.delete_env(:yellow_dog_dhcp_client, :config)
      ConfigWatcher.reload()

      Application.put_env(:yellow_dog_dhcp_client, :config, %{
        "nonexistent_cw_telem_iface" => %{"mode" => "standalone"}
      })

      ConfigWatcher.reload()

      assert_receive {:reconciled, measurements, _metadata}, 2_000
      assert measurements.added >= 1
    end

    test "emits reconciled telemetry with removed count when interface disappears" do
      unique = System.unique_integer([:positive])
      iface = "nonexistent_cw_rm_#{unique}"
      ref = make_ref()
      self_pid = self()

      # Seed the interface into last_config first
      Application.put_env(:yellow_dog_dhcp_client, :config, %{iface => %{"mode" => "standalone"}})
      ConfigWatcher.reload()

      # Attach after the add so we only capture the removal event
      handler_id = "test-cw-removed-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:yellow_dog, :dhcp_client, :config_watcher, :reconciled],
        fn _event, measurements, _metadata, _config ->
          if measurements.removed > 0 do
            send(self_pid, {:removed, measurements})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # Remove the interface from config and reload — should fire removed >= 1
      Application.delete_env(:yellow_dog_dhcp_client, :config)
      ConfigWatcher.reload()

      assert_receive {:removed, measurements}, 2_000
      assert measurements.removed >= 1
    end

    test "emits reconciled telemetry with changed count when interface config changes" do
      unique = System.unique_integer([:positive])
      iface = "nonexistent_cw_chg_#{unique}"
      ref = make_ref()
      self_pid = self()

      # Seed with standalone mode (no telemetry handler yet)
      Application.put_env(:yellow_dog_dhcp_client, :config, %{iface => %{"mode" => "standalone"}})
      ConfigWatcher.reload()

      # Now attach and change the mode
      handler_id = "test-cw-changed-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:yellow_dog, :dhcp_client, :config_watcher, :reconciled],
        fn _event, measurements, _metadata, _config ->
          if measurements.changed > 0 do
            send(self_pid, {:changed, measurements})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Application.put_env(:yellow_dog_dhcp_client, :config, %{iface => %{"mode" => "hook"}})
      ConfigWatcher.reload()

      assert_receive {:changed, measurements}, 2_000
      assert measurements.changed >= 1
    end

    test "does not emit reconciled telemetry when config is unchanged" do
      unique = System.unique_integer([:positive])
      iface = "nonexistent_cw_idempotent_#{unique}"
      ref = make_ref()
      self_pid = self()

      # Seed the interface
      Application.put_env(:yellow_dog_dhcp_client, :config, %{iface => %{"mode" => "standalone"}})
      ConfigWatcher.reload()

      # Attach and reload again with the same config — should not fire
      handler_id = "test-cw-idempotent-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:yellow_dog, :dhcp_client, :config_watcher, :reconciled],
        fn _event, measurements, _metadata, _config ->
          send(self_pid, {:reconciled, measurements})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      ConfigWatcher.reload()

      refute_receive {:reconciled, _}, 500
    end
  end
end
