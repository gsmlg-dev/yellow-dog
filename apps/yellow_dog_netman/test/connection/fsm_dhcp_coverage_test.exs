defmodule YellowDog.Netman.Connection.FSMDhcpCoverageTest do
  @moduledoc """
  Tests covering the DHCP start success path in Connection.FSM (line 544).

  The Logger.info("DHCP started for ...") line is only reached when
  YellowDog.DhcpClient.start_interface/2 returns {:ok, pid}.

  For fake/random interface names, read_mac/1 fails (no sysfs entry) and
  start_interface returns {:error, {:mac_detection_failed, ...}}, so line 544
  is never reached in ordinary FSM tests.

  Strategy: use the real loopback interface "lo", which has a valid sysfs MAC
  entry at /sys/class/net/lo/address ("00:00:00:00:00:00"). In test mode,
  DhcpSocket.UdpFallback opens a generic UDP socket (port 0, no interface
  binding), so start_interface succeeds regardless of the interface state.
  The FSM stays in :configuring waiting for a lease that never arrives,
  confirming line 544 was executed.
  """
  use ExUnit.Case

  alias YellowDog.Netman.Connection.FSM
  alias YellowDog.Netman.Connection.Supervisor, as: ConnSupervisor
  alias YellowDog.Netman.Types.Profile
  alias YellowDog.Netman.Test.MockNetlink

  @moduletag :capture_log

  # Loopback always has /sys/class/net/lo/address = "00:00:00:00:00:00"
  # so read_mac("lo") returns {:ok, <<0, 0, 0, 0, 0, 0>>}.
  @loopback "lo"

  describe "DHCP start success path (FSM line 544)" do
    test "Logger.info fires when DhcpClient.start_interface succeeds on loopback" do
      # Guard: only run on Linux systems with loopback sysfs MAC entry
      if not File.exists?("/sys/class/net/#{@loopback}/address") do
        :ok
      else
        profile_id = "fsm-dhcp-lo-#{:rand.uniform(65_535)}"

        profile = %Profile{
          id: profile_id,
          type: :ethernet,
          interface: @loopback,
          autoconnect: true,
          autoconnect_priority: 100,
          ethernet: %{mtu: nil},
          ipv4: %{method: :auto, address: nil, gateway: nil, dns: []},
          ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
        }

        # Clean up any stale FSM or DhcpClient for "lo" from a prior run
        ConnSupervisor.stop_connection(@loopback)
        YellowDog.DhcpClient.stop_interface(@loopback)

        # Register profile so ReconciliationEngine does not auto-deactivate
        YellowDog.Netman.ProfileStore.put(profile_id, profile)

        on_exit(fn ->
          ConnSupervisor.stop_connection(@loopback)
          YellowDog.DhcpClient.stop_interface(@loopback)
          YellowDog.Netman.ProfileStore.delete(profile_id)
          MockNetlink.link_removed(@loopback)
        end)

        # Start FSM — begins in :unavailable (no link in ETS yet)
        {:ok, fsm_pid} = ConnSupervisor.start_connection(@loopback, profile)

        # Trigger link_up with carrier → FSM transitions:
        #   :unavailable → :disconnected (auto_activate) → :prepare → :configuring
        # In :configuring, configure_ip fires with ipv4.method == :auto:
        #   → start_dhcp(data) → apply_dhcp_start("lo")
        #   → DhcpClient.start_interface("lo", mode: :hook)
        #   → resolve_mac("lo") reads /sys/class/net/lo/address → {:ok, mac}
        #   → DynamicSupervisor.start_child with UdpFallback socket → {:ok, pid}
        #   → Logger.info("DHCP started for lo")  ← LINE 544 ←
        MockNetlink.link_up(@loopback, carrier: true)

        # Allow time for FSM to traverse through all state transitions
        Process.sleep(300)

        # If line 544 was hit (DHCP started successfully), the FSM stays in
        # :configuring waiting for a lease that never arrives.
        # If DHCP failed, the FSM would have sent itself {:dhcp_lease_failed, reason}
        # and transitioned to a retry/failed state within this window.
        {:ok, state_info} = FSM.get_state(fsm_pid)

        assert state_info.state == :configuring,
               "Expected FSM in :configuring (DHCP started OK on loopback), got #{state_info.state}"
      end
    end
  end
end
