defmodule YellowDog.Resolved.LinkDnsTest do
  use ExUnit.Case, async: false

  alias YellowDog.Resolved.LinkDns

  setup do
    # LinkDns isn't started in test env (app supervisor is empty)
    # Start it manually and the Config GenServer it depends on
    unless Process.whereis(YellowDog.Resolved.Config) do
      start_supervised!({YellowDog.Resolved.Config, YellowDog.Resolved.Config.load()})
    end

    start_supervised!(LinkDns)
    :ok
  end

  test "set_link_dns stores configuration for interface" do
    config = %{
      servers: [{8, 8, 8, 8}, {8, 8, 4, 4}],
      search: ["corp.example.com"],
      priority: 100
    }

    assert :ok = LinkDns.set_link_dns("test_eth0", config)
    stored = LinkDns.get("test_eth0")
    assert stored.servers == [{8, 8, 8, 8}, {8, 8, 4, 4}]
    assert stored.search == ["corp.example.com"]
    assert stored.priority == 100

    # Cleanup
    LinkDns.reset_link_dns("test_eth0")
  end

  test "reset_link_dns removes configuration for interface" do
    LinkDns.set_link_dns("test_eth1", %{
      servers: [{1, 1, 1, 1}],
      search: [],
      priority: 50
    })

    assert LinkDns.get("test_eth1") != nil
    assert :ok = LinkDns.reset_link_dns("test_eth1")
    assert LinkDns.get("test_eth1") == nil
  end

  test "list_all returns all link configurations" do
    LinkDns.set_link_dns("test_list_a", %{servers: [{1, 1, 1, 1}], search: [], priority: 100})
    LinkDns.set_link_dns("test_list_b", %{servers: [{8, 8, 8, 8}], search: [], priority: 50})

    all = LinkDns.list_all()
    assert Map.has_key?(all, "test_list_a")
    assert Map.has_key?(all, "test_list_b")

    LinkDns.reset_link_dns("test_list_a")
    LinkDns.reset_link_dns("test_list_b")
  end

  test "effective_upstreams merges link DNS with global upstreams by priority" do
    LinkDns.set_link_dns("test_prio_high", %{
      servers: [{10, 0, 0, 1}],
      search: [],
      priority: 200
    })

    LinkDns.set_link_dns("test_prio_low", %{
      servers: [{10, 0, 1, 1}],
      search: [],
      priority: 50
    })

    upstreams = LinkDns.effective_upstreams()
    # Higher priority link's servers should come first
    link_idx_high = Enum.find_index(upstreams, &(&1 == {10, 0, 0, 1}))
    link_idx_low = Enum.find_index(upstreams, &(&1 == {10, 0, 1, 1}))
    assert link_idx_high < link_idx_low

    LinkDns.reset_link_dns("test_prio_high")
    LinkDns.reset_link_dns("test_prio_low")
  end

  test "effective_search_domains returns search domains ordered by priority" do
    LinkDns.set_link_dns("test_search_a", %{
      servers: [],
      search: ["high.example.com"],
      priority: 200
    })

    LinkDns.set_link_dns("test_search_b", %{
      servers: [],
      search: ["low.example.com"],
      priority: 50
    })

    domains = LinkDns.effective_search_domains()
    assert "high.example.com" in domains
    assert "low.example.com" in domains
    idx_high = Enum.find_index(domains, &(&1 == "high.example.com"))
    idx_low = Enum.find_index(domains, &(&1 == "low.example.com"))
    assert idx_high < idx_low

    LinkDns.reset_link_dns("test_search_a")
    LinkDns.reset_link_dns("test_search_b")
  end

  test "set_link_dns normalizes config (filters non-tuple servers)" do
    LinkDns.set_link_dns("test_norm", %{
      servers: [{8, 8, 8, 8}, "invalid", {1, 1, 1, 1}],
      search: ["valid.com", 123],
      priority: 100
    })

    stored = LinkDns.get("test_norm")
    assert stored.servers == [{8, 8, 8, 8}, {1, 1, 1, 1}]
    assert stored.search == ["valid.com"]

    LinkDns.reset_link_dns("test_norm")
  end

  test "reset_link_dns on non-existent interface is safe" do
    assert :ok = LinkDns.reset_link_dns("nonexistent_iface_12345")
  end

  test "facade functions work through YellowDog.Resolved module" do
    assert :ok =
             YellowDog.Resolved.set_link_dns("test_facade", %{
               servers: [{9, 9, 9, 9}],
               search: ["test.local"],
               priority: 75
             })

    stored = LinkDns.get("test_facade")
    assert stored.servers == [{9, 9, 9, 9}]

    assert :ok = YellowDog.Resolved.reset_link_dns("test_facade")
    assert LinkDns.get("test_facade") == nil
  end
end
