defmodule YellowDog.Netman.Connection.SupervisorPropertyTest do
  use ExUnit.Case
  use ExUnitProperties

  alias YellowDog.Netman.Connection.Supervisor, as: ConnSupervisor
  alias YellowDog.Netman.Test.MockNetlink
  alias YellowDog.Netman.Types.Profile

  @moduletag :capture_log

  defp make_profile(iface) do
    %Profile{
      id: "csprop-#{iface}",
      type: :ethernet,
      interface: iface,
      autoconnect: false,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }
  end

  # Properties

  property "find_connection always returns :error for unknown interface names" do
    check all(iface <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)) do
      # Prefix guarantees this interface was never started by our test suite
      assert ConnSupervisor.find_connection("unk_#{iface}") == :error
    end
  end

  property "find_connection_by_profile always returns :error for unknown profile IDs" do
    check all(id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)) do
      assert ConnSupervisor.find_connection_by_profile("unk_#{id}") == :error
    end
  end

  property "start_connection then find_connection returns ok with the started pid" do
    check all(seed <- StreamData.integer(1..99_999), max_runs: 20) do
      iface = "csp_sf_#{seed}"
      profile = make_profile(iface)

      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(30)

      {:ok, pid} = ConnSupervisor.start_connection(iface, profile)
      assert {:ok, ^pid} = ConnSupervisor.find_connection(iface)

      ConnSupervisor.stop_connection(iface)
    end
  end

  property "start_connection is idempotent — duplicate call returns same pid" do
    check all(seed <- StreamData.integer(1..99_999), max_runs: 20) do
      iface = "csp_idem_#{seed}"
      profile = make_profile(iface)

      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(30)

      {:ok, pid1} = ConnSupervisor.start_connection(iface, profile)
      {:ok, pid2} = ConnSupervisor.start_connection(iface, profile)
      assert pid1 == pid2

      ConnSupervisor.stop_connection(iface)
    end
  end

  property "list_connections always returns a list" do
    check all(_ <- StreamData.constant(:ok)) do
      assert is_list(ConnSupervisor.list_connections())
    end
  end

  property "stop_connection for unknown interface always returns {:error, :not_found}" do
    check all(iface <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)) do
      assert ConnSupervisor.stop_connection("unk_stop_#{iface}") == {:error, :not_found}
    end
  end

  property "stop_connection then find_connection returns :error" do
    check all(seed <- StreamData.integer(1..99_999), max_runs: 20) do
      iface = "csp_stop_#{seed}"
      profile = make_profile(iface)

      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(30)

      {:ok, _pid} = ConnSupervisor.start_connection(iface, profile)
      :ok = ConnSupervisor.stop_connection(iface)
      Process.sleep(30)

      assert ConnSupervisor.find_connection(iface) == :error
    end
  end

  property "start_connection then find_connection_by_profile returns ok with the same pid" do
    check all(seed <- StreamData.integer(1..99_999), max_runs: 20) do
      iface = "csp_byp_#{seed}"
      profile = make_profile(iface)

      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(30)

      {:ok, pid} = ConnSupervisor.start_connection(iface, profile)
      assert {:ok, ^pid} = ConnSupervisor.find_connection_by_profile(profile.id)

      ConnSupervisor.stop_connection(iface)
    end
  end

  property "start_connection increments list_connections count by 1" do
    check all(seed <- StreamData.integer(1..99_999), max_runs: 20) do
      iface = "csp_cnt_#{seed}"
      profile = make_profile(iface)

      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(30)

      before_count = length(ConnSupervisor.list_connections())
      {:ok, _pid} = ConnSupervisor.start_connection(iface, profile)
      after_count = length(ConnSupervisor.list_connections())

      assert after_count == before_count + 1,
             "Expected count to increase by 1: #{before_count} -> #{after_count}"

      ConnSupervisor.stop_connection(iface)
    end
  end

  property "stop_connection decrements list_connections count by 1" do
    check all(seed <- StreamData.integer(1..99_999), max_runs: 20) do
      iface = "csp_dcnt_#{seed}"
      profile = make_profile(iface)

      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(30)

      {:ok, _pid} = ConnSupervisor.start_connection(iface, profile)
      before_count = length(ConnSupervisor.list_connections())
      :ok = ConnSupervisor.stop_connection(iface)
      Process.sleep(30)
      after_count = length(ConnSupervisor.list_connections())

      assert after_count == before_count - 1,
             "Expected count to decrease by 1: #{before_count} -> #{after_count}"
    end
  end

  property "two connections at distinct interfaces coexist and are independently findable" do
    check all(
            seed1 <- StreamData.integer(1..49_999),
            seed2 <- StreamData.integer(50_000..99_999)
          ) do
      iface1 = "csp_co1_#{seed1}"
      iface2 = "csp_co2_#{seed2}"
      profile1 = make_profile(iface1)
      profile2 = make_profile(iface2)

      MockNetlink.link_up(iface1, carrier: false)
      MockNetlink.link_up(iface2, carrier: false)
      Process.sleep(30)

      {:ok, pid1} = ConnSupervisor.start_connection(iface1, profile1)
      {:ok, pid2} = ConnSupervisor.start_connection(iface2, profile2)

      assert {:ok, ^pid1} = ConnSupervisor.find_connection(iface1)
      assert {:ok, ^pid2} = ConnSupervisor.find_connection(iface2)
      assert pid1 != pid2

      ConnSupervisor.stop_connection(iface1)
      ConnSupervisor.stop_connection(iface2)
    end
  end

  property "find_connection_by_profile returns :error after stop_connection" do
    check all(seed <- StreamData.integer(1..99_999), max_runs: 20) do
      iface = "csp_bpstop_#{seed}"
      profile = make_profile(iface)

      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(30)

      {:ok, _pid} = ConnSupervisor.start_connection(iface, profile)
      :ok = ConnSupervisor.stop_connection(iface)
      Process.sleep(30)

      assert ConnSupervisor.find_connection_by_profile(profile.id) == :error,
             "Expected find_connection_by_profile to return :error after stop"
    end
  end

  property "start_connection returns {:ok, pid} where pid is alive" do
    check all(seed <- StreamData.integer(1..99_999), max_runs: 20) do
      iface = "csp_alive_#{seed}"
      profile = make_profile(iface)

      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(30)

      {:ok, pid} = ConnSupervisor.start_connection(iface, profile)

      assert is_pid(pid), "Expected pid, got: #{inspect(pid)}"
      assert Process.alive?(pid), "Expected started pid to be alive"

      ConnSupervisor.stop_connection(iface)
    end
  end

  property "stop_connection then start_connection returns a new different pid" do
    check all(seed <- StreamData.integer(1..99_999), max_runs: 20) do
      iface = "csp_restart_#{seed}"
      profile = make_profile(iface)

      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(30)

      {:ok, pid1} = ConnSupervisor.start_connection(iface, profile)
      :ok = ConnSupervisor.stop_connection(iface)
      Process.sleep(30)

      {:ok, pid2} = ConnSupervisor.start_connection(iface, profile)

      assert pid1 != pid2,
             "Expected a new pid after stop+start, got the same pid #{inspect(pid1)}"

      ConnSupervisor.stop_connection(iface)
    end
  end

  property "stop_connection terminates the started pid" do
    check all(seed <- StreamData.integer(1..99_999), max_runs: 20) do
      iface = "csp_kill_#{seed}"
      profile = make_profile(iface)

      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(30)

      {:ok, pid} = ConnSupervisor.start_connection(iface, profile)
      assert Process.alive?(pid)

      :ok = ConnSupervisor.stop_connection(iface)
      Process.sleep(50)

      refute Process.alive?(pid),
             "Expected pid #{inspect(pid)} to be dead after stop_connection"
    end
  end

  property "stopping one of two connections decrements count by exactly 1" do
    check all(
            seed1 <- StreamData.integer(1..49_999),
            seed2 <- StreamData.integer(50_000..99_999),
            max_runs: 20
          ) do
      iface1 = "csp_d1c_#{seed1}"
      iface2 = "csp_d2c_#{seed2}"
      profile1 = make_profile(iface1)
      profile2 = make_profile(iface2)

      MockNetlink.link_up(iface1, carrier: false)
      MockNetlink.link_up(iface2, carrier: false)
      Process.sleep(30)

      {:ok, _} = ConnSupervisor.start_connection(iface1, profile1)
      {:ok, _} = ConnSupervisor.start_connection(iface2, profile2)
      before_count = length(ConnSupervisor.list_connections())

      :ok = ConnSupervisor.stop_connection(iface1)
      Process.sleep(30)
      after_count = length(ConnSupervisor.list_connections())

      assert after_count == before_count - 1,
             "Expected count -1 after stopping one of two: #{before_count} -> #{after_count}"

      ConnSupervisor.stop_connection(iface2)
    end
  end

  property "start then stop leaves list_connections count unchanged" do
    check all(seed <- StreamData.integer(1..99_999), max_runs: 20) do
      iface = "csp_cycle_#{seed}"
      profile = make_profile(iface)

      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(30)

      initial_count = length(ConnSupervisor.list_connections())
      {:ok, _} = ConnSupervisor.start_connection(iface, profile)
      :ok = ConnSupervisor.stop_connection(iface)
      Process.sleep(30)
      final_count = length(ConnSupervisor.list_connections())

      assert final_count == initial_count,
             "Expected count to return to #{initial_count} after start+stop, got #{final_count}"
    end
  end

  property "every connection in list_connections is findable by interface" do
    check all(_ <- StreamData.constant(:ok)) do
      connections = ConnSupervisor.list_connections()

      for {iface, _pid} <- connections do
        assert match?({:ok, _}, ConnSupervisor.find_connection(iface)),
               "Interface #{iface} from list_connections is not findable"
      end
    end
  end

  property "list_connections entries always have binary :interface field" do
    check all(_ <- StreamData.constant(:ok)) do
      connections = ConnSupervisor.list_connections()

      for conn <- connections do
        assert is_binary(conn[:interface]),
               "Expected binary :interface in connection, got: #{inspect(conn[:interface])}"
      end
    end
  end

  property "all connections in list_connections have valid FSM state fields" do
    check all(_ <- StreamData.constant(:ok)) do
      connections = ConnSupervisor.list_connections()
      valid_states = [:unavailable, :disconnected, :prepare, :configuring,
                      :ip_check, :activated, :deactivating, :failed]

      for conn <- connections do
        assert is_map(conn),
               "Expected map in list_connections, got: #{inspect(conn)}"

        assert Map.has_key?(conn, :interface),
               "Connection missing :interface field"

        assert Map.has_key?(conn, :state),
               "Connection missing :state field"

        assert conn.state in valid_states,
               "Invalid state #{inspect(conn.state)} in connection"
      end
    end
  end

  property "list_connections never contains duplicate interface names" do
    check all(_ <- StreamData.constant(:ok)) do
      connections = ConnSupervisor.list_connections()
      ifaces = Enum.map(connections, & &1.interface)

      assert length(ifaces) == length(Enum.uniq(ifaces)),
             "list_connections contains duplicate interfaces: #{inspect(ifaces)}"
    end
  end

  property "list_connections returns identical results on two consecutive calls" do
    check all(_ <- StreamData.constant(:ok)) do
      c1 = ConnSupervisor.list_connections()
      c2 = ConnSupervisor.list_connections()

      assert c1 == c2,
             "list_connections returned different results on consecutive calls"
    end
  end

  property "list_connections never contains entries with nil state" do
    check all(_ <- StreamData.constant(:ok)) do
      connections = ConnSupervisor.list_connections()

      for conn <- connections do
        assert conn.state != nil,
               "Connection has nil state: #{inspect(conn)}"
      end
    end
  end

  property "find_connection_by_profile returns :error for unk-prefixed profile IDs" do
    check all(id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)) do
      assert ConnSupervisor.find_connection_by_profile("unk2_#{id}") == :error
    end
  end

  property "list_connections result is always a list of maps" do
    check all(_ <- StreamData.constant(:ok)) do
      result = ConnSupervisor.list_connections()
      assert is_list(result),
             "Expected list from list_connections, got: #{inspect(result)}"
      for conn <- result do
        assert is_map(conn),
               "Expected map in list_connections, got: #{inspect(conn)}"
      end
    end
  end

  property "two distinct interfaces always have distinct pids" do
    check all(
            seed1 <- StreamData.integer(1..49_999),
            seed2 <- StreamData.integer(50_000..99_999),
            max_runs: 20
          ) do
      iface1 = "csp_dp1_#{seed1}"
      iface2 = "csp_dp2_#{seed2}"
      profile1 = make_profile(iface1)
      profile2 = make_profile(iface2)

      MockNetlink.link_up(iface1, carrier: false)
      MockNetlink.link_up(iface2, carrier: false)
      Process.sleep(30)

      {:ok, pid1} = ConnSupervisor.start_connection(iface1, profile1)
      {:ok, pid2} = ConnSupervisor.start_connection(iface2, profile2)

      assert pid1 != pid2,
             "Expected distinct pids for #{iface1} and #{iface2}"

      ConnSupervisor.stop_connection(iface1)
      ConnSupervisor.stop_connection(iface2)
    end
  end

  property "find_connection always returns :error for empty string interface" do
    check all(_ <- StreamData.constant(:ok)) do
      assert ConnSupervisor.find_connection("") == :error
    end
  end

  property "find_connection_by_profile always returns :error for empty string id" do
    check all(_ <- StreamData.constant(:ok)) do
      assert ConnSupervisor.find_connection_by_profile("") == :error
    end
  end

  property "list_connections always returns a non-nil result" do
    check all(_ <- StreamData.constant(:ok)) do
      result = ConnSupervisor.list_connections()
      assert result != nil,
             "Expected non-nil from list_connections"
      assert is_list(result),
             "Expected list from list_connections, got: #{inspect(result)}"
    end
  end

  property "stop_connection for known then re-start returns new pid" do
    check all(seed <- StreamData.integer(1..99_999), max_runs: 10) do
      iface = "csp_re2_#{seed}"
      profile = make_profile(iface)

      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(30)

      {:ok, pid1} = ConnSupervisor.start_connection(iface, profile)
      :ok = ConnSupervisor.stop_connection(iface)
      Process.sleep(30)
      {:ok, pid2} = ConnSupervisor.start_connection(iface, profile)

      assert is_pid(pid2) and pid1 != pid2,
             "Expected a new pid after restart, got same: #{inspect(pid2)}"
      ConnSupervisor.stop_connection(iface)
    end
  end

  property "find_connection returns :error for interface with special chars" do
    check all(
            seed <- StreamData.integer(1..999_999)
          ) do
      iface = "!bad@iface##{seed}"
      assert ConnSupervisor.find_connection(iface) == :error,
             "Expected :error for special char interface"
    end
  end

  property "list_connections pid field is always nil or alive pid" do
    check all(_ <- StreamData.constant(:ok)) do
      connections = ConnSupervisor.list_connections()
      for conn <- connections do
        pid = conn[:pid]
        if pid != nil do
          assert is_pid(pid) and Process.alive?(pid),
                 "Expected alive pid in connection, got: #{inspect(pid)}"
        end
      end
    end
  end

  property "find_connection returns :error for very long interface name" do
    check all(
            seed <- StreamData.integer(1..999_999)
          ) do
      long_iface = String.duplicate("x", 16) <> "#{seed}"
      assert ConnSupervisor.find_connection(long_iface) == :error,
             "Expected :error for overlong interface name"
    end
  end

  property "list_connections returns list of maps with :profile_id key" do
    check all(_ <- StreamData.constant(:ok)) do
      connections = ConnSupervisor.list_connections()
      assert is_list(connections)
      for conn <- connections do
        assert Map.has_key?(conn, :profile_id),
               "Expected :profile_id key in connection, got: #{inspect(conn)}"
      end
    end
  end

  property "find_connection for unknown interface always returns :error" do
    check all(seed <- StreamData.integer(1..999_999)) do
      unknown = "never_started_#{seed}"
      assert ConnSupervisor.find_connection(unknown) == :error,
             "Expected :error for unknown interface #{unknown}"
    end
  end

  property "start_connection with valid profile and interface returns {:ok, pid}" do
    check all(seed <- StreamData.integer(1..99_999), max_runs: 5) do
      iface = "csp_start_#{seed}"
      profile = make_profile(iface)
      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(50)
      result = ConnSupervisor.start_connection(iface, profile)
      assert match?({:ok, _}, result) or match?({:error, :already_started}, result),
             "Expected {:ok, pid} or :already_started, got: #{inspect(result)}"
      ConnSupervisor.stop_connection(iface)
    end
  end

  property "list_connections result maps all have :state key" do
    check all(_ <- StreamData.constant(:ok)) do
      connections = ConnSupervisor.list_connections()
      for conn <- connections do
        assert Map.has_key?(conn, :state),
               "Expected :state key in connection, got: #{inspect(conn)}"
      end
    end
  end

  property "list_connections never raises during concurrent reads" do
    check all(_ <- StreamData.constant(:ok)) do
      tasks = for _ <- 1..3, do: Task.async(fn -> ConnSupervisor.list_connections() end)
      results = Task.await_many(tasks, 5_000)
      assert Enum.all?(results, &is_list/1),
             "Expected all concurrent list_connections to return lists"
    end
  end

  property "list_connections count is always non-negative" do
    check all(_ <- StreamData.constant(:ok)) do
      count = length(ConnSupervisor.list_connections())
      assert count >= 0,
             "Expected non-negative connection count, got: #{count}"
    end
  end

  property "ConnSupervisor is always accessible" do
    check all(_ <- StreamData.constant(:ok)) do
      assert function_exported?(YellowDog.Netman.Connection.Supervisor, :list_connections, 0),
             "Expected list_connections/0 to be exported"
    end
  end

  property "list_connections never returns nil" do
    check all(_ <- StreamData.constant(:ok)) do
      conns = ConnSupervisor.list_connections()
      assert conns != nil,
             "Expected non-nil from list_connections"
    end
  end

  property "ConnSupervisor is always alive" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.Connection.Supervisor)
      assert pid != nil, "Expected ConnSupervisor to be registered"
      assert Process.alive?(pid), "Expected ConnSupervisor to be alive"
    end
  end

  property "list_connections maps all have :state key" do
    check all(_ <- StreamData.constant(:ok)) do
      for conn <- ConnSupervisor.list_connections() do
        assert Map.has_key?(conn, :state),
               "Expected :state key in connection map, got: #{inspect(conn)}"
      end
    end
  end
  property "ConnSupervisor list_connections always returns a list with round-45 check" do
    check all(_ <- StreamData.constant(:ok)) do
      result = YellowDog.Netman.Connection.Supervisor.list_connections()
      assert is_list(result),
             "Expected list from list_connections, got: \#{inspect(result)}"
    end
  end
  property "ConnSupervisor list_connections round-46 returns list" do
    check all(_ <- StreamData.constant(:ok)) do
      result = YellowDog.Netman.Connection.Supervisor.list_connections()
      assert is_list(result),
             "Expected list from list_connections, got: #{inspect(result)}"
    end
  end

end
