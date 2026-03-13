defmodule YellowDog.Netman.Connection.LeaseCoordinatorTest do
  use ExUnit.Case, async: false

  alias YellowDog.Netman.Connection.LeaseCoordinator

  setup do
    # Registry and LeaseCoordinator are started by the app supervisor.
    # Just verify they're running.
    assert Process.whereis(YellowDog.Netman.Registry),
           "YellowDog.Netman.Registry must be running"

    assert Process.whereis(LeaseCoordinator),
           "LeaseCoordinator must be running"

    :ok
  end

  describe "handle_telemetry/4" do
    test "routes :bound event as :dhcp_lease_acquired to FSM" do
      interface = "eth_coord_#{:erlang.unique_integer([:positive])}"
      register_self_as_fsm(interface)

      :telemetry.execute(
        [:yellow_dog, :dhcp_client, :lease, :bound],
        %{lease_time_s: 3600, handshake_duration_ms: 50},
        %{interface: interface, ip: "10.0.0.5", server: "10.0.0.1"}
      )

      assert_receive {:dhcp_lease_acquired, lease_info}, 1000
      assert lease_info.ip == "10.0.0.5"
      assert lease_info.server == "10.0.0.1"
      assert lease_info.lease_time_s == 3600
    end

    test "routes :renewed event as :dhcp_lease_renewed to FSM" do
      interface = "eth_coord_#{:erlang.unique_integer([:positive])}"
      register_self_as_fsm(interface)

      :telemetry.execute(
        [:yellow_dog, :dhcp_client, :lease, :renewed],
        %{lease_time_s: 7200},
        %{interface: interface, ip: "10.0.0.5"}
      )

      assert_receive {:dhcp_lease_renewed, lease_info}, 1000
      assert lease_info.ip == "10.0.0.5"
      assert lease_info.lease_time_s == 7200
    end

    test "routes :expired event as :dhcp_lease_expired to FSM" do
      interface = "eth_coord_#{:erlang.unique_integer([:positive])}"
      register_self_as_fsm(interface)

      :telemetry.execute(
        [:yellow_dog, :dhcp_client, :lease, :expired],
        %{},
        %{interface: interface, ip: "10.0.0.5"}
      )

      assert_receive {:dhcp_lease_expired, :expired}, 1000
    end

    test "drops events for unregistered interfaces" do
      :telemetry.execute(
        [:yellow_dog, :dhcp_client, :lease, :bound],
        %{lease_time_s: 3600},
        %{interface: "unknown_iface", ip: "10.0.0.5"}
      )

      refute_receive {:dhcp_lease_acquired, _}, 200
    end

    test "drops events without interface in metadata" do
      :telemetry.execute(
        [:yellow_dog, :dhcp_client, :lease, :bound],
        %{lease_time_s: 3600},
        %{ip: "10.0.0.5"}
      )

      refute_receive {:dhcp_lease_acquired, _}, 200
    end
  end

  describe "handle_telemetry/4 direct" do
    test "handles events via function call directly" do
      interface = "eth_direct_#{:erlang.unique_integer([:positive])}"
      register_self_as_fsm(interface)

      LeaseCoordinator.handle_telemetry(
        [:yellow_dog, :dhcp_client, :lease, :bound],
        %{lease_time_s: 1800},
        %{interface: interface, ip: "10.0.0.77", server: "10.0.0.1"},
        nil
      )

      assert_receive {:dhcp_lease_acquired, lease_info}, 1000
      assert lease_info.ip == "10.0.0.77"
    end
  end

  describe "dns_servers and domain_name passthrough" do
    test ":bound event includes dns_servers and domain_name in lease info" do
      interface = "eth_dns_#{:erlang.unique_integer([:positive])}"
      register_self_as_fsm(interface)

      :telemetry.execute(
        [:yellow_dog, :dhcp_client, :lease, :bound],
        %{lease_time_s: 3600},
        %{
          interface: interface,
          ip: "10.0.0.10",
          server: "10.0.0.1",
          dns_servers: ["8.8.8.8", "1.1.1.1"],
          domain_name: "corp.internal"
        }
      )

      assert_receive {:dhcp_lease_acquired, lease_info}, 1000
      assert lease_info.dns_servers == ["8.8.8.8", "1.1.1.1"]
      assert lease_info.domain_name == "corp.internal"
    end
  end

  describe "unknown event type" do
    test "unknown telemetry event type is forwarded as dhcp_unknown_event" do
      interface = "eth_unk_#{:erlang.unique_integer([:positive])}"
      register_self_as_fsm(interface)

      LeaseCoordinator.handle_telemetry(
        [:yellow_dog, :dhcp_client, :lease, :released],
        %{},
        %{interface: interface, ip: "10.0.0.5"},
        nil
      )

      assert_receive {:dhcp_unknown_event, :released}, 1000
    end
  end

  defp register_self_as_fsm(interface) do
    Registry.register(YellowDog.Netman.Registry, {:connection, interface}, nil)
  end
end
