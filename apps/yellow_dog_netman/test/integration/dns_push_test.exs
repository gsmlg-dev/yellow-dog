defmodule YellowDog.Netman.Integration.DnsPushTest do
  @moduledoc """
  Tests verifying that push_dns/reset_dns in Connection.FSM actually call
  YellowDog.Resolved when the module is available.

  Covers FSM lines 677-679 (set_link_dns) and 688 (reset_link_dns) which are
  normally uncovered because YellowDog.Resolved is not loaded in the test env.
  """
  use ExUnit.Case

  alias YellowDog.Netman.Connection
  alias YellowDog.Netman.ProfileStore
  alias YellowDog.Netman.Test.MockNetlink
  alias YellowDog.Netman.Types.Profile

  @moduletag :capture_log

  setup do
    iface = "dnspush_#{:rand.uniform(65535)}"

    # Store test PID so the mock can send messages back
    :persistent_term.put(:dns_push_test_pid, self())

    # Replace YellowDog.Resolved with a mock that sends messages back to the test.
    # The real module is loaded (in-umbrella dep) but its LinkDns GenServer isn't running,
    # so we must purge and replace it with our mock.
    :code.purge(YellowDog.Resolved)
    :code.delete(YellowDog.Resolved)

    Module.create(
      YellowDog.Resolved,
      quote do
        def set_link_dns(interface, config) do
          pid = :persistent_term.get(:dns_push_test_pid, nil)
          if pid, do: send(pid, {:resolved_set_link_dns, interface, config})
          :ok
        end

        def reset_link_dns(interface) do
          pid = :persistent_term.get(:dns_push_test_pid, nil)
          if pid, do: send(pid, {:resolved_reset_link_dns, interface})
          :ok
        end
      end,
      Macro.Env.location(__ENV__)
    )

    on_exit(fn ->
      Connection.Supervisor.stop_connection(iface)
      ProfileStore.delete("dns-push-#{iface}")
      :persistent_term.erase(:dns_push_test_pid)

      :code.delete(YellowDog.Resolved)
      :code.purge(YellowDog.Resolved)
    end)

    %{iface: iface}
  end

  test "push_dns calls YellowDog.Resolved.set_link_dns on activation", %{iface: iface} do
    profile = %Profile{
      id: "dns-push-#{iface}",
      type: :ethernet,
      interface: iface,
      autoconnect: true,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{
        method: :manual,
        address: "10.70.0.10/24",
        gateway: "10.70.0.1",
        dns: ["8.8.8.8", "1.1.1.1"]
      },
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    ProfileStore.put(profile.id, profile)
    MockNetlink.link_up(iface, carrier: true)
    Process.sleep(50)

    {:ok, _pid} = Connection.Supervisor.start_connection(iface, profile)
    Process.sleep(100)

    # Add address so ip_check passes → transitions to :activated → calls push_dns
    MockNetlink.address_added(iface, "10.70.0.10/24")

    # Wait for FSM to reach :activated and call push_dns → set_link_dns
    assert_receive {:resolved_set_link_dns, ^iface, config}, 5_000
    assert is_list(config.servers)
    assert length(config.servers) == 2
    assert config.priority == 100
    assert config.search == []
  end

  test "push_dns includes dns_search domains", %{iface: iface} do
    profile = %Profile{
      id: "dns-push-#{iface}",
      type: :ethernet,
      interface: iface,
      autoconnect: true,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{
        method: :manual,
        address: "10.70.0.30/24",
        gateway: "10.70.0.1",
        dns: ["8.8.8.8"],
        dns_search: ["corp.example.com", "internal.local"]
      },
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: [], dns_search: []}
    }

    ProfileStore.put(profile.id, profile)
    MockNetlink.link_up(iface, carrier: true)
    Process.sleep(50)

    {:ok, _pid} = Connection.Supervisor.start_connection(iface, profile)
    Process.sleep(100)

    MockNetlink.address_added(iface, "10.70.0.30/24")

    assert_receive {:resolved_set_link_dns, ^iface, config}, 5_000
    assert config.search == ["corp.example.com", "internal.local"]
  end

  test "push_dns re-pushes DNS on DHCP lease renewal", %{iface: iface} do
    profile = %Profile{
      id: "dns-push-#{iface}",
      type: :ethernet,
      interface: iface,
      autoconnect: true,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{
        method: :manual,
        address: "10.70.0.40/24",
        gateway: "10.70.0.1",
        dns: ["8.8.8.8"]
      },
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    ProfileStore.put(profile.id, profile)
    MockNetlink.link_up(iface, carrier: true)
    Process.sleep(50)

    {:ok, pid} = Connection.Supervisor.start_connection(iface, profile)
    Process.sleep(100)

    MockNetlink.address_added(iface, "10.70.0.40/24")

    # Wait for initial push_dns on activation
    assert_receive {:resolved_set_link_dns, ^iface, _config}, 5_000

    # Simulate DHCP lease renewal with updated DNS servers
    send(
      pid,
      {:dhcp_lease_renewed,
       %{
         ip: "10.70.0.40",
         server: "10.70.0.1",
         lease_time_s: 7200,
         dns_servers: ["1.1.1.1", "9.9.9.9"]
       }}
    )

    # push_dns should be called again with the renewed data
    assert_receive {:resolved_set_link_dns, ^iface, _renewed_config}, 5_000
  end

  test "push_dns includes DHCP domain_name in search domains", %{iface: iface} do
    profile = %Profile{
      id: "dns-push-#{iface}",
      type: :ethernet,
      interface: iface,
      autoconnect: true,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{
        method: :manual,
        address: "10.70.0.50/24",
        gateway: "10.70.0.1",
        dns: ["8.8.8.8"],
        dns_search: ["profile.local"]
      },
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: [], dns_search: []}
    }

    ProfileStore.put(profile.id, profile)
    MockNetlink.link_up(iface, carrier: true)
    Process.sleep(50)

    {:ok, pid} = Connection.Supervisor.start_connection(iface, profile)
    Process.sleep(100)

    MockNetlink.address_added(iface, "10.70.0.50/24")

    # Wait for initial push_dns on activation (no DHCP domain yet)
    assert_receive {:resolved_set_link_dns, ^iface, initial_config}, 5_000
    assert initial_config.search == ["profile.local"]

    # Drain any queued set_link_dns messages from reconciliation engine
    Process.sleep(200)
    flush_set_link_dns(iface)

    # Now simulate DHCP lease renewal with domain_name (Option 15)
    send(
      pid,
      {:dhcp_lease_renewed,
       %{
         ip: "10.70.0.50",
         server: "10.70.0.1",
         lease_time_s: 3600,
         dns_servers: ["8.8.8.8"],
         domain_name: "dhcp.example.com"
       }}
    )

    # push_dns should be called again with domain_name in search
    assert_receive {:resolved_set_link_dns, ^iface, config}, 5_000
    assert "profile.local" in config.search
    assert "dhcp.example.com" in config.search
  end

  test "reset_dns calls YellowDog.Resolved.reset_link_dns on deactivation", %{iface: iface} do
    profile = %Profile{
      id: "dns-push-#{iface}",
      type: :ethernet,
      interface: iface,
      autoconnect: true,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{
        method: :manual,
        address: "10.70.0.20/24",
        gateway: "10.70.0.1",
        dns: ["8.8.8.8"]
      },
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    ProfileStore.put(profile.id, profile)
    MockNetlink.link_up(iface, carrier: true)
    Process.sleep(50)

    {:ok, _pid} = Connection.Supervisor.start_connection(iface, profile)
    Process.sleep(100)

    MockNetlink.address_added(iface, "10.70.0.20/24")

    # Wait for activation (push_dns)
    assert_receive {:resolved_set_link_dns, ^iface, _config}, 5_000

    # Now deactivate — should call reset_link_dns via deactivating :cleanup
    {:ok, pid} = Connection.Supervisor.find_connection(iface)
    Connection.FSM.deactivate(pid)

    assert_receive {:resolved_reset_link_dns, ^iface}, 5_000
  end

  test "push_dns called on late dhcp_lease_acquired in activated state", %{iface: iface} do
    profile = %Profile{
      id: "dns-push-#{iface}",
      type: :ethernet,
      interface: iface,
      autoconnect: true,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{
        method: :manual,
        address: "10.70.0.60/24",
        gateway: "10.70.0.1",
        dns: ["8.8.8.8"]
      },
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    ProfileStore.put(profile.id, profile)
    MockNetlink.link_up(iface, carrier: true)
    Process.sleep(50)

    {:ok, pid} = Connection.Supervisor.start_connection(iface, profile)
    Process.sleep(100)

    MockNetlink.address_added(iface, "10.70.0.60/24")

    # Wait for initial push_dns on activation
    assert_receive {:resolved_set_link_dns, ^iface, _config}, 5_000

    # Drain any queued set_link_dns messages
    Process.sleep(200)
    flush_set_link_dns(iface)

    # Simulate a late DHCP lease acquisition (as if dual-stack SLAAC arrived first)
    send(
      pid,
      {:dhcp_lease_acquired,
       %{
         ip: "10.70.0.60",
         server: "10.70.0.1",
         lease_time_s: 3600,
         dns_servers: ["1.1.1.1", "9.9.9.9"]
       }}
    )

    # push_dns should be called with the DHCP-provided DNS servers merged
    assert_receive {:resolved_set_link_dns, ^iface, config}, 5_000

    # Should include both profile DNS and DHCP DNS
    server_strings =
      Enum.map(config.servers, fn ip -> ip |> :inet.ntoa() |> List.to_string() end)

    assert "8.8.8.8" in server_strings
    assert "1.1.1.1" in server_strings
    assert "9.9.9.9" in server_strings
  end

  test "push_dns calls reset_link_dns when no DNS servers configured", %{iface: iface} do
    profile = %Profile{
      id: "dns-push-#{iface}",
      type: :ethernet,
      interface: iface,
      autoconnect: true,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{
        method: :manual,
        address: "10.70.0.70/24",
        gateway: "10.70.0.1",
        dns: []
      },
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    ProfileStore.put(profile.id, profile)
    MockNetlink.link_up(iface, carrier: true)
    Process.sleep(50)

    {:ok, _pid} = Connection.Supervisor.start_connection(iface, profile)
    Process.sleep(100)

    MockNetlink.address_added(iface, "10.70.0.70/24")

    # With no DNS servers in profile or lease, push_dns should call reset_link_dns
    assert_receive {:resolved_reset_link_dns, ^iface}, 5_000
  end

  defp flush_set_link_dns(iface) do
    receive do
      {:resolved_set_link_dns, ^iface, _} -> flush_set_link_dns(iface)
    after
      0 -> :ok
    end
  end
end
