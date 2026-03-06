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
end
