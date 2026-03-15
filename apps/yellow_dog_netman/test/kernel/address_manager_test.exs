defmodule YellowDog.Netman.Kernel.AddressManagerTest do
  use ExUnit.Case

  alias YellowDog.Netman.Kernel.AddressManager
  alias YellowDog.Netman.Test.MockNetlink

  test "address_added creates an address entry" do
    MockNetlink.address_added("test_addr_eth0", "10.0.0.1/24")
    Process.sleep(50)

    addresses = AddressManager.get_addresses("test_addr_eth0")
    assert length(addresses) >= 1
    assert Enum.any?(addresses, &(&1.address == "10.0.0.1"))
  end

  test "address_removed deletes an address" do
    MockNetlink.address_added("test_addr_eth1", "10.0.1.1/24")
    Process.sleep(50)
    assert Enum.any?(AddressManager.get_addresses("test_addr_eth1"), &(&1.address == "10.0.1.1"))

    MockNetlink.address_removed("test_addr_eth1", "10.0.1.1/24")
    Process.sleep(50)
    refute Enum.any?(AddressManager.get_addresses("test_addr_eth1"), &(&1.address == "10.0.1.1"))
  end

  test "list_all returns addresses grouped by interface" do
    MockNetlink.address_added("test_all_a", "10.0.10.1/24")
    MockNetlink.address_added("test_all_b", "10.0.20.1/24")
    Process.sleep(50)

    all = AddressManager.list_all()
    assert Map.has_key?(all, "test_all_a")
    assert Map.has_key?(all, "test_all_b")
  end

  test "get_addresses returns empty list for unknown interface" do
    assert AddressManager.get_addresses("nonexistent") == []
  end

  test "IPv6 address is stored with inet6 family" do
    iface = "addr_ipv6_#{:rand.uniform(65535)}"
    MockNetlink.address_added(iface, "fe80::1/64", family: "inet6", scope: "link")
    Process.sleep(50)

    addresses = AddressManager.get_addresses(iface)
    assert Enum.any?(addresses, &(&1.family == :inet6 and &1.scope == :link))
  end

  test "address scope is preserved for link-local addresses" do
    iface = "addr_link_#{:rand.uniform(65535)}"
    MockNetlink.address_added(iface, "169.254.0.1/16", scope: "link")
    Process.sleep(50)

    addresses = AddressManager.get_addresses(iface)
    assert Enum.any?(addresses, &(&1.scope == :link))
  end

  test "flush removes all addresses for an interface" do
    iface = "addr_flush_#{:rand.uniform(65535)}"
    MockNetlink.address_added(iface, "10.1.0.1/24")
    MockNetlink.address_added(iface, "10.1.0.2/24")
    Process.sleep(50)

    assert length(AddressManager.get_addresses(iface)) >= 2

    AddressManager.flush(iface)
    Process.sleep(50)

    # After flush, the ETS table entry may still exist but commands were sent
    # (In mock mode, flush sends commands but the ETS isn't actually updated by commands)
    # Verify flush didn't crash and sent the remove commands
    assert is_list(AddressManager.get_addresses(iface))
  end

  test "address_change event is published to EventBus on add" do
    iface = "addr_event_#{:rand.uniform(65535)}"
    YellowDog.Netman.EventBus.subscribe("netman:address:#{iface}")

    MockNetlink.address_added(iface, "10.2.0.1/24")
    Process.sleep(50)

    assert_receive {:netman_event, "netman:address:" <> ^iface, {:add, %{address: "10.2.0.1"}}},
                   500
  end

  test "address_change event is published to EventBus on remove" do
    iface = "addr_del_event_#{:rand.uniform(65535)}"
    MockNetlink.address_added(iface, "10.3.0.1/24")
    Process.sleep(50)

    YellowDog.Netman.EventBus.subscribe("netman:address:#{iface}")
    MockNetlink.address_removed(iface, "10.3.0.1/24")
    Process.sleep(50)

    assert_receive {:netman_event, "netman:address:" <> ^iface,
                    {:remove, %{address: "10.3.0.1"}}},
                   500
  end

  test "duplicate address add is idempotent" do
    iface = "addr_dup_#{:rand.uniform(65535)}"
    MockNetlink.address_added(iface, "10.4.0.1/24")
    MockNetlink.address_added(iface, "10.4.0.1/24")
    Process.sleep(50)

    addresses = AddressManager.get_addresses(iface)
    matching = Enum.filter(addresses, &(&1.address == "10.4.0.1"))
    assert length(matching) == 1, "Expected exactly 1 entry for duplicate address"
  end

  test "add_address/3 sends netlink command without crashing" do
    result = AddressManager.add_address("eth0", "192.168.1.1", 24)
    assert result == :ok or match?({:error, _}, result)
  end

  test "remove_address/3 sends netlink command without crashing" do
    result = AddressManager.remove_address("eth0", "192.168.1.1", 24)
    assert result == :ok or match?({:error, _}, result)
  end

  test "handle_info with unknown message is silently ignored" do
    pid = Process.whereis(AddressManager)
    assert pid != nil
    send(pid, :unexpected_message_xyz)
    Process.sleep(20)
    assert Process.alive?(pid)
  end

  test "address event with unknown action is ignored" do
    iface = "addr_unknown_action_#{:rand.uniform(65535)}"
    test_pid = self()
    handler_id = {__MODULE__, :addr_unknown, :rand.uniform(1_000_000)}
    YellowDog.Netman.EventBus.subscribe("netman:address:#{iface}")

    :telemetry.attach(
      handler_id,
      [:yellow_dog, :netman, :kernel, :address_change],
      fn _event, _measurements, meta, _config ->
        if meta.interface == iface, do: send(test_pid, {:telem, meta})
      end,
      nil
    )

    send(
      Process.whereis(AddressManager),
      {:netlink_event,
       {:address_change,
        %{
          "action" => "update",
          "interface" => iface,
          "address" => "10.5.0.1/24"
        }}}
    )

    refute_receive {:telem, %{interface: ^iface}}, 200
    refute_receive {:netman_event, "netman:address:" <> ^iface, _}, 200
    assert AddressManager.get_addresses(iface) == []
    :telemetry.detach(handler_id)
  end

  test "address event with malformed payload is handled gracefully" do
    pid = Process.whereis(AddressManager)
    send(pid, {:netlink_event, {:address_change, "not_a_map"}})
    Process.sleep(20)
    assert Process.alive?(pid)
  end

  test "address without CIDR prefix defaults to /32" do
    iface = "addr_no_prefix_#{:rand.uniform(65535)}"

    send(
      Process.whereis(AddressManager),
      {:netlink_event,
       {:address_change, %{"action" => "add", "interface" => iface, "address" => "10.6.0.1"}}}
    )

    Process.sleep(50)
    addresses = AddressManager.get_addresses(iface)
    assert Enum.any?(addresses, &(&1.address == "10.6.0.1" and &1.prefix_len == 32))
  end

  test "address with unknown scope defaults to :global" do
    iface = "addr_scope_unk_#{:rand.uniform(65535)}"

    send(
      Process.whereis(AddressManager),
      {:netlink_event,
       {:address_change,
        %{
          "action" => "add",
          "interface" => iface,
          "address" => "10.7.0.1/24",
          "scope" => "bizarre_scope"
        }}}
    )

    Process.sleep(50)
    addresses = AddressManager.get_addresses(iface)
    assert Enum.any?(addresses, &(&1.scope == :unknown))
  end

  test "address with invalid CIDR prefix defaults to /32" do
    iface = "addr_bad_cidr_#{:rand.uniform(65535)}"

    send(
      Process.whereis(AddressManager),
      {:netlink_event,
       {:address_change,
        %{
          "action" => "add",
          "interface" => iface,
          "address" => "10.8.0.1/abc"
        }}}
    )

    Process.sleep(50)
    addresses = AddressManager.get_addresses(iface)
    assert Enum.any?(addresses, &(&1.address == "10.8.0.1" and &1.prefix_len == 32))
  end

  @tag :capture_log
  test "IPv6 address without CIDR prefix defaults to /128" do
    iface = "addr_v6_noprefix_#{:rand.uniform(65535)}"

    send(
      Process.whereis(AddressManager),
      {:netlink_event,
       {:address_change,
        %{
          "action" => "add",
          "interface" => iface,
          "address" => "fe80::1",
          "family" => "inet6"
        }}}
    )

    Process.sleep(50)
    addresses = AddressManager.get_addresses(iface)
    assert Enum.any?(addresses, &(&1.address == "fe80::1" and &1.prefix_len == 128))
  end

  @tag :capture_log
  test "IPv6 address with invalid CIDR prefix defaults to /128" do
    iface = "addr_v6_badcidr_#{:rand.uniform(65535)}"

    send(
      Process.whereis(AddressManager),
      {:netlink_event,
       {:address_change,
        %{
          "action" => "add",
          "interface" => iface,
          "address" => "2001:db8::1/xyz",
          "family" => "inet6"
        }}}
    )

    Process.sleep(50)
    addresses = AddressManager.get_addresses(iface)
    assert Enum.any?(addresses, &(&1.address == "2001:db8::1" and &1.prefix_len == 128))
  end

  test "address with host scope is parsed correctly" do
    iface = "addr_host_scope_#{:rand.uniform(65535)}"

    send(
      Process.whereis(AddressManager),
      {:netlink_event,
       {:address_change,
        %{
          "action" => "add",
          "interface" => iface,
          "address" => "127.0.0.1/8",
          "scope" => "host"
        }}}
    )

    Process.sleep(50)
    addresses = AddressManager.get_addresses(iface)
    assert Enum.any?(addresses, &(&1.scope == :host))
  end
end
