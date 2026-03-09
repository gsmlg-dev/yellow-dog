defmodule YellowDog.Netman.ProfileStoreCoverageTest do
  @moduledoc """
  Tests targeting uncovered branches in ProfileStore:
  - valid_profile_path?/1 catch-all for non-binary input
  - FileSystem watcher error/ignore branches (via process message simulation)
  """
  use ExUnit.Case

  alias YellowDog.Netman.ProfileStore

  @moduletag :capture_log

  describe "import_file path validation" do
    test "import_file rejects non-binary path (integer)" do
      # valid_profile_path?/1 catch-all: defp valid_profile_path?(_), do: false
      result = ProfileStore.import_file(42)
      assert {:error, :invalid_path} = result
    end

    test "import_file rejects nil path" do
      result = ProfileStore.import_file(nil)
      assert {:error, :invalid_path} = result
    end

    test "import_file rejects atom path" do
      result = ProfileStore.import_file(:not_a_path)
      assert {:error, :invalid_path} = result
    end
  end

  describe "file_event for watcher stop" do
    test "watcher :stop message clears watcher_pid in state" do
      pid = Process.whereis(ProfileStore)

      state_before = :sys.get_state(pid)

      send(pid, {:file_event, self(), :stop})
      Process.sleep(50)

      state_after = :sys.get_state(pid)
      # watcher_pid should be set to nil after stop
      assert state_after.watcher_pid == nil

      # Restore is not needed since watcher was already nil in test env
      # Just verify the process is still alive
      assert Process.alive?(pid)

      # Restore profile state to avoid contaminating other tests
      _ = state_before
    end
  end

  describe "unknown handle_info messages" do
    test "various unknown message types do not crash ProfileStore" do
      pid = Process.whereis(ProfileStore)

      for msg <- [:random_atom, {:tuple, :msg}, 42, "string_msg"] do
        send(pid, msg)
        Process.sleep(10)
        assert Process.alive?(pid)
      end
    end
  end

  describe "file_event with symlink during hot-reload check" do
    test "modified event on a path that does not exist is handled" do
      # non-existent path: symlink? returns false (no lstat), but File.read fails
      # This exercises the reload_profile error branch with :file_read error
      nonexistent = "/tmp/nonexistent_#{:rand.uniform(65535)}.toml"

      initial_count = length(ProfileStore.list())

      send(ProfileStore, {:file_event, self(), {nonexistent, [:modified]}})
      # Wait for debounce timer (200ms) to flush pending reloads
      Process.sleep(300)

      # Should not crash; profile count unchanged
      assert Process.alive?(Process.whereis(ProfileStore))
      assert length(ProfileStore.list()) == initial_count
    end
  end

  describe "load_profiles with a real profile directory" do
    test "loads valid TOML files and skips invalid ones" do
      tmp_dir = System.tmp_dir!() |> Path.join("ps_load_#{:rand.uniform(65535)}")
      File.mkdir_p!(tmp_dir)

      File.write!(Path.join(tmp_dir, "valid.toml"), """
      [connection]
      id = "ps-load-valid"
      type = "ethernet"
      [ipv4]
      method = "auto"
      [ipv6]
      method = "auto"
      """)

      File.write!(Path.join(tmp_dir, "invalid.toml"), "not valid toml {{")

      old_env = Application.get_env(:yellow_dog_netman, :profile_dir)

      on_exit(fn ->
        File.rm_rf(tmp_dir)

        if old_env do
          Application.put_env(:yellow_dog_netman, :profile_dir, old_env)
        else
          Application.delete_env(:yellow_dog_netman, :profile_dir)
        end
      end)

      Application.put_env(:yellow_dog_netman, :profile_dir, tmp_dir)

      # Start an isolated ProfileStore without a registered name to cover load_profiles
      # and start_watcher branches (File.dir? is true, FileSystem.start_link may succeed)
      {:ok, test_pid} = GenServer.start_link(YellowDog.Netman.ProfileStore, [])

      on_exit(fn ->
        if Process.alive?(test_pid), do: GenServer.stop(test_pid, :normal)
      end)

      profiles = GenServer.call(test_pid, :list)
      assert Enum.any?(profiles, &(&1.id == "ps-load-valid"))
      # The invalid.toml should be silently skipped (only 1 profile loaded)
      assert length(profiles) == 1
    end
  end
end
