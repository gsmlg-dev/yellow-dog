defmodule YellowDogIdentity.RegistryInitTest do
  use ExUnit.Case

  alias YellowDogIdentity.Registry

  describe "init error handling" do
    test "starts successfully with valid data_dir" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "yd_init_test_#{:erlang.unique_integer([:positive])}")

      name = :"init_test_#{:erlang.unique_integer([:positive])}"
      {:ok, pid} = Registry.start_link(data_dir: tmp_dir, name: name)

      assert Process.alive?(pid)
      GenServer.stop(pid)
      File.rm_rf!(tmp_dir)
    end

    test "creates hosts and tokens subdirectories on init" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "yd_init_dirs_#{:erlang.unique_integer([:positive])}")

      name = :"init_dirs_#{:erlang.unique_integer([:positive])}"
      {:ok, pid} = Registry.start_link(data_dir: tmp_dir, name: name)

      assert File.dir?(Path.join(tmp_dir, "hosts"))
      assert File.dir?(Path.join(tmp_dir, "tokens"))

      GenServer.stop(pid)
      File.rm_rf!(tmp_dir)
    end

    test "fails gracefully when data_dir is not writable" do
      # /proc is a read-only filesystem on Linux
      unwritable_dir = "/proc/identity_test_#{:erlang.unique_integer([:positive])}"

      name = :"init_fail_#{:erlang.unique_integer([:positive])}"

      # Trap exits so start_link doesn't crash the test process
      Process.flag(:trap_exit, true)

      assert {:error, {:mkdir_failed, _posix}} =
               Registry.start_link(data_dir: unwritable_dir, name: name)
    end

    test "loads existing host data from disk on restart" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "yd_init_load_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      # Start, add a host, stop
      name1 = :"init_load1_#{:erlang.unique_integer([:positive])}"
      {:ok, pid1} = Registry.start_link(data_dir: tmp_dir, name: name1)

      {:ok, host} =
        YellowDogIdentity.Host.new(%{
          hostname: "init-test",
          ssh_pubkey:
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHUzjC6gKCLjRoHMvMXBx3cCe49wjm69r9B7YBcFcAv1 test@host",
          age_recipient: "age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p"
        })

      :ok = GenServer.call(pid1, {:put_host, host})
      GenServer.stop(pid1)

      # Restart and verify data loaded
      name2 = :"init_load2_#{:erlang.unique_integer([:positive])}"
      {:ok, pid2} = Registry.start_link(data_dir: tmp_dir, name: name2)

      hosts = GenServer.call(pid2, :list_hosts)
      assert length(hosts) == 1
      assert hd(hosts).hostname == "init-test"

      GenServer.stop(pid2)
      File.rm_rf!(tmp_dir)
    end

    test "skips corrupt TOML files without crashing" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "yd_init_corrupt_#{:erlang.unique_integer([:positive])}")

      hosts_dir = Path.join(tmp_dir, "hosts")
      tokens_dir = Path.join(tmp_dir, "tokens")
      File.mkdir_p!(hosts_dir)
      File.mkdir_p!(tokens_dir)

      # Write a corrupt TOML file
      corrupt_path = Path.join(hosts_dir, "corrupt-id.toml")
      File.write!(corrupt_path, "this is not valid TOML [[[[")

      name = :"init_corrupt_#{:erlang.unique_integer([:positive])}"
      {:ok, pid} = Registry.start_link(data_dir: tmp_dir, name: name)

      # Should start successfully, ignoring corrupt file
      assert Process.alive?(pid)
      assert GenServer.call(pid, :list_hosts) == []

      GenServer.stop(pid)
      File.rm_rf!(tmp_dir)
    end

    test "skips TOML files with missing required fields" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "yd_init_missing_#{:erlang.unique_integer([:positive])}")

      hosts_dir = Path.join(tmp_dir, "hosts")
      tokens_dir = Path.join(tmp_dir, "tokens")
      File.mkdir_p!(hosts_dir)
      File.mkdir_p!(tokens_dir)

      # Write a valid TOML but missing required host fields
      incomplete_path = Path.join(hosts_dir, "incomplete-id.toml")

      File.write!(incomplete_path, """
      [host]
      id = "incomplete-id"
      hostname = "partial-host"
      """)

      name = :"init_missing_#{:erlang.unique_integer([:positive])}"
      {:ok, pid} = Registry.start_link(data_dir: tmp_dir, name: name)

      assert Process.alive?(pid)
      assert GenServer.call(pid, :list_hosts) == []

      GenServer.stop(pid)
      File.rm_rf!(tmp_dir)
    end
  end
end
